---
name: handover
description: |
  This skill should be used when the user asks to "handover session", "prepare next session",
  "save handover", "session handover", "entry prompt", "hand off tasks", or wants to
  prepare context for a new Claude Code session before ending the current one.
  Usage: /handover [query]
user-invocable: true
argument-hint: "[query]"
---

# Handover

Prepare a structured handover for the next Claude Code session by collecting current work state, letting the user select what to transfer, and saving as a TaskCreate entry.

## Purpose

1. Collect work state summaries from multiple sources (TaskList, git/PR, session context)
2. Present collected information via AskUserQuestion for user selection
3. Fetch details only for selected components, then compose an entry prompt
4. Save as TaskCreate entry for automatic surfacing in the next session
5. Output resume command with `CLAUDE_CODE_TASK_LIST_ID` for the next session

## Input

- `$ARGUMENTS`: Optional topic filter. If provided, scope collection to the specified topic.

## Workflow

### Step 1: Data Collection (Summaries)

Issue initial calls in parallel: TaskList, git/PR state (Bash). Session context analysis requires no tool call.

1. **Incomplete Tasks**: Call `TaskList` to get task summaries. Count non-completed tasks and note their subjects. Do NOT call TaskGet yet — defer to Step 3.
2. **Git + PR State**: Run a single Bash call:
   ```bash
   BRANCH=$(git branch --show-current) && git status -sb && gh pr list --state open --head "$BRANCH" --json number,title,url,body
   ```
   Extract: branch name, working tree status, open PR info (number, title, unchecked `- [ ]` items).
3. **Session Context**: Analyze current conversation for:
   - Key decisions made in this session
   - Discoveries or findings
   - Blocked items or open questions
   - Overall progress summary

If `$ARGUMENTS` is provided, filter tasks by subject keyword match from TaskList summaries before counting.

### Step 2: User Selection

Call `AskUserQuestion` with `multiSelect: true` to present the collected data.

Present only options where data was actually collected (skip empty sources):

```
Which information should be included in the handover?

Options (select all that apply):
1. Incomplete Tasks (N items) — [top 3 task subjects]
2. Session Context — [1-line summary of decisions/discoveries]
3. PR State — PR #N: [title], [M unchecked items]
4. Git State — branch: [name], [clean/dirty]
```

**Option rules**:
- Skip sources with no data (e.g., no open PR → omit PR option)
- If only 1 source has data, present as single-option confirmation
- If user selects no options, treat as cancellation — do not create a task
- If no data from any source, inform the user and offer to create a session-context-only handover via AskUserQuestion

### Step 3: Entry Prompt Composition

**Fetch details for selected components**: If "Incomplete Tasks" was selected, now call `TaskGet` for each non-completed task to retrieve descriptions (Current Status / Next Steps). This defers the N+1 cost to only when needed.

Compose the handover entry prompt from selected components. Use this template:

```markdown
## Handover

### Incomplete Tasks
- [ ] [task subject]
  - Current Status: [status from task description]
  - Next Steps: [steps from task description]
  - PR: #[number] (if linked)

### Session Context
- Decisions: [key decisions]
- Discoveries: [findings]
- Blocked: [blockers or open questions]

### Git State
- Branch: [current branch]
- Working tree: [clean/uncommitted changes summary]

### PR State
- PR: #[number] [title] ([M unchecked items])

### Priority
1. [highest priority item]
2. [next priority item]
```

**Composition rules**:
- Include only sections for selected components
- Priority section is generated only when 2+ actionable items exist across selected components
- Keep concise; prefer bullet points over prose
- Use checkbox format (`- [ ]`) for actionable items

### Step 4: TaskCreate

Append a source session endnote to the composed description:

```markdown
---
**Handover Source**: `<source_session_id>`
To retrieve context from the originating session: `find ~/.claude/projects/ -name "<source_session_id>.jsonl"`
```

**Obtaining `source_session_id`**: Run `ls -t ~/.claude/projects/*/*.jsonl | head -1` and extract the UUID filename (without `.jsonl` extension). Run immediately before TaskCreate. **Note**: In multi-session environments, this may return a different session's ID. Run the command immediately before TaskCreate to minimize the window for ambiguity.

Create a single TaskCreate with:

| Field | Format |
|-------|--------|
| **subject** | `Handover: [1-line summary of primary work]` |
| **description** | Entry prompt composed in Step 3 + source session endnote |
| **activeForm** | `Handover ready for next session` |
| **metadata** | `{"source": "handover", "topic": "...", "source_session_id": "..."}` |

### Metadata Schema

```json
{
  "source": "handover",
  "topic": "[primary topic or $ARGUMENTS value]",
  "source_session_id": "[current session UUID]"
}
```

### Step 5: Resume Instructions

After TaskCreate, output the resume command so the user can start a new session with the same task list.

**Obtaining the task list ID**: Run a single Bash call:
```bash
echo "${CLAUDE_CODE_TASK_LIST_ID:-}"
```

- **Named list** (env var is set): Inform that the task list is already shared and the next session will see it automatically (assuming the same env var is configured).
- **UUID-based list** (env var is empty, default): The task list ID equals the current session UUID (already obtained as `source_session_id` in Step 4). Output the resume command:

```
To resume this handover in a new session:
CLAUDE_CODE_TASK_LIST_ID=<source_session_id> claude
```

**Note**: UUID-based task directories are cleaned up at session end. The resume command must be used before starting another session in the same project, or the tasks will be lost.

## Extraction Sources

1. TaskList — incomplete task summaries (subjects, counts)
2. TaskGet — incomplete task details (deferred to Step 3, only for selected tasks)
3. Bash (`git status -sb`, `git branch --show-current`, `gh pr list`) — git and PR state in single call
4. Conversation context — decisions, discoveries, blockers from current session

## Rules

- Always call AskUserQuestion for component selection — never auto-include all data without user choice
- Respect user selection exactly — do not add unselected components to the entry prompt
- If no data from any source, inform the user and offer session-context-only handover via AskUserQuestion
- Keep the composed entry prompt concise — prefer bullet points, summarize aggressively for long task lists
- Include source_session_id in both metadata and description endnote for traceability
- Do not call TaskUpdate or TaskDelete during handover — handover is read-only collection
- task-run will skip handover tasks by default (description pattern: `## Handover`)

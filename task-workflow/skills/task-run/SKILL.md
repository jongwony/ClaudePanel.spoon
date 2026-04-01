---
name: task-run
description: |
  This skill should be used when the user asks to "run tasks", "execute tasks",
  "work through tasks", "do my tasks", "task-run", "sync tasks", "clean up tasks",
  "review stale tasks", "check task status", "handover session", "prepare next session",
  "save handover", "session handover", "hand off tasks",
  "rearrange dependencies", "reorder tasks",
  or wants to execute, sync, or handover tasks from the current session's task list.
  Usage: /task-run [--all] [--sync [--dry-run]] [--handover [query]]
user-invocable: true
argument-hint: "[--all] [--sync [--dry-run]] [--handover [query]]"
---

# Task Run

Execute, sync, or hand over tasks from the current task list.

## Purpose

Unified task lifecycle management:
1. **Execute** — Load the task list, filter eligible tasks, execute work, mark completed
2. **Sync** — Reconcile task list against codebase/PR state, surface stale tasks
3. **Handover** — Collect session state, compose an entry prompt for the next session

## Input

- `$ARGUMENTS`: Mode selector and optional context.
  - `--all`: Batch mode with pre-flight sync. Execute all eligible tasks sequentially.
  - `--sync`: Sync-only mode. Reconcile task list, no execution. Accepts `--dry-run` sub-flag.
  - `--handover [query]`: Handover mode. Collect state and compose entry prompt. Optional query filters scope.
  - (empty): Interactive mode. Show eligible tasks and let user choose one to execute.
  - Free-text after flags is passed as context (e.g., `/task-run --all static verification`).

## Argument Parsing

Parse `$ARGUMENTS`:
1. If `--handover` is present → handover mode. Text after `--handover` is the optional query.
2. If `--sync` is present → sync-only mode. Check for `--dry-run` sub-flag.
3. If `--all` is present → batch mode with pre-flight sync.
4. If empty → interactive mode.

---

## Eligibility Filter

A task is **eligible** (Ready) when ALL conditions are met:
- `status` is `pending`
- `blockedBy` is empty (no unresolved dependencies)
- `owner` is empty or matches the current agent

A task is **skipped** when ANY condition is true:
- `status` is not `pending` (already in_progress or completed)
- `blockedBy` is non-empty (blocked by other tasks)
- `owner` is set to a different agent
- Description contains `**Source Session**:` pattern (handoff task — must be executed in target project)
- Description contains `## Handover` pattern (handover task — informational context for next session, not executable)

Note: In `--all` mode, the pre-flight sync may auto-complete handover/pr-linked tasks before the eligibility check runs, reducing the skip list.

---

## Source Classification

Used by both `--all` pre-flight and `--sync` modes. Classify each pending task by source type using a two-pass approach.

Note: This skill uses the TaskGet API which does not expose metadata fields. Classification relies on description patterns and subject heuristics.

**Pass 1 — Subject-based pre-classification**:
- Subject starts with `Handover:` → `handover` type
- Subject contains `PR #` or `pr:` → likely `pr-linked` type
- Otherwise → `unknown` (needs TaskGet)

Note: Handoff tasks cannot be reliably classified from subject alone (`task-save` generates imperative verb phrase subjects). Handoff classification happens exclusively in Pass 2.

**Pass 2 — Description-based confirmation** (only for `unknown` tasks from Pass 1):
Call `TaskGet` for each unknown task and classify by description patterns:
- Contains `## Handover` → `handover`
- Contains `**Source Session**:` → `handoff` (skip — must be in target project)
- Contains `pr:` AND `checkbox_text:` → `pr-linked`
- Otherwise → `general`
- If `TaskGet` fails for a task (deleted, transient error): classify as `uncertain` and include the error in the sync report

This deferred N+1 approach minimizes TaskGet calls for well-named tasks.

---

## Execution Modes

### Interactive (no arguments)

1. Call `TaskList` to get all tasks.
2. Categorize into Ready and Skipped (with skip reason).
3. If no Ready tasks exist, report and stop.
4. If exactly one Ready task, confirm with user then execute.
5. If multiple Ready tasks, present them via `AskUserQuestion`:
   - Each option: `[ID] subject` as label, description snippet as description
   - Allow selecting one task to execute
6. Execute the selected task.

### Batch with Pre-flight Sync (`/task-run --all`)

#### Pre-flight Sync

Before batch execution, run a lightweight sync to clear stale tasks:

1. **Task loading**: Call `TaskList`. Filter to `status=pending` tasks.
2. **Source classification**: Apply the Source Classification procedure (see above).
3. **PR status comparison**: Run `gh pr list --state all --json number,state --limit 100`. Match pr-linked tasks against PR state. Mark merged/closed as likely-completed. If `gh` is not installed or fails, skip gracefully (mark as uncertain).
4. **Stale surfacing**: Display classified groups before execution:

```
## Pre-flight Sync

### PR-linked (N)
**Likely completed** (merged/closed):
  - [ID] subject — PR #X MERGED
**Still relevant** (open):
  - [ID] subject — PR #X OPEN

### Handover (N)
  - [ID] subject — [status note]

### General (N)
  - [ID] subject

### Handoff (N) — skipped (uses CLAUDE_CODE_TASK_LIST_ID path)
  - [ID] subject
```

Omit empty sections. Do NOT surface handoff tasks for action — they use the `CLAUDE_CODE_TASK_LIST_ID` path in their target project.

5. **Auto-complete**: For each likely-completed task (merged/closed PR): `TaskUpdate(taskId, status="completed")`. Independent TaskUpdate calls can be made in parallel.

#### Batch Execution

1. Display a grouped overview:
   - **Ready** (N): list subjects
   - **Skipped** (N): list subjects with skip reasons
2. If no Ready tasks, report and stop.
3. Execute Ready tasks sequentially in ID order (lowest first).
4. Between tasks, call `TaskList` to refresh state (earlier tasks may unblock later ones).

### Single Task Execution

For each task to execute (used by both interactive and batch modes):

1. **Claim**: `TaskUpdate(taskId, status="in_progress")` with activeForm from TaskGet.
2. **Read**: `TaskGet(taskId)` to get full description and requirements.
3. **Work**: Perform the described work following the task's description and next steps.
   - Follow all existing safety rules (irreversibility checks, user confirmation for destructive actions).
   - Use appropriate tools based on what the task requires.
4. **Complete**: `TaskUpdate(taskId, status="completed")` when work is done.

---

## Sync Mode (`/task-run --sync`)

Reconcile the current task list against codebase state. No task execution.

### Step 1: Task Loading

Call `TaskList` to get all tasks. Collect task summaries (id, subject, status, blockedBy).

**Guard**: If total tasks exceed 50, warn the user and ask whether to proceed or filter by status.

Filter to `status=pending` tasks only. If none exist, report "No pending tasks to sync" and stop.

### Step 2: Source Classification

Apply the Source Classification procedure (see above).

### Step 3: Codebase Comparison

For each source type, apply the appropriate comparison method:

#### PR-linked tasks

```bash
gh pr list --state all --json number,state --limit 100
```

Same command as Pre-flight Sync step 3 — classification rules are shared.

- Match task's PR number against the list.
- **Likely-completed**: PR state is `MERGED` or `CLOSED`.
- **Still-relevant**: PR state is `OPEN`.
- **Uncertain**: PR number not found in list (may be in a different repo).
- If `gh` is not installed or fails: skip PR comparison, mark all as `uncertain` with note.

#### Handover tasks

Parse the task description for checklist items (`- [ ]` / `- [x]` patterns).
For each unchecked item, search for evidence:

```bash
git log --oneline -20 --grep="<keyword>"
```

And/or use Grep to search for relevant code changes.

- **Likely-completed**: All checklist items have evidence of being addressed.
- **Still-relevant**: Some items lack evidence.
- **Uncertain**: Description has no parseable checklist.

#### Handoff tasks

Infer target directory from the task description context or subject. Note: `target_cwd` is stored in task metadata which is not accessible via TaskGet. The `**Source Session**:` endnote contains the source session UUID, not the target path. If the target cannot be inferred, ask the user or mark as `uncertain`.

If target_cwd is accessible:
```bash
git -C <target_cwd> log --oneline -5
```

- **Likely-completed**: Recent commits in target repo relate to the task subject.
- **Still-relevant**: No related commits found.
- **Uncertain**: target_cwd is not accessible or not a git repo.

#### General tasks

Search for evidence using the task subject keywords:

```bash
git log --oneline -20 --grep="<keyword>"
```

And use Grep to search for related code changes.

- **Likely-completed**: Recent commits or code changes match the task subject.
- **Still-relevant**: No matching evidence found.
- **Uncertain**: Subject is too generic to search effectively.

### Step 3.5: Stale Dependency Detection (Report-Only)

Identify stale dependencies — where a blocking task is already `completed`:
- For each pending task with non-empty `blockedBy`:
  - Check each blocking task's status
  - If blocking task is `completed` → mark dependency as **stale**
- **Action**: Report only (both default and dry-run modes). No dependency re-arrangement, no recreate pattern.

**Note**: Report only — the TaskUpdate API only supports `addBlockedBy` (no remove). TaskList auto-filters completed blockers at runtime, so stale dependencies are cosmetic.

### Step 4: Grouped Report

Present results grouped by source type, then by relevance:

```
## Task Sync Report

### PR-linked (N)
**Likely completed** (merged/closed):
  - [ID] subject — PR #X MERGED
**Still relevant** (open):
  - [ID] subject — PR #X OPEN

### Handover (N)
**Likely completed**:
  - [ID] subject — all checklist items addressed
**Still relevant**:
  - [ID] subject — 2/5 items remaining

### Handoff (N)
**Likely completed**:
  - [ID] subject → /path/to/target — related commits found
**Uncertain**:
  - [ID] subject → /path/to/target — target not accessible

### General (N)
**Likely completed**:
  - [ID] subject — matching commits found
**Still relevant**:
  - [ID] subject — no evidence found

### Stale Dependencies (N)
  - [ID] subject — stale blockedBy: [ID_completed] (blocking task completed)
  - [ID] subject — fully unblocked (all blockers completed)
```

Omit empty sections. Show task count per group.

### Step 5: Apply or Report

#### Default mode (no `--dry-run`)

1. For each `likely-completed` task: `TaskUpdate(taskId, status="completed")`. Independent calls can be made in parallel.
2. For `uncertain` tasks: keep as `pending`. Display with "(flagged by sync)" annotation in the report only — do not modify the task description.
3. For `still-relevant` tasks: no action.
4. Display summary:
   ```
   ## Sync Summary
   - Completed: N tasks
   - Flagged (uncertain): N tasks
   - Unchanged (still relevant): N tasks
   - Stale dependencies: N (auto-filtered by TaskList)
   ```

#### Dry-run mode (`--sync --dry-run`)

1. Display the grouped report from Step 4.
2. Append "DRY RUN — no tasks were modified" at the end.
3. No TaskUpdate calls.

---

## Handover Mode (`/task-run --handover [query]`)

Prepare a structured handover for the next Claude Code session by collecting current work state, letting the user select what to transfer, and saving as a TaskCreate entry.

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

If `$ARGUMENTS` query is provided after `--handover`, filter tasks by subject keyword match from TaskList summaries before counting. Scope session context analysis to the specified topic.

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

**Obtaining `source_session_id`**: Run `ls -t ~/.claude/projects/*/*.jsonl | head -1` and extract the UUID filename (without `.jsonl` extension). Run immediately before TaskCreate.

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
  "topic": "[primary topic or query value]",
  "source_session_id": "[current session UUID]"
}
```

### Step 5: Resume Instructions

After TaskCreate, output resume instructions:

1. Run `echo "${CLAUDE_CODE_TASK_LIST_ID:-}"` to check for a named list.
2. If the env var is set: inform the user the next session inherits it automatically.
3. If empty: use `source_session_id` from Step 4 as the task list ID:
   ```
   CLAUDE_CODE_TASK_LIST_ID=<source_session_id> claude
   ```
   Note: UUID-based task directories are cleaned up at session end.

---

## Failure Handling

Track `consecutiveFailures` counter (starts at 0):
- On task failure or inability to complete: increment counter, keep task as `in_progress`.
- On task success: reset counter to 0.
- If counter reaches 2: pause execution, ask user via `AskUserQuestion` whether to continue, skip, or stop.

A task "fails" when:
- Required files or dependencies are missing
- Tests fail after changes
- The task description is too ambiguous to act on
- An error occurs that cannot be resolved within 2 retry attempts

## Completion Summary

Display a summary when `--all` mode completes or when 2+ tasks were executed:

```
## Task Run Summary
- Completed: N
- Failed (in_progress): N
- Skipped: N
- Remaining pending: N
```

## Rules

### All Modes
- Never delete tasks — only complete or leave as pending.
- Never execute tasks owned by a different agent.
- Eligibility Filter rules (handoff/handover skip, owner check) apply to all execution modes.
- Follow existing CLAUDE.md irreversibility rules: confirm before destructive actions.
- Prefer executing tasks in ID order (lowest first) as earlier tasks often set up context for later ones.
- If a task's description references PR checkboxes (contains `pr:` and `checkbox_text:`), update the PR checkbox after completion per PR-Task Sync rules.
- Do not modify task descriptions or subjects — only update status.
- Skip `gh` gracefully if not installed (mark PR-related items as uncertain).
- If the user requests dependency re-arrangement or task reordering, inform them that this feature was removed in v2. Use manual `TaskUpdate` with `addBlockedBy` to manage dependencies.

### Sync Mode
- In `--sync --dry-run` mode, perform all comparisons but make zero mutations.
- Task count upper bound for sync: 50 total tasks (all statuses, before pending filter). If exceeded, warn and ask before proceeding.

### Handover Mode
- Handover: always call AskUserQuestion for component selection — never auto-include all data without user choice.
- Handover: respect user selection exactly — do not add unselected components to the entry prompt.
- Handover: include source_session_id in both metadata and description endnote for traceability.
- Handover: do not call TaskUpdate or TaskDelete — handover is read-only collection plus a single TaskCreate.

---
name: task-save
description: |
  This skill should be used when the user asks to "save current task", "save progress",
  "create task from context", "task-save", "break down tasks", "decompose work",
  or wants to capture current work state as structured tasks with dependency ordering.
  Usage: /task-save [--cwd <path>] [query]
  --cwd: Cross-project handoff (records target directory in metadata for ClaudePanel.spoon).
user-invocable: true
argument-hint: "[--cwd <path>] [query]"
---

# Task Save

Capture current work state as structured task entries with dependency ordering using TaskCreate.

## Purpose

Transform conversation context into actionable task entries by:
1. Analyzing current conversation for work state
2. Decomposing context into discrete work items when multiple are present
3. Determining execution order and dependency relationships between work items
4. Creating TaskCreate entries with blockedBy relationships

## Input

- `$ARGUMENTS`: Optional flags and topic filter.
  - `--cwd <path>`: Cross-project handoff. The path is the target project directory (absolute or relative).
  - Remaining arguments: topic filter. If omitted, analyze entire recent conversation.

## Argument Parsing

Parse `$ARGUMENTS` for `--cwd`:
1. If `--cwd <path>` is present, extract the path and resolve to absolute path using Bash `realpath`.
2. Remaining arguments after `--cwd <path>` become the topic filter.
3. If `--cwd` is absent, behave as normal task-save.

## Context Analysis

Analyze the conversation context to identify discrete work items:

1. **Scan** recent conversation for actionable work: user requests, decisions made, pending actions, blockers identified.
2. **Classify** each work item: Is it a distinct, independently describable unit of work?
3. **Count**: If 1 work item → single-task mode. If 2+ work items → multi-task mode.

**Single-task signals**: The conversation focuses on one specific change, one file, one bug, or one feature.

**Multi-task signals**: The conversation covers multiple distinct actions, a checklist, a plan with phases, or work spanning different files/components for different purposes.

## Task Decomposition (Multi-Task Mode)

When 2+ work items are identified:

### Dependency Analysis

Analyze semantic relationships between work items to determine execution order. Use your understanding of the work — not keyword matching — to judge dependencies:

- **Sequential dependency**: Task B requires the output, result, or state change from Task A → `B.blockedBy = [A.id]`
- **Shared resource dependency**: Task B modifies something that Task A creates or configures → `B.blockedBy = [A.id]`
- **Knowledge dependency**: Task B needs information or context that Task A produces → `B.blockedBy = [A.id]`
- **Independent**: Tasks operate on unrelated concerns → no blockedBy relationship

### Ordering Rules

- Earlier tasks in the dependency chain get lower IDs (created first)
- Parallelizable tasks share the same dependency depth level
- Circular dependencies indicate incorrect decomposition — re-analyze

### Creation Sequence

1. Create all tasks via TaskCreate in dependency order (roots first, dependents after)
2. After all tasks are created, set blockedBy relationships via TaskUpdate:
   ```
   TaskUpdate(taskId=<dependent>, addBlockedBy=[<dependency1>, <dependency2>])
   ```
3. TaskUpdate must be called after all TaskCreate calls complete, because blockedBy references task IDs that must exist

## Output

### Single-Task Mode

Create a single TaskCreate with:

| Field | Format |
|-------|--------|
| **subject** | Imperative verb phrase (task goal) |
| **description** | `**Current Status**: ...`<br>`**Next Steps**: ...`<br>(handoff: append source session endnote) |
| **activeForm** | Present continuous form (spinner display) |
| **metadata** | Context fields (see below) |

### Multi-Task Mode

Create N TaskCreate entries, then set dependencies:

| Step | Action |
|------|--------|
| 1 | TaskCreate for each work item (same format as single-task) |
| 2 | TaskUpdate for each task with dependencies to set blockedBy |

Each task follows the same field format as single-task mode. The description for each task should be self-contained — a reader should understand the task without needing to read other tasks in the group.

After creation, display a summary:
```
## Task Save Summary
Created N tasks with dependency graph:
- [ID1] subject (root)
- [ID2] subject (blocked by: ID1)
- [ID3] subject (blocked by: ID1, ID2)
```

### Metadata Schema

**Standard** (no `--cwd`):
```json
{"source": "task-save", "topic": "..."}
```

**Handoff** (with `--cwd`):
```json
{
  "source": "task-save",
  "handoff": true,
  "target_cwd": "/absolute/path/to/target",
  "source_cwd": "/absolute/path/to/current",
  "source_session_id": "uuid-of-current-session"
}
```

- `target_cwd`: resolved absolute path from `--cwd` argument
- `source_cwd`: current working directory (`$PWD`) at handoff time
- `source_session_id`: current session UUID (stored for future UI integration; currently consumed via the description endnote below)

**Obtaining `source_session_id`**: Run `ls -t ~/.claude/projects/*/*.jsonl | head -1` and extract the UUID filename (without `.jsonl` extension). This returns the most recently modified session file. **Note**: In multi-session environments, this may return a different session's ID. Run the command immediately before TaskCreate to minimize the window for ambiguity.

When `handoff: true`, ClaudePanel.spoon renders the task with a distinct handoff launcher that opens a new Claude session in `target_cwd` with a fresh `CLAUDE_CODE_TASK_LIST_ID`.

### Handoff Description Endnote

When `--cwd` is present, append the following endnote to the description after `**Next Steps**`:

```
---
**Source Session**: `<source_session_id>`
To retrieve context from the originating session: `find ~/.claude/projects/ -name "<source_session_id>.jsonl"`
```

Replace `<source_session_id>` with the actual UUID obtained above.

This endnote is necessary because `TaskGet` API output does not include `metadata` fields. The description endnote ensures the handoff target session can discover and read the source conversation regardless of API limitations.

## Extraction Sources

1. Conversation messages (user requests, assistant responses)
2. Tool results (Slack, Linear, file reads, etc.)
3. User's additional instructions in current message

## Rules

- Concise, actionable content only
- Single-task mode when context contains one work item; multi-task mode when 2+ distinct items are present
- Each task description must be self-contained — no cross-references to other task IDs in descriptions
- Dependency analysis uses LLM understanding of the work, not keyword matching
- Adapt structure to user's additional instructions if provided
- If context insufficient, ask user for clarification before creating tasks
- For `--cwd`: validate the path exists before creating the task
- Maximum 10 tasks per invocation — if more are identified, group related items

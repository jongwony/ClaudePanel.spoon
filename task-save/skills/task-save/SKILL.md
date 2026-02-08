---
name: task-save
description: |
  This skill should be used when the user asks to "save current task", "save progress",
  "create task from context", "task-save", or wants to capture current work state.
  Usage: /task-save [--cwd <path>] [query]
  --cwd: Cross-project handoff (records target directory in metadata for ClaudePanel.spoon).
user-invocable: true
argument-hint: "[--cwd <path>] [query]"
---

# Task Save

Capture current work state as a structured task entry using TaskCreate.

## Purpose

Transform conversation context into actionable task entries by:
1. Analyzing current conversation for work state
2. Identifying current status and pending next steps
3. Creating a concise TaskCreate entry with status and action items

## Input

- `$ARGUMENTS`: Optional flags and topic filter.
  - `--cwd <path>`: Cross-project handoff. The path is the target project directory (absolute or relative).
  - Remaining arguments: topic filter. If omitted, analyze entire recent conversation.

## Argument Parsing

Parse `$ARGUMENTS` for `--cwd`:
1. If `--cwd <path>` is present, extract the path and resolve to absolute path using Bash `realpath`.
2. Remaining arguments after `--cwd <path>` become the topic filter.
3. If `--cwd` is absent, behave as normal task-save.

## Output

Create a single TaskCreate with:

| Field | Format |
|-------|--------|
| **subject** | Imperative verb phrase (task goal) |
| **description** | `**Current Status**: ...`<br>`**Next Steps**: ...` |
| **activeForm** | Present continuous form (spinner display) |
| **metadata** | Context fields (see below) |

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
  "source_cwd": "/absolute/path/to/current"
}
```

- `target_cwd`: resolved absolute path from `--cwd` argument
- `source_cwd`: current working directory (`$PWD`) at handoff time

When `handoff: true`, ClaudePanel.spoon renders the task with a distinct handoff launcher that opens a new Claude session in `target_cwd` with a fresh `CLAUDE_CODE_TASK_LIST_ID`.

## Extraction Sources

1. Conversation messages (user requests, assistant responses)
2. Tool results (Slack, Linear, file reads, etc.)
3. User's additional instructions in current message

## Rules

- Concise, actionable content only
- Single focused task per invocation
- Adapt structure to user's additional instructions if provided
- If context insufficient, ask user for clarification before creating task
- For `--cwd`: validate the path exists before creating the task

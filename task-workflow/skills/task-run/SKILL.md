---
name: task-run
description: |
  This skill should be used when the user asks to "run tasks", "execute tasks",
  "work through tasks", "do my tasks", "task-run", or wants to execute pending tasks
  from the current session's task list.
  Usage: /task-run [--all] [task-id]
user-invocable: true
argument-hint: "[--all] [task-id]"
---

# Task Run

Execute pending tasks from the current task list sequentially.

## Purpose

Automate the TaskList → TaskGet → work → TaskUpdate(completed) loop by:
1. Loading the current task list
2. Filtering eligible tasks
3. Executing each task's described work
4. Marking completed tasks as done

## Input

- `$ARGUMENTS`: Optional mode selector.
  - `--all`: Batch mode. Execute all eligible tasks sequentially.
  - `<task-id>`: Single task mode. Execute only the specified task.
  - (empty): Interactive mode. Show eligible tasks and let user choose.

## Argument Parsing

Parse `$ARGUMENTS`:
1. If `--all` is present → batch mode.
2. If a numeric or string ID is present → single task mode.
3. If empty → interactive mode.

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

### Single Task (`/task-run <id>`)

1. Call `TaskGet` with the provided ID.
2. Verify eligibility:
   - If not eligible, explain why and stop.
   - If handoff task, explain it must be run in the target project and stop.
   - If handover task, explain it contains session context for reference and is not executable work, then stop.
3. Execute the task.

### Batch (`/task-run --all`)

1. Call `TaskList` to get all tasks.
2. Display a grouped overview before starting:
   - **Ready** (N): list subjects
   - **Skipped** (N): list subjects with skip reasons
3. If no Ready tasks, report and stop.
4. Execute Ready tasks sequentially in ID order (lowest first).
5. Between tasks, call `TaskList` to refresh state (earlier tasks may unblock later ones).

## Single Task Execution

For each task to execute:

1. **Claim**: `TaskUpdate(taskId, status="in_progress")` with activeForm from TaskGet.
2. **Read**: `TaskGet(taskId)` to get full description and requirements.
3. **Work**: Perform the described work following the task's description and next steps.
   - Follow all existing safety rules (irreversibility checks, user confirmation for destructive actions).
   - Use appropriate tools based on what the task requires.
4. **Complete**: `TaskUpdate(taskId, status="completed")` when work is done.

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

- Never execute tasks owned by a different agent.
- Always skip handoff tasks (description contains `**Source Session**:`) — these must be executed in their target project directory.
- Always skip handover tasks (description contains `## Handover`) — these are informational context for session bootstrapping, not executable work.
- Follow existing CLAUDE.md irreversibility rules: confirm before destructive actions.
- Prefer executing tasks in ID order (lowest first) as earlier tasks often set up context for later ones.
- If a task's description references PR checkboxes (contains `pr:` and `checkbox_text:`), update the PR checkbox after completion per PR-Task Sync rules.
- Do not modify task descriptions or subjects — only update status.

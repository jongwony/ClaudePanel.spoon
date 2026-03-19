---
name: task-sync
description: |
  This skill should be used when the user asks to "sync tasks", "clean up tasks",
  "task-sync", "review stale tasks", "organize tasks", "check task status",
  "rearrange dependencies", "reorder tasks",
  or wants to reconcile the current task list against codebase state.
  Usage: /task-sync [--dry-run]
user-invocable: true
argument-hint: "[--dry-run]"
---

# Task Sync

Reconcile the current task list against codebase state by comparing each task's source type to its real-world completion signals, and re-arrange dependency relationships.

## Purpose

Detect and resolve drift between TaskList entries and actual codebase/PR state:
1. Load all tasks and classify by source type
2. Compare each task against codebase signals (git log, PR state, file changes)
3. Re-arrange dependency relationships based on current context
4. Present grouped results by source, relevance, and dependency changes
5. Batch-complete likely-completed tasks (or report-only in dry-run mode)

## Input

- `$ARGUMENTS`: Optional flags.
  - `--dry-run`: Report only, no TaskUpdate calls.
  - (empty): Default mode. Complete likely-completed tasks, re-arrange dependencies, flag uncertain ones.

## Argument Parsing

Parse `$ARGUMENTS`:
1. If `--dry-run` is present → dry-run mode (no mutations).
2. If empty → default mode (complete likely-completed tasks, apply dependency changes).

## Workflow

### Step 1: Task Loading

Call `TaskList` to get all tasks. Collect task summaries (id, subject, status, blockedBy).

**Guard**: If total tasks exceed 50, warn the user and ask whether to proceed or filter by status.

Filter to `status=pending` tasks only. If none exist, report "No pending tasks to sync" and stop.

### Step 2: Source Classification

Classify each pending task by its source type using a two-pass approach.

Note: Unlike `stale-task-detector.py` which reads raw JSON metadata (direct file access), this skill uses the TaskGet API which does not expose metadata fields. Classification relies on description patterns and subject heuristics instead.

**Pass 1 — Subject-based pre-classification**:
- Subject starts with `Handover:` → likely `handover`
- Subject contains `PR #` or `pr:` → likely `pr-linked`
- Otherwise → `unknown` (needs TaskGet)

Note: Handoff tasks cannot be reliably classified from subject alone (`task-save` generates imperative verb phrase subjects, not paths). Handoff classification happens exclusively in Pass 2 via description patterns.

**Pass 2 — Description-based confirmation** (only for `unknown` tasks from Pass 1):
Call `TaskGet` for each unknown task and classify by description patterns:
- Contains `## Handover` → `handover`
- Contains `**Source Session**:` → `handoff`
- Contains `pr:` AND `checkbox_text:` → `pr-linked`
- Otherwise → `general`

This deferred N+1 approach minimizes TaskGet calls for well-named tasks.

### Step 3: Codebase Comparison

For each source type, apply the appropriate comparison method:

#### PR-linked tasks

```bash
gh pr list --state all --json number,state,mergedAt,closedAt --limit 100
```

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

### Step 3.5: Dependency Re-arrangement

After codebase comparison, analyze and update dependency relationships among pending tasks.

#### 3.5.1: Collect Current State

For each pending task, record its current `blockedBy` from TaskList. If Step 2 required TaskGet calls, reuse those results to avoid redundant calls.

#### 3.5.2: Stale Dependency Detection (Report-Only)

Identify stale dependencies — where a blocking task is already `completed`:
- For each pending task with non-empty `blockedBy`:
  - Check each blocking task's status
  - If blocking task is `completed` → mark dependency as **stale**
- **Action**: Report only (both default and dry-run modes)

**Why report-only**: The TaskUpdate API has no `removeBlockedBy` or `blockedBy` setter — only `addBlockedBy` (additive). However, stale dependencies are cosmetic: the TaskList API automatically filters out completed tasks from `blockedBy` display. So completed blockers don't affect task ordering or visibility — they only exist in raw data.

**Edge case**: When all entries in a task's `blockedBy` are stale (all blocking tasks completed), the task is already effectively unblocked — TaskList will show no `blockedBy` for it. Report this as fully unblocked in the stale detection output.

#### 3.5.3: Dependency Re-analysis

Re-analyze the remaining pending tasks for dependency relationships that should exist but don't, or that should be changed:

1. **Load context**: Read descriptions of all still-relevant and uncertain pending tasks (reuse TaskGet results from Step 2 where available; call TaskGet for any tasks not yet loaded). TaskGet calls for unloaded tasks can be made in parallel.
2. **Analyze relationships**: Use your understanding of the tasks' purposes, not keyword matching, to determine:
   - **Missing dependency**: Task B semantically requires Task A's completion, but `B.blockedBy` does not include A → **add** (via `addBlockedBy`)
   - **Incorrect dependency**: Task A is blocked by Task B, but A should actually execute first → **recreate** (see below)
   - **Unnecessary dependency**: Task B lists Task A in blockedBy, but they are actually independent → **recreate** (see below)
3. **Skip tasks marked as likely-completed** in Step 3 — they will be completed in Step 5 and need no dependency updates

**Why recreate for swap/remove**: The TaskUpdate API only supports `addBlockedBy` (additive). There is no `removeBlockedBy` or `blockedBy` setter. To correct or remove dependencies, the task must be recreated:
1. Complete the old task (`TaskUpdate(status="completed")`)
2. Create a new task with the same subject and description (`TaskCreate`)
3. Set correct dependencies on the new task (`TaskUpdate(addBlockedBy=[...])`)
4. Transfer downstream blockers: for any task that had the old task in its `blockedBy`, call `TaskUpdate(taskId=<downstream>, addBlockedBy=[<new_task_id>])` to preserve the relationship

#### 3.5.4: Dependency Change Set

Compile all dependency changes into a change set before applying:

```
Change set:
**Stale** (report-only — auto-filtered by TaskList):
- [ID_X] stale blockedBy: [ID_completed] (blocking task completed)

**Add** (apply via addBlockedBy):
- [ID_Y] add blockedBy: [ID_Z] (missing — Y requires Z's output)

**Recreate** (complete old → create new with correct deps):
- [ID_A] recreate without blockedBy: [ID_B] (unnecessary — independent tasks)
- [ID_C] recreate with swapped direction: was blocked by [ID_D], should block [ID_D] instead
```

### Step 4: Grouped View

Present results grouped by source type, then by relevance, followed by dependency changes:

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

### Dependencies (N changes)
**Stale** (report-only — auto-filtered by TaskList):
  - [ID] subject — stale blockedBy: [ID_completed] (completed)
**Added** (via addBlockedBy):
  - [ID] subject — added blockedBy: [ID_prerequisite] (reason)
**Recreated** (old completed → new created with correct deps):
  - [ID_old] → [ID_new] subject — removed unnecessary blockedBy: [ID_independent]
  - [ID_old] → [ID_new] subject — swapped direction with [ID_other] (reason)
```

Omit empty sections. Show task count per group.

### Step 5: Batch Actions

#### Default mode (no flags)

1. For each `likely-completed` task: `TaskUpdate(taskId, status="completed")`. Independent TaskUpdate calls for different tasks can be made in parallel.
2. For `uncertain` tasks: keep as `pending`, append "(flagged by task-sync)" note to display.
3. For `still-relevant` tasks: no action on status.
4. Apply dependency change set from Step 3.5:
   - **Stale**: No action (TaskList auto-filters completed blockers from display)
   - **Add**: `TaskUpdate(taskId, addBlockedBy=[<new_dependency>])`
   - **Recreate** (for swap/incorrect/unnecessary deps):
     1. `TaskUpdate(taskId=<old>, status="completed")` — complete the old task
     2. `TaskCreate(subject=<same>, description=<same>)` — create replacement task
     3. `TaskUpdate(taskId=<new>, addBlockedBy=[<correct_deps>])` — set correct dependencies
     4. For each downstream task that had `<old>` in its blockedBy: `TaskUpdate(taskId=<downstream>, addBlockedBy=[<new>])` — transfer the relationship
5. Display summary:
   ```
   ## Sync Summary
   - Completed: N tasks
   - Flagged (uncertain): N tasks
   - Unchanged (still relevant): N tasks
   - Dependencies: N stale (auto-filtered), K added, J recreated
   ```

#### Dry-run mode (`--dry-run`)

1. Display the grouped view from Step 4.
2. Append "DRY RUN — no tasks were modified" at the end.
3. No TaskUpdate calls.

## Rules

- Never delete tasks — only complete or leave as pending.
- If `gh` CLI is not installed, skip PR state checks gracefully (mark as uncertain).
- If a handoff task's `target_cwd` is not accessible, mark as uncertain (do not error).
- Task count upper bound: 50 total tasks (all statuses, before pending filter). If exceeded, warn and ask before proceeding.
- Respect existing CLAUDE.md irreversibility rules: TaskUpdate status changes are reversible.
- Do not modify task descriptions or subjects in-place — only update status and dependencies. When dependencies need correction (swap/remove), recreate the task with the same subject and description.
- In dry-run mode, perform all comparisons and dependency analysis but make zero mutations.
- Skip dependency re-analysis for tasks classified as likely-completed — they will be completed in Step 5.
- When updating dependencies via `addBlockedBy`, preserve any existing valid dependencies — only add new ones or recreate tasks as identified in the change set.

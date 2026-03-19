---
name: task-sync
description: |
  This skill should be used when the user asks to "sync tasks", "clean up tasks",
  "task-sync", "review stale tasks", "organize tasks", "check task status",
  or wants to reconcile the current task list against codebase state.
  Usage: /task-sync [--dry-run]
user-invocable: true
argument-hint: "[--dry-run]"
---

# Task Sync

Reconcile the current task list against codebase state by comparing each task's source type to its real-world completion signals.

## Purpose

Detect and resolve drift between TaskList entries and actual codebase/PR state:
1. Load all tasks and classify by source type
2. Compare each task against codebase signals (git log, PR state, file changes)
3. Present grouped results by source and relevance
4. Batch-complete likely-completed tasks (or report-only in dry-run mode)

## Input

- `$ARGUMENTS`: Optional flags.
  - `--dry-run`: Report only, no TaskUpdate calls.
  - (empty): Default mode. Complete likely-completed tasks, flag uncertain ones.

## Argument Parsing

Parse `$ARGUMENTS`:
1. If `--dry-run` is present → dry-run mode (no mutations).
2. If empty → default mode (complete likely-completed tasks).

## Workflow

### Step 1: Task Loading

Call `TaskList` to get all tasks. Collect task summaries (id, subject, status).

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

### Step 4: Grouped View

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
```

Omit empty sections. Show task count per group.

### Step 5: Batch Actions

#### Default mode (no flags)

1. For each `likely-completed` task: `TaskUpdate(taskId, status="completed")`.
2. For `uncertain` tasks: keep as `pending`, append "(flagged by task-sync)" note to display.
3. For `still-relevant` tasks: no action.
4. Display summary:
   ```
   ## Sync Summary
   - Completed: N tasks
   - Flagged (uncertain): N tasks
   - Unchanged (still relevant): N tasks
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
- Do not modify task descriptions or subjects — only update status.
- In dry-run mode, perform all comparisons but make zero mutations.

---
name: ship
description: |
  This skill should be used when the user asks to "ship", "ship it",
  "commit and create PR with tasks", "commit push pr and register tasks",
  or wants to commit, push, create a pull request, AND register test plan items as tasks.
  This combines the commit-push-pr workflow with automatic task registration from PR checklists.
  Use this skill instead of commit-push-pr when the user wants test plan tracking.
  Usage: /ship
user-invocable: true
argument-hint: ""
allowed-tools: Bash(git checkout --branch:*), Bash(git add:*), Bash(git status:*), Bash(git push:*), Bash(git commit:*), Bash(gh pr create:*), Bash(gh pr view:*), TaskCreate
---

# Ship

Commit, push, create a pull request, then register test plan checklist items as classified tasks.

## Purpose

Extends the standard commit-push-pr workflow with task registration: after PR creation, extract `- [ ]` items from the PR body, classify each by type, confirm with the user, and create tasks with metadata linking back to the PR.

## Workflow

### Phase 1: Commit, Push, PR

Follow the standard commit-push-pr flow:

1. Read current git status, diff, and branch
2. Create a new branch if on main
3. Create a single commit with an appropriate message
4. Push the branch to origin
5. Create a pull request using `gh pr create`

All git operations should be done in a single message with parallel tool calls where possible, exactly as commit-push-pr does.

### Phase 2: Extract Checklist Items

After PR creation:

1. Run `gh pr view --json number,body,url` to read the created PR
2. Parse the PR body for the `## Test plan` section
3. Extract all top-level `- [ ]` (unchecked) items from that section. Ignore indented (nested) checklist items — only lines starting with `- [ ]` at the section's base indentation level.
4. Stop at the "Generated with" footer line or end of body
5. Ignore `- [x]` items (already completed)

**Guard**: If no `## Test plan` section exists or no `- [ ]` items found, inform the user and stop. Do not create tasks.

### Phase 3: Classify Items

Classify each extracted item into one of four types, applying rules in priority order:

**Priority 1 — `executable`**: Item contains a command in backticks that Claude can run.
Detection: backtick-wrapped content matching executable patterns — shell commands (`lua`, `node`, `python`, `grep`, `echo`), slash commands (`/verify`, `/task-run`), or CLI invocations.
Task behavior: can be executed by `/task-run --all` in the current or next session.

**Priority 2 — `ci`**: Item depends on CI pipeline results.
Detection: contains "CI", "pipeline", "workflow", "review pass", "GitHub Actions" without an executable command.
Task behavior: verify via `gh run list` or `gh pr checks` after push.

**Priority 3 — `post-merge`**: Item requires merge or a separate session to verify.
Detection: contains keywords indicating post-merge context — new session, reload, restart, next session, after merge, plugin reload, routing, deploy (in any language matching the PR body).
Task behavior: carried to next session as a handover-style task.

**Priority 4 — `manual`** (default): Item requires human interaction or visual confirmation.
Detection: none of the above patterns match. Typically UI checks, visual verification, keyboard interaction.
Task behavior: surfaced in ClaudePanel for user to manually check off.

### Phase 4: User Confirmation

Present the classified items via `AskUserQuestion`. Group items by type, showing the count per type and listing each item under its classification.

The user can:
- Confirm as-is
- Reclassify specific items (e.g., "move item 3 to post-merge")
- Remove items they don't want tracked
- Cancel task registration entirely

### Phase 5: Create Tasks

For each confirmed item, call `TaskCreate`:

| Field | Value |
|-------|-------|
| **subject** | Checklist text (cleaned, without leading `- [ ]`) |
| **description** | `pr: N\ncheckbox_text: [original text]\ntype: [executable|ci|post-merge|manual]` |
| **metadata** | `{"source": "pr-checklist", "pr": N, "type": "[type]", "checkbox_text": "[text]"}` |

**Ordering and dependencies**:
- Create `executable` tasks first (lowest IDs), then `ci`, then `post-merge`, then `manual`
- No blockedBy relationships between items (they are independent checklist items)

**Batch creation**: TaskCreate calls for independent tasks can be made in parallel.

After task creation, output a summary showing the count per type with a brief note on each type's expected handling (executable: run now, ci: await pipeline, post-merge: verify after merge, manual: user checks).

## Input

- `$ARGUMENTS`: None expected. The skill reads git state directly.

## Rules

- Always create a PR first, then register tasks. Never create tasks without a successful PR.
- Respect the user's classification corrections in Phase 4 — do not re-classify after user confirmation.
- If `gh` CLI is not available, complete the git workflow but skip task registration with a warning.
- Do not modify PR body or add task IDs back to the PR. Tasks reference the PR, not vice versa.
- If the user cancels task registration in Phase 4, the PR is still created successfully — only task creation is skipped.
- PR body language follows the repository's conventions (check recent PR history for language preference).

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

Commit, push, create a pull request, then auto-register the immediately-actionable test plan checklist items as tasks. Deferred items (`ci`, `post-merge`) are summarized, not tracked.

## Purpose

Extends the standard commit-push-pr workflow with task registration: after PR creation, extract `- [ ]` items from the PR body, classify each by type, and automatically create tasks for the immediately-actionable items with metadata linking back to the PR. Deferred items (`ci`, `post-merge`) are reported in the closing summary only — not tracked as tasks, because linking a task to a later session requires belatedly wiring up `CLAUDE_CODE_TASK_LIST_ID`, which defeats the purpose of leaving only here-and-now work in the task list.

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

Classify each extracted item into one of four types, applying rules in priority order. The type determines the outcome: **immediate** types (`executable`, `manual`) become tracked tasks; **deferred** types (`ci`, `post-merge`) appear in the closing summary only.

**Priority 1 — `executable`**: Item contains a command in backticks that Claude can run.
Detection: backtick-wrapped content matching executable patterns — shell commands (`lua`, `node`, `python`, `grep`, `echo`), slash commands (`/verify`), or CLI invocations.
Outcome: **tracked task** — surfaced in ClaudePanel for execution in the current or a later session.

**Priority 2 — `ci`**: Item depends on CI pipeline results.
Detection: contains "CI", "pipeline", "workflow", "review pass", "GitHub Actions" AND no backtick-wrapped executable command matching Priority 1 patterns.
Outcome: **summary only** — never created as a task. CI results are auto-verifiable via `gh pr checks` / `gh run list`; listed in the closing summary for transparency.

**Priority 3 — `post-merge`**: Item requires merge or a separate session to verify.
Detection: no executable command (Priority 1) AND no CI keywords (Priority 2) AND contains keywords indicating post-merge context — new session, reload, restart, next session, after merge, plugin reload, routing, deploy (in any language matching the PR body).
Outcome: **summary only** — never created as a task. Verifying it would require a separate/later session and after-the-fact `CLAUDE_CODE_TASK_LIST_ID` wiring; listed in the closing summary instead.

**Priority 4 — `manual`** (default): Item requires human interaction or visual confirmation.
Detection: none of the above patterns match. Typically UI checks, visual verification, keyboard interaction.
Outcome: **tracked task** — surfaced in ClaudePanel and actionable in the current session: resolvable by Claude via browser-use / computer-use, or checked off manually by the user.

### Phase 4: Create Tasks & Summarize

For each `executable` and `manual` item, call `TaskCreate`. Creation is automatic — there is no user confirmation step. The classification fully determines the outcome, so no choice needs to be presented. `ci` and `post-merge` items are never created as tasks; they appear in the closing summary only.

| Field | Value |
|-------|-------|
| **subject** | Checklist text (cleaned, without leading `- [ ]`) |
| **description** | `pr: N\ncheckbox_text: [original text]\ntype: [executable|manual]` |
| **metadata** | `{"source": "pr-checklist", "pr": N, "type": "[type]", "checkbox_text": "[text]"}` |

**Ordering and dependencies**:
- Create `executable` tasks first (lowest IDs), then `manual`
- No blockedBy relationships between items (they are independent checklist items)

**Batch creation**: TaskCreate calls for independent tasks can be made in parallel.

**Failure handling**: If any TaskCreate call fails during batch creation, report partial results:
- List successfully registered items with their task IDs
- List failed items with error reason
- Do not silently continue — the user must know which items were not tracked

After task creation, output a summary:
- **Created tasks** — count, with a handling note per type (executable: run now; manual: resolve via browser-use / computer-use, or user check in ClaudePanel)
- **Not tracked** — list the `ci` and `post-merge` items as informational only, with how to verify each (ci: `gh pr checks`; post-merge: re-check in a later session)

## Input

- `$ARGUMENTS`: None expected. The skill reads git state directly.

## Rules

- Always create a PR first, then register tasks. Never create tasks without a successful PR.
- Only `executable` and `manual` items become tasks; `ci` and `post-merge` are summarized, never tracked.
- Task creation is automatic — do not present a confirmation gate. The classification is deterministic, so there is no choice to confirm; if a misclassification surfaces later, the user can adjust the task directly.
- If `gh` CLI is not available, complete the git workflow but skip task registration with a warning.
- Do not modify PR body or add task IDs back to the PR. Tasks reference the PR, not vice versa.
- PR body language follows the repository's conventions (check recent PR history for language preference).

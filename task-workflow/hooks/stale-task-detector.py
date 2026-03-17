#!/usr/bin/env python3
"""
SessionStart hook: Surface stale PR-linked and handover tasks at session startup.

Scans all task directories for tasks with status=pending and either metadata.pr
or metadata.source="handover", then injects them as additionalContext.

Design:
- Only runs on source="startup" (skips resume, compact)
- Scans ~/.claude/tasks/*/ for pending tasks with metadata.pr or metadata.source="handover"
- Outputs additionalContext listing stale PR-linked tasks and handover tasks
- Fail-open: all errors → silent exit
"""

import json
import sys
from pathlib import Path


def log(msg: str) -> None:
    """Log to stderr with hook prefix."""
    print(f"[stale-task-detector] {msg}", file=sys.stderr)


TASKS_DIR = Path.home() / ".claude" / "tasks"
MAX_PR_DISPLAY = 20
MAX_HANDOVER_DISPLAY = 5


def find_pending_tasks() -> dict[str, list[dict]]:
    """Find all pending tasks that have metadata.pr or metadata.source='handover'.

    Returns pre-partitioned dict: {"pr": [...], "handover": [...]}.
    """
    result = {"pr": [], "handover": []}

    if not TASKS_DIR.is_dir():
        return result

    try:
        for session_dir in TASKS_DIR.iterdir():
            if not session_dir.is_dir():
                continue
            try:
                for task_file in session_dir.iterdir():
                    if task_file.suffix != ".json":
                        continue
                    try:
                        with task_file.open() as f:
                            data = json.load(f)
                        if data.get("status") != "pending":
                            continue
                        metadata = data.get("metadata", {})
                        if not isinstance(metadata, dict):
                            continue
                        pr_num = metadata.get("pr", "")
                        task_source = metadata.get("source", "")
                        if not pr_num and task_source != "handover":
                            continue
                        entry = {
                            "session": session_dir.name,
                            "task_id": task_file.stem,
                            "subject": data.get("subject", "(no subject)"),
                        }
                        # Detection: this hook uses metadata.source (direct JSON access).
                        # task-run uses description pattern "## Handover" (TaskGet API).
                        # Handover takes priority over PR when both metadata fields present.
                        if task_source == "handover":
                            entry["topic"] = metadata.get("topic", "")
                            entry["description"] = data.get("description", "")
                            entry["mtime"] = task_file.stat().st_mtime
                            result["handover"].append(entry)
                        else:
                            entry["pr"] = str(pr_num)
                            entry["repo"] = metadata.get("repo", "")
                            result["pr"].append(entry)
                    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as e:
                        log(f"Skipping {task_file.name}: {type(e).__name__}: {e}")
                        continue
            except OSError as e:
                log(f"Error scanning {session_dir.name}: {e}")
                continue
    except OSError as e:
        log(f"Error scanning tasks directory: {e}")

    return result


def main():
    try:
        input_data = sys.stdin.read()
        if not input_data.strip():
            sys.exit(0)

        hook_input = json.loads(input_data)

        hook_source = hook_input.get("source", "")
        if hook_source != "startup":
            sys.exit(0)

        grouped = find_pending_tasks()
        pr_tasks = grouped["pr"]
        handover_tasks = grouped["handover"]
        if not pr_tasks and not handover_tasks:
            sys.exit(0)

        lines = []
        if pr_tasks:
            lines.append(f"Stale PR-linked tasks detected ({len(pr_tasks)}):")
            for t in pr_tasks[:MAX_PR_DISPLAY]:
                repo_info = f" [{t.get('repo', '')}]" if t.get("repo") else ""
                lines.append(f"  - PR {t['pr']}{repo_info}: {t['subject']} (session: {t['session'][:8]}...)")

        if handover_tasks:
            handover_tasks.sort(key=lambda t: t.get("mtime", 0), reverse=True)
            lines.append(f"\nHandover tasks from previous sessions ({len(handover_tasks)}):")
            for i, t in enumerate(handover_tasks[:MAX_HANDOVER_DISPLAY]):
                topic_info = f" [{t['topic']}]" if t.get("topic") else ""
                task_id = t["task_id"]
                if i == 0:
                    # Most recent: inject full description
                    desc = t.get("description", "")
                    if desc:
                        lines.append(f"\n--- Handover{topic_info} (session: {t['session'][:8]}...) ---")
                        lines.append(desc)
                        lines.append(f'After reviewing, complete: TaskUpdate(taskId="{task_id}", status="completed")')
                        lines.append("--- end ---")
                    else:
                        lines.append(f"  - {t['subject']}{topic_info} (session: {t['session'][:8]}..., id: {task_id})")
                else:
                    # Older: one-line summary to bound context window cost
                    lines.append(f'  - {t["subject"]}{topic_info} (session: {t["session"][:8]}...) — TaskGet("{task_id}") to review')

        if pr_tasks:
            lines.append("\nReview PR-linked tasks: complete, update, or delete as appropriate.")
        if handover_tasks:
            lines.append("\nComplete handover tasks after reviewing to prevent re-injection on next session start.")

        context = "\n".join(lines)

        output = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": context,
            }
        }
        print(json.dumps(output))
        sys.exit(0)

    except Exception as e:
        log(f"Unexpected error: {type(e).__name__}: {e}")
        sys.exit(0)  # Fail-open


if __name__ == "__main__":
    main()

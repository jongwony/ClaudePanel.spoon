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


TASKS_DIR = Path.home() / ".claude" / "tasks"


def find_pending_tasks() -> list[dict]:
    """Find all pending tasks that have metadata.pr or metadata.source='handover'."""
    if not TASKS_DIR.is_dir():
        return []

    results = []
    try:
        for session_dir in TASKS_DIR.iterdir():
            if not session_dir.is_dir():
                continue
            try:
                for task_file in session_dir.iterdir():
                    if task_file.suffix != ".json":
                        continue
                    try:
                        data = json.loads(task_file.read_text())
                        if data.get("status") != "pending":
                            continue
                        metadata = data.get("metadata", {})
                        if not isinstance(metadata, dict):
                            continue
                        pr_num = metadata.get("pr", "")
                        source = metadata.get("source", "")
                        if not pr_num and source != "handover":
                            continue
                        entry = {
                            "session": session_dir.name,
                            "task_id": task_file.stem,
                            "subject": data.get("subject", "(no subject)"),
                            "kind": "handover" if source == "handover" else "pr",
                        }
                        if pr_num:
                            entry["pr"] = str(pr_num)
                            entry["repo"] = metadata.get("repo", "")
                        if source == "handover":
                            entry["topic"] = metadata.get("topic", "")
                        results.append(entry)
                    except (json.JSONDecodeError, OSError):
                        continue
            except OSError:
                continue
    except OSError:
        pass

    return results


def main():
    try:
        input_data = sys.stdin.read()
        if not input_data.strip():
            sys.exit(0)

        hook_input = json.loads(input_data)

        # Only run on startup (not resume or compact)
        source = hook_input.get("source", "")
        if source != "startup":
            sys.exit(0)

        tasks = find_pending_tasks()
        if not tasks:
            sys.exit(0)

        pr_tasks = [t for t in tasks if t["kind"] == "pr"]
        handover_tasks = [t for t in tasks if t["kind"] == "handover"]

        lines = []
        if pr_tasks:
            lines.append(f"Stale PR-linked tasks detected ({len(pr_tasks)}):")
            for t in pr_tasks[:20]:
                repo_info = f" [{t.get('repo', '')}]" if t.get("repo") else ""
                lines.append(f"  - PR {t['pr']}{repo_info}: {t['subject']} (session: {t['session'][:8]}...)")

        if handover_tasks:
            lines.append(f"\nHandover tasks from previous sessions ({len(handover_tasks)}):")
            for t in handover_tasks[:5]:
                topic_info = f" [{t['topic']}]" if t.get("topic") else ""
                lines.append(f"  - {t['subject']}{topic_info} (session: {t['session'][:8]}...)")
            lines.append("  Use TaskGet to read handover entry prompts.")

        lines.append("\nConsider reviewing these tasks: complete, update, or delete as appropriate.")

        context = "\n".join(lines)

        output = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": context,
            }
        }
        print(json.dumps(output))
        sys.exit(0)

    except Exception:
        sys.exit(0)  # Fail-open


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
SubagentStart hook: Inject TaskCreate persistence context into subagents.

Anti-silencing mechanism: ensures subagent findings survive coordinator synthesis
by prompting subagents to register actionable findings as Tasks directly.

Matcher: ^(?!Bash$|Explore$) — excludes simple utility subagents.
"""

import json
import sys


def log(msg: str) -> None:
    print(f"[subagent-task-persist] {msg}", file=sys.stderr)


def main():
    try:
        hook_input = json.load(sys.stdin)
    except (ValueError, OSError) as e:
        log(f"Failed to read hook input: {type(e).__name__}: {e}")
        return

    agent_type = hook_input.get("agent_type", "unknown")
    log(f"Injecting TaskCreate context for agent_type={agent_type}")

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SubagentStart",
            "additionalContext": (
                "If your analysis produces actionable findings "
                "(bugs, gaps, issues, recommendations), "
                "register each via TaskCreate before returning results. "
                "This ensures findings persist beyond coordinator synthesis."
            ),
        }
    }
    print(json.dumps(output))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Unexpected error: {type(e).__name__}: {e}")
        sys.exit(1)

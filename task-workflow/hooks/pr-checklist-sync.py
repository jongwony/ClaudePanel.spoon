#!/usr/bin/env python3
"""
PostToolUse hook: Detect PR creation and prompt TaskCreate for unchecked items.

Triggers on: gh pr create
Output: additionalContext if PR body contains unchecked items (- [ ])
"""

import json
import re
import subprocess
import sys


def log(msg: str) -> None:
    """Log to stderr with hook prefix."""
    print(f"[pr-checklist-sync] {msg}", file=sys.stderr)


def get_pr_body(pr_url: str) -> str | None:
    """Fetch PR body using gh CLI."""
    try:
        result = subprocess.run(
            ["gh", "pr", "view", pr_url, "--json", "body", "-q", ".body"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        log(f"gh pr view failed (exit {result.returncode}): {result.stderr.strip() or 'no error message'}")
    except subprocess.TimeoutExpired:
        log(f"gh pr view timed out after 10s for {pr_url}")
    except FileNotFoundError:
        log("gh CLI not found. Install with: brew install gh")
    return None


def has_unchecked_items(body: str) -> bool:
    """Check if PR body contains unchecked checklist items."""
    return bool(re.search(r"- \[ \]", body))


def main():
    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        log(f"Failed to parse hook input: {e}")
        return

    tool_input = hook_input.get("tool_input")
    if not isinstance(tool_input, dict):
        log(f"Unexpected tool_input type: {type(tool_input).__name__}")
        return

    command = tool_input.get("command", "")
    if "gh pr create" not in command:
        return

    tool_response = hook_input.get("tool_response", {})
    stdout = tool_response.get("stdout", "")

    # Extract PR URL from stdout (gh pr create outputs the URL)
    pr_url_match = re.search(r"https://github\.com/[^\s]+/pull/\d+", stdout)
    if not pr_url_match:
        if stdout.strip():
            log(f"Could not extract PR URL from stdout: {stdout[:200]}")
        return

    pr_url = pr_url_match.group(0)
    pr_body = get_pr_body(pr_url)

    if not pr_body or not has_unchecked_items(pr_body):
        return

    # Output feedback for Claude
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "PR has unchecked items. Call TaskCreate for each checklist item.",
        }
    }
    print(json.dumps(output))


if __name__ == "__main__":
    main()

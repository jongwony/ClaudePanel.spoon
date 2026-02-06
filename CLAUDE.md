# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClaudeTasks.spoon is a Hammerspoon Spoon that provides a floating WebView-based task viewer for Claude Code tasks stored in `~/.claude/tasks/`.

## Architecture

Modular Spoon architecture with coordinator pattern:

```
ClaudeTasks.spoon/
├── init.lua              # Thin coordinator, routes WebView actions to modules
├── lib/
│   ├── utils.lua         # Pure utilities: log, file ops, JSON, HTML escape
│   ├── discovery.lua     # CLI/terminal app discovery
│   ├── state.lua         # State persistence and session management
│   ├── tasks.lua         # Task loading and CWD extraction
│   ├── html.lua          # HTML/CSS/JS generation
│   ├── webview.lua       # WebView management (main, detail, quickTask)
│   ├── watcher.lua       # File system watcher with debounce
│   └── updater.lua       # GitHub release update checker
├── state.json
└── docs.json
```

### Module Loading

Hammerspoon Spoons cannot use `require()`. Uses `loadfile()` pattern:
```lua
local function loadModule(name)
    local path = obj.spoonPath .. "/lib/" .. name .. ".lua"
    local f, err = loadfile(path)
    if not f then error("Failed to load " .. name .. ": " .. err) end
    return f()
end
```

### Circular Dependency Solution

WebView callbacks reference `obj` methods. Solved via action handler injection:
```lua
-- init.lua: Action handler passed to webview module
local function actionHandler(action, params)
    if action == "setSession" then obj:setTaskListId(params.value)
    elseif action == "createTask" then obj:createTask(params.subject)
    -- ...
    end
end

-- webview.lua: Receives callback, no direct obj reference
function M.createUserContent(actionHandler, log)
    usercontent:setCallback(function(msg)
        actionHandler(msg.body.action, msg.body)
    end)
end
```

### JS-Lua Bridge

WebView communicates with Lua via `hs.webview.usercontent`. JavaScript calls `webkit.messageHandlers.taskBridge.postMessage()` which triggers the `userContentController` callback in Lua.

### Mode System (html.lua)

UI has two input modes managed by `currentMode` variable:
- `'session'` - Session ID input (default)
- `'search'` - Task filtering

Key functions:
- `setMode(mode)` - Switch mode, release task focus, focus input field
- `releaseToNavigation()` - Blur input, clear task focus for j/k navigation
- `toggleMode()` - Toggle between modes (for button click)

### Task File Structure

Tasks are stored in `~/.claude/tasks/{sessionId}/*.json`. Each session directory contains individual task JSON files.

### CWD Path Encoding

Claude Code encodes working directory paths in session IDs:
- `/` → `-` (path separator)
- `.` → `-` (dot in filenames, e.g., `ClaudeTasks.spoon` → `ClaudeTasks-spoon`)
- `/.` → `--` (dot directories, e.g., `/.claude` → `--claude`)

The `tasks.decodeCwdPath()` function resolves ambiguity by backtracking through all interpretations of `-` (as `/`, `.`, or literal `-`) and validating against the filesystem. This is critical for the "Launch Claude" feature.

## Development Commands

**Unit tests**: Run with pure Lua (no Hammerspoon required):
```bash
lua tests/test_tasks.lua
```

**Integration testing**: Reload in Hammerspoon console:
```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:start()
```

**Debug mode**: Enable logging via `spoon.ClaudeTasks:configure({debugMode = true})`

## Key Conventions

- **State persistence**: `currentTaskListId` and `lastUpdateCheck` persisted to `state.json`
- **External tools**: Always auto-discovered, never hardcoded paths
- **Task sorting**: Numeric IDs first, then string IDs alphabetically
- **Debounce pattern**: Timer-based debounce for file watcher events (0.2s default)
- **iTerm2 handling**: Uses AppleScript instead of `-e` flag (doesn't support shell args)
- **Completed tasks cap**: Only 5 most recent shown to avoid clutter

## Update Checker

Built-in update checker uses GitHub API to check for new releases:

- **Auto-check**: Runs on `start()` with 24-hour interval (configurable)
- **Manual check**: `spoon.ClaudeTasks:checkForUpdates(true)`
- **Disable**: `spoon.ClaudeTasks:configure({checkForUpdates = false})`

SpoonInstall compatible via `docs.json` metadata file.

## Public API

See README.md for complete API documentation. Key methods:
- `obj:start()`, `obj:stop()`, `obj:show()`, `obj:hide()`, `obj:toggle()`
- `obj:refresh()`, `obj:setTaskListId()`, `obj:createTask()`, `obj:quickTaskUpdate()`
- `obj:launchClaudeWithTaskList()`, `obj:launchClaudeWithCwd()`, `obj:launchClaudeWithSession()`, `obj:launchClaudeHandoff()`
- `obj:configure()`, `obj:checkForUpdates()`, `obj:status()`, `obj:bindHotkeys()`, `obj:bindShortcuts()`

### Launch Methods

- `launchClaudeWithCwd(sessionId, cwd)` - Resume session (`-r` flag) and cd to working directory
- `launchClaudeWithSession(sessionId)` - Launch with `CLAUDE_CODE_TASK_LIST_ID` env var only (for tasks without cwd)
- `launchClaudeHandoff(sessionId, targetCwd)` - Cross-project handoff: same task list, new conversation, different cwd (no `-r` flag)

### Cross-Project Handoff

Tasks with `metadata.handoff = true` and `metadata.target_cwd` are rendered with a distinct purple launch button (⤴). Created via `/task-save --cwd <path>`.

Key difference from resume: handoff shares the task list (`CLAUDE_CODE_TASK_LIST_ID`) but starts a fresh conversation without `-r`. Uses `export CLAUDE_CODE_TASK_LIST_ID=... && claude` (not inline `VAR=val cmd`) to ensure env var propagation.

Handoff metadata schema:
```json
{"source": "task-save", "handoff": true, "target_cwd": "/abs/path", "source_cwd": "/abs/current"}
```

UI helpers in `html.lua`: `generateLaunchBtn(task, utils)` and `generateCwdDisplay(task, utils)` handle both regular and handoff task rendering.

## Quick Task Implementation

Quick Task uses Claude CLI with ephemeral flags to avoid side effects:
```bash
claude -p --model haiku --no-session-persistence --disable-slash-commands \
  --strict-mcp-config --dangerously-skip-permissions --setting-sources ""
```

## Keyboard Shortcuts

WebView embedded shortcuts (in `html.lua`):

**Navigation (vim-like, Korean keyboard mappings supported)**:
- `j` - Next task
- `k` - Previous task
- `Space` - View task detail
- `Enter` - Launch Claude session for focused task
- `Cmd+Backspace` - Delete task (with confirmation)

**Mode switching (global, works even in input fields)**:
- `/` - Search mode (filter tasks by subject/description)
- `=` - Session input mode
- `Escape` / `Ctrl+[` - Return to navigation mode

**Other**:
- `Cmd+Enter` - Create task from input
- `Cmd+E` - Open Quick Task dialog
- `?` - Toggle keyboard shortcuts help popup

Default Hammerspoon hotkeys (configurable via `bindHotkeys`):
- `Opt+.` - Toggle task viewer (focuses window for keyboard input)
- `Cmd+Alt+T` - Show status summary

### Customizable Shortcuts (`bindShortcuts`)

WebView navigation shortcuts are customizable via `obj:bindShortcuts()`. The default bindings are defined in `obj.defaultShortcuts`:

```lua
obj.defaultShortcuts = {
    navigateDown = {modifiers = {}, keys = {'j', 'ㅓ', 'ArrowDown'}},
    navigateUp = {modifiers = {}, keys = {'k', 'ㅏ', 'ArrowUp'}},
    deleteTask = {modifiers = {'cmd'}, keys = {'Backspace'}},
    openTask = {modifiers = {}, keys = {' '}},
    launchTask = {modifiers = {}, keys = {'Enter'}},
}
```

**Binding format**:
- `modifiers`: Array of modifier keys (`'cmd'`, `'alt'`, `'ctrl'`, `'shift'`)
- `keys`: Array of key names (supports multiple keys for same action, e.g., Korean keyboard)

**Usage**:
```lua
spoon.ClaudeTasks:bindShortcuts({
    deleteTask = {modifiers = {'cmd', 'shift'}, keys = {'Backspace', 'Delete'}},
})
```

Partial overrides are supported - only specified bindings are changed, others use defaults.

## Dependencies

- Hammerspoon (macOS)
- Claude Code CLI (`claude` command)
- Terminal: Ghostty, iTerm2, or Terminal.app

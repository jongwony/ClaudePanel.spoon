# ClaudeTasks.spoon

Hammerspoon Spoon for viewing Claude Code tasks in a floating window.

## Demo

![Clipboard-20260129-135743-665](https://github.com/user-attachments/assets/fab18506-2a2a-4fcc-adfc-f30a96ff31c3)

## Features

- Floating task viewer with WebView UI
- **Vim-like keyboard navigation** (j/k or ↑/↓ to move, Space to view, Enter to launch)
- **Customizable key bindings** - configure all keyboard shortcuts
- **Task deletion** with keyboard shortcut (⌘⌫)
- **Task search/filtering** with real-time results
- Auto-refresh on file changes via pathwatcher
- Session selector with datalist autocomplete
- Quick TaskUpdate via dialog (⌘E)
- Launch Claude session in terminal (▶ button)
- Task detail view with metadata display
- Keyboard shortcuts help popup (?)

## Installation

### Option 1: Clone and Symlink (Recommended for development)

```bash
git clone https://github.com/jongwony/ClaudeTasks.spoon.git
ln -sf $(pwd)/ClaudeTasks.spoon ~/.hammerspoon/Spoons/ClaudeTasks.spoon
```

### Option 2: Direct Download

Download and extract to `~/.hammerspoon/Spoons/ClaudeTasks.spoon/`

## Usage

Add to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:bindHotkeys(spoon.ClaudeTasks.defaultHotkeys)
spoon.ClaudeTasks:start()
```

### Default Hotkeys

| Hotkey | Action |
|--------|--------|
| `opt+.` | Toggle task viewer |
| `cmd+alt+T` | Show task status summary |

### In-App Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j` / `k` / `↓` / `↑` | Navigate tasks |
| `Space` | View task detail |
| `Enter` | Launch Claude session |
| `⌘⌫` | Delete selected task |
| `/` | Search mode |
| `=` | Session input mode |
| `Escape` | Return to navigation |
| `?` | Show shortcuts help |
| `⌘E` | Quick Task dialog |
| `⌘Enter` | Create task |

All keyboard shortcuts can be customized via `bindShortcuts()`.

### Custom Configuration

```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:configure({
    width = 500,
    height = 700,
    margin = 30,
    debugMode = true,
    -- Specify paths explicitly if auto-discovery fails
    claudePath = "/usr/local/bin/claude",
    terminalApp = "/Applications/iTerm.app/Contents/MacOS/iTerm2",
    shell = "/bin/bash",
})
spoon.ClaudeTasks:bindHotkeys({
    toggle = {{"cmd", "shift"}, "t"},
    status = {{"cmd", "alt"}, "t"}
})
-- You can customize all in-app keyboard shortcuts
spoon.ClaudeTasks:bindShortcuts({
    navigateDown = {modifiers = {}, keys = {'j', 'ㅓ', 'ArrowDown'}},
    navigateUp = {modifiers = {}, keys = {'k', 'ㅏ', 'ArrowUp'}},
    deleteTask = {modifiers = {'cmd'}, keys = {'Backspace'}},
    openTask = {modifiers = {}, keys = {' '}},
    launchTask = {modifiers = {}, keys = {'Enter'}},
})
spoon.ClaudeTasks:start()
```

## API

### Methods

- `obj:init()` - Initialize the Spoon (called automatically)
- `obj:start()` - Start file watching and load saved state
- `obj:stop()` - Stop file watching and cleanup
- `obj:show()` - Show the task viewer
- `obj:hide()` - Hide the task viewer
- `obj:toggle()` - Toggle visibility
- `obj:refresh()` - Manually refresh the task list
- `obj:setTaskListId(id)` - Set the session ID filter
- `obj:createTask(subject)` - Create a new task via Claude CLI
- `obj:quickTaskUpdate(prompt)` - Run quick TaskUpdate via haiku model
- `obj:launchClaudeWithTaskList()` - Launch Claude in terminal with current session
- `obj:launchClaudeWithCwd(sessionId, cwd)` - Launch Claude with specific working directory
- `obj:launchClaudeWithSession(sessionId)` - Launch Claude with session env var
- `obj:showTaskDetailWindow(subject, description, metadata)` - Show task detail popup
- `obj:deleteTask(taskId, sessionId)` - Delete a task by ID
- `obj:status()` - Get current status info
- `obj:configure(options)` - Update configuration
- `obj:bindHotkeys(mapping)` - Bind hotkeys

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `width` | 420 | Window width |
| `height` | 580 | Window height |
| `margin` | 20 | Screen edge margin |
| `refreshDebounce` | 0.2 | Debounce delay for file changes (seconds) |
| `debugMode` | false | Enable debug logging |
| `taskListId` | `$CLAUDE_CODE_TASK_LIST_ID` | Session ID filter |
| `claudePath` | nil | Path to claude CLI (auto-discovered if nil) |
| `terminalApp` | nil | Path to terminal app (auto-discovered if nil) |
| `shell` | nil | Shell to use (defaults to `$SHELL` or `/bin/zsh`) |
| `keyBindings` | (see below) | Customizable keyboard shortcuts (use `bindShortcuts()`) |

## Requirements

- Hammerspoon
- Claude Code CLI (`claude` command)
- A supported terminal app (Ghostty, iTerm2, or Terminal.app)

## License

MIT License - see [LICENSE](LICENSE)

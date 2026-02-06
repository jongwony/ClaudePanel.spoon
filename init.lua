-- ClaudeTasks.spoon
-- Hammerspoon Spoon for Claude Code Task viewer
-- opt+. 핫키로 플로팅 윈도우에 태스크 목록 표시

local obj = {}

-- Spoon Metadata
obj.name = "ClaudeTasks"
obj.version = "1.7.1"
obj.author = "jongwony <lastone9182@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/jongwony/ClaudeTasks.spoon"
obj.spoonPath = hs.spoons.scriptPath()

-- ============================================================================
-- Module Loader
-- ============================================================================

local function loadModule(name)
    local path = obj.spoonPath .. "/lib/" .. name .. ".lua"
    local f, err = loadfile(path)
    if not f then error("Failed to load " .. name .. ": " .. err) end
    return f()
end

-- Load modules
local utils = loadModule("utils")
local discovery = loadModule("discovery")
local stateModule = loadModule("state")
local tasks = loadModule("tasks")
local html = loadModule("html")
local updater = loadModule("updater")
local watcher = loadModule("watcher")
local webviewModule = loadModule("webview")

-- ============================================================================
-- Configuration
-- ============================================================================

obj.config = {
    -- UI
    width = 420,
    height = 580,
    margin = 20,
    refreshDebounce = 0.2,
    debugMode = true,

    -- Session
    taskListId = os.getenv("CLAUDE_CODE_TASK_LIST_ID"),

    -- External Tools (nil = auto-discover)
    claudePath = nil,
    terminalApp = nil,
    shell = nil,

    -- Update Checker
    checkForUpdates = true,
    updateCheckInterval = 86400,

    -- WebView Key Bindings (initialized in init() from defaultShortcuts)
    keyBindings = nil,
}

-- ============================================================================
-- State
-- ============================================================================

obj.state = {
    currentTaskListId = nil,
    configPath = nil,
    lastUpdateCheck = nil,
}

-- ============================================================================
-- Helper Functions
-- ============================================================================

local function log(message)
    utils.log(obj.config.debugMode, message)
end

local function saveState()
    stateModule.saveState(obj.state.configPath, obj.state, log)
end

local function refreshWebView()
    local allTasks = tasks.loadAllTasks(obj.config, utils, log)
    local sessions = stateModule.listSessionDirs(utils.getTasksDir(), utils)
    local currentSessionValue = obj.state.currentTaskListId or ''
    local htmlContent = html.generateHTML(allTasks, sessions, currentSessionValue, utils, obj.config)
    webviewModule.refreshWebView(htmlContent, log)
    log("WebView refreshed with " .. #allTasks .. " tasks")
end

-- ============================================================================
-- Action Handler (for WebView callbacks)
-- ============================================================================

local function actionHandler(action, params)
    if action == "setSession" then
        obj:setTaskListId(params.value)
    elseif action == "createTask" then
        obj:createTask(params.subject)
    elseif action == "launchClaude" then
        obj:launchClaudeWithTaskList()
    elseif action == "launchClaudeWithCwd" then
        obj:launchClaudeWithCwd(params.sessionId, params.cwd)
    elseif action == "launchClaudeWithSession" then
        obj:launchClaudeWithSession(params.sessionId)
    elseif action == "showQuickUpdateDialog" then
        obj:showQuickTaskDialog()
    elseif action == "launchClaudeHandoff" then
        obj:launchClaudeHandoff(params.sessionId, params.cwd)
    elseif action == "showTaskDetail" then
        obj:showTaskDetailWindow(params.subject, params.description, params.metadata)
    elseif action == "deleteTask" then
        obj:deleteTask(params.taskId, params.sessionId)
    end
end

local function quickTaskActionHandler(action, params)
    if action == "close" then
        webviewModule.closeQuickTaskDialog()
    elseif action == "submit" then
        webviewModule.closeQuickTaskDialog()
        if params.prompt and params.prompt ~= "" then
            obj:quickTaskUpdate(params.prompt)
        end
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

function obj:init()
    obj.state.configPath = obj.spoonPath .. "/state.json"
    -- Initialize keyBindings from defaultShortcuts (single source of truth)
    if not obj.config.keyBindings then
        obj.config.keyBindings = obj.defaultShortcuts
    end
    log("ClaudeTasks Spoon initialized")
    return self
end

function obj:show()
    webviewModule.createWebView(obj.config, actionHandler, log)
    refreshWebView()
    webviewModule.show(log)
    watcher.startPathWatcher(utils.getTasksDir(), obj.config, utils, log, function(needsRestart)
        if needsRestart then
            obj:stop()
            obj:start()
        else
            refreshWebView()
        end
    end)
    return self
end

function obj:hide()
    webviewModule.hide(log)
    return self
end

function obj:toggle()
    if webviewModule.isVisible() then
        obj:hide()
    else
        obj:show()
    end
    return self
end

function obj:refresh()
    refreshWebView()
    return self
end

function obj:setTaskListId(id)
    local sessionId = (id ~= "" and id) or nil
    obj.state.currentTaskListId = sessionId
    obj.config.taskListId = sessionId
    saveState()
    log("Session changed to: " .. (sessionId or "none"))

    -- Restart file watcher for new session
    watcher.stopPathWatcher(log)
    watcher.startPathWatcher(utils.getTasksDir(), obj.config, utils, log, function(needsRestart)
        if needsRestart then
            obj:stop()
            obj:start()
        else
            refreshWebView()
        end
    end)

    obj:refresh()
    return self
end

function obj:createTask(subject)
    local claudePath = discovery.discoverClaudePath(obj.config.claudePath)
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return nil
    end

    local prompt = string.format("TaskCreate(%s)", subject)
    log("Creating task: " .. prompt)

    local env = {}
    if obj.state.currentTaskListId and obj.state.currentTaskListId ~= "" then
        env.CLAUDE_CODE_TASK_LIST_ID = obj.state.currentTaskListId
    end

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            hs.alert.show("Task created", 1)
            log("Task created successfully. stdout: " .. (stdout or ""))
        else
            hs.alert.show("Task creation failed", 2)
            log("Task creation failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end

        webviewModule.resetForm()
        obj:refresh()
    end, {
        "-p",
        "--model", "haiku",
        prompt
    })

    if next(env) then
        task:setEnvironment(env)
    end

    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    return task
end

function obj:quickTaskUpdate(prompt)
    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local claudePath = discovery.discoverClaudePath(obj.config.claudePath)
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return
    end

    local env = {
        PATH = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        HOME = os.getenv("HOME"),
        USER = os.getenv("USER"),
        SHELL = discovery.getShell(obj.config.shell),
        TERM = "xterm-256color",
        CLAUDE_CODE_ENABLE_TASKS = "true",
        CLAUDE_CODE_TASK_LIST_ID = taskListId
    }

    local systemPrompt = [[This is a lightweight Todo Task management command. Use TaskCreate or TaskUpdate tools immediately based on the user's input. Do not ask for clarification - execute the tool directly.

For TaskCreate: If description is not explicitly provided, infer a meaningful description from the subject.]]

    log("QuickTaskUpdate: " .. prompt .. " (taskListId: " .. taskListId .. ")")

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            local result = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if result == "" then result = "Done" end
            if #result > 200 then
                result = result:sub(1, 200) .. "..."
            end
            hs.alert.show(result, 3)
            log("QuickTaskUpdate completed. stdout: " .. (stdout or ""))
        else
            local errMsg = (stderr or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if errMsg == "" then errMsg = "TaskUpdate failed" end
            hs.alert.show("❌ " .. errMsg:sub(1, 100), 3)
            log("QuickTaskUpdate failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end
        obj:refresh()
    end, {
        "--model", "haiku",
        "-p",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--dangerously-skip-permissions",
        "--setting-sources", "",
        "--system-prompt", systemPrompt,
        "--verbose",
        "--",
        prompt
    })

    task:setEnvironment(env)
    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    hs.alert.show("Running Quick Task...", 1)
end

function obj:showTaskDetailWindow(subject, description, metadata)
    webviewModule.showTaskDetailWindow(subject, description, metadata, utils, log)
    return self
end

function obj:deleteTask(taskId, sessionId)
    -- Input validation
    if not taskId or not sessionId then
        log("deleteTask: taskId or sessionId is nil")
        hs.alert.show("Failed to delete task", 2)
        return false
    end

    -- Path traversal prevention: block ../ and path separators
    if taskId:match("%.%.") or sessionId:match("%.%.") or
       taskId:match("[/\\]") or sessionId:match("[/\\]") then
        log("deleteTask: Invalid characters in taskId or sessionId")
        hs.alert.show("Failed to delete task", 2)
        return false
    end

    local filepath = utils.getTasksDir() .. "/" .. sessionId .. "/" .. taskId .. ".json"

    -- Check file exists
    if not utils.fileExists(filepath) then
        log("deleteTask: File not found: " .. filepath)
        hs.alert.show("Failed to delete task", 2)
        return false
    end

    -- Execute deletion with error handling
    local success, err = os.remove(filepath)
    if not success then
        log("deleteTask: Failed to delete: " .. filepath .. " - " .. (err or "unknown error"))
        hs.alert.show("Failed to delete task", 2)
        return false
    end

    log("deleteTask: Deleted " .. filepath)
    hs.alert.show("Task deleted", 1)
    obj:refresh()
    return true
end

function obj:showQuickTaskDialog()
    webviewModule.showQuickTaskDialog(quickTaskActionHandler, log)
    return self
end

function obj:launchClaudeWithTaskList()
    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local terminalPath = discovery.discoverTerminalApp(obj.config.terminalApp)
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local claudeDir = os.getenv("HOME") .. "/.claude"
    local shell = discovery.getShell(obj.config.shell)
    local shellCmd = string.format("cd %s && CLAUDE_CODE_TASK_LIST_ID=%s claude", claudeDir, taskListId)

    log("Launching Claude: " .. shellCmd)

    local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
        if exitCode ~= 0 then
            log("Terminal launch error: " .. (stderr or "unknown"))
        end
    end, {
        "-e", shell, "-c", shellCmd
    })

    task:start()
    hs.alert.show("Launching Claude...", 1)
end

function obj:launchClaudeWithCwd(sessionId, cwd)
    if not sessionId or sessionId == "" then
        hs.alert.show("No session ID", 2)
        return
    end
    if not cwd or cwd == "" then
        hs.alert.show("No working directory", 2)
        return
    end

    local terminalPath = discovery.discoverTerminalApp(obj.config.terminalApp)
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local shell = discovery.getShell(obj.config.shell)
    local claudePath = discovery.discoverClaudePath(obj.config.claudePath) or "claude"
    local shellCmd = string.format("cd '%s' && CLAUDE_CODE_TASK_LIST_ID=%s %s -r %s", cwd, sessionId, claudePath, sessionId)

    log("Launching Claude with cwd: " .. shellCmd)

    -- iTerm2: use AppleScript since it doesn't support -e shell -c cmd args
    if terminalPath:find("iTerm") then
        local escapedCmd = shellCmd:gsub("\\", "\\\\"):gsub('"', '\\"')
        local script = [[
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "]] .. escapedCmd .. [["
                end tell
            end tell
        ]]
        hs.osascript.applescript(script)
    else
        local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
            if exitCode ~= 0 then
                log("Terminal launch error: " .. (stderr or "unknown"))
            end
        end, {
            "-e", shell, "-c", shellCmd
        })
        task:start()
    end

    hs.alert.show("Launching Claude in " .. cwd:match("[^/]+$") .. "...", 1)
end

function obj:launchClaudeWithSession(sessionId)
    if not sessionId or sessionId == "" then
        hs.alert.show("No session ID", 2)
        return
    end

    local terminalPath = discovery.discoverTerminalApp(obj.config.terminalApp)
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local shell = discovery.getShell(obj.config.shell)
    local claudePath = discovery.discoverClaudePath(obj.config.claudePath) or "claude"
    local shellCmd = string.format("CLAUDE_CODE_TASK_LIST_ID=%s %s", sessionId, claudePath)

    log("Launching Claude with session: " .. shellCmd)

    -- iTerm2: use AppleScript since it doesn't support -e shell -c cmd args
    if terminalPath:find("iTerm") then
        local escapedCmd = shellCmd:gsub("\\", "\\\\"):gsub('"', '\\"')
        local script = [[
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "]] .. escapedCmd .. [["
                end tell
            end tell
        ]]
        hs.osascript.applescript(script)
    else
        local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
            if exitCode ~= 0 then
                log("Terminal launch error: " .. (stderr or "unknown"))
            end
        end, {
            "-e", shell, "-c", shellCmd
        })
        task:start()
    end

    hs.alert.show("Launching Claude with session...", 1)
end

function obj:launchClaudeHandoff(sessionId, targetCwd)
    if not targetCwd or targetCwd == "" then
        hs.alert.show("No target directory", 2)
        return
    end
    if not sessionId or sessionId == "" then
        hs.alert.show("No session ID", 2)
        return
    end

    local terminalPath = discovery.discoverTerminalApp(obj.config.terminalApp)
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local shell = discovery.getShell(obj.config.shell)
    local claudePath = discovery.discoverClaudePath(obj.config.claudePath) or "claude"
    local shellCmd = string.format("cd '%s' && export CLAUDE_CODE_TASK_LIST_ID=%s && %s", targetCwd, sessionId, claudePath)

    log("Launching Claude handoff: " .. shellCmd)

    if terminalPath:find("iTerm") then
        local escapedCmd = shellCmd:gsub("\\", "\\\\"):gsub('"', '\\"')
        local script = [[
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "]] .. escapedCmd .. [["
                end tell
            end tell
        ]]
        hs.osascript.applescript(script)
    else
        local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
            if exitCode ~= 0 then
                log("Terminal launch error: " .. (stderr or "unknown"))
            end
        end, {
            "-e", shell, "-c", shellCmd
        })
        task:start()
    end

    hs.alert.show("Handoff to " .. targetCwd:match("[^/]+$") .. "...", 1)
end

function obj:start()
    local loaded = stateModule.loadState(obj.state.configPath, utils, log)
    obj.state.currentTaskListId = loaded.currentTaskListId
    obj.state.lastUpdateCheck = loaded.lastUpdateCheck
    obj.config.taskListId = loaded.currentTaskListId

    watcher.startPathWatcher(utils.getTasksDir(), obj.config, utils, log, function(needsRestart)
        if needsRestart then
            obj:stop()
            obj:start()
        else
            refreshWebView()
        end
    end)

    -- Async update check with delay
    if obj.config.checkForUpdates then
        hs.timer.doAfter(2, function()
            updater.maybeCheckForUpdates(obj.config, obj.state, obj.homepage, obj.version, utils, log, saveState)
        end)
    end

    log("Claude Tasks module started")
    return self
end

function obj:stop()
    watcher.stopPathWatcher(log)
    webviewModule.cleanup()
    tasks.clearCache()
    log("Claude Tasks module stopped")
    return self
end

function obj:toggleOverlay()
    local enabled = webviewModule.toggleOverlay(log)
    if enabled then
        hs.alert.show("Overlay mode ON", 1)
    else
        hs.alert.show("Overlay mode OFF", 1)
    end
    return self
end

function obj:configure(options)
    if options then
        for k, v in pairs(options) do
            obj.config[k] = v
        end
    end
    return self
end

function obj:checkForUpdates(showNoUpdate)
    updater.checkForUpdates(obj.homepage, obj.version, utils, log, function(updateInfo, err)
        if err then
            hs.alert.show("Update check failed: " .. err, 3)
            return
        end

        -- Save check time
        obj.state.lastUpdateCheck = os.time()
        saveState()

        if updateInfo.hasUpdate then
            updater.showUpdateNotification(updateInfo)
        elseif showNoUpdate then
            hs.alert.show(string.format(
                "ClaudeTasks v%s is up to date",
                updateInfo.currentVersion
            ), 2)
        end
    end)
    return self
end

function obj:status()
    local allTasks = tasks.loadAllTasks(obj.config, utils, log)
    local pending = 0
    local inProgress = 0
    local completed = 0

    for _, task in ipairs(allTasks) do
        if task.status == "completed" then
            completed = completed + 1
        elseif task.status == "in_progress" then
            inProgress = inProgress + 1
        else
            pending = pending + 1
        end
    end

    return {
        visible = webviewModule.isVisible(),
        taskCount = #allTasks,
        pending = pending,
        inProgress = inProgress,
        completed = completed,
        taskListId = obj.config.taskListId,
        currentTaskListId = obj.state.currentTaskListId,
        watcherActive = watcher.isActive(),
    }
end

-- ============================================================================
-- Hotkey, Shortcuts Binding
-- ============================================================================

obj.defaultHotkeys = {
    toggle = {{"alt"}, "."},
    status = {{"cmd", "alt"}, "T"},
    overlay = {{"alt"}, "p"}
}

function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() obj:toggle() end,
        status = function()
            local status = obj:status()
            local msg = string.format(
                "Tasks: %d total\n⏳ %d pending\n🔄 %d in progress\n✓ %d completed",
                status.taskCount, status.pending, status.inProgress, status.completed
            )
            hs.alert.show(msg, 3)
        end,
        overlay = function() obj:toggleOverlay() end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

obj.defaultShortcuts = {
    navigateDown = {modifiers = {}, keys = {'j', 'ㅓ', 'ArrowDown'}},
    navigateUp = {modifiers = {}, keys = {'k', 'ㅏ', 'ArrowUp'}},
    deleteTask = {modifiers = {'cmd'}, keys = {'Backspace'}},
    openTask = {modifiers = {}, keys = {' '}},
    launchTask = {modifiers = {}, keys = {'Enter'}},
}

function obj:bindShortcuts(mapping)
    -- Input validation
    if mapping ~= nil and type(mapping) ~= "table" then
        log("bindShortcuts: mapping must be a table, got " .. type(mapping))
        return self
    end

    local shortcuts = {}
    for k, v in pairs(obj.defaultShortcuts) do
        shortcuts[k] = v
    end
    if mapping then
        for name, binding in pairs(mapping) do
            if type(binding) ~= "table" then
                log("bindShortcuts: Invalid binding for '" .. tostring(name) .. "' (not a table)")
            elseif not binding.keys then
                log("bindShortcuts: Invalid binding for '" .. tostring(name) .. "' (missing 'keys')")
            else
                shortcuts[name] = binding
            end
        end
    end
    obj.config.keyBindings = shortcuts
    log("Shortcuts bound: " .. hs.json.encode(shortcuts))
    return self
end

return obj

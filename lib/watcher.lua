-- lib/watcher.lua
-- File system watcher for task changes

local M = {}

-- Module-level state
local pathWatcher = nil
local refreshTimer = nil

-- Start watching tasks directory
function M.startPathWatcher(tasksDir, config, utils, log, onChangeCallback)
    if pathWatcher then return end

    -- If directory doesn't exist, watch parent
    if not utils.fileExists(tasksDir) then
        log("Tasks directory does not exist, will watch parent")
        local parentDir = os.getenv("HOME") .. "/.claude"
        pathWatcher = hs.pathwatcher.new(parentDir, function(paths)
            -- Restart when tasks directory is created
            if utils.fileExists(tasksDir) then
                M.stopPathWatcher()
                -- Caller should restart
                if onChangeCallback then onChangeCallback(true) end  -- true = restart needed
            end
        end)
        pathWatcher:start()
        return
    end

    -- Watch tasks directory and all session subdirectories
    local sessions = utils.listDir(tasksDir)
    local watchPaths = {tasksDir}

    for _, sessionId in ipairs(sessions) do
        table.insert(watchPaths, tasksDir .. "/" .. sessionId)
    end

    pathWatcher = hs.pathwatcher.new(tasksDir, function(paths)
        log("File change detected: " .. table.concat(paths, ", "))

        -- Extract changed session IDs from paths
        local changedSessions = {}
        local seen = {}
        for _, p in ipairs(paths) do
            local relative = p:sub(#tasksDir + 2)
            local sessionId = relative:match("^([^/]+)")
            if sessionId and not seen[sessionId] then
                table.insert(changedSessions, sessionId)
                seen[sessionId] = true
            end
        end

        -- Debounce: only process last change in rapid succession
        if refreshTimer then
            refreshTimer:stop()
        end

        refreshTimer = hs.timer.doAfter(config.refreshDebounce, function()
            if onChangeCallback then onChangeCallback(false, changedSessions) end
            refreshTimer = nil
        end)
    end)

    pathWatcher:start()
    log("PathWatcher started on: " .. tasksDir)
end

-- Stop watching
function M.stopPathWatcher(log)
    if pathWatcher then
        pathWatcher:stop()
        pathWatcher = nil
        if log then log("PathWatcher stopped") end
    end
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end
end

-- Check if watcher is active
function M.isActive()
    return pathWatcher ~= nil
end

return M

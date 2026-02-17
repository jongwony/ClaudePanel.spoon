-- lib/state.lua
-- State persistence and session management

local M = {}

-- Load state from file
function M.loadState(configPath, utils, log)
    local state = {
        currentTaskListId = nil,
        lastUpdateCheck = nil,
        cwdCache = {}
    }
    local f = io.open(configPath, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local data = utils.parseJSON(content)
        if data then
            state.currentTaskListId = data.currentTaskListId
            state.lastUpdateCheck = data.lastUpdateCheck
            state.cwdCache = data.cwdCache or {}
            log("State loaded: " .. (data.currentTaskListId or "nil"))
        end
    end
    return state
end

-- Save state to file
function M.saveState(configPath, state, log)
    local data = hs.json.encode({
        currentTaskListId = state.currentTaskListId,
        lastUpdateCheck = state.lastUpdateCheck,
        cwdCache = state.cwdCache
    })
    local f = io.open(configPath, "w")
    if f then
        f:write(data)
        f:close()
        log("State saved: " .. (state.currentTaskListId or "nil"))
    end
end

-- List session directories with tasks
function M.listSessionDirs(tasksDir, utils)
    if not utils.fileExists(tasksDir) then
        return {}
    end

    local allDirs = utils.listDir(tasksDir)
    local nonEmptySessions = {}

    for _, sessionId in ipairs(allDirs) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = utils.listDir(sessionDir)
        -- Include if at least one .json file exists
        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                table.insert(nonEmptySessions, sessionId)
                break
            end
        end
    end

    return nonEmptySessions
end

return M

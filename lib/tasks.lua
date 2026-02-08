-- lib/tasks.lua
-- Task loading and CWD extraction

local M = {}

-- CWD cache (module-level)
local cwdCache = {}

-- Encode a path back to Claude's format for verification
-- /Users/choi/.claude → -Users-choi--claude
-- Claude encodes: / → -, . → - (but /. → --)
local function encodePath(path)
    -- First handle /. → -- (dot directories after slash)
    local encoded = path:gsub("/%.", "--")
    -- Then handle remaining / → -
    encoded = encoded:gsub("/", "-")
    -- Finally handle remaining . → - (dots in filenames like ClaudePanel.spoon)
    encoded = encoded:gsub("%.", "-")
    return encoded
end

-- Decode CWD path from encoded directory name
-- Claude encodes paths: / → -, . → -, /. → --
-- Problem: hyphens in dir names (e.g. aqueduct-deploy) and dots (e.g. ClaudePanel.spoon) are ambiguous.
-- Solution: walk the filesystem and verify by re-encoding.
function M.decodeCwdPath(encodedDir)
    -- First handle '--' (encoded /.) by replacing with placeholder
    local encoded = encodedDir:gsub("%-%-", "\001")

    -- Remove leading '-' (represents root /)
    local startsWithDot = false
    if encoded:sub(1,1) == "-" then
        encoded = encoded:sub(2)
    elseif encoded:sub(1,1) == "\001" then
        encoded = encoded:sub(2)
        startsWithDot = true
    end

    -- Split by '\001' to get segments separated by /. (dot directories)
    local segments = {}
    for seg in encoded:gmatch("[^\001]+") do
        table.insert(segments, seg)
    end

    -- For a single segment, resolve it by trying all interpretations of '-'
    -- Each '-' could be: '/' (path separator), '.' (dot in name), or '-' (literal hyphen)
    local function resolveSegment(basePath, segment, prefixWithDot)
        local tokens = {}
        for t in segment:gmatch("[^%-]+") do
            table.insert(tokens, t)
        end
        if #tokens == 0 then return basePath end

        -- Recursive function: try building path from tokens[idx] onwards
        -- accumulated = current directory name being built
        local function tryBuild(idx, currentPath, accumulated)
            if idx > #tokens then
                -- All tokens consumed, check if accumulated forms a valid dir
                local finalPath = currentPath .. "/" .. accumulated
                if hs.fs.attributes(finalPath, "mode") == "directory" then
                    return finalPath
                end
                return nil
            end

            local token = tokens[idx]

            -- Option 1: '-' was '/' - accumulated is complete dir name, token starts new dir
            if accumulated ~= "" then
                local dirPath = currentPath .. "/" .. accumulated
                if hs.fs.attributes(dirPath, "mode") == "directory" then
                    local result = tryBuild(idx + 1, dirPath, token)
                    if result then return result end
                end
            end

            -- Option 2: '-' was '.' - join with dot
            if accumulated ~= "" then
                local result = tryBuild(idx + 1, currentPath, accumulated .. "." .. token)
                if result then return result end
            end

            -- Option 3: '-' was literal '-' - join with hyphen
            if accumulated ~= "" then
                local result = tryBuild(idx + 1, currentPath, accumulated .. "-" .. token)
                if result then return result end
            end

            -- First token case
            if accumulated == "" then
                local prefix = prefixWithDot and "." or ""
                return tryBuild(idx + 1, currentPath, prefix .. token)
            end

            return nil
        end

        return tryBuild(1, basePath, "")
    end

    local result = ""
    for i, seg in ipairs(segments) do
        local prefixWithDot = (i > 1) or startsWithDot
        result = resolveSegment(result, seg, prefixWithDot)
        if not result then return nil end
    end
    return result
end

-- Get CWD from session ID by scanning projects directory
function M.getCwdFromSessionId(sessionId, utils)
    if cwdCache[sessionId] then return cwdCache[sessionId] end

    local projectsDir = os.getenv("HOME") .. "/.claude/projects"
    if not utils.fileExists(projectsDir) then return nil end

    for _, encodedDir in ipairs(utils.listDir(projectsDir)) do
        local sessionFile = projectsDir .. "/" .. encodedDir .. "/" .. sessionId .. ".jsonl"
        if utils.fileExists(sessionFile) then
            local cwd = M.decodeCwdPath(encodedDir)
            cwdCache[sessionId] = cwd
            return cwd
        end
    end
    return nil
end

-- Load all tasks from session directories
function M.loadAllTasks(config, utils, log)
    local tasks = {}
    local tasksDir = utils.getTasksDir()

    if not utils.fileExists(tasksDir) then
        log("Tasks directory does not exist: " .. tasksDir)
        return tasks
    end

    -- Load specific session or all sessions
    local sessions = {}
    if config.taskListId then
        sessions = {config.taskListId}
    else
        sessions = utils.listDir(tasksDir)
    end

    for _, sessionId in ipairs(sessions) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = utils.listDir(sessionDir)

        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                local filepath = sessionDir .. "/" .. filename
                local content = utils.readFile(filepath)

                if content then
                    local task = utils.parseJSON(content)
                    if task then
                        task._sessionId = sessionId
                        task._filepath = filepath
                        task._cwd = M.getCwdFromSessionId(sessionId, utils)
                        table.insert(tasks, task)
                    end
                end
            end
        end
    end

    -- Sort by ID (numeric first, then string)
    table.sort(tasks, function(a, b)
        local aNum = tonumber(a.id)
        local bNum = tonumber(b.id)
        if aNum and bNum then
            return aNum < bNum
        end
        return tostring(a.id) < tostring(b.id)
    end)

    log("Loaded " .. #tasks .. " tasks")
    return tasks
end

-- Clear CWD cache
function M.clearCache()
    cwdCache = {}
end

return M

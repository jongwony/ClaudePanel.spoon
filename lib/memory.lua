-- lib/memory.lua
-- Memory file discovery and loading
-- Uses hs.fs directly to avoid subprocess spawning via io.popen

local M = {}

local projectsDir = os.getenv("HOME") .. "/.claude/projects"

-- Get the projects directory path
function M.getProjectsDir()
    return projectsDir
end

-- List directory entries using hs.fs.dir (no subprocess)
local function listDir(path)
    local items = {}
    local iter, dir = hs.fs.dir(path)
    if not iter then return items end
    for entry in iter, dir do
        if entry ~= "." and entry ~= ".." then
            table.insert(items, entry)
        end
    end
    return items
end

-- Check if path exists using hs.fs.attributes (no subprocess)
local function pathExists(path)
    return hs.fs.attributes(path, "mode") ~= nil
end

-- List all projects with decoded paths
-- decodeCwdPath: function from tasks module to decode encoded directory names
function M.listProjects(decodeCwdPath, log)
    if not pathExists(projectsDir) then
        return {}
    end

    local projects = {}
    local dirs = listDir(projectsDir)

    for _, encodedDir in ipairs(dirs) do
        local memoryDir = projectsDir .. "/" .. encodedDir .. "/memory"
        -- Only include projects that have a memory/ subdirectory
        if pathExists(memoryDir) then
            local decodedPath = nil
            if decodeCwdPath then
                local ok, result = pcall(decodeCwdPath, encodedDir)
                if ok then
                    decodedPath = result
                elseif log then
                    log("listProjects: decodeCwdPath failed for " .. encodedDir .. ": " .. tostring(result))
                end
            end
            table.insert(projects, {
                hash = encodedDir,
                decodedPath = decodedPath or encodedDir,
            })
        end
    end

    -- Sort by decoded path alphabetically
    table.sort(projects, function(a, b)
        return a.decodedPath < b.decodedPath
    end)

    return projects
end

-- Find which project hash contains a given session ID
-- Returns the project hash string, or nil if not found
function M.findProjectForSession(sessionId)
    if not sessionId or sessionId == "" then return nil end
    if not pathExists(projectsDir) then return nil end

    local dirs = listDir(projectsDir)
    for _, encodedDir in ipairs(dirs) do
        local sessionFile = projectsDir .. "/" .. encodedDir .. "/" .. sessionId .. ".jsonl"
        if pathExists(sessionFile) then
            return encodedDir
        end
    end
    return nil
end

-- Get full filesystem path for a memory file
-- Returns nil if path components contain traversal characters
function M.getFilePath(projectHash, filename)
    if projectHash:match("%.%.") or filename:match("%.%.") or
       projectHash:match("[/\\]") or filename:match("[/\\]") then
        return nil
    end
    return projectsDir .. "/" .. projectHash .. "/memory/" .. filename
end

-- Load memory file metadata for a specific project hash directory
-- Returns array of {name, modified} (content loaded on-demand via getFilePath + utils.readFile)
function M.loadMemoryFiles(projectHash)
    local memoryDir = projectsDir .. "/" .. projectHash .. "/memory"
    if not pathExists(memoryDir) then
        return {}
    end

    local files = {}
    local items = listDir(memoryDir)

    for _, filename in ipairs(items) do
        if filename:match("%.md$") then
            local filepath = memoryDir .. "/" .. filename
            local modified = hs.fs.attributes(filepath, "modification")
            table.insert(files, {
                name = filename,
                modified = modified,
            })
        end
    end

    -- Sort by filename alphabetically
    table.sort(files, function(a, b)
        return a.name < b.name
    end)

    return files
end

-- Load all projects with their memory files
-- currentProjectHash: optional, prioritizes matching project to top of list
-- Returns [{hash, decodedPath, isCurrent, files: [{name, modified}]}]
function M.loadAllMemories(log, decodeCwdPath, currentProjectHash)
    local projects = M.listProjects(decodeCwdPath, log)
    local result = {}

    for _, project in ipairs(projects) do
        local files = M.loadMemoryFiles(project.hash)
        if #files > 0 then
            table.insert(result, {
                hash = project.hash,
                decodedPath = project.decodedPath,
                isCurrent = (currentProjectHash and project.hash == currentProjectHash) or false,
                files = files,
            })
        end
    end

    -- Sort: current project first, then alphabetically by decoded path
    if currentProjectHash then
        table.sort(result, function(a, b)
            if a.isCurrent ~= b.isCurrent then
                return a.isCurrent
            end
            return a.decodedPath < b.decodedPath
        end)
    end

    if log then
        local totalFiles = 0
        for _, p in ipairs(result) do
            totalFiles = totalFiles + #p.files
        end
        log("Loaded " .. totalFiles .. " memory files from " .. #result .. " projects")
    end

    return result
end

return M

-- lib/memory.lua
-- Memory file discovery and loading

local M = {}

-- Get the projects directory path
function M.getProjectsDir()
    return os.getenv("HOME") .. "/.claude/projects"
end

-- List all projects with decoded paths
-- decodeCwdPath: function from tasks module to decode encoded directory names
function M.listProjects(utils, decodeCwdPath, log)
    local projectsDir = M.getProjectsDir()
    if not utils.fileExists(projectsDir) then
        return {}
    end

    local projects = {}
    local dirs = utils.listDir(projectsDir)

    for _, encodedDir in ipairs(dirs) do
        local memoryDir = projectsDir .. "/" .. encodedDir .. "/memory"
        -- Only include projects that have a memory/ subdirectory
        if utils.fileExists(memoryDir) then
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
function M.findProjectForSession(sessionId, utils)
    if not sessionId or sessionId == "" then return nil end
    local projectsDir = M.getProjectsDir()
    if not utils.fileExists(projectsDir) then return nil end

    local dirs = utils.listDir(projectsDir)
    for _, encodedDir in ipairs(dirs) do
        local sessionFile = projectsDir .. "/" .. encodedDir .. "/" .. sessionId .. ".jsonl"
        if utils.fileExists(sessionFile) then
            return encodedDir
        end
    end
    return nil
end

-- Get full filesystem path for a memory file
function M.getFilePath(projectHash, filename)
    return M.getProjectsDir() .. "/" .. projectHash .. "/memory/" .. filename
end

-- Search memory files for content matching query
-- Returns array of {projectHash, filename} for files containing the query
function M.searchContent(query, log)
    if not query or query == "" then return {} end
    local projectsDir = M.getProjectsDir()

    -- Escape single quotes in query for shell safety
    local safeQuery = query:gsub("'", "'\\''")

    -- Try rg first, fallback to grep
    local cmd = string.format(
        "rg -l --no-heading -i '%s' '%s'/*/memory/*.md 2>/dev/null || grep -rl -i '%s' '%s'/*/memory/*.md 2>/dev/null",
        safeQuery, projectsDir, safeQuery, projectsDir
    )

    local handle = io.popen(cmd)
    if not handle then return {} end

    local results = {}
    local seen = {}
    for line in handle:lines() do
        -- Parse path: .../projects/{hash}/memory/{filename}
        local hash, filename = line:match("/projects/([^/]+)/memory/([^/]+)$")
        if hash and filename then
            local key = hash .. "/" .. filename
            if not seen[key] then
                seen[key] = true
                table.insert(results, { projectHash = hash, filename = filename })
            end
        end
    end
    handle:close()

    if log then
        log("Memory search for '" .. query .. "': " .. #results .. " matches")
    end

    return results
end

-- Load memory file metadata for a specific project hash directory
-- Returns array of {name, modified} (content loaded on-demand via getFilePath + readFile)
function M.loadMemoryFiles(projectHash, utils)
    local memoryDir = M.getProjectsDir() .. "/" .. projectHash .. "/memory"
    if not utils.fileExists(memoryDir) then
        return {}
    end

    local files = {}
    local items = utils.listDir(memoryDir)

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
function M.loadAllMemories(utils, log, decodeCwdPath, currentProjectHash)
    local projects = M.listProjects(utils, decodeCwdPath, log)
    local result = {}

    for _, project in ipairs(projects) do
        local files = M.loadMemoryFiles(project.hash, utils)
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

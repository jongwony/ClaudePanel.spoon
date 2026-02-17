-- lib/utils.lua
-- Pure utility functions for ClaudePanel

local M = {}

-- Debug logging
function M.log(debugMode, message)
    if debugMode then
        print("[ClaudePanel] " .. message)
    end
end

-- Get Claude tasks directory
function M.getTasksDir()
    return os.getenv("HOME") .. "/.claude/tasks"
end

-- JSON parsing using hs.json
function M.parseJSON(str)
    local success, result = pcall(hs.json.decode, str)
    if success then
        return result
    end
    return nil
end

-- List directory contents
function M.listDir(path)
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

-- Check if file exists
function M.fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- Read file contents
function M.readFile(path)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        return content
    end
    return nil
end

-- Escape HTML special characters
function M.escapeHtml(str)
    if not str then return "" end
    return str:gsub("&", "&amp;")
              :gsub("<", "&lt;")
              :gsub(">", "&gt;")
              :gsub('"', "&quot;")
              :gsub("'", "&#39;")
end

-- Encode string as JSON (hs.json.encode only takes tables)
function M.jsonEncodeString(str)
    if not str then return '""' end
    local encoded = hs.json.encode({v = str})
    -- Extract value part from {"v":"..."}
    local jsonStr = encoded:match('"v":(.+)}$')
    -- Convert single quotes to JS hex escape for HTML attribute usage
    return jsonStr:gsub("'", "\\x27")
end

return M

-- lib/teams.lua
-- Team config loading and discovery
-- Reads ~/.claude/teams/{teamId}/config.json

local M = {}

local teamsDir = os.getenv("HOME") .. "/.claude/teams"

-- CSS color map for team member color names
local COLOR_MAP = {
    blue   = "#3b82f6",
    green  = "#22c55e",
    yellow = "#eab308",
    purple = "#8b5cf6",
    orange = "#f97316",
    pink   = "#ec4899",
    red    = "#ef4444",
    cyan   = "#06b6d4",
}

-- Check if path exists using hs.fs.attributes (no subprocess)
local function pathExists(path)
    return hs.fs.attributes(path, "mode") ~= nil
end

-- Load team config for a given taskListId
-- Returns: {name, description, cwd, members: [{name, agentType, color}]} or nil
-- Returns nil if taskListId has no config.json (i.e., it's a regular session, not a team)
function M.loadTeamConfig(taskListId, utils, log)
    if not taskListId or taskListId == "" then return nil end
    -- Block path traversal
    if taskListId:match("%.%.") or taskListId:match("[/\\]") then return nil end

    local configPath = teamsDir .. "/" .. taskListId .. "/config.json"
    if not pathExists(configPath) then return nil end

    local content = utils.readFile(configPath)
    if not content then return nil end

    local ok, data = pcall(utils.parseJSON, content)
    if not ok or type(data) ~= "table" then
        if log then log("teams.loadTeamConfig: parse error for " .. taskListId) end
        return nil
    end

    -- Extract members (exclude prompt field to avoid loading large strings)
    local members = {}
    for _, m in ipairs(data.members or {}) do
        table.insert(members, {
            name      = m.name,
            agentType = m.agentType,
            color     = m.color,
            cwd       = m.cwd,
        })
    end

    -- Derive team cwd from first member that has one (all members share the same cwd)
    local cwd = nil
    for _, m in ipairs(members) do
        if m.cwd then cwd = m.cwd; break end
    end

    return {
        name        = data.name or taskListId,
        description = data.description,
        cwd         = cwd,
        members     = members,
    }
end

-- Build memberColorMap from team data for use in generateTaskCard
-- Returns: {memberName -> cssColor}
function M.getMemberColorMap(teamData)
    if not teamData or not teamData.members then return {} end
    local colorMap = {}
    for _, m in ipairs(teamData.members) do
        if m.name and m.color then
            colorMap[m.name] = COLOR_MAP[m.color] or m.color
        end
    end
    return colorMap
end

-- List all named teams (directories that have a config.json)
-- Returns: [{name, description, memberCount}] sorted by name
function M.listNamedTeams(utils, log)
    if not pathExists(teamsDir) then return {} end

    local result = {}
    local iter, dir = hs.fs.dir(teamsDir)
    if not iter then return result end

    for entry in iter, dir do
        if entry ~= "." and entry ~= ".." then
            local configPath = teamsDir .. "/" .. entry .. "/config.json"
            if pathExists(configPath) then
                local content = utils.readFile(configPath)
                if content then
                    local ok, data = pcall(utils.parseJSON, content)
                    if ok and type(data) == "table" then
                        table.insert(result, {
                            name        = data.name or entry,
                            description = data.description,
                            memberCount = #(data.members or {}),
                        })
                    end
                end
            end
        end
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

return M

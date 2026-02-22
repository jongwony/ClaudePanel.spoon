-- tests/test_teams.lua
-- Unit tests for lib/teams.lua
-- Run with: lua tests/test_teams.lua

local TEST_PASSED = 0
local TEST_FAILED = 0

-- ============================================================================
-- Mocks
-- ============================================================================

local mockFiles = {}  -- path -> content string
local mockDirs  = {}  -- path -> {entry, ...}

hs = {
    fs = {
        attributes = function(path, attr)
            if attr == "mode" then
                if mockFiles[path] then return "file"
                elseif mockDirs[path] then return "directory"
                else return nil end
            end
            return nil
        end,
        dir = function(path)
            local entries = mockDirs[path]
            if not entries then return nil, nil end
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end, nil
        end,
    }
}

local function setMockFile(path, content)
    mockFiles[path] = content
end

local function setMockDir(path, entries)
    mockDirs[path] = entries
end

local function clearMocks()
    mockFiles = {}
    mockDirs  = {}
end

-- Mock utils
local utils = {
    readFile = function(path)
        return mockFiles[path]
    end,
    parseJSON = function(str)
        -- Minimal JSON parser sufficient for test fixtures
        -- Uses load() to eval a Lua-compatible table literal
        -- Real implementation uses hs.json.decode
        local chunk = load("return " .. str:gsub('"([^"]+)"%s*:', '["%1"]='):gsub('%[(%d+)%]', ''))
        if chunk then
            local ok, result = pcall(chunk)
            if ok then return result end
        end
        error("parseJSON mock: cannot parse: " .. str)
    end,
}

-- Override parseJSON with a proper implementation using json.lua or raw table construction
-- Since we can't use hs.json in pure Lua tests, build test fixtures as Lua tables directly
local function makeConfigJSON(t)
    -- We bypass JSON parsing by injecting a custom parseJSON that uses our fixtures
    return t  -- return table directly
end

-- Patch utils to return pre-parsed table when readFile returns a special marker
local fixtureMap = {}
utils.readFile = function(path)
    if fixtureMap[path] then
        return "__fixture__" .. path
    end
    return mockFiles[path]
end
utils.parseJSON = function(str)
    if str and str:sub(1, 11) == "__fixture__" then
        local path = str:sub(12)
        return fixtureMap[path]
    end
    error("parseJSON: unexpected call with: " .. tostring(str))
end

local function setMockConfig(path, tableData)
    fixtureMap[path] = tableData
    mockFiles[path] = "__fixture__" .. path  -- trigger the fixture path
end

-- ============================================================================
-- Load module
-- ============================================================================

local function loadTeams()
    local path = debug.getinfo(1, "S").source:sub(2)
    local dir = path:match("(.*/)")
    local f, err = loadfile(dir .. "../lib/teams.lua")
    if not f then error("Failed to load teams.lua: " .. err) end
    return f()
end

local teams = loadTeams()

-- ============================================================================
-- Test helpers
-- ============================================================================

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        TEST_PASSED = TEST_PASSED + 1
        print("✓ " .. name)
    else
        TEST_FAILED = TEST_FAILED + 1
        print("✗ " .. name)
        print("  Error: " .. tostring(err))
    end
end

local function assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\n  Expected: %s\n  Actual:   %s",
            msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

local function assertNil(val, msg)
    if val ~= nil then
        error((msg or "Expected nil") .. ", got: " .. tostring(val))
    end
end

local function assertNotNil(val, msg)
    if val == nil then
        error(msg or "Expected non-nil value")
    end
end

local HOME = os.getenv("HOME")
local teamsDir = HOME .. "/.claude/teams"

-- ============================================================================
-- Tests: loadTeamConfig
-- ============================================================================

print("\n=== loadTeamConfig ===")

test("returns nil for nil taskListId", function()
    clearMocks()
    assertNil(teams.loadTeamConfig(nil, utils, nil))
end)

test("returns nil for empty taskListId", function()
    clearMocks()
    assertNil(teams.loadTeamConfig("", utils, nil))
end)

test("returns nil for path traversal attempt", function()
    clearMocks()
    assertNil(teams.loadTeamConfig("../etc/passwd", utils, nil))
end)

test("returns nil when config.json does not exist", function()
    clearMocks()
    -- No mock file set → pathExists returns nil
    assertNil(teams.loadTeamConfig("some-session-id", utils, nil))
end)

test("returns team data when config.json exists", function()
    clearMocks()
    local configPath = teamsDir .. "/my-team/config.json"
    setMockConfig(configPath, {
        name        = "my-team",
        description = "Test team",
        members     = {
            { name = "team-lead",   agentType = "team-lead",       color = nil,    cwd = "/work" },
            { name = "data-analyst", agentType = "general-purpose", color = "blue", cwd = "/work" },
        }
    })

    local result = teams.loadTeamConfig("my-team", utils, nil)
    assertNotNil(result, "Expected non-nil result")
    assertEqual(result.name, "my-team", "name")
    assertEqual(result.description, "Test team", "description")
    assertEqual(result.cwd, "/work", "cwd from first member")
    assertEqual(#result.members, 2, "member count")
    assertEqual(result.members[2].color, "blue", "member color")
end)

test("derives cwd from first member with cwd", function()
    clearMocks()
    local configPath = teamsDir .. "/cwd-team/config.json"
    setMockConfig(configPath, {
        name    = "cwd-team",
        members = {
            { name = "lead", cwd = "/project/root" },
            { name = "worker", cwd = "/project/root" },
        }
    })

    local result = teams.loadTeamConfig("cwd-team", utils, nil)
    assertEqual(result.cwd, "/project/root", "cwd")
end)

test("excludes prompt field from members", function()
    clearMocks()
    local configPath = teamsDir .. "/prompt-team/config.json"
    setMockConfig(configPath, {
        name    = "prompt-team",
        members = {
            { name = "agent", agentType = "general-purpose", color = "green",
              prompt = string.rep("x", 17000), cwd = "/repo" },
        }
    })

    local result = teams.loadTeamConfig("prompt-team", utils, nil)
    assertNil(result.members[1].prompt, "prompt should not be included")
    assertEqual(result.members[1].name, "agent", "name preserved")
    assertEqual(result.members[1].color, "green", "color preserved")
end)

-- ============================================================================
-- Tests: getMemberColorMap
-- ============================================================================

print("\n=== getMemberColorMap ===")

test("returns empty map for nil teamData", function()
    local result = teams.getMemberColorMap(nil)
    assertEqual(type(result), "table", "should return table")
end)

test("maps known color names to CSS hex values", function()
    local teamData = {
        members = {
            { name = "alice", color = "blue" },
            { name = "bob",   color = "green" },
            { name = "carol", color = "yellow" },
            { name = "dave",  color = "purple" },
        }
    }
    local colorMap = teams.getMemberColorMap(teamData)
    assertEqual(colorMap["alice"], "#3b82f6", "blue -> #3b82f6")
    assertEqual(colorMap["bob"],   "#22c55e", "green -> #22c55e")
    assertEqual(colorMap["carol"], "#eab308", "yellow -> #eab308")
    assertEqual(colorMap["dave"],  "#8b5cf6", "purple -> #8b5cf6")
end)

test("skips members without color (team-lead pattern)", function()
    local teamData = {
        members = {
            { name = "team-lead", color = nil },
            { name = "worker",    color = "orange" },
        }
    }
    local colorMap = teams.getMemberColorMap(teamData)
    assertNil(colorMap["team-lead"], "team-lead should not appear in colorMap")
    assertEqual(colorMap["worker"], "#f97316", "orange -> #f97316")
end)

test("passes through unknown color as-is", function()
    local teamData = {
        members = { { name = "agent", color = "#custom" } }
    }
    local colorMap = teams.getMemberColorMap(teamData)
    assertEqual(colorMap["agent"], "#custom", "unknown color passed through")
end)

-- ============================================================================
-- Tests: listNamedTeams
-- ============================================================================

print("\n=== listNamedTeams ===")

test("returns empty list when teams dir does not exist", function()
    clearMocks()
    -- teamsDir not in mockDirs → pathExists returns nil
    local result = teams.listNamedTeams(utils, nil)
    assertEqual(type(result), "table", "should return table")
    assertEqual(#result, 0, "should be empty")
end)

test("returns teams with config.json", function()
    clearMocks()
    setMockDir(teamsDir, {"pr8-code-review", "s2s-500-analysis", "no-config-dir"})
    setMockConfig(teamsDir .. "/pr8-code-review/config.json", {
        name = "pr8-code-review", description = "PR review", members = {{},{},{}}
    })
    setMockConfig(teamsDir .. "/s2s-500-analysis/config.json", {
        name = "s2s-500-analysis", description = "500 analysis", members = {{},{},{},{},{},{}}
    })
    -- no-config-dir has no config.json → skipped

    local result = teams.listNamedTeams(utils, nil)
    assertEqual(#result, 2, "two teams with config.json")
    -- sorted by name: pr8 < s2s
    assertEqual(result[1].name, "pr8-code-review", "first team name")
    assertEqual(result[1].memberCount, 3, "pr8 member count")
    assertEqual(result[2].name, "s2s-500-analysis", "second team name")
    assertEqual(result[2].memberCount, 6, "s2s member count")
end)

test("skips directories without config.json", function()
    clearMocks()
    setMockDir(teamsDir, {"uuid-dir-1", "uuid-dir-2"})
    -- No config.json files set

    local result = teams.listNamedTeams(utils, nil)
    assertEqual(#result, 0, "no teams without config.json")
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", TEST_PASSED, TEST_FAILED))
if TEST_FAILED > 0 then os.exit(1) end

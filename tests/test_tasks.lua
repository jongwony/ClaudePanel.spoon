-- tests/test_tasks.lua
-- Unit tests for lib/tasks.lua (decodeCwdPath)
-- Run with: lua tests/test_tasks.lua

local TEST_PASSED = 0
local TEST_FAILED = 0

-- Mock filesystem for testing
local mockFs = {}

local function setMockFs(paths)
    mockFs = {}
    for _, path in ipairs(paths) do
        mockFs[path] = "directory"
    end
end

-- Mock hs.fs.attributes
hs = {
    fs = {
        attributes = function(path, attr)
            if attr == "mode" then
                return mockFs[path]
            end
            return nil
        end
    }
}

-- Load the tasks module
local function loadTasks()
    local path = debug.getinfo(1, "S").source:sub(2)
    local dir = path:match("(.*/)")
    local f, err = loadfile(dir .. "../lib/tasks.lua")
    if not f then error("Failed to load tasks.lua: " .. err) end
    return f()
end

local tasks = loadTasks()

-- Test helper
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

-- Test cases
print("\n=== decodeCwdPath Tests ===\n")

test("Simple path: /Users/choi", function()
    setMockFs({"/Users", "/Users/choi"})
    local result = tasks.decodeCwdPath("-Users-choi")
    assertEqual(result, "/Users/choi")
end)

test("Path with dot directory: /Users/choi/.claude", function()
    setMockFs({"/Users", "/Users/choi", "/Users/choi/.claude"})
    local result = tasks.decodeCwdPath("-Users-choi--claude")
    assertEqual(result, "/Users/choi/.claude")
end)

test("Path with dot in dirname: ClaudePanel.spoon", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/Downloads",
        "/Users/choi/Downloads/github", "/Users/choi/Downloads/github/private",
        "/Users/choi/Downloads/github/private/ClaudePanel.spoon"
    })
    local result = tasks.decodeCwdPath("-Users-choi-Downloads-github-private-ClaudePanel-spoon")
    assertEqual(result, "/Users/choi/Downloads/github/private/ClaudePanel.spoon")
end)

test("Path with hyphen in dirname: my-project", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/my-project"
    })
    local result = tasks.decodeCwdPath("-Users-choi-my-project")
    assertEqual(result, "/Users/choi/my-project")
end)

test("Path with multiple hyphens: aqueduct-deploy", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/Downloads",
        "/Users/choi/Downloads/github", "/Users/choi/Downloads/github/private",
        "/Users/choi/Downloads/github/private/aqueduct-deploy"
    })
    local result = tasks.decodeCwdPath("-Users-choi-Downloads-github-private-aqueduct-deploy")
    assertEqual(result, "/Users/choi/Downloads/github/private/aqueduct-deploy")
end)

test("Hidden directory at start: /.config", function()
    setMockFs({"/.config"})
    local result = tasks.decodeCwdPath("--config")
    assertEqual(result, "/.config")
end)

test("Multiple dots: file.test.spoon", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/file.test.spoon"
    })
    local result = tasks.decodeCwdPath("-Users-choi-file-test-spoon")
    assertEqual(result, "/Users/choi/file.test.spoon")
end)

test("Mixed hyphen and dot: my-app.spoon", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/my-app.spoon"
    })
    local result = tasks.decodeCwdPath("-Users-choi-my-app-spoon")
    assertEqual(result, "/Users/choi/my-app.spoon")
end)

test("Nested dot directories: /Users/choi/.config/.local", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/.config",
        "/Users/choi/.config/.local"
    })
    local result = tasks.decodeCwdPath("-Users-choi--config--local")
    assertEqual(result, "/Users/choi/.config/.local")
end)

test("Ambiguous: prefers existing path (hyphen exists, dot doesn't)", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/foo-bar"
        -- /Users/choi/foo.bar does NOT exist
    })
    local result = tasks.decodeCwdPath("-Users-choi-foo-bar")
    assertEqual(result, "/Users/choi/foo-bar")
end)

test("Ambiguous: prefers existing path (dot exists, hyphen doesn't)", function()
    setMockFs({
        "/Users", "/Users/choi", "/Users/choi/foo.bar"
        -- /Users/choi/foo-bar does NOT exist
    })
    local result = tasks.decodeCwdPath("-Users-choi-foo-bar")
    assertEqual(result, "/Users/choi/foo.bar")
end)

test("Non-existent path returns nil", function()
    setMockFs({"/Users", "/Users/choi"})
    local result = tasks.decodeCwdPath("-Users-choi-nonexistent")
    assertEqual(result, nil)
end)

-- groupTasksByCwd tests
print("\n=== groupTasksByCwd Tests ===\n")

test("Empty tasks returns empty groups", function()
    local result = tasks.groupTasksByCwd({})
    assertEqual(#result, 0, "Should return empty table")
end)

test("Tasks grouped by _cwd", function()
    local input = {
        {id = "1", subject = "task1", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
        {id = "2", subject = "task2", status = "in_progress", _sessionId = "s2", _cwd = "/project/b"},
        {id = "3", subject = "task3", status = "completed", _sessionId = "s1", _cwd = "/project/a"},
    }
    local result = tasks.groupTasksByCwd(input)
    assertEqual(#result, 2, "Should have 2 groups")
    assertEqual(result[1].projectName, "a", "First group alphabetically")
    assertEqual(result[2].projectName, "b", "Second group alphabetically")
    assertEqual(#result[1].tasks, 2, "Group a has 2 tasks")
    assertEqual(#result[2].tasks, 1, "Group b has 1 task")
end)

test("Tasks without _cwd grouped as Unknown (last)", function()
    local input = {
        {id = "1", subject = "task1", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
        {id = "2", subject = "task2", status = "pending", _sessionId = "s2"},
    }
    local result = tasks.groupTasksByCwd(input)
    assertEqual(#result, 2, "Should have 2 groups")
    assertEqual(result[1].projectName, "a", "Known project first")
    assertEqual(result[2].projectName, "Unknown", "Unknown last")
end)

test("Tasks sorted by status within group (in_progress > pending > completed)", function()
    local input = {
        {id = "1", subject = "completed", status = "completed", _sessionId = "s1", _cwd = "/project/a"},
        {id = "2", subject = "pending", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
        {id = "3", subject = "in_progress", status = "in_progress", _sessionId = "s1", _cwd = "/project/a"},
    }
    local result = tasks.groupTasksByCwd(input)
    assertEqual(#result, 1, "Should have 1 group")
    assertEqual(result[1].tasks[1].status, "in_progress", "in_progress first")
    assertEqual(result[1].tasks[2].status, "pending", "pending second")
    assertEqual(result[1].tasks[3].status, "completed", "completed last")
end)

test("Groups sorted alphabetically by projectName", function()
    local input = {
        {id = "1", subject = "t1", status = "pending", _sessionId = "s1", _cwd = "/z-project"},
        {id = "2", subject = "t2", status = "pending", _sessionId = "s2", _cwd = "/a-project"},
    }
    local result = tasks.groupTasksByCwd(input)
    assertEqual(result[1].projectName, "a-project", "a-project first")
    assertEqual(result[2].projectName, "z-project", "z-project second")
end)

test("Same status tasks sorted by ID within group", function()
    local input = {
        {id = "3", subject = "t3", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
        {id = "1", subject = "t1", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
        {id = "2", subject = "t2", status = "pending", _sessionId = "s1", _cwd = "/project/a"},
    }
    local result = tasks.groupTasksByCwd(input)
    assertEqual(result[1].tasks[1].id, "1", "ID 1 first")
    assertEqual(result[1].tasks[2].id, "2", "ID 2 second")
    assertEqual(result[1].tasks[3].id, "3", "ID 3 third")
end)

-- Summary
print(string.format("\n=== Results: %d passed, %d failed ===\n",
    TEST_PASSED, TEST_FAILED))

os.exit(TEST_FAILED > 0 and 1 or 0)

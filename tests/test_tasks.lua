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

-- Summary
print(string.format("\n=== Results: %d passed, %d failed ===\n",
    TEST_PASSED, TEST_FAILED))

os.exit(TEST_FAILED > 0 and 1 or 0)

-- tests/test_snooze.lua
-- Unit tests for lib/snooze.lua
-- Run with: lua tests/test_snooze.lua

local TEST_PASSED = 0
local TEST_FAILED = 0

-- Mock hs.json for test environment
local json_encode, json_decode

-- Minimal JSON encoder for test purposes (handles strings, numbers, bools, tables)
local function simpleJsonEncode(val)
    if val == nil then return "null" end
    local t = type(val)
    if t == "string" then
        local escaped = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. escaped .. '"'
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "table" then
        -- Check if array
        local isArray = #val > 0 or next(val) == nil
        if not isArray then
            -- Check if all keys are strings
            for k, _ in pairs(val) do
                if type(k) ~= "string" then
                    isArray = true
                    break
                end
            end
        end
        -- Determine array vs object by checking for string keys
        local hasStringKey = false
        for k, _ in pairs(val) do
            if type(k) == "string" then hasStringKey = true; break end
        end
        if hasStringKey then
            -- Object
            local parts = {}
            local keys = {}
            for k, _ in pairs(val) do table.insert(keys, k) end
            table.sort(keys)
            for _, k in ipairs(keys) do
                table.insert(parts, simpleJsonEncode(k) .. ":" .. simpleJsonEncode(val[k]))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        else
            -- Array
            local parts = {}
            for i = 1, #val do
                table.insert(parts, simpleJsonEncode(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
    end
    return "null"
end

-- Minimal JSON decoder for test purposes
local function simpleJsonDecode(str)
    if not str then return nil end
    -- Use Lua load to parse JSON (safe enough for tests)
    str = str:gsub('"%s*:%s*', '"]=')
    str = str:gsub('{%s*"', '{["')
    str = str:gsub(',%s*"', ',["')
    str = str:gsub(':null', '=nil')
    str = str:gsub(':true', '=true')
    str = str:gsub(':false', '=false')
    -- Fix nested objects after ]=
    str = str:gsub('=%s*{%s*%[', '={[')
    local fn, err = load("return " .. str)
    if fn then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    return nil
end

hs = {
    json = {
        encode = simpleJsonEncode,
        decode = simpleJsonDecode,
    }
}

-- Mock file system for tests
local mockFiles = {}

-- Override io.open to intercept file writes into mockFiles
local realIoOpen = io.open
io.open = function(path, mode)
    if mode == "w" then
        -- Return a mock file handle that captures writes
        local buffer = {}
        return {
            write = function(self, content) table.insert(buffer, content) end,
            close = function(self) mockFiles[path] = table.concat(buffer) end,
        }
    elseif mode == "r" then
        -- Read from mockFiles
        if mockFiles[path] then
            local content = mockFiles[path]
            local pos = 0
            return {
                read = function(self, fmt)
                    if fmt == "*all" or fmt == "*a" then
                        if pos > 0 then return nil end
                        pos = 1
                        return content
                    end
                    return nil
                end,
                close = function(self) end,
            }
        end
        return nil
    end
    return realIoOpen(path, mode)
end

local mockUtils = {
    readFile = function(path)
        return mockFiles[path]
    end,
    parseJSON = function(str)
        if not str then return nil end
        return simpleJsonDecode(str)
    end,
}

local function mockLog(msg)
    -- silent during tests
end

-- Load the snooze module
local function loadSnooze()
    local path = debug.getinfo(1, "S").source:sub(2)
    local dir = path:match("(.*/)")
    local f, err = loadfile(dir .. "../lib/snooze.lua")
    if not f then error("Failed to load snooze.lua: " .. err) end
    return f()
end

local snooze = loadSnooze()

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

local function assertNotNil(actual, msg)
    if actual == nil then
        error(msg or "Expected non-nil value")
    end
end

local function assertNil(actual, msg)
    if actual ~= nil then
        error((msg or "Expected nil") .. ", got: " .. tostring(actual))
    end
end

-- Reset mock files before each relevant test
local function resetMockFiles()
    mockFiles = {}
end

local SNOOZE_PATH = "/tmp/test_snooze.json"

-- === parseISO Tests ===
print("\n=== parseISO Tests ===\n")

test("parseISO: nil input returns nil", function()
    assertNil(snooze.parseISO(nil))
end)

test("parseISO: empty string returns nil", function()
    assertNil(snooze.parseISO(""))
end)

test("parseISO: invalid string returns nil", function()
    assertNil(snooze.parseISO("not-a-date"))
end)

test("parseISO: number input returns nil", function()
    assertNil(snooze.parseISO(12345))
end)

test("parseISO: UTC Z suffix", function()
    local epoch = snooze.parseISO("2026-02-28T00:00:00Z")
    assertNotNil(epoch, "Should parse UTC date")
    -- Verify by converting back: should be midnight UTC
    local utcTime = os.date("!*t", epoch)
    assertEqual(utcTime.year, 2026, "Year should be 2026")
    assertEqual(utcTime.month, 2, "Month should be 2")
    assertEqual(utcTime.day, 28, "Day should be 28")
    assertEqual(utcTime.hour, 0, "Hour should be 0 UTC")
    assertEqual(utcTime.min, 0, "Min should be 0")
    assertEqual(utcTime.sec, 0, "Sec should be 0")
end)

test("parseISO: positive offset +09:00", function()
    -- 2026-02-28T09:00:00+09:00 is 2026-02-28T00:00:00Z
    local epoch = snooze.parseISO("2026-02-28T09:00:00+09:00")
    assertNotNil(epoch, "Should parse +09:00 offset")
    local utcTime = os.date("!*t", epoch)
    assertEqual(utcTime.year, 2026, "Year")
    assertEqual(utcTime.month, 2, "Month")
    assertEqual(utcTime.day, 28, "Day")
    assertEqual(utcTime.hour, 0, "Hour should be 0 UTC (09:00+09:00 = 00:00Z)")
    assertEqual(utcTime.min, 0, "Min")
end)

test("parseISO: negative offset -05:00", function()
    -- 2026-02-27T19:00:00-05:00 is 2026-02-28T00:00:00Z
    local epoch = snooze.parseISO("2026-02-27T19:00:00-05:00")
    assertNotNil(epoch, "Should parse -05:00 offset")
    local utcTime = os.date("!*t", epoch)
    assertEqual(utcTime.year, 2026, "Year")
    assertEqual(utcTime.month, 2, "Month")
    assertEqual(utcTime.day, 28, "Day")
    assertEqual(utcTime.hour, 0, "Hour should be 0 UTC (19:00-05:00 = 00:00Z)")
end)

test("parseISO: round-trip consistency", function()
    local original = "2026-06-15T14:30:00+09:00"
    local epoch = snooze.parseISO(original)
    assertNotNil(epoch, "Should parse")
    local roundTrip = snooze.toISO(epoch)
    assertNotNil(roundTrip, "Should format back")
    -- Parse again and verify same epoch
    local epoch2 = snooze.parseISO(roundTrip)
    assertEqual(epoch2, epoch, "Round-trip should preserve epoch")
end)

-- === toISO Tests ===
print("\n=== toISO Tests ===\n")

test("toISO: nil input returns nil", function()
    assertNil(snooze.toISO(nil))
end)

test("toISO: format matches ISO 8601 pattern", function()
    local epoch = os.time({year=2026, month=2, day=28, hour=9, min=0, sec=0})
    local result = snooze.toISO(epoch)
    assertNotNil(result, "Should produce string")
    -- Pattern: YYYY-MM-DDTHH:MM:SS+HH:MM or -HH:MM
    local matched = result:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%+%-]%d%d:%d%d$")
    assertNotNil(matched, "Should match ISO 8601 format, got: " .. result)
end)

-- === makeKey Tests ===
print("\n=== makeKey Tests ===\n")

test("makeKey: composes sessionId:taskId", function()
    assertEqual(snooze.makeKey("abc-123", "5"), "abc-123:5")
end)

test("makeKey: handles empty strings", function()
    assertEqual(snooze.makeKey("", ""), ":")
end)

-- === load Tests ===
print("\n=== load Tests ===\n")

test("load: missing file returns empty table", function()
    resetMockFiles()
    local data = snooze.load("/nonexistent/path.json", mockUtils, mockLog)
    assertEqual(next(data), nil, "Should be empty table")
end)

test("load: corrupt JSON returns empty table and creates backup", function()
    resetMockFiles()
    local corruptContent = "not valid json {"
    mockFiles[SNOOZE_PATH] = corruptContent
    local data = snooze.load(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(next(data), nil, "Should be empty table for corrupt JSON")
    -- Verify backup was created
    local bakContent = mockFiles[SNOOZE_PATH .. ".bak"]
    assertNotNil(bakContent, "Backup file should be created")
    assertEqual(bakContent, corruptContent, "Backup should contain original corrupt content")
end)

test("load: valid JSON returns data", function()
    resetMockFiles()
    local entry = {sessionId="s1", taskId="1", subject="Test", snoozeUntil="2026-02-28T09:00:00+09:00", createdAt="2026-02-27T15:00:00+09:00"}
    local jsonData = simpleJsonEncode({["s1:1"] = entry})
    mockFiles[SNOOZE_PATH] = jsonData
    local data = snooze.load(SNOOZE_PATH, mockUtils, mockLog)
    assertNotNil(data["s1:1"], "Should have entry with key s1:1")
    assertEqual(data["s1:1"].subject, "Test", "Subject should match")
end)

-- === add and remove Tests ===
print("\n=== add/remove Tests ===\n")

test("add: creates entry with correct key", function()
    resetMockFiles()
    local entry = {
        sessionId = "sess-1",
        taskId = "42",
        subject = "Fix bug",
        snoozeUntil = "2026-02-28T09:00:00+09:00",
        createdAt = "2026-02-27T15:00:00+09:00",
    }
    snooze.add(SNOOZE_PATH, entry, mockUtils, mockLog)
    local data = snooze.load(SNOOZE_PATH, mockUtils, mockLog)
    assertNotNil(data["sess-1:42"], "Should have entry")
    assertEqual(data["sess-1:42"].subject, "Fix bug")
end)

test("add: missing fields returns false", function()
    resetMockFiles()
    local result = snooze.add(SNOOZE_PATH, {sessionId = "s1"}, mockUtils, mockLog)
    assertEqual(result, false, "Should return false for incomplete entry")
end)

test("add: nil entry returns false", function()
    resetMockFiles()
    local result = snooze.add(SNOOZE_PATH, nil, mockUtils, mockLog)
    assertEqual(result, false, "Should return false for nil")
end)

test("remove: existing key returns true", function()
    resetMockFiles()
    local entry = {
        sessionId = "s1", taskId = "1", subject = "Test",
        snoozeUntil = "2026-02-28T09:00:00+09:00", createdAt = "2026-02-27T15:00:00+09:00",
    }
    snooze.add(SNOOZE_PATH, entry, mockUtils, mockLog)
    local result = snooze.remove(SNOOZE_PATH, "s1:1", mockUtils, mockLog)
    assertEqual(result, true, "Should return true")
    local data = snooze.load(SNOOZE_PATH, mockUtils, mockLog)
    assertNil(data["s1:1"], "Entry should be removed")
end)

test("remove: non-existing key returns false", function()
    resetMockFiles()
    local result = snooze.remove(SNOOZE_PATH, "nonexistent:key", mockUtils, mockLog)
    assertEqual(result, false, "Should return false for missing key")
end)

-- === list Tests ===
print("\n=== list Tests ===\n")

test("list: returns items sorted by snoozeUntil ascending", function()
    resetMockFiles()
    -- Add entries with different times
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "1", subject = "Later",
        snoozeUntil = "2026-03-01T09:00:00+09:00", createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "2", subject = "Sooner",
        snoozeUntil = "2026-02-28T09:00:00+09:00", createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "3", subject = "Latest",
        snoozeUntil = "2026-03-15T09:00:00+09:00", createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)

    local items = snooze.list(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(#items, 3, "Should have 3 items")
    assertEqual(items[1].subject, "Sooner", "First should be earliest")
    assertEqual(items[2].subject, "Later", "Second")
    assertEqual(items[3].subject, "Latest", "Third should be latest")
end)

test("list: items have key and epochUntil fields", function()
    resetMockFiles()
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "1", subject = "Test",
        snoozeUntil = "2026-02-28T09:00:00+09:00", createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)
    local items = snooze.list(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(#items, 1, "Should have 1 item")
    assertEqual(items[1].key, "s1:1", "Should have key field")
    assertNotNil(items[1].epochUntil, "Should have epochUntil field")
end)

test("list: empty file returns empty array", function()
    resetMockFiles()
    local items = snooze.list(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(#items, 0, "Should be empty")
end)

-- === checkDue Tests ===
print("\n=== checkDue Tests ===\n")

test("checkDue: returns past entries, excludes future", function()
    resetMockFiles()
    -- Save original os.time
    local originalOsTime = os.time

    -- Use a fixed "now": 2026-02-28T12:00:00+09:00 => UTC 03:00
    local fakeNow = snooze.parseISO("2026-02-28T12:00:00+09:00")

    -- Mock os.time
    os.time = function(t)
        if t then return originalOsTime(t) end
        return fakeNow
    end

    -- Past entry (should be due)
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "1", subject = "Past task",
        snoozeUntil = "2026-02-28T09:00:00+09:00",
        createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)

    -- Future entry (should NOT be due)
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "2", subject = "Future task",
        snoozeUntil = "2026-03-01T09:00:00+09:00",
        createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)

    -- Exactly now (should be due - <= comparison)
    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "3", subject = "Exact now",
        snoozeUntil = "2026-02-28T12:00:00+09:00",
        createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)

    local due = snooze.checkDue(SNOOZE_PATH, mockUtils, mockLog)

    -- Restore os.time
    os.time = originalOsTime

    assertEqual(#due, 2, "Should have 2 due entries (past + exact now)")

    -- Verify the due items are the right ones
    local subjects = {}
    for _, item in ipairs(due) do
        subjects[item.subject] = true
    end
    assertEqual(subjects["Past task"], true, "Past task should be due")
    assertEqual(subjects["Exact now"], true, "Exact now should be due")
    assertNil(subjects["Future task"], "Future task should NOT be due")
end)

test("checkDue: empty data returns empty array", function()
    resetMockFiles()
    local due = snooze.checkDue(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(#due, 0, "Should be empty")
end)

test("checkDue: does not remove due entries", function()
    resetMockFiles()
    local originalOsTime = os.time

    -- All entries are in the past
    local fakeNow = snooze.parseISO("2030-01-01T00:00:00Z")
    os.time = function(t)
        if t then return originalOsTime(t) end
        return fakeNow
    end

    snooze.add(SNOOZE_PATH, {
        sessionId = "s1", taskId = "1", subject = "Old task",
        snoozeUntil = "2026-02-28T09:00:00+09:00",
        createdAt = "2026-02-27T15:00:00+09:00",
    }, mockUtils, mockLog)

    local due = snooze.checkDue(SNOOZE_PATH, mockUtils, mockLog)
    assertEqual(#due, 1, "Should find 1 due")

    -- Verify data still exists after checkDue
    local data = snooze.load(SNOOZE_PATH, mockUtils, mockLog)
    assertNotNil(data["s1:1"], "Entry should still exist after checkDue")

    os.time = originalOsTime
end)

-- Summary
print(string.format("\n=== Results: %d passed, %d failed ===\n",
    TEST_PASSED, TEST_FAILED))

os.exit(TEST_FAILED > 0 and 1 or 0)

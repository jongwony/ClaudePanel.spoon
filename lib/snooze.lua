-- lib/snooze.lua
-- Snooze management for tasks

local M = {}

-- Build composite key from sessionId and taskId
function M.makeKey(sessionId, taskId)
    return sessionId .. ":" .. taskId
end

-- Parse ISO 8601 string to epoch seconds
-- Handles: 2026-02-28T09:00:00+09:00, 2026-02-28T09:00:00Z, 2026-02-28T09:00:00 (local)
function M.parseISO(isoStr)
    if not isoStr or type(isoStr) ~= "string" then return nil end

    local year, month, day, hour, min, sec, tz =
        isoStr:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)")
    if not year then return nil end

    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)

    -- os.time() interprets its argument as local time and returns epoch.
    -- We need to treat the parsed components as if they were in a specific timezone.
    --
    -- Strategy: interpret as local time first, then adjust based on timezone info.
    local timeTable = {year = year, month = month, day = day,
                       hour = hour, min = min, sec = sec, isdst = false}
    local epoch = os.time(timeTable)
    -- epoch now represents "these date/time values interpreted as local time"

    if tz == "Z" or tz == "z" then
        -- The values are UTC, but os.time interpreted them as local.
        -- We need the system's UTC offset to correct.
        -- sysOffset = localTime - UTC (positive east of Greenwich)
        local lt = os.date("*t", epoch)
        local ut = os.date("!*t", epoch)
        lt.isdst = false
        local sysOffset = os.difftime(os.time(lt), os.time(ut))
        -- os.time gave us epoch assuming local; actual UTC is sysOffset seconds later
        epoch = epoch + sysOffset
    elseif tz ~= "" and tz ~= nil then
        local sign, tzHour, tzMin = tz:match("^([%+%-])(%d%d):(%d%d)")
        if sign then
            -- The values are in the given offset timezone.
            -- os.time interpreted them as local time.
            -- Compute system offset first.
            local lt = os.date("*t", epoch)
            local ut = os.date("!*t", epoch)
            lt.isdst = false
            local sysOffset = os.difftime(os.time(lt), os.time(ut))
            -- Convert from "local interpretation" to UTC
            epoch = epoch + sysOffset
            -- Now subtract the source timezone offset to get true UTC
            local sourceOffset = (tonumber(tzHour) * 3600 + tonumber(tzMin) * 60)
            if sign == "+" then
                epoch = epoch - sourceOffset
            else
                epoch = epoch + sourceOffset
            end
        end
    end
    -- If tz == "" (no timezone), epoch stays as-is (local time interpretation is correct)

    return epoch
end

-- Convert epoch seconds to ISO 8601 string with local timezone offset
function M.toISO(epochTime)
    if not epochTime then return nil end

    local localTime = os.date("*t", epochTime)
    local utcTime = os.date("!*t", epochTime)

    -- Calculate local offset in seconds
    local localEpoch = os.time(localTime)
    local utcEpoch = os.time(utcTime)
    local offsetSec = os.difftime(localEpoch, utcEpoch)

    local sign = "+"
    if offsetSec < 0 then
        sign = "-"
        offsetSec = -offsetSec
    end

    local offsetHour = math.floor(offsetSec / 3600)
    local offsetMin = math.floor((offsetSec % 3600) / 60)

    return string.format("%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d",
        localTime.year, localTime.month, localTime.day,
        localTime.hour, localTime.min, localTime.sec,
        sign, offsetHour, offsetMin)
end

-- Load snooze data from file
function M.load(snoozePath, utils, log)
    local content = utils.readFile(snoozePath)
    if not content then
        return {}
    end
    local data = utils.parseJSON(content)
    if not data or type(data) ~= "table" then
        if log then log("Snooze: corrupt or empty file, returning {}") end
        return {}
    end
    return data
end

-- Save snooze data to file
function M.save(snoozePath, data, log)
    local encoded = hs.json.encode(data)
    if not encoded then
        if log then log("Snooze: failed to encode data") end
        return false
    end
    local f = io.open(snoozePath, "w")
    if f then
        f:write(encoded)
        f:close()
        if log then log("Snooze: saved to " .. snoozePath) end
        return true
    end
    if log then log("Snooze: failed to write to " .. snoozePath) end
    return false
end

-- Add a snooze entry
function M.add(snoozePath, entry, utils, log)
    if not entry or not entry.sessionId or not entry.taskId
       or not entry.subject or not entry.snoozeUntil or not entry.createdAt then
        if log then log("Snooze: add() missing required fields") end
        return false
    end
    local data = M.load(snoozePath, utils, log)
    local key = M.makeKey(entry.sessionId, entry.taskId)
    data[key] = {
        sessionId = entry.sessionId,
        taskId = entry.taskId,
        subject = entry.subject,
        snoozeUntil = entry.snoozeUntil,
        createdAt = entry.createdAt,
    }
    return M.save(snoozePath, data, log)
end

-- Remove a snooze entry by key
function M.remove(snoozePath, key, utils, log)
    local data = M.load(snoozePath, utils, log)
    if not data[key] then
        return false
    end
    data[key] = nil
    M.save(snoozePath, data, log)
    return true
end

-- List all snooze entries sorted by snoozeUntil ascending
function M.list(snoozePath, utils, log)
    local data = M.load(snoozePath, utils, log)
    local items = {}
    for key, entry in pairs(data) do
        local item = {}
        for k, v in pairs(entry) do
            item[k] = v
        end
        item.key = key
        item.epochUntil = M.parseISO(entry.snoozeUntil)
        table.insert(items, item)
    end
    table.sort(items, function(a, b)
        return (a.epochUntil or 0) < (b.epochUntil or 0)
    end)
    return items
end

-- Check for due snooze entries (epochUntil <= os.time())
function M.checkDue(snoozePath, utils, log)
    local items = M.list(snoozePath, utils, log)
    local now = os.time()
    local due = {}
    for _, item in ipairs(items) do
        if item.epochUntil and item.epochUntil <= now then
            table.insert(due, item)
        end
    end
    return due
end

return M

-- lib/updater.lua
-- GitHub release update checker

local M = {}

-- Semantic version comparison (returns true if latest > current)
function M.isNewerVersion(latest, current)
    local function parseVersion(v)
        local major, minor, patch = v:match("^v?(%d+)%.(%d+)%.(%d+)")
        return {
            tonumber(major) or 0,
            tonumber(minor) or 0,
            tonumber(patch) or 0
        }
    end
    local l = parseVersion(latest)
    local c = parseVersion(current)
    for i = 1, 3 do
        if l[i] > c[i] then return true end
        if l[i] < c[i] then return false end
    end
    return false
end

-- Check for updates via GitHub API
function M.checkForUpdates(homepage, currentVersion, utils, log, callback)
    local repoOwner = homepage:match("github.com/([^/]+)")
    local repoName = homepage:match("github.com/[^/]+/([^/]+)")

    if not repoOwner or not repoName then
        log("Could not parse GitHub repo from homepage")
        if callback then callback(nil, "Invalid homepage URL") end
        return
    end

    local apiUrl = string.format(
        "https://api.github.com/repos/%s/%s/releases/latest",
        repoOwner, repoName
    )

    log("Checking for updates: " .. apiUrl)

    hs.http.asyncGet(apiUrl, {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "Hammerspoon-ClaudePanel"
    }, function(status, body, headers)
        if status ~= 200 then
            log("Update check failed: HTTP " .. status)
            if callback then callback(nil, "HTTP " .. status) end
            return
        end

        local release = utils.parseJSON(body)
        if not release or not release.tag_name then
            log("Update check failed: Invalid response")
            if callback then callback(nil, "Invalid response") end
            return
        end

        local latestVersion = release.tag_name
        local hasUpdate = M.isNewerVersion(latestVersion, currentVersion)

        log(string.format("Version check: current=%s, latest=%s, hasUpdate=%s",
            currentVersion, latestVersion, tostring(hasUpdate)))

        if callback then
            callback({
                hasUpdate = hasUpdate,
                currentVersion = currentVersion,
                latestVersion = latestVersion,
                releaseUrl = release.html_url,
                releaseNotes = release.body,
                publishedAt = release.published_at
            })
        end
    end)
end

-- Show update notification
function M.showUpdateNotification(updateInfo)
    if not updateInfo or not updateInfo.hasUpdate then return end

    local notification = hs.notify.new(function(n)
        -- Open release page on click
        if updateInfo.releaseUrl then
            hs.urlevent.openURL(updateInfo.releaseUrl)
        end
    end, {
        title = "ClaudePanel Update Available",
        subTitle = string.format("v%s → %s", updateInfo.currentVersion, updateInfo.latestVersion),
        informativeText = "Click to view release notes",
        hasActionButton = true,
        actionButtonTitle = "View",
        withdrawAfter = 10
    })
    notification:send()
end

-- Maybe check for updates (respects interval)
function M.maybeCheckForUpdates(config, state, homepage, currentVersion, utils, log, saveStateCallback)
    if not config.checkForUpdates then
        log("Update check disabled")
        return
    end

    local now = os.time()
    local lastCheck = state.lastUpdateCheck or 0
    local interval = config.updateCheckInterval

    if (now - lastCheck) < interval then
        log(string.format("Skipping update check (last check: %d seconds ago)", now - lastCheck))
        return
    end

    M.checkForUpdates(homepage, currentVersion, utils, log, function(updateInfo, err)
        if err then
            log("Update check error: " .. err)
            return
        end

        -- Save check time
        state.lastUpdateCheck = os.time()
        if saveStateCallback then saveStateCallback() end

        if updateInfo and updateInfo.hasUpdate then
            M.showUpdateNotification(updateInfo)
        end
    end)
end

return M

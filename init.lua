-- ClaudeTasks.spoon
-- Hammerspoon Spoon for Claude Code Task viewer
-- opt+. 핫키로 플로팅 윈도우에 태스크 목록 표시

local obj = {}

-- Spoon Metadata
obj.name = "ClaudeTasks"
obj.version = "1.3.0"
obj.author = "jongwony <lastone9182@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/jongwony/ClaudeTasks.spoon"
obj.spoonPath = hs.spoons.scriptPath()

-- ============================================================================
-- 설정
-- ============================================================================

obj.config = {
    -- UI
    width = 420,
    height = 580,
    margin = 20,
    refreshDebounce = 0.2,
    debugMode = true,

    -- Session
    taskListId = os.getenv("CLAUDE_CODE_TASK_LIST_ID"),

    -- External Tools (nil = auto-discover)
    claudePath = nil,
    terminalApp = nil,
    shell = nil,

    -- Update Checker
    checkForUpdates = true,          -- start() 시 자동 체크
    updateCheckInterval = 86400,     -- 체크 간격 (초, 기본 24시간)
}

-- ============================================================================
-- Helper Functions for Discovery
-- ============================================================================

local function discoverClaudePath()
    if obj.config.claudePath then return obj.config.claudePath end
    -- GUI 앱은 PATH가 제한적이므로 일반적인 설치 경로를 직접 탐색
    local candidates = {
        os.getenv("HOME") .. "/.local/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    }
    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path) then return path end
    end
    return nil
end

local function discoverTerminalApp()
    if obj.config.terminalApp then return obj.config.terminalApp end
    local candidates = {
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    }
    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path) then return path end
    end
    return nil
end

local function getShell()
    return obj.config.shell or os.getenv("SHELL") or "/bin/zsh"
end

-- ============================================================================
-- 영속 상태 관리
-- ============================================================================

obj.state = {
    currentTaskListId = nil,
    configPath = nil,  -- Set in init()
    lastUpdateCheck = nil,  -- 마지막 업데이트 체크 시간 (Unix timestamp)
}

-- ============================================================================
-- 내부 상태
-- ============================================================================

local webview = nil
local pathWatcher = nil
local refreshTimer = nil
local isVisible = false
local usercontent = nil  -- JS-Lua 브릿지
local cwdCache = {}  -- sessionId -> cwd path cache

-- ============================================================================
-- 유틸리티 함수
-- ============================================================================

local function log(message)
    if obj.config.debugMode then
        print("[ClaudeTasks] " .. message)
    end
end

local function getTasksDir()
    return os.getenv("HOME") .. "/.claude/tasks"
end

-- JSON 파싱 (간단한 구현 - 태스크 파일용)
local function parseJSON(str)
    -- hs.json 사용
    local success, result = pcall(hs.json.decode, str)
    if success then
        return result
    end
    return nil
end

-- 디렉토리 내 모든 항목 나열
local function listDir(path)
    local items = {}
    local handle = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    if handle then
        for line in handle:lines() do
            table.insert(items, line)
        end
        handle:close()
    end
    return items
end

-- 파일이 존재하는지 확인
local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- 파일 내용 읽기
local function readFile(path)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        return content
    end
    return nil
end

-- ============================================================================
-- 상태 관리 함수
-- ============================================================================

local function loadState()
    local f = io.open(obj.state.configPath, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local data = parseJSON(content)
        if data then
            obj.state.currentTaskListId = data.currentTaskListId
            obj.state.lastUpdateCheck = data.lastUpdateCheck
            obj.config.taskListId = data.currentTaskListId
            log("State loaded: " .. (data.currentTaskListId or "nil"))
        end
    end
end

local function saveState()
    local data = hs.json.encode({
        currentTaskListId = obj.state.currentTaskListId,
        lastUpdateCheck = obj.state.lastUpdateCheck
    })
    local f = io.open(obj.state.configPath, "w")
    if f then
        f:write(data)
        f:close()
        log("State saved: " .. (obj.state.currentTaskListId or "nil"))
    end
end

local function listSessionDirs()
    local tasksDir = getTasksDir()
    if not fileExists(tasksDir) then
        return {}
    end

    local allDirs = listDir(tasksDir)
    local nonEmptySessions = {}

    for _, sessionId in ipairs(allDirs) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = listDir(sessionDir)
        -- .json 파일이 하나라도 있으면 포함
        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                table.insert(nonEmptySessions, sessionId)
                break
            end
        end
    end

    return nonEmptySessions
end

-- ============================================================================
-- CWD 추출 함수
-- ============================================================================

local function decodeCwdPath(encodedDir)
    -- Claude encodes paths: / → -, /. → --
    -- Problem: hyphens in dir names (e.g. team-attention) are ambiguous.
    -- Solution: walk the filesystem to resolve the correct path.
    local parts = {}
    -- Split on '-' but first handle '--' (encoded /.)
    local encoded = encodedDir:gsub("%-%-", "\001")
    -- Remove leading '-' (represents root /)
    if encoded:sub(1,1) == "-" then
        encoded = encoded:sub(2)
    elseif encoded:sub(1,1) == "\001" then
        -- leading -- means /.
        encoded = encoded:sub(2)
        parts[1] = "."
    end
    local segments = {}
    for seg in encoded:gmatch("[^\001]+") do
        table.insert(segments, seg)
    end
    -- For each '--' separated segment, resolve dash ambiguity via filesystem
    local function resolveSegment(basePath, segment)
        local tokens = {}
        for t in segment:gmatch("[^%-]+") do
            table.insert(tokens, t)
        end
        if #tokens == 0 then return basePath end
        -- Try greedily matching longest existing directory names
        local function tryResolve(idx, currentPath, depth)
            depth = depth or 0
            if depth > 50 then
                log("Path resolution depth limit reached: " .. currentPath)
                return currentPath
            end
            if idx > #tokens then return currentPath end
            local accumulated = tokens[idx]
            for j = idx, #tokens do
                if j > idx then
                    accumulated = accumulated .. "-" .. tokens[j]
                end
                local candidate = currentPath .. "/" .. accumulated
                if j == #tokens then
                    -- Last possible combo, must use it
                    return candidate
                end
                if hs.fs.attributes(candidate, "mode") == "directory" then
                    local result = tryResolve(j + 1, candidate, depth + 1)
                    if result then return result end
                end
            end
            -- Fallback: treat each token as a directory
            return tryResolve(idx + 1, currentPath .. "/" .. tokens[idx], depth + 1)
        end
        return tryResolve(1, basePath)
    end
    local result = ""
    for i, seg in ipairs(segments) do
        local actualSeg = seg
        if i > 1 or (parts[1] == ".") then
            -- This segment represents a hidden directory (starts with .)
            actualSeg = "." .. seg
        end
        result = resolveSegment(result, actualSeg)
        if not hs.fs.attributes(result, "mode") then
            log("Warning: resolved path may not exist: " .. result)
        end
    end
    return result
end

local function getCwdFromSessionId(sessionId)
    if cwdCache[sessionId] then return cwdCache[sessionId] end

    local projectsDir = os.getenv("HOME") .. "/.claude/projects"
    if not fileExists(projectsDir) then return nil end

    for _, encodedDir in ipairs(listDir(projectsDir)) do
        local sessionFile = projectsDir .. "/" .. encodedDir .. "/" .. sessionId .. ".jsonl"
        if fileExists(sessionFile) then
            local cwd = decodeCwdPath(encodedDir)
            cwdCache[sessionId] = cwd
            return cwd
        end
    end
    return nil
end

-- ============================================================================
-- 태스크 로딩
-- ============================================================================

local function loadAllTasks()
    local tasks = {}
    local tasksDir = getTasksDir()

    if not fileExists(tasksDir) then
        log("Tasks directory does not exist: " .. tasksDir)
        return tasks
    end

    -- 특정 세션 ID가 설정되어 있으면 해당 세션만 로드
    local sessions = {}
    if obj.config.taskListId then
        sessions = {obj.config.taskListId}
    else
        sessions = listDir(tasksDir)
    end

    for _, sessionId in ipairs(sessions) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = listDir(sessionDir)

        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                local filepath = sessionDir .. "/" .. filename
                local content = readFile(filepath)

                if content then
                    local task = parseJSON(content)
                    if task then
                        task._sessionId = sessionId
                        task._filepath = filepath
                        task._cwd = getCwdFromSessionId(sessionId)
                        table.insert(tasks, task)
                    end
                end
            end
        end
    end

    -- ID로 정렬 (숫자 우선, 문자열 후순)
    table.sort(tasks, function(a, b)
        local aNum = tonumber(a.id)
        local bNum = tonumber(b.id)
        if aNum and bNum then
            return aNum < bNum
        end
        return tostring(a.id) < tostring(b.id)
    end)

    log("Loaded " .. #tasks .. " tasks")
    return tasks
end

-- ============================================================================
-- HTML 렌더링
-- ============================================================================

local function escapeHtml(str)
    if not str then return "" end
    return str:gsub("&", "&amp;")
              :gsub("<", "&lt;")
              :gsub(">", "&gt;")
              :gsub('"', "&quot;")
              :gsub("'", "&#39;")
end

-- 문자열을 JSON으로 인코딩 (hs.json.encode는 테이블만 받음)
local function jsonEncodeString(str)
    if not str then return '""' end
    local encoded = hs.json.encode({v = str})
    -- {"v":"..."} 에서 값 부분만 추출
    local jsonStr = encoded:match('"v":(.+)}$')
    -- HTML 속성(작은따옴표)에서 사용할 때 작은따옴표를 JS hex escape로 변환
    return jsonStr:gsub("'", "\\x27")
end

local function getStatusColor(status)
    if status == "completed" then
        return "#22c55e"  -- green
    elseif status == "in_progress" then
        return "#f59e0b"  -- amber
    else
        return "#6b7280"  -- gray (pending)
    end
end

local function getStatusIcon(status)
    if status == "completed" then
        return "✓"
    elseif status == "in_progress" then
        return "◐"
    else
        return "○"
    end
end

-- metadata를 뱃지 HTML로 변환
local function generateMetadataBadges(metadata)
    if not metadata or type(metadata) ~= "table" then
        return ""
    end
    local badges = ""
    for key, value in pairs(metadata) do
        local displayValue = tostring(value)
        if type(value) == "table" then
            displayValue = hs.json.encode(value)
        end
        -- 긴 값은 truncate
        if #displayValue > 20 then
            displayValue = displayValue:sub(1, 17) .. "..."
        end
        badges = badges .. string.format(
            '<span class="metadata-badge" title="%s: %s"><span class="meta-key">%s:</span> %s</span>',
            escapeHtml(key),
            escapeHtml(tostring(value)),
            escapeHtml(key),
            escapeHtml(displayValue)
        )
    end
    return badges
end

local function generateHTML(tasks)
    local pendingTasks = {}
    local inProgressTasks = {}
    local completedTasks = {}

    for _, task in ipairs(tasks) do
        if task.status == "completed" then
            table.insert(completedTasks, task)
        elseif task.status == "in_progress" then
            table.insert(inProgressTasks, task)
        else
            table.insert(pendingTasks, task)
        end
    end

    -- 세션 datalist 옵션 생성
    local sessions = listSessionDirs()
    local sessionOptions = ''
    for _, sessionId in ipairs(sessions) do
        sessionOptions = sessionOptions .. string.format(
            '                    <option value="%s"></option>\n',
            escapeHtml(sessionId)
        )
    end
    local currentSessionValue = obj.state.currentTaskListId or ''

    local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.4;
            background: rgba(30, 30, 30, 0.95);
            color: #e5e5e5;
            padding: 16px;
            overflow-y: auto;
            -webkit-font-smoothing: antialiased;
        }
        .header {
            margin-bottom: 12px;
            padding-bottom: 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
        }
        .header-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        .title {
            font-size: 15px;
            font-weight: 600;
            color: #fff;
        }
        .header-actions {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .launch-btn {
            background: #22c55e;
            color: #fff;
            border: none;
            width: 32px;
            height: 32px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
        }
        .launch-btn:hover {
            background: #16a34a;
        }
        .launch-btn:disabled {
            background: #4b5563;
            cursor: not-allowed;
        }
        .count {
            font-size: 12px;
            color: #888;
        }
        .session-input {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #e5e5e5;
            padding: 6px 10px;
            border-radius: 4px;
            font-size: 12px;
            width: 100%;
        }
        .session-input:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .session-input::placeholder {
            color: #666;
        }
        /* TaskCreate 폼 */
        .create-form {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 12px;
            margin-bottom: 16px;
        }
        .create-form.collapsed .form-fields {
            display: none;
        }
        .form-toggle {
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            user-select: none;
        }
        .form-toggle-label {
            font-size: 12px;
            font-weight: 500;
            color: #888;
        }
        .form-toggle-icon {
            color: #888;
            transition: transform 0.2s;
        }
        .create-form:not(.collapsed) .form-toggle-icon {
            transform: rotate(180deg);
        }
        .form-fields {
            margin-top: 10px;
        }
        .form-group {
            margin-bottom: 10px;
        }
        .form-label {
            display: block;
            font-size: 11px;
            color: #888;
            margin-bottom: 4px;
        }
        .form-input {
            width: 100%;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.1);
            color: #e5e5e5;
            padding: 8px 10px;
            border-radius: 4px;
            font-size: 13px;
        }
        .form-input:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .form-textarea {
            min-height: 60px;
            resize: vertical;
        }
        .form-actions {
            display: flex;
            justify-content: flex-end;
            gap: 8px;
        }
        .btn {
            padding: 6px 14px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            border: none;
        }
        .btn-primary {
            background: #3b82f6;
            color: #fff;
        }
        .btn-primary:hover {
            background: #2563eb;
        }
        .btn-primary:disabled {
            background: #4b5563;
            cursor: not-allowed;
        }
        .spinner {
            display: inline-block;
            width: 12px;
            height: 12px;
            border: 2px solid rgba(255, 255, 255, 0.3);
            border-top-color: #fff;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
            margin-right: 6px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .section {
            margin-bottom: 16px;
        }
        .section-header {
            font-size: 11px;
            font-weight: 600;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        .task {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 10px 12px;
            margin-bottom: 6px;
            display: flex;
            align-items: flex-start;
            gap: 10px;
        }
        .task:hover {
            background: rgba(255, 255, 255, 0.08);
        }
        .task-icon {
            font-size: 14px;
            margin-top: 1px;
            flex-shrink: 0;
        }
        .task-content {
            flex: 1;
            min-width: 0;
            position: relative;
            padding-right: 36px;
        }
        .task-subject {
            font-weight: 500;
            color: #fff;
            word-wrap: break-word;
        }
        .task-description {
            font-size: 12px;
            color: #999;
            margin-top: 4px;
            line-height: 1.4;
            display: -webkit-box;
            -webkit-line-clamp: 2;
            -webkit-box-orient: vertical;
            overflow: hidden;
            text-overflow: ellipsis;
            cursor: pointer;
        }
        .task-description:hover {
            color: #bbb;
        }
        .task-meta {
            font-size: 11px;
            color: #666;
            margin-top: 4px;
        }
        .task-blocked {
            font-size: 11px;
            color: #ef4444;
            margin-top: 4px;
        }
        .empty {
            color: #555;
            font-style: italic;
            padding: 20px;
            text-align: center;
        }
        .status-pending { color: #6b7280; }
        .status-in_progress { color: #f59e0b; }
        .status-completed { color: #22c55e; }
        .session-badge {
            font-size: 10px;
            background: rgba(255, 255, 255, 0.1);
            padding: 2px 6px;
            border-radius: 4px;
            color: #888;
        }
        .owner-badge {
            font-size: 10px;
            background: rgba(59, 130, 246, 0.2);
            padding: 2px 6px;
            border-radius: 4px;
            color: #60a5fa;
        }
        .metadata-badge {
            font-size: 10px;
            background: rgba(168, 85, 247, 0.2);
            padding: 2px 6px;
            border-radius: 4px;
            color: #c084fc;
            margin-left: 4px;
        }
        .metadata-badge .meta-key {
            opacity: 0.7;
        }
        .cwd-path {
            font-size: 10px;
            color: #555;
            margin-top: 2px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            max-width: 280px;
        }
        .task-launch-btn {
            position: absolute;
            right: 0;
            bottom: 0;
            background: #22c55e;
            border: none;
            color: #fff;
            width: 28px;
            height: 28px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .task-launch-btn:hover {
            background: #16a34a;
        }
    </style>
    <script>
        let isCreating = false;
        let formCollapsed = true;

        function toggleForm() {
            formCollapsed = !formCollapsed;
            const form = document.querySelector('.create-form');
            form.classList.toggle('collapsed', formCollapsed);
            if (!formCollapsed) {
                document.getElementById('taskSubject').focus();
            }
        }

        function setSession(value) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'setSession',
                value: value.trim()
            });
        }

        function onSessionInputChange(input) {
            // Enter 키 또는 blur 시 세션 변경
            setSession(input.value);
        }

        function createTask() {
            if (isCreating) return;

            const subject = document.getElementById('taskSubject').value.trim();

            if (!subject) {
                document.getElementById('taskSubject').focus();
                return;
            }

            isCreating = true;
            const btn = document.getElementById('createBtn');
            btn.disabled = true;
            btn.innerHTML = '<span class="spinner"></span>Creating...';

            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'createTask',
                subject: subject
            });
        }

        function resetForm() {
            isCreating = false;
            const btn = document.getElementById('createBtn');
            btn.disabled = false;
            btn.innerHTML = 'Create';
            document.getElementById('taskSubject').value = '';
        }

        function launchClaude() {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'launchClaude'
            });
        }

        function showQuickUpdateDialog() {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'showQuickUpdateDialog'
            });
        }

        function launchClaudeWithCwd(sessionId, cwd) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'launchClaudeWithCwd',
                sessionId: sessionId,
                cwd: cwd
            });
        }

        function showTaskDetail(subject, description) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'showTaskDetail',
                subject: subject,
                description: description
            });
        }

        // 키보드 단축키
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                createTask();
            }
            if (e.key === 'e' && e.metaKey) {
                e.preventDefault();
                var btn = document.getElementById('quickUpdateBtn');
                if (btn && !btn.disabled) {
                    showQuickUpdateDialog();
                } else {
                    document.getElementById('sessionInput').focus();
                }
            }
            if (e.key === 'Escape') {
                if (!formCollapsed) toggleForm();
            }
        });
    </script>
</head>
<body>
    <div class="header">
        <div class="header-row">
            <span class="title">Claude Tasks</span>
            <div class="header-actions">
                <button id="quickUpdateBtn" class="launch-btn quick-update-btn" onclick="showQuickUpdateDialog()" title="Quick Task ⌘E"]] .. (currentSessionValue == '' and ' disabled' or '') .. [[>⚡</button>
                <button id="launchBtn" class="launch-btn" onclick="launchClaude()" title="Launch Claude session"]] .. (currentSessionValue == '' and ' disabled' or '') .. [[>▶</button>
                <span class="count">]] .. #tasks .. [[ tasks</span>
            </div>
        </div>
        <input type="text" class="session-input" id="sessionInput" list="sessionList"
               value="]] .. escapeHtml(currentSessionValue) .. [["
               placeholder="Enter or select session..."
               onchange="onSessionInputChange(this)"
               onkeydown="if(event.key==='Enter'){onSessionInputChange(this);event.preventDefault();}">
        <datalist id="sessionList">
            ]] .. sessionOptions .. [[
        </datalist>
    </div>
]]

    -- In Progress 섹션
    if #inProgressTasks > 0 then
        html = html .. [[
    <div class="section">
        <div class="section-header">In Progress (]] .. #inProgressTasks .. [[)</div>
]]
        for _, task in ipairs(inProgressTasks) do
            local blocked = ""
            if task.blockedBy and #task.blockedBy > 0 then
                blocked = '<div class="task-blocked">Blocked by: ' .. table.concat(task.blockedBy, ", ") .. '</div>'
            end
            local launchBtn = task._cwd and '<button class="task-launch-btn" onclick="launchClaudeWithCwd(\'' .. escapeHtml(task._sessionId) .. '\', \'' .. escapeHtml(task._cwd) .. '\')" title="Launch in ' .. escapeHtml(task._cwd) .. '">▶</button>' or ''
            local descriptionHtml = ''
            if task.description then
                local jsonDesc = jsonEncodeString(task.description)
                local jsonSubj = jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ")' title='Click to view full description'>" .. escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = generateMetadataBadges(task.metadata)
            html = html .. [[
        <div class="task">
            <span class="task-icon status-in_progress">]] .. getStatusIcon("in_progress") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. escapeHtml(task._sessionId) .. [[">]] .. escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. (task._cwd and '<div class="cwd-path" title="' .. escapeHtml(task._cwd) .. '">' .. escapeHtml(task._cwd) .. '</div>' or '') .. [[
                ]] .. blocked .. launchBtn .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Pending 섹션
    if #pendingTasks > 0 then
        html = html .. [[
    <div class="section">
        <div class="section-header">Pending (]] .. #pendingTasks .. [[)</div>
]]
        for _, task in ipairs(pendingTasks) do
            local blocked = ""
            if task.blockedBy and #task.blockedBy > 0 then
                blocked = '<div class="task-blocked">Blocked by: ' .. table.concat(task.blockedBy, ", ") .. '</div>'
            end
            local launchBtn = task._cwd and '<button class="task-launch-btn" onclick="launchClaudeWithCwd(\'' .. escapeHtml(task._sessionId) .. '\', \'' .. escapeHtml(task._cwd) .. '\')" title="Launch in ' .. escapeHtml(task._cwd) .. '">▶</button>' or ''
            local descriptionHtml = ''
            if task.description then
                local jsonDesc = jsonEncodeString(task.description)
                local jsonSubj = jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ")' title='Click to view full description'>" .. escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = generateMetadataBadges(task.metadata)
            html = html .. [[
        <div class="task">
            <span class="task-icon status-pending">]] .. getStatusIcon("pending") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. escapeHtml(task._sessionId) .. [[">]] .. escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. (task._cwd and '<div class="cwd-path" title="' .. escapeHtml(task._cwd) .. '">' .. escapeHtml(task._cwd) .. '</div>' or '') .. [[
                ]] .. blocked .. launchBtn .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Completed 섹션 (최대 5개만 표시)
    if #completedTasks > 0 then
        local displayCount = math.min(5, #completedTasks)
        html = html .. [[
    <div class="section">
        <div class="section-header">Completed (]] .. #completedTasks .. [[)</div>
]]
        for i = 1, displayCount do
            local task = completedTasks[i]
            local launchBtn = task._cwd and '<button class="task-launch-btn" onclick="launchClaudeWithCwd(\'' .. escapeHtml(task._sessionId) .. '\', \'' .. escapeHtml(task._cwd) .. '\')" title="Launch in ' .. escapeHtml(task._cwd) .. '">▶</button>' or ''
            local descriptionHtml = ''
            if task.description then
                local jsonDesc = jsonEncodeString(task.description)
                local jsonSubj = jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ")' title='Click to view full description'>" .. escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = generateMetadataBadges(task.metadata)
            html = html .. [[
        <div class="task" style="opacity: 0.6;">
            <span class="task-icon status-completed">]] .. getStatusIcon("completed") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. escapeHtml(task._sessionId) .. [[">]] .. escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. (task._cwd and '<div class="cwd-path" title="' .. escapeHtml(task._cwd) .. '">' .. escapeHtml(task._cwd) .. '</div>' or '') .. launchBtn .. [[
            </div>
        </div>
]]
        end
        if #completedTasks > displayCount then
            html = html .. [[
        <div class="task-meta" style="text-align: center; padding: 8px; color: #555;">
            + ]] .. (#completedTasks - displayCount) .. [[ more completed
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- 태스크가 없는 경우
    if #tasks == 0 then
        html = html .. [[
    <div class="empty">
        No tasks found.<br>
        Use TaskCreate in Claude Code to add tasks.
    </div>
]]
    end

    html = html .. [[
</body>
</html>
]]
    return html
end

-- ============================================================================
-- WebView 관리
-- ============================================================================

local function createUserContent()
    if usercontent then
        return usercontent
    end

    usercontent = hs.webview.usercontent.new("taskBridge")
    usercontent:setCallback(function(msg)
        log("Bridge message: " .. hs.json.encode(msg.body))

        if msg.body.action == "setSession" then
            obj:setTaskListId(msg.body.value)
        elseif msg.body.action == "createTask" then
            obj:createTask(msg.body.subject)
        elseif msg.body.action == "launchClaude" then
            obj:launchClaudeWithTaskList()
        elseif msg.body.action == "launchClaudeWithCwd" then
            obj:launchClaudeWithCwd(msg.body.sessionId, msg.body.cwd)
        elseif msg.body.action == "showQuickUpdateDialog" then
            obj:showQuickTaskDialog()
        elseif msg.body.action == "showTaskDetail" then
            obj:showTaskDetailWindow(msg.body.subject, msg.body.description)
        end
    end)

    log("UserContent bridge created")
    return usercontent
end

local function createWebView()
    if webview then
        return webview
    end

    -- JS-Lua 브릿지 생성
    createUserContent()

    -- 화면 크기 가져오기
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    -- 오른쪽 하단에 위치
    local rect = hs.geometry.rect(
        frame.x + frame.w - obj.config.width - obj.config.margin,
        frame.y + frame.h - obj.config.height - obj.config.margin,
        obj.config.width,
        obj.config.height
    )

    webview = hs.webview.new(rect, {}, usercontent)
    webview:windowStyle({"titled", "closable", "utility", "HUD"})
    webview:level(hs.drawing.windowLevels.floating)
    webview:allowTextEntry(true)  -- 폼 입력 허용
    webview:allowGestures(false)
    webview:shadow(true)
    webview:alpha(0.98)
    webview:windowTitle("Claude Tasks")

    -- 창 닫힐 때 상태 업데이트
    webview:deleteOnClose(false)

    log("WebView created with usercontent bridge")
    return webview
end

local function refreshWebView()
    if not webview then return end

    local tasks = loadAllTasks()
    local html = generateHTML(tasks)
    webview:html(html)
    log("WebView refreshed with " .. #tasks .. " tasks")
end

-- ============================================================================
-- 업데이트 체커
-- ============================================================================

-- 시맨틱 버전 비교 (a > b 이면 true)
local function isNewerVersion(latest, current)
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

-- GitHub API로 최신 릴리즈 확인
local function checkForUpdates(callback)
    local repoOwner = obj.homepage:match("github.com/([^/]+)")
    local repoName = obj.homepage:match("github.com/[^/]+/([^/]+)")

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
        ["User-Agent"] = "Hammerspoon-ClaudeTasks"
    }, function(status, body, headers)
        if status ~= 200 then
            log("Update check failed: HTTP " .. status)
            if callback then callback(nil, "HTTP " .. status) end
            return
        end

        local release = parseJSON(body)
        if not release or not release.tag_name then
            log("Update check failed: Invalid response")
            if callback then callback(nil, "Invalid response") end
            return
        end

        local latestVersion = release.tag_name
        local currentVersion = obj.version
        local hasUpdate = isNewerVersion(latestVersion, currentVersion)

        log(string.format("Version check: current=%s, latest=%s, hasUpdate=%s",
            currentVersion, latestVersion, tostring(hasUpdate)))

        -- 체크 시간 저장
        obj.state.lastUpdateCheck = os.time()
        saveState()

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

-- 업데이트 알림 표시
local function showUpdateNotification(updateInfo)
    if not updateInfo or not updateInfo.hasUpdate then return end

    local notification = hs.notify.new(function(n)
        -- 알림 클릭 시 릴리즈 페이지 열기
        if updateInfo.releaseUrl then
            hs.urlevent.openURL(updateInfo.releaseUrl)
        end
    end, {
        title = "ClaudeTasks Update Available",
        subTitle = string.format("v%s → %s", updateInfo.currentVersion, updateInfo.latestVersion),
        informativeText = "Click to view release notes",
        hasActionButton = true,
        actionButtonTitle = "View",
        withdrawAfter = 10
    })
    notification:send()
end

-- 업데이트 체크 실행 (간격 고려)
local function maybeCheckForUpdates()
    if not obj.config.checkForUpdates then
        log("Update check disabled")
        return
    end

    local now = os.time()
    local lastCheck = obj.state.lastUpdateCheck or 0
    local interval = obj.config.updateCheckInterval

    if (now - lastCheck) < interval then
        log(string.format("Skipping update check (last check: %d seconds ago)", now - lastCheck))
        return
    end

    checkForUpdates(function(updateInfo, err)
        if err then
            log("Update check error: " .. err)
            return
        end
        if updateInfo and updateInfo.hasUpdate then
            showUpdateNotification(updateInfo)
        end
    end)
end

-- ============================================================================
-- 파일 감시
-- ============================================================================

local function startPathWatcher()
    if pathWatcher then return end

    local tasksDir = getTasksDir()

    -- 디렉토리가 없으면 생성 대기
    if not fileExists(tasksDir) then
        log("Tasks directory does not exist, will watch parent")
        -- .claude 디렉토리 감시
        local parentDir = os.getenv("HOME") .. "/.claude"
        pathWatcher = hs.pathwatcher.new(parentDir, function(paths)
            -- tasks 디렉토리가 생성되면 재시작
            if fileExists(tasksDir) then
                obj:stop()
                obj:start()
            end
        end)
        pathWatcher:start()
        return
    end

    -- 모든 세션 디렉토리 감시
    local sessions = listDir(tasksDir)
    local watchPaths = {tasksDir}

    for _, sessionId in ipairs(sessions) do
        table.insert(watchPaths, tasksDir .. "/" .. sessionId)
    end

    pathWatcher = hs.pathwatcher.new(tasksDir, function(paths)
        log("File change detected: " .. table.concat(paths, ", "))

        -- 디바운스: 빠른 연속 변경 시 마지막 것만 처리
        if refreshTimer then
            refreshTimer:stop()
        end

        refreshTimer = hs.timer.doAfter(obj.config.refreshDebounce, function()
            refreshWebView()
            refreshTimer = nil
        end)
    end)

    pathWatcher:start()
    log("PathWatcher started on: " .. tasksDir)
end

local function stopPathWatcher()
    if pathWatcher then
        pathWatcher:stop()
        pathWatcher = nil
        log("PathWatcher stopped")
    end
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end
end

-- ============================================================================
-- 공개 API
-- ============================================================================

--- Initialize the Spoon
function obj:init()
    obj.state.configPath = obj.spoonPath .. "/state.json"
    log("ClaudeTasks Spoon initialized")
    return self
end

--- 태스크 뷰어 표시
function obj:show()
    if not webview then
        createWebView()
    end
    refreshWebView()
    webview:show()
    webview:bringToFront()
    isVisible = true
    startPathWatcher()

    -- Focus session input after DOM ready
    hs.timer.doAfter(0.1, function()
        if webview then
            webview:evaluateJavaScript("document.getElementById('sessionInput').focus(); document.getElementById('sessionInput').select();")
        end
    end)

    log("Task viewer shown")
    return self
end

--- 태스크 뷰어 숨기기
function obj:hide()
    if webview then
        webview:hide()
        isVisible = false
        log("Task viewer hidden")
    end
    return self
end

--- 표시/숨기기 토글
function obj:toggle()
    if isVisible then
        obj:hide()
    else
        obj:show()
    end
    return self
end

--- 수동 새로고침
function obj:refresh()
    refreshWebView()
    return self
end

--- 세션 ID 설정
function obj:setTaskListId(id)
    local sessionId = (id ~= "" and id) or nil
    obj.state.currentTaskListId = sessionId
    obj.config.taskListId = sessionId
    saveState()
    log("Session changed to: " .. (sessionId or "none"))

    -- 파일 감시 재시작 (새 세션에 맞게)
    stopPathWatcher()
    startPathWatcher()

    -- UI 새로고침
    obj:refresh()
    return self
end

--- 태스크 생성 (Claude CLI 사용)
function obj:createTask(subject)
    local claudePath = discoverClaudePath()
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return nil
    end

    local prompt = string.format("TaskCreate(%s)", subject)

    log("Creating task: " .. prompt)

    local env = {}
    if obj.state.currentTaskListId and obj.state.currentTaskListId ~= "" then
        env.CLAUDE_CODE_TASK_LIST_ID = obj.state.currentTaskListId
    end

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            hs.alert.show("Task created", 1)
            log("Task created successfully. stdout: " .. (stdout or ""))
        else
            hs.alert.show("Task creation failed", 2)
            log("Task creation failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end

        -- UI 폼 리셋 (JS 호출)
        if webview then
            webview:evaluateJavaScript("resetForm()")
        end

        -- 새로고침
        obj:refresh()
    end, {
        "-p",
        "--model", "haiku",
        prompt
    })

    if next(env) then
        task:setEnvironment(env)
    end

    -- ~/.claude에서 실행
    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    return task
end

--- Quick TaskUpdate (haiku 모델로 빠른 태스크 업데이트)
function obj:quickTaskUpdate(prompt)
    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local claudePath = discoverClaudePath()
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return
    end

    -- 필수 환경변수 설정
    local env = {
        PATH = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        HOME = os.getenv("HOME"),
        USER = os.getenv("USER"),
        SHELL = getShell(),
        TERM = "xterm-256color",
        CLAUDE_CODE_ENABLE_TASKS = "true",
        CLAUDE_CODE_TASK_LIST_ID = taskListId
    }

    local systemPrompt = [[This is a lightweight Todo Task management command. Use TaskCreate or TaskUpdate tools immediately based on the user's input. Do not ask for clarification - execute the tool directly.

For TaskCreate: If description is not explicitly provided, infer a meaningful description from the subject.]]

    log("QuickTaskUpdate: " .. prompt .. " (taskListId: " .. taskListId .. ")")

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            local result = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if result == "" then result = "Done" end
            -- 긴 결과는 잘라서 표시
            if #result > 200 then
                result = result:sub(1, 200) .. "..."
            end
            hs.alert.show(result, 3)
            log("QuickTaskUpdate completed. stdout: " .. (stdout or ""))
        else
            local errMsg = (stderr or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if errMsg == "" then errMsg = "TaskUpdate failed" end
            hs.alert.show("❌ " .. errMsg:sub(1, 100), 3)
            log("QuickTaskUpdate failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end
        obj:refresh()
    end, {
        "--model", "haiku",
        "-p",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--dangerously-skip-permissions",
        "--setting-sources", "",
        "--system-prompt", systemPrompt,
        "--verbose",
        "--",
        prompt
    })

    task:setEnvironment(env)
    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    hs.alert.show("Running Quick Task...", 1)
end

--- 태스크 상세 창 표시
local detailWebview = nil

function obj:showTaskDetailWindow(subject, description)
    -- 기존 상세 창이 있으면 닫기
    if detailWebview then
        detailWebview:delete()
        detailWebview = nil
    end

    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    -- 화면 중앙에 더 큰 창
    local width = 600
    local height = 500
    local rect = hs.geometry.rect(
        frame.x + (frame.w - width) / 2,
        frame.y + (frame.h - height) / 2,
        width,
        height
    )

    local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            font-size: 14px;
            line-height: 1.6;
            background: rgba(30, 30, 30, 0.98);
            color: #e5e5e5;
            padding: 20px;
            -webkit-font-smoothing: antialiased;
        }
        .header {
            margin-bottom: 16px;
            padding-bottom: 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
        }
        .title {
            font-size: 18px;
            font-weight: 600;
            color: #fff;
        }
        .content {
            overflow-y: auto;
            max-height: calc(100vh - 80px);
        }
        .content h1, .content h2, .content h3 { color: #fff; margin: 16px 0 8px 0; }
        .content h1 { font-size: 1.5em; }
        .content h2 { font-size: 1.3em; }
        .content h3 { font-size: 1.1em; }
        .content p { margin: 8px 0; }
        .content ul, .content ol { margin: 8px 0; padding-left: 24px; }
        .content li { margin: 4px 0; }
        .content code {
            background: rgba(255, 255, 255, 0.1);
            padding: 2px 6px;
            border-radius: 4px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: 13px;
        }
        .content pre {
            background: rgba(0, 0, 0, 0.3);
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
            margin: 12px 0;
        }
        .content pre code {
            background: none;
            padding: 0;
        }
        .content blockquote {
            border-left: 3px solid #3b82f6;
            padding-left: 12px;
            margin: 12px 0;
            color: #aaa;
        }
        .content a { color: #60a5fa; }
        .content table { border-collapse: collapse; margin: 12px 0; }
        .content th, .content td {
            border: 1px solid rgba(255, 255, 255, 0.2);
            padding: 8px 12px;
            text-align: left;
        }
        .content th { background: rgba(255, 255, 255, 0.05); }
    </style>
</head>
<body>
    <div class="header">
        <div class="title">]] .. escapeHtml(subject or "Task Detail") .. [[</div>
    </div>
    <div class="content" id="content"></div>
    <script>
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') window.close();
        });
        var description = ]] .. jsonEncodeString(description or "") .. [[;
        document.getElementById('content').innerHTML = marked.parse(description);
    </script>
</body>
</html>
]]

    detailWebview = hs.webview.new(rect)
    detailWebview:windowStyle({"titled", "closable", "resizable"})
    detailWebview:level(hs.drawing.windowLevels.floating)
    detailWebview:allowTextEntry(true)
    detailWebview:shadow(true)
    detailWebview:alpha(0.98)
    detailWebview:windowTitle(subject or "Task Detail")
    detailWebview:html(html)
    detailWebview:show()
    detailWebview:bringToFront()

    log("Task detail window opened: " .. (subject or ""))
    return self
end

--- QuickTask 다이얼로그 표시
local quickTaskWebview = nil
local quickTaskUserContent = nil

function obj:showQuickTaskDialog()
    -- 기존 창이 있으면 닫기
    if quickTaskWebview then
        quickTaskWebview:delete()
        quickTaskWebview = nil
    end

    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    local width = 500
    local height = 420
    local rect = hs.geometry.rect(
        frame.x + (frame.w - width) / 2,
        frame.y + (frame.h - height) / 2,
        width,
        height
    )

    local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            font-size: 14px;
            line-height: 1.5;
            background: rgba(30, 30, 30, 0.98);
            color: #e5e5e5;
            padding: 20px;
            -webkit-font-smoothing: antialiased;
        }
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 16px;
        }
        .title {
            font-size: 16px;
            font-weight: 600;
            color: #fff;
        }
        .help-btn {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #888;
            width: 28px;
            height: 28px;
            border-radius: 50%;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
        }
        .help-btn:hover {
            background: rgba(255, 255, 255, 0.2);
            color: #fff;
        }
        .help-btn.active {
            background: rgba(59, 130, 246, 0.3);
            border-color: #3b82f6;
            color: #60a5fa;
        }
        .input-group {
            margin-bottom: 16px;
        }
        .input-label {
            font-size: 12px;
            color: #888;
            margin-bottom: 6px;
        }
        .input-field {
            width: 100%;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #e5e5e5;
            padding: 10px 12px;
            border-radius: 6px;
            font-size: 14px;
            font-family: inherit;
        }
        .input-field:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .input-field::placeholder {
            color: #555;
        }
        .actions {
            display: flex;
            justify-content: flex-end;
            gap: 10px;
            margin-top: 16px;
        }
        .btn {
            padding: 8px 20px;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 500;
            cursor: pointer;
            border: none;
        }
        .btn-cancel {
            background: rgba(255, 255, 255, 0.1);
            color: #aaa;
        }
        .btn-cancel:hover {
            background: rgba(255, 255, 255, 0.15);
        }
        .btn-primary {
            background: #3b82f6;
            color: #fff;
        }
        .btn-primary:hover {
            background: #2563eb;
        }
        .btn-primary:disabled {
            background: #4b5563;
            cursor: not-allowed;
        }
        .schema-help {
            display: none;
            margin-top: 16px;
            padding: 16px;
            background: rgba(0, 0, 0, 0.3);
            border-radius: 8px;
            font-size: 12px;
            max-height: 200px;
            overflow-y: auto;
        }
        .schema-help.visible {
            display: block;
        }
        .schema-section {
            margin-bottom: 16px;
        }
        .schema-section:last-child {
            margin-bottom: 0;
        }
        .schema-title {
            font-weight: 600;
            color: #60a5fa;
            margin-bottom: 8px;
        }
        .schema-field {
            display: flex;
            margin-bottom: 4px;
            padding-left: 8px;
        }
        .field-name {
            color: #c084fc;
            min-width: 100px;
            font-family: "SF Mono", Menlo, monospace;
        }
        .field-type {
            color: #888;
            min-width: 80px;
        }
        .field-desc {
            color: #aaa;
        }
        .example {
            margin-top: 8px;
            padding: 8px 12px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 4px;
            font-family: "SF Mono", Menlo, monospace;
            color: #22c55e;
        }
        .spinner {
            display: inline-block;
            width: 14px;
            height: 14px;
            border: 2px solid rgba(255, 255, 255, 0.3);
            border-top-color: #fff;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
            margin-right: 8px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="header">
        <span class="title">Quick Task</span>
        <button class="help-btn" id="helpBtn" onclick="toggleHelp()" title="Show schema help">?</button>
    </div>

    <div class="input-group">
        <div class="input-label">Enter prompt</div>
        <input type="text" class="input-field" id="promptInput"
               placeholder="e.g., TaskCreate: Fix login bug" autofocus>
    </div>

    <div class="schema-help" id="schemaHelp">
        <div class="schema-section">
            <div class="schema-title">TaskCreate (Optional Fields)</div>
            <div class="schema-field">
                <span class="field-name">activeForm</span>
                <span class="field-type">string</span>
                <span class="field-desc">Spinner text (e.g., "Fixing bug")</span>
            </div>
            <div class="schema-field">
                <span class="field-name">metadata</span>
                <span class="field-type">object</span>
                <span class="field-desc">Key-value pairs for custom data</span>
            </div>
            <div class="example">TaskCreate: Fix bug, metadata: {priority: high}</div>
        </div>

        <div class="schema-section">
            <div class="schema-title">TaskUpdate (Optional Fields)</div>
            <div class="schema-field">
                <span class="field-name">status</span>
                <span class="field-type">enum</span>
                <span class="field-desc">pending | in_progress | completed | deleted</span>
            </div>
            <div class="schema-field">
                <span class="field-name">subject</span>
                <span class="field-type">string</span>
                <span class="field-desc">New task title</span>
            </div>
            <div class="schema-field">
                <span class="field-name">description</span>
                <span class="field-type">string</span>
                <span class="field-desc">New task description</span>
            </div>
            <div class="schema-field">
                <span class="field-name">activeForm</span>
                <span class="field-type">string</span>
                <span class="field-desc">Spinner text when in_progress</span>
            </div>
            <div class="schema-field">
                <span class="field-name">addBlocks</span>
                <span class="field-type">string[]</span>
                <span class="field-desc">Task IDs this task blocks</span>
            </div>
            <div class="schema-field">
                <span class="field-name">addBlockedBy</span>
                <span class="field-type">string[]</span>
                <span class="field-desc">Task IDs blocking this task</span>
            </div>
            <div class="schema-field">
                <span class="field-name">owner</span>
                <span class="field-type">string</span>
                <span class="field-desc">Task owner/assignee</span>
            </div>
            <div class="schema-field">
                <span class="field-name">metadata</span>
                <span class="field-type">object</span>
                <span class="field-desc">Merge metadata (null to delete key)</span>
            </div>
            <div class="example">TaskUpdate: #1 status completed</div>
        </div>
    </div>

    <div class="actions">
        <button class="btn btn-cancel" onclick="closeDialog()">Cancel</button>
        <button class="btn btn-primary" id="submitBtn" onclick="submitPrompt()">Run</button>
    </div>

    <script>
        function toggleHelp() {
            var help = document.getElementById('schemaHelp');
            var btn = document.getElementById('helpBtn');
            help.classList.toggle('visible');
            btn.classList.toggle('active');
        }

        function closeDialog() {
            window.webkit.messageHandlers.quickTaskBridge.postMessage({
                action: 'close'
            });
        }

        function submitPrompt() {
            var input = document.getElementById('promptInput');
            var prompt = input.value.trim();
            if (!prompt) {
                input.focus();
                return;
            }

            var btn = document.getElementById('submitBtn');
            btn.disabled = true;
            btn.innerHTML = '<span class="spinner"></span>Running...';

            window.webkit.messageHandlers.quickTaskBridge.postMessage({
                action: 'submit',
                prompt: prompt
            });
        }

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
                closeDialog();
            }
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                submitPrompt();
            }
            if (e.key === '?' && e.shiftKey) {
                e.preventDefault();
                toggleHelp();
            }
        });

        document.getElementById('promptInput').focus();
    </script>
</body>
</html>
]]

    -- UserContent 생성
    if not quickTaskUserContent then
        quickTaskUserContent = hs.webview.usercontent.new("quickTaskBridge")
        quickTaskUserContent:setCallback(function(msg)
            log("QuickTask message: " .. hs.json.encode(msg.body))

            if msg.body.action == "close" then
                if quickTaskWebview then
                    quickTaskWebview:delete()
                    quickTaskWebview = nil
                end
            elseif msg.body.action == "submit" then
                local prompt = msg.body.prompt
                if quickTaskWebview then
                    quickTaskWebview:delete()
                    quickTaskWebview = nil
                end
                if prompt and prompt ~= "" then
                    obj:quickTaskUpdate(prompt)
                end
            end
        end)
    end

    quickTaskWebview = hs.webview.new(rect, {}, quickTaskUserContent)
    quickTaskWebview:windowStyle({"titled", "closable", "utility", "HUD"})
    quickTaskWebview:level(hs.drawing.windowLevels.floating)
    quickTaskWebview:allowTextEntry(true)
    quickTaskWebview:shadow(true)
    quickTaskWebview:alpha(0.98)
    quickTaskWebview:windowTitle("Quick Task")
    quickTaskWebview:html(html)
    quickTaskWebview:show()
    quickTaskWebview:bringToFront()

    log("QuickTask dialog opened")
    return self
end

--- Claude Code 세션 실행
function obj:launchClaudeWithTaskList()
    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local terminalPath = discoverTerminalApp()
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local claudeDir = os.getenv("HOME") .. "/.claude"
    local shell = getShell()
    local claudePath = discoverClaudePath() or "claude"

    -- Shell escape helper for single-quoted strings
    local function shellEscape(str)
        return str:gsub("'", "'\\''")
    end

    local shellCmd = string.format("cd '%s' && CLAUDE_CODE_TASK_LIST_ID='%s' '%s'",
        shellEscape(claudeDir), shellEscape(taskListId), shellEscape(claudePath))

    log("Launching Claude: " .. shellCmd)

    -- iTerm2: use AppleScript since it doesn't support -e shell -c cmd args
    if terminalPath:find("iTerm") then
        local escapedCmd = shellCmd:gsub("\\", "\\\\"):gsub('"', '\\"')
        local script = [[
            tell application "iTerm"
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "]] .. escapedCmd .. [["
                end tell
                activate
            end tell
        ]]
        local success, _, rawError = hs.osascript.applescript(script)
        if not success then
            local errorMsg = "iTerm2 launch failed"
            if rawError and rawError.NSLocalizedDescription then
                errorMsg = errorMsg .. ": " .. rawError.NSLocalizedDescription
            end
            log("AppleScript error: " .. hs.inspect(rawError))
            hs.alert.show(errorMsg, 3)
            return
        end
    else
        local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
            if exitCode ~= 0 then
                log("Terminal launch error: " .. (stderr or "unknown"))
            end
        end, {
            "-e", shell, "-c", shellCmd
        })
        task:start()
    end

    hs.alert.show("Launching Claude...", 1)
end

--- Claude Code 세션을 특정 cwd에서 실행
function obj:launchClaudeWithCwd(sessionId, cwd)
    if not sessionId or sessionId == "" then
        hs.alert.show("No session ID", 2)
        return
    end
    if not cwd or cwd == "" then
        hs.alert.show("No working directory", 2)
        return
    end

    local terminalPath = discoverTerminalApp()
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local shell = getShell()
    local claudePath = discoverClaudePath() or "claude"

    -- Shell escape helper for single-quoted strings
    local function shellEscape(str)
        return str:gsub("'", "'\\''")
    end

    local shellCmd = string.format("cd '%s' && CLAUDE_CODE_TASK_LIST_ID='%s' '%s' -r '%s'",
        shellEscape(cwd), shellEscape(sessionId), shellEscape(claudePath), shellEscape(sessionId))

    log("Launching Claude with cwd: " .. shellCmd)

    -- iTerm2: use AppleScript since it doesn't support -e shell -c cmd args
    if terminalPath:find("iTerm") then
        local escapedCmd = shellCmd:gsub("\\", "\\\\"):gsub('"', '\\"')
        local script = [[
            tell application "iTerm"
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "]] .. escapedCmd .. [["
                end tell
                activate
            end tell
        ]]
        local success, _, rawError = hs.osascript.applescript(script)
        if not success then
            local errorMsg = "iTerm2 launch failed"
            if rawError and rawError.NSLocalizedDescription then
                errorMsg = errorMsg .. ": " .. rawError.NSLocalizedDescription
            end
            log("AppleScript error: " .. hs.inspect(rawError))
            hs.alert.show(errorMsg, 3)
            return
        end
    else
        local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
            if exitCode ~= 0 then
                log("Terminal launch error: " .. (stderr or "unknown"))
            end
        end, {
            "-e", shell, "-c", shellCmd
        })
        task:start()
    end

    hs.alert.show("Launching Claude in " .. cwd:match("[^/]+$") .. "...", 1)
end

--- 모듈 시작 (파일 감시 시작)
function obj:start()
    loadState()  -- 저장된 상태 로드
    startPathWatcher()

    -- 업데이트 체크 (비동기, 딜레이 적용)
    if obj.config.checkForUpdates then
        hs.timer.doAfter(2, function()
            maybeCheckForUpdates()
        end)
    end

    log("Claude Tasks module started")
    return self
end

--- 모듈 중지
function obj:stop()
    stopPathWatcher()
    if webview then
        webview:delete()
        webview = nil
    end
    if detailWebview then
        detailWebview:delete()
        detailWebview = nil
    end
    if quickTaskWebview then
        quickTaskWebview:delete()
        quickTaskWebview = nil
    end
    if usercontent then
        usercontent = nil
    end
    if quickTaskUserContent then
        quickTaskUserContent = nil
    end
    isVisible = false
    cwdCache = {}
    log("Claude Tasks module stopped")
    return self
end

--- 설정 업데이트
function obj:configure(options)
    if options then
        for k, v in pairs(options) do
            obj.config[k] = v
        end
    end
    return self
end

--- 수동 업데이트 체크
--- @param showNoUpdate boolean 업데이트 없을 때도 알림 표시
function obj:checkForUpdates(showNoUpdate)
    checkForUpdates(function(updateInfo, err)
        if err then
            hs.alert.show("Update check failed: " .. err, 3)
            return
        end
        if updateInfo.hasUpdate then
            showUpdateNotification(updateInfo)
        elseif showNoUpdate then
            hs.alert.show(string.format(
                "ClaudeTasks v%s is up to date",
                updateInfo.currentVersion
            ), 2)
        end
    end)
    return self
end

--- 현재 상태 반환
function obj:status()
    local tasks = loadAllTasks()
    local pending = 0
    local inProgress = 0
    local completed = 0

    for _, task in ipairs(tasks) do
        if task.status == "completed" then
            completed = completed + 1
        elseif task.status == "in_progress" then
            inProgress = inProgress + 1
        else
            pending = pending + 1
        end
    end

    return {
        visible = isVisible,
        taskCount = #tasks,
        pending = pending,
        inProgress = inProgress,
        completed = completed,
        taskListId = obj.config.taskListId,
        currentTaskListId = obj.state.currentTaskListId,
        watcherActive = pathWatcher ~= nil,
    }
end

-- ============================================================================
-- Hotkey Binding
-- ============================================================================

obj.defaultHotkeys = {
    toggle = {{"alt"}, "."},
    status = {{"cmd", "alt"}, "T"}
}

function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() obj:toggle() end,
        status = function()
            local status = obj:status()
            local msg = string.format(
                "Tasks: %d total\n⏳ %d pending\n🔄 %d in progress\n✓ %d completed",
                status.taskCount, status.pending, status.inProgress, status.completed
            )
            hs.alert.show(msg, 3)
        end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

return obj

-- lib/webview.lua
-- WebView management and UI components

local M = {}

-- Module-level state
local webview = nil
local usercontent = nil
local detailWebview = nil
local quickTaskWebview = nil
local quickTaskUserContent = nil
local snoozeWebview = nil
local snoozeUserContent = nil
local isVisible = false
local isOverlayMode = false

-- Create user content controller for JS-Lua bridge
function M.createUserContent(actionHandler, log)
    if usercontent then
        return usercontent
    end

    usercontent = hs.webview.usercontent.new("taskBridge")
    usercontent:setCallback(function(msg)
        log("Bridge message: " .. hs.json.encode(msg.body))
        actionHandler(msg.body.action, msg.body)
    end)

    log("UserContent bridge created")
    return usercontent
end

-- Create main WebView
function M.createWebView(config, actionHandler, log)
    if webview then
        return webview
    end

    -- Create JS-Lua bridge
    M.createUserContent(actionHandler, log)

    -- Get screen dimensions
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    -- Position at bottom right
    local rect = hs.geometry.rect(
        frame.x + frame.w - config.width - config.margin,
        frame.y + frame.h - config.height - config.margin,
        config.width,
        config.height
    )

    webview = hs.webview.new(rect, {}, usercontent)
    webview:windowStyle({"titled", "closable", "utility", "HUD"})
    webview:level(hs.drawing.windowLevels.floating)
    webview:allowTextEntry(true)  -- Allow form input
    webview:allowGestures(false)
    webview:shadow(true)
    webview:alpha(0.98)
    webview:windowTitle("Claude Tasks")

    -- Don't delete on close
    webview:deleteOnClose(false)

    log("WebView created with usercontent bridge")
    return webview
end

-- Refresh WebView with new HTML
function M.refreshWebView(html, log)
    if not webview then return end
    webview:html(html)
    log("WebView refreshed")
end

-- Show WebView
function M.show(log)
    if webview then
        webview:show()
        webview:bringToFront()
        isVisible = true

        -- Focus the window to receive keyboard input
        local win = webview:hswindow()
        if win then win:focus() end

        -- Focus first task after DOM ready
        hs.timer.doAfter(0.1, function()
            if webview then
                webview:evaluateJavaScript("updateFocus(0);")
            end
        end)

        log("Task viewer shown")
    end
end

-- Hide WebView
function M.hide(log)
    if webview then
        webview:hide()
        isVisible = false
        log("Task viewer hidden")
    end
end

-- Check visibility
function M.isVisible()
    return isVisible
end

-- Get WebView instance
function M.getWebView()
    return webview
end

-- Reset form via JS
function M.resetForm()
    if webview then
        webview:evaluateJavaScript("resetForm()")
    end
end

-- Evaluate arbitrary JavaScript in the main webview
function M.evaluateJavaScript(js)
    if webview then
        webview:evaluateJavaScript(js)
    end
end

-- Show task detail window
function M.showTaskDetailWindow(subject, description, metadata, utils, log)
    -- Close existing detail window
    if detailWebview then
        detailWebview:delete()
        detailWebview = nil
    end

    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    -- Center on screen, larger window
    local width = 600
    local height = 500
    local rect = hs.geometry.rect(
        frame.x + (frame.w - width) / 2,
        frame.y + (frame.h - height) / 2,
        width,
        height
    )

    -- Generate metadata JSON
    local metadataJson = "{}"
    if metadata and type(metadata) == "table" then
        local ok, encoded = pcall(hs.json.encode, metadata)
        if ok then metadataJson = encoded end
    end

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
            display: flex;
            flex-direction: column;
            height: 100vh;
        }
        .header {
            margin-bottom: 16px;
            padding-bottom: 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            flex-shrink: 0;
        }
        .title {
            font-size: 18px;
            font-weight: 600;
            color: #fff;
        }
        .content {
            overflow-y: auto;
            flex: 1;
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
        .metadata {
            margin-top: 16px;
            padding-top: 12px;
            border-top: 1px solid rgba(255, 255, 255, 0.1);
            flex-shrink: 0;
        }
        .metadata-title {
            font-size: 11px;
            font-weight: 600;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        .metadata-tags {
            display: flex;
            flex-wrap: wrap;
            gap: 6px;
        }
        .metadata-tag {
            font-size: 11px;
            background: rgba(168, 85, 247, 0.2);
            padding: 4px 8px;
            border-radius: 4px;
            color: #c084fc;
        }
        .metadata-tag .tag-key {
            opacity: 0.7;
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="title">]] .. utils.escapeHtml(subject or "Task Detail") .. [[</div>
    </div>
    <div class="content" id="content"></div>
    <div class="metadata" id="metadata" style="display: none;">
        <div class="metadata-title">Metadata</div>
        <div class="metadata-tags" id="metadataTags"></div>
    </div>
    <script>
        function closeWindow() {
            window.webkit.messageHandlers.detailBridge.postMessage({ action: 'close' });
        }
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' || e.key === ' ') {
                e.preventDefault();
                closeWindow();
            }
        });
        var description = ]] .. utils.jsonEncodeString(description or "") .. [[;
        document.getElementById('content').innerHTML = marked.parse(description);

        var metadata = ]] .. metadataJson .. [[;
        var metadataEl = document.getElementById('metadata');
        var tagsEl = document.getElementById('metadataTags');
        var keys = Object.keys(metadata);
        if (keys.length > 0) {
            metadataEl.style.display = 'block';
            keys.forEach(function(key) {
                var value = metadata[key];
                var displayValue = typeof value === 'object' ? JSON.stringify(value) : String(value);
                var tag = document.createElement('span');
                tag.className = 'metadata-tag';
                tag.innerHTML = '<span class="tag-key">' + key + ':</span> ' + displayValue;
                tagsEl.appendChild(tag);
            });
        }
    </script>
</body>
</html>
]]

    -- Create usercontent for keyboard callback
    local detailusercontent = hs.webview.usercontent.new("detailBridge")
    detailusercontent:setCallback(function(msg)
        if msg.body and msg.body.action == "close" then
            if detailWebview then
                detailWebview:delete()
                detailWebview = nil
                log("Task detail window closed via keyboard")
            end
        end
    end)

    detailWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, detailusercontent)
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
end

-- Show QuickTask dialog
function M.showQuickTaskDialog(actionHandler, log)
    -- Close existing dialog
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

    <div class="schema-help visible" id="schemaHelp">
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

    -- Create UserContent for QuickTask
    if not quickTaskUserContent then
        quickTaskUserContent = hs.webview.usercontent.new("quickTaskBridge")
        quickTaskUserContent:setCallback(function(msg)
            log("QuickTask message: " .. hs.json.encode(msg.body))
            actionHandler(msg.body.action, msg.body)
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
end

-- Close QuickTask dialog
function M.closeQuickTaskDialog()
    if quickTaskWebview then
        quickTaskWebview:delete()
        quickTaskWebview = nil
    end
end

-- Show Snooze dialog
function M.showSnoozeDialog(actionHandler, taskId, sessionId, subject, utils, log)
    -- Close existing dialog
    if snoozeWebview then
        snoozeWebview:delete()
        snoozeWebview = nil
    end

    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    local width = 480
    local height = 380
    local rect = hs.geometry.rect(
        frame.x + (frame.w - width) / 2,
        frame.y + (frame.h - height) / 2,
        width,
        height
    )

    local escapedSubject = utils.escapeHtml(subject or "")
    local escapedTaskId = utils.escapeHtml(taskId or "")
    local escapedSessionId = utils.escapeHtml(sessionId or "")
    -- JS string context needs jsonEncodeString (escapes backslash, quotes)
    local jsTaskId = utils.jsonEncodeString(taskId or "")
    local jsSessionId = utils.jsonEncodeString(sessionId or "")
    local jsSubject = utils.jsonEncodeString(subject or "")

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
            background: rgba(26, 26, 46, 0.98);
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
            font-size: 16px;
            font-weight: 600;
            color: #fff;
            margin-bottom: 4px;
        }
        .task-subject {
            font-size: 13px;
            color: #888;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .input-group {
            margin-bottom: 8px;
            position: relative;
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
            border-color: #06b6d4;
        }
        .input-field::placeholder {
            color: #555;
        }
        .autocomplete {
            display: none;
            position: absolute;
            left: 0;
            right: 0;
            top: 100%;
            margin-top: 4px;
            background: rgba(20, 20, 40, 0.98);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 6px;
            overflow: hidden;
            z-index: 10;
        }
        .autocomplete.visible {
            display: block;
        }
        .autocomplete-item {
            padding: 10px 12px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .autocomplete-item:hover,
        .autocomplete-item.selected {
            background: rgba(6, 182, 212, 0.15);
        }
        .ac-label {
            font-weight: 500;
            color: #e5e5e5;
        }
        .ac-time {
            font-size: 12px;
            color: #06b6d4;
            font-family: "SF Mono", Menlo, monospace;
        }
        .hint {
            font-size: 12px;
            color: #555;
            margin-top: 12px;
            line-height: 1.6;
        }
        .hint kbd {
            background: rgba(255, 255, 255, 0.1);
            padding: 1px 5px;
            border-radius: 3px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: 11px;
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
            background: #06b6d4;
            color: #fff;
        }
        .btn-primary:hover {
            background: #0891b2;
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="title">Snooze Task</div>
        <div class="task-subject">]] .. escapedSubject .. [[</div>
    </div>

    <div class="input-group">
        <div class="input-label">Snooze until</div>
        <input type="text" class="input-field" id="snoozeInput"
               placeholder="e.g., 2h, tomorrow, next week" autofocus>
        <div class="autocomplete" id="autocomplete"></div>
    </div>

    <div class="hint">
        Try: <kbd>30m</kbd> <kbd>2h</kbd> <kbd>1d</kbd> <kbd>1w</kbd> <kbd>tomorrow</kbd> <kbd>next week</kbd> <kbd>tonight</kbd> <kbd>afternoon</kbd><br>
        Or type a natural description for AI parsing.
    </div>

    <div class="actions">
        <button class="btn btn-cancel" onclick="closeDialog()">Cancel</button>
        <button class="btn btn-primary" onclick="submitSnooze()">Snooze</button>
    </div>

    <script>
        var TASK_ID = ]] .. jsTaskId .. [[;
        var SESSION_ID = ]] .. jsSessionId .. [[;
        var SUBJECT = ]] .. jsSubject .. [[;

        function pad(n) { return String(n).padStart(2, '0'); }
        function toISO(d) {
            var off = -d.getTimezoneOffset();
            var sign = off >= 0 ? '+' : '-';
            var h = pad(Math.floor(Math.abs(off)/60));
            var m = pad(Math.abs(off)%60);
            return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate())+'T'+
                   pad(d.getHours())+':'+pad(d.getMinutes())+':'+pad(d.getSeconds())+sign+h+':'+m;
        }
        function addHours(n) { var d = new Date(); d.setHours(d.getHours()+n); return d; }
        function addMinutes(n) { var d = new Date(); d.setMinutes(d.getMinutes()+n); return d; }
        function addDays(n) { var d = new Date(); d.setDate(d.getDate()+n); return d; }
        function addWeeks(n) { return addDays(n*7); }
        function addMonths(n) { var d = new Date(); d.setMonth(d.getMonth()+n); return d; }
        function tomorrowAt9() { var d = new Date(); d.setDate(d.getDate()+1); d.setHours(9,0,0,0); return d; }
        function nextMondayAt9() {
            var d = new Date();
            var day = d.getDay();
            var daysUntilMon = day === 0 ? 1 : (8 - day);
            d.setDate(d.getDate()+daysUntilMon);
            d.setHours(9,0,0,0);
            return d;
        }
        function todayAt(h,m) { var d = new Date(); d.setHours(h,m,0,0); return d; }

        var PRESETS = [
            { pattern: /^(\d+)\s*h/i, fn: function(m) { return addHours(+m[1]); }, label: function(m) { return m[1]+' hour(s)'; } },
            { pattern: /^(\d+)\s*m(?:in|$)/i, fn: function(m) { return addMinutes(+m[1]); }, label: function(m) { return m[1]+' minute(s)'; } },
            { pattern: /^(\d+)\s*mo/i, fn: function(m) { return addMonths(+m[1]); }, label: function(m) { return m[1]+' month(s)'; } },
            { pattern: /^(\d+)\s*d/i, fn: function(m) { return addDays(+m[1]); }, label: function(m) { return m[1]+' day(s)'; } },
            { pattern: /^(\d+)\s*w/i, fn: function(m) { return addWeeks(+m[1]); }, label: function(m) { return m[1]+' week(s)'; } },
            { pattern: /^(tomorrow)$/i, fn: function() { return tomorrowAt9(); }, label: function() { return 'Tomorrow 9:00 AM'; } },
            { pattern: /^(next\s*week)$/i, fn: function() { return nextMondayAt9(); }, label: function() { return 'Next Monday 9:00 AM'; } },
            { pattern: /^(tonight)$/i, fn: function() { return todayAt(21,0); }, label: function() { return 'Tonight 9:00 PM'; } },
            { pattern: /^(afternoon)$/i, fn: function() { return todayAt(14,0); }, label: function() { return 'Today 2:00 PM'; } },
            { pattern: /^(\uB0B4\uC77C)$/i, fn: function() { return tomorrowAt9(); }, label: function() { return '\uB0B4\uC77C 9:00 AM'; } },
            { pattern: /^(\uB2E4\uC74C\s*\uC8FC)$/i, fn: function() { return nextMondayAt9(); }, label: function() { return '\uB2E4\uC74C \uC8FC \uC6D4\uC694\uC77C 9:00 AM'; } },
            { pattern: /^(\uC624\uB298\s*\uBC24)$/i, fn: function() { return todayAt(21,0); }, label: function() { return '\uC624\uB298 \uBC24 9:00 PM'; } },
            { pattern: /^(\uC624\uD6C4)$/i, fn: function() { return todayAt(14,0); }, label: function() { return '\uC624\uB298 \uC624\uD6C4 2:00 PM'; } },
        ];

        var currentMatch = null;
        var selectedIndex = -1;

        function updateAutocomplete() {
            var input = document.getElementById('snoozeInput').value.trim();
            var ac = document.getElementById('autocomplete');
            currentMatch = null;
            selectedIndex = -1;

            if (!input) {
                ac.classList.remove('visible');
                return;
            }

            for (var i = 0; i < PRESETS.length; i++) {
                var m = input.match(PRESETS[i].pattern);
                if (m) {
                    var resolvedDate = PRESETS[i].fn(m);
                    var label = PRESETS[i].label(m);
                    var timeStr = toISO(resolvedDate);
                    currentMatch = { date: resolvedDate, label: label, iso: timeStr };
                    selectedIndex = 0;
                    ac.innerHTML = '<div class="autocomplete-item selected" onclick="selectPreset()">' +
                        '<span class="ac-label">' + label + '</span>' +
                        '<span class="ac-time">' + timeStr + '</span>' +
                        '</div>';
                    ac.classList.add('visible');
                    return;
                }
            }

            ac.classList.remove('visible');
        }

        function selectPreset() {
            if (!currentMatch) return;
            window.webkit.messageHandlers.snoozeBridge.postMessage({
                action: 'submit',
                isoTimestamp: currentMatch.iso,
                taskId: TASK_ID,
                sessionId: SESSION_ID,
                subject: SUBJECT
            });
        }

        function submitSnooze() {
            if (currentMatch) {
                selectPreset();
                return;
            }
            var input = document.getElementById('snoozeInput').value.trim();
            if (!input) return;
            window.webkit.messageHandlers.snoozeBridge.postMessage({
                action: 'submit',
                input: input,
                taskId: TASK_ID,
                sessionId: SESSION_ID,
                subject: SUBJECT
            });
        }

        function closeDialog() {
            window.webkit.messageHandlers.snoozeBridge.postMessage({ action: 'close' });
        }

        document.getElementById('snoozeInput').addEventListener('input', updateAutocomplete);

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
                closeDialog();
            }
            if (e.key === 'Enter') {
                e.preventDefault();
                submitSnooze();
            }
        });

        document.getElementById('snoozeInput').focus();
    </script>
</body>
</html>
]]

    -- Create UserContent for Snooze (singleton pattern)
    if not snoozeUserContent then
        snoozeUserContent = hs.webview.usercontent.new("snoozeBridge")
        snoozeUserContent:setCallback(function(msg)
            log("Snooze message: " .. hs.json.encode(msg.body))
            actionHandler(msg.body.action, msg.body)
        end)
    end

    snoozeWebview = hs.webview.new(rect, {}, snoozeUserContent)
    snoozeWebview:windowStyle({"titled", "closable", "utility", "HUD"})
    snoozeWebview:level(hs.drawing.windowLevels.floating)
    snoozeWebview:allowTextEntry(true)
    snoozeWebview:shadow(true)
    snoozeWebview:alpha(0.98)
    snoozeWebview:windowTitle("Snooze Task")
    snoozeWebview:html(html)
    snoozeWebview:show()
    snoozeWebview:bringToFront()

    log("Snooze dialog opened for task: " .. (taskId or ""))
end

-- Close Snooze dialog
function M.closeSnoozeDialog()
    if snoozeWebview then
        snoozeWebview:delete()
        snoozeWebview = nil
    end
end

-- Toggle overlay mode (semi-transparent passthrough)
function M.toggleOverlay(log)
    if not webview then return false end

    isOverlayMode = not isOverlayMode

    if isOverlayMode then
        webview:alpha(0.3)
        webview:behavior({"canJoinAllSpaces", "stationary"})
        log("Overlay mode enabled")
    else
        webview:alpha(0.98)
        webview:behavior({})
        log("Overlay mode disabled")
    end

    return isOverlayMode
end

-- Check overlay mode
function M.isOverlayMode()
    return isOverlayMode
end

-- Cleanup all webviews
function M.cleanup()
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
    if snoozeWebview then snoozeWebview:delete(); snoozeWebview = nil end
    if snoozeUserContent then snoozeUserContent = nil end
    usercontent = nil
    quickTaskUserContent = nil
    isVisible = false
    isOverlayMode = false
end

return M

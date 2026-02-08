-- lib/webview.lua
-- WebView management and UI components

local M = {}

-- Module-level state
local webview = nil
local usercontent = nil
local detailWebview = nil
local quickTaskWebview = nil
local quickTaskUserContent = nil
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
    usercontent = nil
    quickTaskUserContent = nil
    isVisible = false
    isOverlayMode = false
end

return M

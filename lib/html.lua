-- lib/html.lua
-- HTML/CSS/JS generation for WebView

local M = {}

-- Get status color
function M.getStatusColor(status)
    if status == "completed" then
        return "#22c55e"  -- green
    elseif status == "in_progress" then
        return "#f59e0b"  -- amber
    else
        return "#6b7280"  -- gray (pending)
    end
end

-- Get status icon
function M.getStatusIcon(status)
    if status == "completed" then
        return "✓"
    elseif status == "in_progress" then
        return "◐"
    else
        return "○"
    end
end

-- Generate metadata badges HTML
function M.generateMetadataBadges(metadata, utils)
    if not metadata or type(metadata) ~= "table" then
        return ""
    end
    local badges = ""
    for key, value in pairs(metadata) do
        local displayValue = tostring(value)
        if type(value) == "table" then
            displayValue = hs.json.encode(value)
        end
        -- Truncate long values
        if #displayValue > 20 then
            displayValue = displayValue:sub(1, 17) .. "..."
        end
        badges = badges .. string.format(
            '<span class="metadata-badge" title="%s: %s"><span class="meta-key">%s:</span> %s</span>',
            utils.escapeHtml(key),
            utils.escapeHtml(tostring(value)),
            utils.escapeHtml(key),
            utils.escapeHtml(displayValue)
        )
    end
    return badges
end

-- Generate launch button for a task (handles handoff metadata)
function M.generateLaunchBtn(task, utils)
    if task.metadata and task.metadata.handoff and task.metadata.target_cwd then
        local cwd = task.metadata.target_cwd
        return '<button class="task-launch-btn task-handoff-btn" onclick="launchClaudeHandoff(\'' .. utils.escapeHtml(task._sessionId) .. '\', \'' .. utils.escapeHtml(cwd) .. '\')" title="Handoff to ' .. utils.escapeHtml(cwd) .. '">⤴</button>'
    elseif task._cwd then
        return '<button class="task-launch-btn" onclick="launchClaudeWithCwd(\'' .. utils.escapeHtml(task._sessionId) .. '\', \'' .. utils.escapeHtml(task._cwd) .. '\')" title="Launch in ' .. utils.escapeHtml(task._cwd) .. '">▶</button>'
    else
        return '<button class="task-launch-btn" onclick="launchClaudeWithSession(\'' .. utils.escapeHtml(task._sessionId) .. '\')" title="Launch with session">▶</button>'
    end
end

-- Generate cwd display for a task (handles handoff target_cwd)
function M.generateCwdDisplay(task, utils)
    local cwd = task._cwd
    local isHandoff = task.metadata and task.metadata.handoff and task.metadata.target_cwd
    if isHandoff then
        cwd = task.metadata.target_cwd
    end
    if not cwd then return '' end
    local prefix = isHandoff and '<span style="color:#8b5cf6">&#x2934; </span>' or ''
    return '<div class="cwd-path" title="' .. utils.escapeHtml(cwd) .. '">' .. prefix .. utils.escapeHtml(cwd) .. '</div>'
end

-- Generate full HTML for task viewer
function M.generateHTML(tasks, sessions, currentSessionValue, utils, config)
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

    -- Session datalist options
    local sessionOptions = ''
    for _, sessionId in ipairs(sessions) do
        sessionOptions = sessionOptions .. string.format(
            '                    <option value="%s"></option>\n',
            utils.escapeHtml(sessionId)
        )
    end

    -- Generate keyBindings JavaScript (no fallback - config.keyBindings must be set)
    if not config or not config.keyBindings then
        error("html.generateHTML: config.keyBindings is required")
    end
    local keyBindingsJson = hs.json.encode(config.keyBindings)

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
        /* TaskCreate form */
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
        .task.focused {
            outline: 2px solid #3b82f6;
            outline-offset: -2px;
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
        .task-handoff-btn {
            background: #8b5cf6;
            font-size: 14px;
        }
        .task-handoff-btn:hover {
            background: #7c3aed;
        }
        /* Search/Session toggle */
        .input-row {
            display: flex;
            gap: 8px;
            align-items: center;
        }
        .input-container {
            flex: 1;
            position: relative;
        }
        .toggle-btn {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #888;
            width: 32px;
            height: 32px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
        }
        .toggle-btn:hover {
            background: rgba(255, 255, 255, 0.15);
            color: #e5e5e5;
        }
        .toggle-btn.active {
            background: rgba(59, 130, 246, 0.2);
            border-color: #3b82f6;
            color: #60a5fa;
        }
        .search-input {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(59, 130, 246, 0.5);
            color: #e5e5e5;
            padding: 6px 10px;
            padding-left: 28px;
            border-radius: 4px;
            font-size: 12px;
            width: 100%;
        }
        .search-input:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .search-input::placeholder {
            color: #666;
        }
        .search-icon {
            position: absolute;
            left: 8px;
            top: 50%;
            transform: translateY(-50%);
            color: #60a5fa;
            font-size: 12px;
            pointer-events: none;
        }
        .hidden {
            display: none !important;
        }
        .no-results {
            color: #666;
            font-style: italic;
            padding: 12px;
            text-align: center;
        }
        /* Help popup */
        .help-btn {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #888;
            width: 24px;
            height: 24px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .help-btn:hover {
            background: rgba(255, 255, 255, 0.15);
            color: #e5e5e5;
        }
        .help-popup {
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background: rgba(40, 40, 40, 0.98);
            border: 1px solid rgba(255, 255, 255, 0.2);
            border-radius: 8px;
            padding: 16px 20px;
            z-index: 1000;
            min-width: 280px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
        }
        .help-popup.hidden {
            display: none;
        }
        .help-overlay {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(0, 0, 0, 0.5);
            z-index: 999;
        }
        .help-overlay.hidden {
            display: none;
        }
        .help-title {
            font-size: 14px;
            font-weight: 600;
            color: #fff;
            margin-bottom: 12px;
            padding-bottom: 8px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
        }
        .help-section {
            margin-bottom: 12px;
        }
        .help-section-title {
            font-size: 11px;
            font-weight: 600;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 6px;
        }
        .help-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 4px 0;
        }
        .help-key {
            background: rgba(255, 255, 255, 0.1);
            padding: 2px 8px;
            border-radius: 4px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: 11px;
            color: #60a5fa;
        }
        .help-desc {
            font-size: 12px;
            color: #ccc;
        }
    </style>
    <script>
        const keyBindings = ]] .. keyBindingsJson .. [[;

        let isCreating = false;
        let formCollapsed = true;
        let focusedIndex = -1;
        let currentMode = 'session'; // 'session' | 'search'
        let searchDebounceTimer = null;
        let helpVisible = false;

        // Check if a key matches a binding
        // Format: {modifiers: ['cmd'], keys: ['Backspace']}
        function matchesBinding(e, bindingName) {
            const binding = keyBindings[bindingName];
            if (!binding) {
                console.warn('matchesBinding: Unknown binding "' + bindingName + '"');
                return false;
            }
            if (!binding.keys) return false;

            const modifiers = binding.modifiers || [];
            const keys = binding.keys;

            // Check if key matches any of the keys
            const keyMatches = keys.includes(e.key);
            if (!keyMatches) return false;

            // Check modifiers
            const cmdRequired = modifiers.includes('cmd');
            const altRequired = modifiers.includes('alt');
            const ctrlRequired = modifiers.includes('ctrl');
            const shiftRequired = modifiers.includes('shift');

            const cmdMatches = cmdRequired ? e.metaKey : !e.metaKey;
            const altMatches = altRequired ? e.altKey : !e.altKey;
            const ctrlMatches = ctrlRequired ? e.ctrlKey : !e.ctrlKey;
            const shiftMatches = shiftRequired ? e.shiftKey : !e.shiftKey;

            return cmdMatches && altMatches && ctrlMatches && shiftMatches;
        }

        // Release focus to navigation mode
        function releaseToNavigation() {
            if (document.activeElement) {
                document.activeElement.blur();
            }
            document.querySelectorAll('.task').forEach(t => t.classList.remove('focused'));
            focusedIndex = -1;
        }

        // Set input mode
        function setMode(mode) {
            currentMode = mode;
            const sessionContainer = document.getElementById('sessionContainer');
            const searchContainer = document.getElementById('searchContainer');
            const toggleBtn = document.getElementById('toggleBtn');

            releaseToNavigation();

            if (mode === 'search') {
                sessionContainer.classList.add('hidden');
                searchContainer.classList.remove('hidden');
                toggleBtn.classList.add('active');
                toggleBtn.innerHTML = '⊟';
                toggleBtn.title = 'Session input (=)';
                document.getElementById('searchInput').focus();
            } else {
                sessionContainer.classList.remove('hidden');
                searchContainer.classList.add('hidden');
                toggleBtn.classList.remove('active');
                toggleBtn.innerHTML = '⌕';
                toggleBtn.title = 'Search tasks (/)';
                clearSearch();
                document.getElementById('sessionInput').focus();
            }
        }

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
            // Enter key or blur triggers session change
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

        function launchClaudeWithSession(sessionId) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'launchClaudeWithSession',
                sessionId: sessionId
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

        function launchClaudeHandoff(sessionId, cwd) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'launchClaudeHandoff',
                sessionId: sessionId,
                cwd: cwd
            });
        }

        function showTaskDetail(subject, description, metadata) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'showTaskDetail',
                subject: subject,
                description: description,
                metadata: metadata || {}
            });
        }

        // vim-like navigation
        function getVisibleTasks() {
            return Array.from(document.querySelectorAll('.task:not(.hidden)'));
        }

        function updateFocus(newIndex) {
            const tasks = getVisibleTasks();
            if (tasks.length === 0) return;

            // Clamp index
            newIndex = Math.max(0, Math.min(newIndex, tasks.length - 1));

            // Remove previous focus
            tasks.forEach(t => t.classList.remove('focused'));

            // Add focus to new task
            focusedIndex = newIndex;
            const focusedTask = tasks[focusedIndex];
            focusedTask.classList.add('focused');

            // Scroll into view
            focusedTask.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }

        function openFocusedTask() {
            const tasks = getVisibleTasks();
            if (focusedIndex >= 0 && focusedIndex < tasks.length) {
                const task = tasks[focusedIndex];
                const descEl = task.querySelector('.task-description');
                if (descEl) {
                    descEl.click();
                }
            }
        }

        function launchFocusedTask() {
            const tasks = getVisibleTasks();
            if (focusedIndex >= 0 && focusedIndex < tasks.length) {
                const task = tasks[focusedIndex];
                const launchBtn = task.querySelector('.task-launch-btn');
                if (launchBtn) {
                    launchBtn.click();
                }
            }
        }

        function deleteFocusedTask() {
            const tasks = getVisibleTasks();
            if (focusedIndex < 0 || focusedIndex >= tasks.length) {
                console.warn('deleteFocusedTask: No task focused');
                return;
            }

            const task = tasks[focusedIndex];
            const taskId = task.dataset.taskId;
            const sessionId = task.dataset.sessionId;

            if (!taskId || !sessionId) {
                console.warn('deleteFocusedTask: Missing task-id or session-id');
                return;
            }

            const subjectEl = task.querySelector('.task-subject');
            const title = subjectEl ? subjectEl.textContent.trim() : 'this task';

            if (confirm('Delete "' + title + '"?\n\nThis cannot be undone.')) {
                window.webkit.messageHandlers.taskBridge.postMessage({
                    action: 'deleteTask',
                    taskId: taskId,
                    sessionId: sessionId
                });
            }
        }

        // Toggle between modes (for button click)
        function toggleMode() {
            setMode(currentMode === 'search' ? 'session' : 'search');
        }

        function clearSearch() {
            const searchInput = document.getElementById('searchInput');
            if (searchInput) {
                searchInput.value = '';
                filterTasks('');
            }
        }

        function filterTasks(query) {
            const tasks = document.querySelectorAll('.task');
            const normalizedQuery = query.toLowerCase().trim();
            let visibleCount = 0;

            tasks.forEach(task => {
                if (!normalizedQuery) {
                    task.classList.remove('hidden');
                    visibleCount++;
                    return;
                }

                const subject = task.querySelector('.task-subject')?.textContent?.toLowerCase() || '';
                const description = task.querySelector('.task-description')?.textContent?.toLowerCase() || '';

                if (subject.includes(normalizedQuery) || description.includes(normalizedQuery)) {
                    task.classList.remove('hidden');
                    visibleCount++;
                } else {
                    task.classList.add('hidden');
                }
            });

            // Show/hide no results message
            let noResultsEl = document.getElementById('noResults');
            if (normalizedQuery && visibleCount === 0) {
                if (!noResultsEl) {
                    noResultsEl = document.createElement('div');
                    noResultsEl.id = 'noResults';
                    noResultsEl.className = 'no-results';
                    noResultsEl.textContent = 'No matching tasks';
                    document.body.appendChild(noResultsEl);
                }
                noResultsEl.classList.remove('hidden');
            } else if (noResultsEl) {
                noResultsEl.classList.add('hidden');
            }

        }

        function onSearchInput(input) {
            if (searchDebounceTimer) {
                clearTimeout(searchDebounceTimer);
            }
            searchDebounceTimer = setTimeout(() => {
                filterTasks(input.value);
            }, 200);
        }

        // Help popup
        function toggleHelp() {
            helpVisible = !helpVisible;
            document.getElementById('helpOverlay').classList.toggle('hidden', !helpVisible);
            document.getElementById('helpPopup').classList.toggle('hidden', !helpVisible);
        }

        // Auto-focus first task on load
        document.addEventListener('DOMContentLoaded', function() {
            const tasks = getVisibleTasks();
            if (tasks.length > 0) {
                updateFocus(0);
            }
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', function(e) {
            const activeEl = document.activeElement;
            const isInputFocused = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');

            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                createTask();
                return;
            }
            if (e.key === 'e' && e.metaKey) {
                e.preventDefault();
                var btn = document.getElementById('quickUpdateBtn');
                if (btn && !btn.disabled) {
                    showQuickUpdateDialog();
                } else {
                    document.getElementById('sessionInput').focus();
                }
                return;
            }
            if (e.key === '?') {
                e.preventDefault();
                toggleHelp();
                return;
            }
            if (e.key === 'Escape' || (e.key === '[' && e.ctrlKey)) {
                e.preventDefault();
                // Close help if open
                if (helpVisible) {
                    toggleHelp();
                    return;
                }
                // Exit search mode if active
                if (currentMode === 'search') {
                    setMode('session');
                    return;
                }
                // Collapse form if open
                if (!formCollapsed) {
                    toggleForm();
                }
                // Release to navigation
                releaseToNavigation();
                return;
            }

            // Mode switching (global)
            if (e.key === '/') {
                e.preventDefault();
                setMode('search');
                return;
            }
            if (e.key === '=') {
                e.preventDefault();
                setMode('session');
                return;
            }

            // vim-like navigation (only when not in input)
            if (!isInputFocused) {
                if (matchesBinding(e, 'navigateDown')) {
                    e.preventDefault();
                    updateFocus(focusedIndex + 1);
                    return;
                }
                if (matchesBinding(e, 'navigateUp')) {
                    e.preventDefault();
                    updateFocus(focusedIndex - 1);
                    return;
                }
                if (matchesBinding(e, 'openTask')) {
                    e.preventDefault();
                    openFocusedTask();
                    return;
                }
                if (matchesBinding(e, 'launchTask')) {
                    e.preventDefault();
                    launchFocusedTask();
                    return;
                }
                if (matchesBinding(e, 'deleteTask')) {
                    e.preventDefault();
                    deleteFocusedTask();
                    return;
                }
            }
        });
    </script>
</head>
<body>
    <div class="header">
        <div class="header-row">
            <span class="title">Claude Tasks</span>
            <div class="header-actions">
                <span class="count">]] .. #tasks .. [[ tasks</span>
                <button class="help-btn" onclick="toggleHelp()" title="Keyboard shortcuts (?)">?</button>
            </div>
        </div>
        <div class="input-row">
            <div class="input-container" id="sessionContainer">
                <input type="text" class="session-input" id="sessionInput" list="sessionList"
                       value="]] .. utils.escapeHtml(currentSessionValue) .. [["
                       placeholder="Enter or select session..."
                       onchange="onSessionInputChange(this)"
                       onkeydown="if(event.key==='Enter'){onSessionInputChange(this);releaseToNavigation();event.preventDefault();}">
                <datalist id="sessionList">
                    ]] .. sessionOptions .. [[
                </datalist>
            </div>
            <div class="input-container hidden" id="searchContainer">
                <span class="search-icon">⌕</span>
                <input type="text" class="search-input" id="searchInput"
                       placeholder="Search tasks..."
                       oninput="onSearchInput(this)"
                       onkeydown="if(event.key==='Enter'){releaseToNavigation();event.preventDefault();}">
            </div>
            <button id="toggleBtn" class="toggle-btn" onclick="toggleMode()" title="Search tasks (/)">⌕</button>
            <button id="quickUpdateBtn" class="toggle-btn" onclick="showQuickUpdateDialog()" title="Quick Task ⌘E"]] .. (currentSessionValue == '' and ' disabled' or '') .. [[>⚡</button>
        </div>
    </div>
]]

    -- In Progress section
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
            local launchBtn = M.generateLaunchBtn(task, utils)
            local descriptionHtml = ''
            local jsonMeta = task.metadata and hs.json.encode(task.metadata) or '{}'
            if task.description then
                local jsonDesc = utils.jsonEncodeString(task.description)
                local jsonSubj = utils.jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ", " .. jsonMeta .. ")' title='Click to view full description'>" .. utils.escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. utils.escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = M.generateMetadataBadges(task.metadata, utils)
            html = html .. [[
        <div class="task" data-task-id="]] .. utils.escapeHtml(tostring(task.id)) .. [[" data-session-id="]] .. utils.escapeHtml(task._sessionId) .. [[">
            <span class="task-icon status-in_progress">]] .. M.getStatusIcon("in_progress") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. utils.escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. utils.escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. utils.escapeHtml(task._sessionId) .. [[">]] .. utils.escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. M.generateCwdDisplay(task, utils) .. [[
                ]] .. blocked .. launchBtn .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Pending section
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
            local launchBtn = M.generateLaunchBtn(task, utils)
            local descriptionHtml = ''
            local jsonMeta = task.metadata and hs.json.encode(task.metadata) or '{}'
            if task.description then
                local jsonDesc = utils.jsonEncodeString(task.description)
                local jsonSubj = utils.jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ", " .. jsonMeta .. ")' title='Click to view full description'>" .. utils.escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. utils.escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = M.generateMetadataBadges(task.metadata, utils)
            html = html .. [[
        <div class="task" data-task-id="]] .. utils.escapeHtml(tostring(task.id)) .. [[" data-session-id="]] .. utils.escapeHtml(task._sessionId) .. [[">
            <span class="task-icon status-pending">]] .. M.getStatusIcon("pending") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. utils.escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. utils.escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. utils.escapeHtml(task._sessionId) .. [[">]] .. utils.escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. M.generateCwdDisplay(task, utils) .. [[
                ]] .. blocked .. launchBtn .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Completed section (max 5)
    if #completedTasks > 0 then
        local displayCount = math.min(5, #completedTasks)
        html = html .. [[
    <div class="section">
        <div class="section-header">Completed (]] .. #completedTasks .. [[)</div>
]]
        for i = 1, displayCount do
            local task = completedTasks[i]
            local launchBtn = M.generateLaunchBtn(task, utils)
            local descriptionHtml = ''
            local jsonMeta = task.metadata and hs.json.encode(task.metadata) or '{}'
            if task.description then
                local jsonDesc = utils.jsonEncodeString(task.description)
                local jsonSubj = utils.jsonEncodeString(task.subject)
                descriptionHtml = "<div class='task-description' onclick='showTaskDetail(" .. jsonSubj .. ", " .. jsonDesc .. ", " .. jsonMeta .. ")' title='Click to view full description'>" .. utils.escapeHtml(task.description) .. "</div>"
            end
            local ownerHtml = task.owner and ' <span class="owner-badge">' .. utils.escapeHtml(task.owner) .. '</span>' or ''
            local metadataHtml = M.generateMetadataBadges(task.metadata, utils)
            html = html .. [[
        <div class="task" data-task-id="]] .. utils.escapeHtml(tostring(task.id)) .. [[" data-session-id="]] .. utils.escapeHtml(task._sessionId) .. [[" style="opacity: 0.6;">
            <span class="task-icon status-completed">]] .. M.getStatusIcon("completed") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. utils.escapeHtml(task.subject) .. [[</div>
                ]] .. descriptionHtml .. [[
                <div class="task-meta">
                    #]] .. utils.escapeHtml(tostring(task.id)) .. [[ <span class="session-badge" title="]] .. utils.escapeHtml(task._sessionId) .. [[">]] .. utils.escapeHtml(task._sessionId) .. [[</span>]] .. ownerHtml .. [[
                </div>
                ]] .. (metadataHtml ~= '' and '<div class="task-meta">' .. metadataHtml .. '</div>' or '') .. [[
                ]] .. M.generateCwdDisplay(task, utils) .. launchBtn .. [[
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

    -- No tasks message
    if #tasks == 0 then
        html = html .. [[
    <div class="empty">
        No tasks found.<br>
        Use TaskCreate in Claude Code to add tasks.
    </div>
]]
    end

    html = html .. [[
    <div id="helpOverlay" class="help-overlay hidden" onclick="toggleHelp()"></div>
    <div id="helpPopup" class="help-popup hidden">
        <div class="help-title">Keyboard Shortcuts</div>
        <div class="help-section">
            <div class="help-section-title">Navigation</div>
            <div class="help-row"><span class="help-key">j / ㅓ</span><span class="help-desc">Next task</span></div>
            <div class="help-row"><span class="help-key">k / ㅏ</span><span class="help-desc">Previous task</span></div>
            <div class="help-row"><span class="help-key">Space</span><span class="help-desc">View detail</span></div>
            <div class="help-row"><span class="help-key">Enter</span><span class="help-desc">Launch Claude</span></div>
            <div class="help-row"><span class="help-key">⌘⌫</span><span class="help-desc">Delete task</span></div>
        </div>
        <div class="help-section">
            <div class="help-section-title">Mode</div>
            <div class="help-row"><span class="help-key">/</span><span class="help-desc">Search mode</span></div>
            <div class="help-row"><span class="help-key">=</span><span class="help-desc">Session input</span></div>
            <div class="help-row"><span class="help-key">Esc / ^[</span><span class="help-desc">Back to navigation</span></div>
        </div>
        <div class="help-section">
            <div class="help-section-title">Other</div>
            <div class="help-row"><span class="help-key">⌘E</span><span class="help-desc">Quick Task</span></div>
            <div class="help-row"><span class="help-key">⌘Enter</span><span class="help-desc">Create task</span></div>
            <div class="help-row"><span class="help-key">?</span><span class="help-desc">Toggle this help</span></div>
        </div>
    </div>
</body>
</html>
]]
    return html
end

return M

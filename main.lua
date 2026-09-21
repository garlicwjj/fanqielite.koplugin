local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local logger = require("logger")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Export = require("fanqielite.export")
local Import = require("fanqielite.import")
local Library = require("fanqielite.library")
local NetworkTask = require("fanqielite.networktask")
local Parser = require("fanqielite.parser")
local Persistence = require("fanqielite.persistence")
local Search = require("fanqielite.search")
local Storage = require("fanqielite.storage")

local FanqieLite = WidgetContainer:extend{
    name = "fanqielite",
    is_doc_only = false,
}

local BASE = "https://fanqienovel.com"
local BOOK_PARSE_NEXT = "请稍后重试；若持续出现，请确认链接仍可在番茄官网打开并检查插件更新。"
local DIRECTORY_PARSE_NEXT = "请稍后重试；若持续出现，请确认该书仍可在番茄官网打开并检查插件更新。"
local SEARCH_PARSE_NEXT = "请改用番茄官网书籍链接；若持续出现，请检查插件更新。"
local CHAPTER_PARSE_NEXT = "请返回书籍页选择其他章节；需要登录或解锁时请使用番茄官方客户端；"
    .. "若持续出现，请检查插件更新。"
local NETWORK_WAIT_TIMEOUT_SECONDS = 50
local CATALOG_DIRECT_LIMIT = 200
local CATALOG_RANGE_SIZE = 100
local user_error_messages = setmetatable({}, { __mode = "k" })

local function book_has_progress(book)
    return type(book) == "table"
        and ((tonumber(book.last_opened_at) or 0) > 0
            or type(book.imported_progress) == "table")
end

local function raise_user_error(message, retryable)
    if type(message) ~= "string" or message == "" then
        message = "操作无法安全完成，请返回本地书架后重试。"
    end
    local token = {}
    user_error_messages[token] = {
        message = message,
        retryable = retryable == true,
    }
    error(token, 0)
end

local function user_error_detail(prefix, detail)
    if type(detail) ~= "string" or detail == "" then
        return prefix .. "操作没有返回可安全显示的错误说明，请返回本地书架确认状态后重试。"
    end
    return prefix .. detail
end

local function raise_network_error(prefix, detail, error_kind)
    raise_user_error(
        user_error_detail(prefix, detail),
        error_kind == "retryable")
end

local function cache_error_detail(detail)
    if type(detail) ~= "string" or detail == "" then
        return "缓存操作没有返回可安全显示的错误说明"
    end
    return detail
end

local function export_error_detail(detail)
    if type(detail) ~= "string" or detail == "" then
        return "导出操作没有返回可安全显示的错误说明"
    end
    return detail
end

local function import_error_detail(detail)
    if type(detail) ~= "string" or detail == "" then
        return "导入操作没有返回可安全显示的错误说明"
    end
    return detail
end

function FanqieLite:parser_failure_message(operation, detail, next_action)
    if type(operation) ~= "string" or operation == "" then
        operation = "解析官方内容失败"
    end
    if type(detail) ~= "string" or detail == "" then
        detail = "官方响应未返回可安全显示的失败原因"
    end
    if type(next_action) ~= "string" or next_action == "" then
        next_action = "请返回本地书架后重试；若持续出现，请检查插件更新。"
    end
    return operation .. "：" .. detail
        .. "\n\n本地书架、阅读进度和缓存没有改变。" .. next_action
end

function FanqieLite:raise_parser_failure(operation, detail, next_action)
    raise_user_error(self:parser_failure_message(operation, detail, next_action))
end

local function safe_import_directory(value)
    if type(value) ~= "string" or value == "" or #value > 1024
            or value:find("[%z\1-\31\127]") then
        return nil
    end
    return value
end

function FanqieLite:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/fanqielite.lua")
    local loaded_settings = type(self.settings.data) == "table"
        and Persistence.copy(self.settings.data) or nil
    local unsafe_loaded_settings = Persistence.has_sensitive_fields(loaded_settings)
    self.storage = Storage:new()
    local changed
    self.library, changed = Library.load(
        self.settings:readSetting("library"),
        self.settings:readSetting("book"),
        self.settings:readSetting("chapters"),
        self.settings:readSetting("current_index"))
    self.active_book_id = self.settings:readSetting("active_book_id")
    if not Library.find(self.library, self.active_book_id) then
        self.active_book_id = self.library.books[1] and self.library.books[1].id or nil
        changed = true
    end
    local normalized_settings = self:state_table()
    if loaded_settings and not Persistence.equal(loaded_settings, normalized_settings) then
        changed = true
    end
    if unsafe_loaded_settings then
        self.persisted_settings = normalized_settings
        self.startup_sensitive_cleanup = true
        changed = true
    else
        self.persisted_settings = changed and loaded_settings or normalized_settings
    end
    if type(self.persisted_settings) ~= "table" then
        self.persisted_settings = normalized_settings
    end
    if changed then
        local saved, save_err = self:save_state(true)
        if not saved then self.startup_save_error = save_err end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.startup_save_error then
        UIManager:nextTick(function() self:info(self.startup_save_error) end)
    end
end

function FanqieLite:onDispatcherRegisterActions()
    Dispatcher:registerAction("fanqielite_open", {
        category = "none", event = "FanqieLiteOpen", title = _("番茄小说（实验版）"), general = true,
    })
    Dispatcher:registerAction("fanqielite_previous_chapter", {
        category = "none",
        event = "FanqieLitePreviousChapter",
        title = _("番茄小说：上一章"),
        reader = true,
    })
    Dispatcher:registerAction("fanqielite_next_chapter", {
        category = "none",
        event = "FanqieLiteNextChapter",
        title = _("番茄小说：下一章"),
        reader = true,
    })
end

function FanqieLite:onFanqieLiteOpen()
    self:show_home()
end

function FanqieLite:current_reader_chapter()
    local file = self.ui and self.ui.document and self.ui.document.file
    local root = self.storage and self.storage.root
    if type(file) ~= "string" or file == ""
            or type(root) ~= "string" or root == "" then
        return nil, nil, "当前打开的不是 Fanqie Lite 章节。"
            .. "请先从本地书架打开一本书，再使用章节快捷操作。"
    end

    root = root:gsub("/+$", "")
    local prefix = root .. "/"
    if file:sub(1, #prefix) ~= prefix then
        return nil, nil, "当前打开的不是 Fanqie Lite 章节。"
            .. "此快捷操作不会影响普通 EPUB、PDF 或其他插件的书籍。"
    end
    local relative = file:sub(#prefix + 1)
    local book_id, chapter_id = relative:match("^(%d+)/(%d+)%.xhtml$")
    if not book_id or not chapter_id then
        return nil, nil, "当前打开的不是可识别的 Fanqie Lite 章节。"
            .. "请返回本地书架后重新打开。"
    end

    local book = Library.find(self.library, book_id)
    if not book then
        return nil, nil, "当前章节所属书籍已不在本地书架中。"
            .. "请重新添加该书后再使用章节快捷操作。"
    end
    local chapter_index
    for index, chapter in ipairs(book.chapters or {}) do
        if chapter.id == chapter_id then
            chapter_index = index
            break
        end
    end
    if not chapter_index then
        return nil, nil, "当前章节不在本地目录中。"
            .. "请打开书籍页刷新目录后重试。"
    end

    local checked, cached = pcall(
        self.storage.cached_chapter, self.storage, book_id, chapter_id)
    if not checked or cached ~= file then
        return nil, nil, "无法安全确认当前章节缓存，已停止切换。"
            .. "本地书架、阅读进度和缓存没有改变。"
            .. "请从书籍页重新打开本章；若持续出现，请重启 KOReader。"
    end
    return book, chapter_index
end

function FanqieLite:open_reader_adjacent_chapter(offset)
    local book, current_index, context_err = self:current_reader_chapter()
    if not book then
        self:info(context_err)
        return
    end
    local target_index = current_index + offset
    if target_index < 1 then
        self:info("已经是本书第一章；没有可打开的上一章。", 3)
        return
    end
    if target_index > #book.chapters then
        self:info("已经是本书最后一章；没有可打开的下一章。", 3)
        return
    end
    self:open_chapter(book.id, target_index)
end

function FanqieLite:onFanqieLitePreviousChapter()
    self:open_reader_adjacent_chapter(-1)
end

function FanqieLite:onFanqieLiteNextChapter()
    self:open_reader_adjacent_chapter(1)
end

function FanqieLite:addToMainMenu(menu_items)
    menu_items.fanqielite = {
        text = _("番茄小说（实验版）"), sorting_hint = "more_tools",
        callback = function() self:show_home() end,
    }
end

function FanqieLite:info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function FanqieLite:show_cache_prune_warning(reason)
    self:info("章节已保存并可继续阅读，但旧缓存自动清理未完成：\n"
        .. cache_error_detail(reason)
        .. "\n\n书架和当前章节没有损坏。稍后可在本书页面选择“清理章节缓存”；"
        .. "如果持续出现，请检查 Kindle 剩余空间或只读状态。")
end

function FanqieLite:book_local_status(book, cached_count, now)
    local chapter_count = type(book.chapters) == "table" and #book.chapters or 0
    local cache_text = cached_count == nil
        and "缓存状态不可读"
        or ("缓存文件 " .. tostring(cached_count) .. " 个")
    if chapter_count == 0 then
        return "本地状态：尚未获取目录；" .. cache_text
            .. "\n首次阅读需要联网。"
    end

    now = tonumber(now) or os.time()
    local timestamp = tonumber(book.directory_updated_at)
    local refreshed = "未知（下次联网刷新后记录）"
    if timestamp and timestamp == timestamp and timestamp > 0 then
        if now == now and timestamp > now + 86400 then
            refreshed = "设备时间异常，请校准后刷新"
        else
            local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M", timestamp)
            if ok and type(formatted) == "string" and formatted ~= "" then refreshed = formatted end
        end
    end
    return "本地状态：目录 " .. tostring(chapter_count) .. " 章；" .. cache_text
        .. "\n目录更新：" .. refreshed .. "；离线仅能打开完整缓存。"
end

function FanqieLite:active_book()
    return Library.find(self.library, self.active_book_id)
end

function FanqieLite:state_table()
    local state = { library = Persistence.copy(self.library) }
    if self.active_book_id then state.active_book_id = self.active_book_id end
    -- Keep the 0.1.0 fields in sync so downgrading does not lose the active book.
    local active = self:active_book()
    if active then
        state.book = {
            id = active.id, title = active.title, author = active.author,
        }
        state.chapters = Persistence.copy(active.chapters)
        state.current_index = active.current_index
    end
    local import_path = self.settings:readSetting("import_path")
    state.import_path = safe_import_directory(import_path)
    return state
end

function FanqieLite:restore_persisted_state()
    self.settings.data = Persistence.copy(self.persisted_settings)
    self.library = Library.load(
        self.settings:readSetting("library"),
        self.settings:readSetting("book"),
        self.settings:readSetting("chapters"),
        self.settings:readSetting("current_index"))
    self.active_book_id = self.settings:readSetting("active_book_id")
    if not Library.find(self.library, self.active_book_id) then
        self.active_book_id = self.library.books[1] and self.library.books[1].id or nil
    end
end

function FanqieLite:save_state(force)
    local candidate = self:state_table()
    if not force and Persistence.equal(candidate, self.persisted_settings) then return true end
    local saved, save_err, persistence_state = Persistence.write(
        self.settings.file, candidate, self.persisted_settings)
    if not saved then
        self:restore_persisted_state()
        local detail = type(save_err) == "string" and save_err
            or "设置写入没有返回可安全显示的错误说明"
        if persistence_state == "uncertain" then
            if self.startup_sensitive_cleanup then
                return nil, "检测到旧插件设置包含不应持久化的账号、会话或不安全封面地址，"
                    .. "但安全清理后的主设置无法完成最终校验，自动恢复也失败：" .. detail
                    .. "\n\n运行中的本地书架仍使用清洗副本，但磁盘上的主设置文件可能已经改变。"
                    .. "请停止继续操作并重启 KOReader；保留 fanqielite.lua.old，"
                    .. "若重启后书架异常请从备份恢复。"
            end
            return nil, "无法安全保存插件设置：" .. detail
                .. "\n\n本次内存中的书架或阅读进度变更已撤销，"
                .. "但磁盘上的主设置文件可能已经改变，无法确认与当前内存一致。"
                .. "请停止继续操作并重启 KOReader；保留 fanqielite.lua.old，"
                .. "若重启后书架异常请从备份恢复。"
        end
        if self.startup_sensitive_cleanup then
            return nil, "检测到旧插件设置包含不应持久化的账号、会话或不安全封面地址，"
                .. "但无法完成安全清理：" .. detail
                .. "\n\n运行中的本地书架已使用清洗副本，原设置文件可能仍未更新。"
                .. "请勿继续账号导入；检查 Kindle 剩余空间或只读状态后重启 KOReader。"
        end
        return nil, "无法安全保存插件设置：" .. detail
            .. "\n\n本次书架或阅读进度变更已撤销，上一版设置仍被保留。"
            .. "请检查 Kindle 剩余空间或只读状态后重试。"
    end
    self.startup_sensitive_cleanup = nil
    self.persisted_settings = Persistence.copy(candidate)
    self.settings.data = Persistence.copy(candidate)
    return true
end

function FanqieLite:with_network(callback)
    local function boundary_failure()
        self.network_busy = false
        self.network_wait = nil
        self:info("无法启动安全的网络操作。为避免显示不受信任的错误内容，详细信息已隐藏。"
            .. "\n\n本地书架、阅读进度和缓存没有改变。"
            .. "请返回本地书架后重试；若持续出现，请重启 KOReader。")
    end

    if self.network_busy then
        self:info("已有网络操作正在进行，请在当前进度窗口点按取消，或等待操作完成。", 3)
        return
    end

    if self.network_wait then
        local pending = self.network_wait
        self.network_wait = nil
        if pending.timeout_callback then
            pcall(UIManager.unschedule, UIManager, pending.timeout_callback)
        end
        self:info("已取消等待联网；本次操作没有开始。"
            .. "\n\n即使 Wi-Fi 随后连接成功，刚才的操作也不会继续；"
            .. "本地书架、阅读进度和缓存没有改变。", 4)
        return
    end

    local request = {}
    self.network_wait = request
    local function clear_wait()
        if self.network_wait ~= request then return false end
        self.network_wait = nil
        if request.timeout_callback then
            pcall(UIManager.unschedule, UIManager, request.timeout_callback)
        end
        return true
    end

    request.timeout_callback = function()
        if not clear_wait() then return end
        self:info("等待 Wi-Fi 超时，本次操作已取消。"
            .. "\n\n请确认网络可用后重新点按；本地书架、阅读进度和缓存没有改变。")
    end
    local scheduled_ok = pcall(
        UIManager.scheduleIn, UIManager, NETWORK_WAIT_TIMEOUT_SECONDS, request.timeout_callback)
    if not scheduled_ok then
        clear_wait()
        boundary_failure()
        return
    end

    local manager_ok = pcall(NetworkMgr.runWhenOnline, NetworkMgr, function()
        -- KOReader may deliver this callback after its own Wi-Fi UI has gone away.
        -- A cancelled or timed-out token must never revive the old operation.
        if not clear_wait() then return end
        if self.network_busy then
            self:info("已有网络操作正在进行，请在当前进度窗口点按取消，或等待操作完成。", 3)
            return
        end
        self.network_busy = true
        local wrapped_ok = pcall(Trapper.wrap, Trapper, function()
            local ok, err = pcall(callback)
            self.network_busy = false
            local reset_ok = pcall(Trapper.reset, Trapper)
            if not reset_ok then
                boundary_failure()
                return
            end
            if not ok then
                local failure = user_error_messages[err]
                local message = failure and failure.message
                if type(message) ~= "string" or message == "" then
                    message = "发生未预期的插件错误。为避免显示不受信任的错误内容，详细信息已隐藏。"
                        .. "请返回本地书架确认状态后重试；若持续出现，请停止操作并重启 KOReader。"
                end
                if failure and failure.retryable == true then
                    local retry_callback = callback
                    UIManager:show(ConfirmBox:new{
                        text = "操作未完成：\n" .. message
                            .. "\n\n本次操作已经停止。是否重试同一操作？",
                        cancel_text = _("返回"),
                        ok_text = _("重试"),
                        flush_events_on_show = true,
                        ok_callback = function()
                            UIManager:nextTick(function()
                                self:with_network(retry_callback)
                            end)
                        end,
                    })
                else
                    self:info("操作未完成：\n" .. message)
                end
            end
        end)
        if not wrapped_ok then
            self.network_busy = false
            pcall(Trapper.reset, Trapper)
            boundary_failure()
        end
    end)
    if not manager_ok then
        clear_wait()
        boundary_failure()
    end
end

function FanqieLite:fetch_book(book_id)
    local html, page_err, page_error_kind = NetworkTask.get(
        BASE .. "/page/" .. book_id, nil, "正在读取书籍信息……")
    if not html then
        raise_network_error("获取书籍页面失败：", page_err, page_error_kind)
    end
    local json_text, state_err = Parser.extract_initial_state(html)
    if not json_text then
        self:raise_parser_failure("解析书籍页面失败", state_err, BOOK_PARSE_NEXT)
    end
    local state, decode_err = Parser.decode_json(json_text)
    if not state then
        self:raise_parser_failure("解析书籍页面失败", decode_err, BOOK_PARSE_NEXT)
    end
    local book, book_err = Parser.book_from_state(state, book_id)
    if not book then self:raise_parser_failure("解析书籍页面失败", book_err, BOOK_PARSE_NEXT) end

    local directory_text, directory_err, directory_error_kind = NetworkTask.get(
        BASE .. "/api/reader/directory/detail?bookId=" .. book_id,
        "application/json", "正在读取目录……")
    if not directory_text then
        raise_network_error("获取目录失败：", directory_err, directory_error_kind)
    end
    local payload, payload_err = Parser.decode_json(directory_text)
    if not payload then self:raise_parser_failure("解析目录失败", payload_err, DIRECTORY_PARSE_NEXT) end
    local chapters, chapters_err = Parser.directory_from_payload(payload)
    if not chapters then
        self:raise_parser_failure("解析目录失败", chapters_err, DIRECTORY_PARSE_NEXT)
    end
    return book, chapters
end

function FanqieLite:load_book(input)
    local book_id, input_err = Parser.book_id(input)
    if not book_id then raise_user_error(input_err) end
    local book, chapters = self:fetch_book(book_id)
    local record, save_err = Library.upsert(self.library, book, chapters)
    if not record then raise_user_error(save_err) end
    self.active_book_id = record.id
    local saved, state_err = self:save_state()
    if not saved then raise_user_error(state_err) end
    local reading_action = book_has_progress(record) and "继续阅读" or "开始阅读"
    self:info("已加入《" .. record.title .. "》\n共 " .. tostring(#record.chapters)
        .. " 章\n\n正在打开书籍页，请选择“" .. reading_action .. "”。", 4)
    UIManager:nextTick(function() self:show_book(record.id) end)
end

function FanqieLite:refresh_book(book_id, quiet)
    local book, chapters = self:fetch_book(book_id)
    local record, save_err = Library.upsert(self.library, book, chapters)
    if not record then raise_user_error(save_err) end
    self.active_book_id = record.id
    local saved, state_err = self:save_state()
    if not saved then raise_user_error(state_err) end
    if not quiet then
        self:info("目录已刷新，共 " .. tostring(#record.chapters) .. " 章", 3)
    end
    return record
end

function FanqieLite:prompt_book()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索或添加一本书"),
        description = _("推荐粘贴番茄官网书籍链接；也可输入书名或作者名搜索（官网可能要求验证）。"),
        input_hint = _("官网链接、书名或作者名"),
        buttons = {{
            { text = _("取消"), callback = function() UIManager:close(dialog) end },
            { text = _("搜索/添加"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                self:submit_book_input(value)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanqieLite:submit_book_input(value)
    local book_id, input_err = Parser.book_id(value)
    if book_id then
        self:with_network(function() self:load_book(book_id) end)
        return
    end
    local trimmed = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    local lower = trimmed:lower()
    if trimmed:find("://", 1, true) or lower:find("fanqienovel.com", 1, true)
            or (trimmed:match("^%d+$") and #trimmed >= 10) then
        self:info(input_err or "请输入番茄小说官方书籍链接或书籍 ID")
        return
    end
    local url, query_or_err = Search.build_url(value)
    if not url then self:info(query_or_err); return end
    self:with_network(function() self:search_books(url, query_or_err) end)
end

function FanqieLite:search_books(url, query)
    local json_text, request_err, request_error_kind = NetworkTask.get(
        url, "application/json", "正在番茄官网搜索“" .. query .. "”……")
    if not json_text then
        raise_network_error("搜索未完成：", request_err, request_error_kind)
    end
    local payload, decode_err = Parser.decode_json(json_text)
    if not payload then
        self:raise_parser_failure("解析搜索结果失败", decode_err, SEARCH_PARSE_NEXT)
    end
    local results, results_err = Search.parse(payload)
    if not results then
        self:raise_parser_failure("解析搜索结果失败", results_err, SEARCH_PARSE_NEXT)
    end
    if #results == 0 then
        UIManager:nextTick(function() self:show_empty_search() end)
        return
    end
    UIManager:nextTick(function() self:show_search_results(query, results) end)
end

function FanqieLite:show_empty_search()
    UIManager:show(ConfirmBox:new{
        text = "没有找到匹配的书籍。可以换用完整书名或作者名；"
            .. "如果官网搜索不可用，请打开番茄官网书籍详情页，复制地址栏链接后重新输入。"
            .. "\n\n本地书架、阅读进度和缓存没有改变。",
        cancel_text = _("返回"),
        ok_text = _("重新输入"),
        ok_callback = function() self:prompt_book() end,
    })
end

function FanqieLite:show_search_results(query, results)
    local items = {}
    for _, result in ipairs(results) do
        local book_id = result.id
        local existing = Library.find(self.library, book_id)
        local author = result.author ~= "" and (" · " .. result.author) or ""
        items[#items + 1] = {
            text = result.title .. author .. (existing and "  [已在书架]" or ""),
            callback = existing and function() self:show_book(book_id) end or function()
                self:with_network(function() self:load_book(book_id) end)
            end,
        }
    end
    items[#items + 1] = {
        text = "没有想要的书？重新输入或粘贴官网链接",
        callback = function() self:prompt_book() end,
    }
    UIManager:show(Menu:new{
        title = "搜索：“" .. query .. "”",
        item_table = items,
        is_borderless = true,
    })
end

function FanqieLite:show_qr_import_status()
    self:info("一次性扫码导入尚未开放。\n\n"
        .. "当前版本没有发起账号授权，也没有请求或保存任何登录信息；"
        .. "已有本地书架不受影响。\n\n"
        .. "现在可以返回“我的本地书架”，选择：\n"
        .. "1. 搜索或添加一本书\n"
        .. "2. 从文件导入书架\n\n"
        .. "扫码功能只有在安全审计和测试账号验证完成后才会开放。")
end

function FanqieLite:choose_import_file()
    UIManager:show(PathChooser:new{
        title = _("长按 fanqielite-bookshelf.json 选择导入"),
        select_directory = false,
        select_file = true,
        path = self.settings:readSetting("import_path") or Device.home_dir or DataStorage:getDataDir(),
        file_filter = function(filename) return filename == Import.FILENAME end,
        onConfirm = function(path)
            logger.info("[FanqieLite] import file selected; waiting for chooser input to finish")
            UIManager:tickAfterNext(function()
                logger.info("[FanqieLite] import validation started")
                self:prepare_file_import(path)
            end)
        end,
    })
end

function FanqieLite:prepare_file_import(path)
    local books, import_err = Import.read_file(path)
    if not books then
        logger.info("[FanqieLite] import validation rejected")
        self:info("导入失败：\n" .. import_error_detail(import_err)
            .. "\n\n现有本地书架没有改变。")
        return
    end
    local new_count, update_count = 0, 0
    for _, book in ipairs(books) do
        if Library.find(self.library, book.id) then update_count = update_count + 1
        else new_count = new_count + 1 end
    end
    logger.info("[FanqieLite] import validation passed; showing confirmation")
    UIManager:show(ConfirmBox:new{
        text = "文件格式验证通过，未发现 Cookie、Token、手机号等凭证字段。\n\n"
            .. "新增 " .. tostring(new_count) .. " 本，更新 " .. tostring(update_count) .. " 本。\n"
            .. "已有目录、缓存和本地阅读进度不会被覆盖。是否导入？",
        ok_text = _("导入"),
        ok_callback = function() self:apply_file_import(path, books) end,
    })
end

function FanqieLite:apply_file_import(path, books)
    local added, updated = Library.import_books(self.library, books)
    if not self.active_book_id and books[1] then self.active_book_id = books[1].id end
    local directory = type(path) == "string" and path:match("^(.*)/") or nil
    if directory == nil then directory = Device.home_dir end
    directory = safe_import_directory(directory)
    if directory then self.settings:saveSetting("import_path", directory) end
    local saved, save_err = self:save_state()
    if not saved then self:info(save_err); return end
    self:info("导入完成：新增 " .. tostring(added) .. " 本，更新 " .. tostring(updated)
        .. " 本。\n\n首次打开新书时需要联网获取目录。", 5)
    UIManager:nextTick(function() self:show_home() end)
end

function FanqieLite:export_path()
    local directory = Device.home_dir or DataStorage:getDataDir()
    return directory:gsub("/+$", "") .. "/" .. Import.FILENAME
end

function FanqieLite:prepare_local_export()
    if #self.library.books == 0 then
        self:info("本地书架为空，没有可导出的书籍。")
        return
    end
    local path = self:export_path()
    local open_call, existing = pcall(io.open, path, "rb")
    if not open_call then existing = nil end
    if existing then pcall(existing.close, existing) end
    UIManager:show(ConfirmBox:new{
        text = "将 " .. tostring(#self.library.books) .. " 本书导出到 Kindle 用户盘根目录：\n\n"
            .. Import.FILENAME .. "\n\n"
            .. (existing and "同名文件已存在，确认后会安全替换。\n\n" or "")
            .. "文件只含书名、作者、封面地址和章节进度，不含 Cookie、Token、手机号、正文或缓存。"
            .. "连接电脑后可以读取此文件。是否继续？",
        ok_text = existing and _("替换") or _("导出"),
        ok_callback = function() self:write_local_export(path) end,
    })
end

function FanqieLite:write_local_export(path)
    local count, export_err = Export.write(path, self.library)
    if not count then
        self:info("导出失败：\n" .. export_error_detail(export_err)
            .. "\n\n原有书架和章节缓存没有改变。请检查剩余空间或只读状态后重试。")
        return
    end
    self:info("已安全导出 " .. tostring(count) .. " 本书：\n\n" .. Import.FILENAME
        .. "\n\n可以连接电脑备份，或复制到另一台安装 Fanqie Lite 的 Kindle。", 7)
end

function FanqieLite:show_settings()
    local items = {
        { text = _("从文件导入书架"), callback = function() self:choose_import_file() end },
        { text = _("导出本地书架"), callback = function() self:prepare_local_export() end },
        {
            text = _("缓存管理说明"), callback = function()
                self:info("每本书最多保留 12 个章节缓存；写入新章节后会优先清理较早写入的缓存。\n\n"
                    .. "清理入口位于对应书籍页面；移除书籍后也会另行询问是否立即清理。"
                    .. "两项操作独立确认，选择保留时以后重新添加同一本书仍可复用。\n\n"
                    .. "清理只删除插件安全目录内的数字 XHTML 缓存；KOReader .sdr 阅读位置和未知文件保留。"
                    .. "离线时只能打开仍有完整缓存的章节。")
            end,
        },
        {
            text = _("可选手势快捷操作"), callback = function()
                self:info("不设置手势也能完整使用：本地书架、书籍页和章节目录"
                    .. "始终保留可见的上一章、下一章入口。\n\n"
                    .. "如需在正文中加速切章，可在 KOReader 的手势管理中，"
                    .. "把任意手势绑定到“番茄小说：下一章”或“番茄小说：上一章”。\n\n"
                    .. "快捷操作只会跟随当前打开的 Fanqie Lite 章节；"
                    .. "普通 EPUB、PDF、其他插件书籍或无法安全确认的缓存不会跳转。"
                    .. "目标章节未缓存时仍会显示正常的联网、取消和错误提示。")
            end,
        },
        {
            text = _("隐私与使用边界"), callback = function()
                self:info("默认阅读只访问番茄官网公开内容。扫码导入目前尚未开放，"
                    .. "没有发起账号授权；未来即使开放，也只用于一次性导入，"
                    .. "不会保存账号登录。\n\n"
                    .. "插件不接入第三方书源、不下载全本，也不绕过付费、登录或章节锁定。"
                    .. "JSON 导入会拒绝凭证字段和异常数据；本地导出不含账号凭证、正文或缓存。")
            end,
        },
        {
            text = _("完全卸载与安全回退"), callback = function()
                self:info("插件不会自动删除任何文件。如果以后可能恢复，请先导出本地书架，"
                    .. "并把 JSON 复制到电脑。完全卸载时请先退出 KOReader，再由电脑仅删除：\n\n"
                    .. "1. koreader/plugins/fanqielite.koplugin\n"
                    .. "2. 可选：koreader/fanqielite\n"
                    .. "3. 可选：koreader/settings/fanqielite.lua、fanqielite.lua.old、fanqielite.lua.tmp、fanqielite.lua.old.tmp\n"
                    .. "4. 可选：用户盘根目录的 fanqielite-bookshelf.json\n\n"
                    .. "第 1 项即可停用插件，保留第 2 至 4 项可供以后恢复。"
                    .. "删除第 2 项会永久删除离线章节和对应的 .sdr 阅读位置；"
                    .. "删除第 3 项会永久删除本地书架、目录和阅读进度；"
                    .. "删除第 4 项会删除手动导出的备份。\n\n"
                    .. "以上路径都只属于本插件，不会影响 Kindle 系统、KOReader、"
                    .. "其他书籍或其他插件。")
            end,
        },
    }
    UIManager:show(Menu:new{ title = _("设置与数据"), item_table = items, is_borderless = true })
end

function FanqieLite:cycle_sort()
    local next_mode = { recent = "title", title = "added", added = "recent" }
    self.library.sort = next_mode[self.library.sort] or "recent"
    local saved, save_err = self:save_state()
    if not saved then self:info(save_err); return end
    self:show_home()
end

function FanqieLite:show_home()
    local sort_names = { recent = "最近阅读", title = "书名", added = "最近添加" }
    local onboarding = {
        { text = _("搜索或添加一本书（推荐）"), callback = function() self:prompt_book() end },
        {
            text = _("从文件导入书架"),
            callback = function() self:choose_import_file() end,
        },
        {
            text = _("扫码导入我的番茄书架（尚未开放）"),
            callback = function() self:show_qr_import_status() end,
        },
    }
    local items = {}
    if #self.library.books > 0 then
        local recent = Library.sorted({ sort = "recent", books = self.library.books })[1]
        if recent then
            if #recent.chapters > 0 then
                local current_index = recent.current_index
                local action = book_has_progress(recent) and "继续阅读" or "开始阅读"
                items[#items + 1] = {
                    text = action .. "：《" .. recent.title .. "》（第 "
                        .. tostring(current_index) .. " 章）",
                    callback = function()
                        self:open_chapter(recent.id, current_index)
                    end,
                }
                if current_index < #recent.chapters then
                    local next_index = current_index + 1
                    items[#items + 1] = {
                        text = "下一章（第 " .. tostring(next_index) .. " 章）",
                        callback = function() self:open_chapter(recent.id, next_index) end,
                    }
                end
                if current_index > 1 then
                    local previous_index = current_index - 1
                    items[#items + 1] = {
                        text = "上一章（第 " .. tostring(previous_index) .. " 章）",
                        callback = function() self:open_chapter(recent.id, previous_index) end,
                    }
                end
            else
                items[#items + 1] = {
                    text = "打开：《" .. recent.title .. "》（待获取目录）",
                    callback = function() self:show_book(recent.id) end,
                }
            end
        end
        items[#items + 1] = {
            text = "排序：" .. (sort_names[self.library.sort] or sort_names.recent),
            callback = function() self:cycle_sort() end,
        }
        for _, book in ipairs(Library.sorted(self.library)) do
            local book_id = book.id
            local author = book.author ~= "" and (" · " .. book.author) or ""
            local progress = #book.chapters > 0
                and ("  [" .. tostring(book.current_index) .. "/" .. tostring(#book.chapters) .. "]")
                or "  [待获取目录]"
            items[#items + 1] = {
                text = book.title .. author .. progress,
                callback = function() self:show_book(book_id) end,
            }
        end
        for _, item in ipairs(onboarding) do items[#items + 1] = item end
    else
        for _, item in ipairs(onboarding) do items[#items + 1] = item end
        items[#items + 1] = {
            text = _("书架还是空的，请从上面选择一种添加方式"),
            callback = function() end,
        }
    end
    items[#items + 1] = { text = _("设置与数据"), callback = function() self:show_settings() end }
    UIManager:show(Menu:new{ title = _("我的本地书架"), item_table = items, is_borderless = true })
end

function FanqieLite:show_book(book_id)
    local book = Library.find(self.library, book_id)
    if not book then self:info("这本书已不在本地书架中"); return end
    local cached_count = self.storage:cached_count(book.id)
    local cache_status = cached_count and (tostring(cached_count) .. " 个") or "状态不可读"
    self.active_book_id = book.id
    local saved, save_err = self:save_state()
    if not saved then self:info(save_err); return end
    local items = {}
    if #book.chapters > 0 then
        local current_index = book.current_index
        items[#items + 1] = {
            text = (book_has_progress(book) and "继续阅读" or "开始阅读")
                .. "（第 " .. tostring(current_index) .. " 章）",
            callback = function() self:open_chapter(book.id, current_index) end,
        }
    else
        items[#items + 1] = {
            text = _("联网获取目录并开始阅读"), callback = function()
                self:with_network(function()
                    local refreshed = self:refresh_book(book.id, true)
                    -- Start a second network operation only after this one is reset.
                    UIManager:nextTick(function()
                        self:open_chapter(refreshed.id, refreshed.current_index)
                    end)
                end)
            end,
        }
    end
    items[#items + 1] = {
        text = self:book_local_status(book, cached_count),
        callback = function() end,
    }
    if #book.chapters > 0 then
        items[#items + 1] = { text = _("章节目录"), callback = function() self:show_catalog(book.id) end }
        if book.current_index > 1 then
            local previous_index = book.current_index - 1
            items[#items + 1] = {
                text = "上一章（第 " .. tostring(previous_index) .. " 章）",
                callback = function() self:open_chapter(book.id, previous_index) end,
            }
        end
        if book.current_index < #book.chapters then
            local next_index = book.current_index + 1
            items[#items + 1] = {
                text = "下一章（第 " .. tostring(next_index) .. " 章）",
                callback = function() self:open_chapter(book.id, next_index) end,
            }
        end
    end
    if #book.chapters > 0 then
        items[#items + 1] = {
            text = _("刷新书籍信息与目录"), callback = function()
                self:with_network(function()
                    self:refresh_book(book.id)
                    UIManager:nextTick(function() self:show_book(book.id) end)
                end)
            end,
        }
    end
    items[#items + 1] = {
            text = "清理章节缓存（" .. cache_status .. "）",
            callback = function() self:confirm_clear_cache(book.id) end,
    }
    items[#items + 1] = { text = _("从本地书架移除"), callback = function() self:confirm_remove(book.id) end }
    UIManager:show(Menu:new{
        title = book.title .. (book.author ~= "" and ("\n" .. book.author) or ""),
        item_table = items, is_borderless = true,
    })
end

function FanqieLite:confirm_remove(book_id)
    local book = Library.find(self.library, book_id)
    if not book then return end
    local cached_count = self.storage:cached_count(book_id)
    UIManager:show(ConfirmBox:new{
        text = "确定从本地书架移除《" .. book.title .. "》吗？\n\n"
            .. "移除只删除本地书架记录，不会同时删除缓存。"
            .. "移除后可选择是否立即清理；选择保留时，"
            .. "以后重新添加同一本书仍可复用完整缓存。",
        ok_text = _("移除"),
        ok_callback = function()
            Library.remove(self.library, book_id)
            if self.active_book_id == book_id then
                self.active_book_id = self.library.books[1] and self.library.books[1].id or nil
            end
            local saved, save_err = self:save_state()
            if not saved then self:info(save_err); return end
            UIManager:nextTick(function()
                self:show_home()
                self:offer_removed_cache_cleanup(book.id, book.title, cached_count)
            end)
        end,
    })
end

function FanqieLite:offer_removed_cache_cleanup(book_id, title, cached_count)
    if cached_count == 0 then
        self:info("已从本地书架移除；该书没有章节缓存需要清理。", 3)
        return
    end
    local cache_text = type(cached_count) == "number"
        and ("检测到 " .. tostring(cached_count) .. " 个章节缓存。")
        or "缓存数量暂时无法读取。"
    UIManager:show(ConfirmBox:new{
        text = "已从本地书架移除《" .. title .. "》。\n\n" .. cache_text
            .. "是否现在清理该书的数字 XHTML 章节缓存？\n\n"
            .. "取消将保留缓存，以后重新添加同一本书时仍可复用。"
            .. "KOReader .sdr 阅读位置和未知文件不会被删除。",
        ok_text = _("清理缓存"),
        ok_callback = function() self:clear_removed_book_cache(book_id) end,
    })
end

function FanqieLite:clear_removed_book_cache(book_id)
    local count, err = self.storage:clear_book(book_id)
    if not count then
        self:info("已移除书籍，但缓存清理失败：" .. cache_error_detail(err)
            .. "\n\n其他书籍、缓存和阅读进度没有改变。"
            .. "如需重试，可重新添加同一本书后进入其缓存清理入口。")
        return
    end
    if err then
        self:info("书籍已移除，缓存只完成了部分清理：\n" .. cache_error_detail(err)
            .. "\n\n其他书籍与数据没有改变；.sdr 和未知文件仍保留。")
        return
    end
    self:info("已清理 " .. tostring(count)
        .. " 个章节缓存；KOReader .sdr 阅读位置和未知文件仍保留。", 5)
end

function FanqieLite:confirm_clear_cache(book_id)
    local book = Library.find(self.library, book_id)
    if not book then return end
    UIManager:show(ConfirmBox:new{
        text = "确定清理《" .. book.title .. "》的章节缓存吗？\n\n书籍、目录和阅读进度会保留；离线时将无法打开被清理的章节。",
        ok_text = _("清理"),
        ok_callback = function()
            local count, err = self.storage:clear_book(book_id)
            if not count then
                self:info("清理失败：" .. cache_error_detail(err)
                    .. "\n\n书架和阅读进度没有改变。请检查存储空间或只读状态后重试。")
                return
            end
            if err then
                self:info("缓存只完成了部分清理：\n" .. cache_error_detail(err)
                    .. "\n\n未删除的缓存仍可继续使用；书架和阅读进度没有改变。")
                return
            end
            self:info("已清理 " .. tostring(count) .. " 个缓存文件", 3)
        end,
    })
end

local function catalog_cache_state(plugin, book)
    local cached_ids, damaged_ids = plugin.storage:verified_cached_chapter_ids(book.id)
    local cache_summary = "离线缓存状态不可读"
    if type(cached_ids) == "table" and type(damaged_ids) == "table" then
        local cached_count, damaged_count = 0, 0
        for _, chapter in ipairs(book.chapters) do
            if cached_ids[chapter.id] == true then cached_count = cached_count + 1 end
            if damaged_ids[chapter.id] == true then damaged_count = damaged_count + 1 end
        end
        cache_summary = "离线可读 " .. tostring(cached_count) .. " 章"
        if damaged_count > 0 then
            cache_summary = cache_summary .. "；" .. tostring(damaged_count) .. " 章缓存需修复"
        end
    end
    return cached_ids, damaged_ids, cache_summary
end

local function catalog_chapter_items(plugin, book, start_index, end_index,
        cached_ids, damaged_ids)
    local items = {}
    for index = start_index, end_index do
        local chapter = book.chapters[index]
        local chapter_index = index
        local status = index == book.current_index and "  [当前]" or ""
        if type(cached_ids) == "table" and cached_ids[chapter.id] == true then
            status = status .. "  [可离线]"
        elseif type(damaged_ids) == "table" and damaged_ids[chapter.id] == true then
            status = status .. "  [缓存需修复]"
        end
        items[#items + 1] = {
            text = chapter.title .. status,
            callback = function() plugin:open_chapter(book.id, chapter_index) end,
        }
    end
    return items
end

function FanqieLite:show_catalog_range(book_id, start_index, end_index)
    local book = Library.find(self.library, book_id)
    if not book or #book.chapters == 0 then self:info("目录为空，请联网刷新"); return end
    if type(start_index) ~= "number" or start_index ~= math.floor(start_index)
            or type(end_index) ~= "number" or end_index ~= math.floor(end_index)
            or start_index < 1 or end_index < start_index or start_index > #book.chapters
            or end_index - start_index + 1 > CATALOG_RANGE_SIZE then
        self:info("章段范围已变化，请返回书籍页重新打开目录")
        return
    end
    end_index = math.min(end_index, #book.chapters)
    local cached_ids, damaged_ids, cache_summary = catalog_cache_state(self, book)
    local items = catalog_chapter_items(
        self, book, start_index, end_index, cached_ids, damaged_ids)
    local range_text = "第 " .. tostring(start_index) .. "–" .. tostring(end_index) .. " 章"
    local menu = Menu:new{
        title = book.title .. "\n" .. range_text .. "；" .. cache_summary,
        item_table = items,
        is_borderless = true,
    }
    UIManager:show(menu)
    local selected = book.current_index >= start_index and book.current_index <= end_index
        and (book.current_index - start_index + 1) or 1
    if menu.onGotoPage then menu:onGotoPage(menu:getPageNumber(selected)) end
end

function FanqieLite:show_catalog(book_id)
    local book = Library.find(self.library, book_id)
    if not book or #book.chapters == 0 then self:info("目录为空，请联网刷新"); return end
    local cached_ids, damaged_ids, cache_summary = catalog_cache_state(self, book)
    local items, selected, title
    if #book.chapters <= CATALOG_DIRECT_LIMIT then
        items = catalog_chapter_items(
            self, book, 1, #book.chapters, cached_ids, damaged_ids)
        selected = book.current_index
        title = book.title .. "\n" .. cache_summary
    else
        items = {}
        for start_index = 1, #book.chapters, CATALOG_RANGE_SIZE do
            local range_start = start_index
            local range_end = math.min(start_index + CATALOG_RANGE_SIZE - 1, #book.chapters)
            local status = book.current_index >= range_start and book.current_index <= range_end
                and "  [当前]" or ""
            items[#items + 1] = {
                text = "第 " .. tostring(range_start) .. "–" .. tostring(range_end) .. " 章" .. status,
                callback = function()
                    self:show_catalog_range(book.id, range_start, range_end)
                end,
            }
        end
        selected = math.floor((book.current_index - 1) / CATALOG_RANGE_SIZE) + 1
        title = book.title .. "\n共 " .. tostring(#book.chapters) .. " 章；" .. cache_summary
    end
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
    }
    UIManager:show(menu)
    if menu.onGotoPage then menu:onGotoPage(menu:getPageNumber(selected)) end
end

function FanqieLite:open_file(path, after_open_callback)
    local open_call = pcall(
        FileManager.openFile, self.ui, path, nil, nil, nil, after_open_callback)
    if not open_call then
        self:info("无法打开章节文件，已停止进入阅读器。\n\n"
            .. "本地书架和缓存没有删除；从网页导入的阅读位置仍会保留供重试。"
            .. "当前书籍可能已记录为本章。"
            .. "请返回书籍页重试；若持续出现，请重启 KOReader。")
        return nil
    end
    return true
end

function FanqieLite:complete_imported_position(
        reader_ui, book_id, index, imported_position)
    local book = Library.find(self.library, book_id)
    if not book then
        self:info("章节已经打开，但本地书架状态已变化，未应用或清理导入位置。"
            .. "\n\n请返回本地书架确认书籍；导入位置仍保留供下次安全重试。")
        return nil
    end
    local current_position, pending = Library.inspect_imported_position(
        book, index, imported_position == nil)
    if not pending or current_position ~= imported_position then
        self:info("章节已经打开，但待处理的导入位置状态已变化，已停止修改。"
            .. "\n\nKOReader 本机位置和当前本地书架保持优先；请返回书籍页确认进度。")
        return nil
    end
    if imported_position ~= nil then
        local applied = pcall(function()
            reader_ui:handleEvent(Event:new("GotoPercent", imported_position * 100))
        end)
        if not applied then
            self:info("章节已经打开，但无法应用从文件导入的阅读位置。"
                .. "\n\n导入位置仍保留，本次没有把它标记为已使用。"
                .. "请返回书籍页重试；若持续出现，请重启 KOReader。")
            return nil
        end
    end

    Library.take_imported_position(book, index, true)
    local saved = self:save_state()
    if not saved then
        self:info("章节已经打开，但无法保存导入位置的一次性清理。\n\n"
            .. "本地书架已恢复到打开前的安全状态；导入位置没有丢失。"
            .. "如果 KOReader 已生成本机阅读位置，下次打开会优先使用它；"
            .. "否则可能再次应用导入位置。请检查存储空间或只读状态后重试。")
        return nil
    end
    return true
end

function FanqieLite:after_reader_ready(reader_ui, book_id, index, imported_position)
    local active_plugin = type(reader_ui) == "table" and reader_ui.fanqielite or nil
    if type(active_plugin) ~= "table"
            or type(active_plugin.complete_imported_position) ~= "function" then
        active_plugin = self
    end
    local completed = pcall(
        active_plugin.complete_imported_position, active_plugin,
        reader_ui, book_id, index, imported_position)
    if not completed then
        pcall(active_plugin.info, active_plugin,
            "章节已经打开，但无法安全完成导入位置处理。"
            .. "\n\n未显示底层错误，也未把本次处理视为已保存。"
            .. "请返回书籍页确认进度；若持续出现，请重启 KOReader。")
    end
end

local function written_cache_status(prune_warning)
    local status = "缓存状态已改变；较早缓存可能已按每书 12 个上限自动清理。"
    if prune_warning ~= nil then
        status = status .. "\n旧缓存自动清理未完成：" .. cache_error_detail(prune_warning)
    end
    return status
end

function FanqieLite:prepare_chapter_open(book, index, path, cache_written, prune_warning)
    local sidecar_call, has_local_position = pcall(
        DocSettings.hasSidecarFile, DocSettings, path)
    if not sidecar_call then
        if cache_written then
            return nil, "章节缓存已经写入，但无法确认 KOReader 本机阅读位置，已停止打开章节。"
                .. "\n\n本地书架和阅读进度没有改变；"
                .. written_cache_status(prune_warning)
                .. "\n请返回书籍页重试；若持续出现，请重启 KOReader。"
        end
        return nil, "无法确认 KOReader 本机阅读位置，已停止打开章节。"
            .. "本地书架、阅读进度和缓存没有改变。"
            .. "请返回书籍页重试；若持续出现，请重启 KOReader。"
    end
    local imported_position, pending_consumption = Library.inspect_imported_position(
        book, index, has_local_position)
    Library.touch(self.library, book.id, index)
    self.active_book_id = book.id
    local saved, save_err = self:save_state()
    if not saved then
        if cache_written then
            return nil, "章节缓存已经写入，但无法保存继续阅读位置，已停止打开章节。"
                .. "\n\n" .. written_cache_status(prune_warning)
                .. "\n" .. user_error_detail("设置保存失败：", save_err)
        end
        return nil, save_err
    end
    return true, imported_position, pending_consumption
end

function FanqieLite:open_prepared_chapter(
        book, index, path, imported_position, pending_consumption)
    local after_open_callback
    if pending_consumption then
        local book_id = book.id
        after_open_callback = function(reader_ui)
            self:after_reader_ready(reader_ui, book_id, index, imported_position)
        end
    end
    return self:open_file(path, after_open_callback)
end

function FanqieLite:open_chapter(book_id, index)
    local book = Library.find(self.library, book_id)
    index = tonumber(index)
    if not book or not index or not book.chapters[index] then
        self:info("已经到达目录边界", 2)
        return
    end
    local chapter = book.chapters[index]
    local cached, cache_err, recoverable_cache =
        self.storage:cached_chapter(book.id, chapter.id)
    if cached then
        local ready, position_or_err, pending_consumption =
            self:prepare_chapter_open(book, index, cached)
        if not ready then self:info(position_or_err); return end
        self:open_prepared_chapter(
            book, index, cached, position_or_err, pending_consumption)
        return
    end
    if cache_err and not recoverable_cache then
        self:info("无法安全检查本地缓存，已停止打开章节。\n\n"
            .. "本地书架、阅读进度和缓存没有改变。"
            .. "请返回书籍页重试；若持续出现，请重启 KOReader。")
        return
    end
    local loading_label = "正在读取第 " .. tostring(index) .. " 章……"
    if cache_err then
        loading_label = "缓存损坏，已拒绝打开；书架和进度未改变。\n正在联网重新获取……"
    end
    self:with_network(function()
        local html, fetch_err, fetch_error_kind = NetworkTask.get(
            BASE .. "/reader/" .. chapter.id, nil, loading_label)
        if not html then
            raise_network_error("读取章节失败：", fetch_err, fetch_error_kind)
        end
        local json_text, state_err = Parser.extract_initial_state(html)
        if not json_text then
            self:raise_parser_failure("解析章节失败", state_err, CHAPTER_PARSE_NEXT)
        end
        local state, decode_err = Parser.decode_json(json_text)
        if not state then
            self:raise_parser_failure("解析章节失败", decode_err, CHAPTER_PARSE_NEXT)
        end
        local parsed, chapter_err = Parser.chapter_from_state(state, chapter.id)
        if not parsed then
            self:raise_parser_failure("解析章节失败", chapter_err, CHAPTER_PARSE_NEXT)
        end
        parsed.title = chapter.title ~= "" and chapter.title or parsed.title
        local path, write_err, prune_warning = self.storage:write_chapter(
            book.id, chapter.id, Parser.to_xhtml(book, parsed))
        if not path then
            raise_user_error(user_error_detail("保存章节失败：", write_err)
                .. "\n未完整写入的临时文件已清理。请检查存储空间或只读状态后重试。")
        end
        local ready, position_or_err, pending_consumption =
            self:prepare_chapter_open(book, index, path, true, prune_warning)
        if not ready then raise_user_error(position_or_err) end
        UIManager:nextTick(function()
            local opened = self:open_prepared_chapter(
                book, index, path, position_or_err, pending_consumption)
            if opened and prune_warning then
                UIManager:nextTick(function() self:show_cache_prune_warning(prune_warning) end)
            end
        end)
    end)
end

return FanqieLite

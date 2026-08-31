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
local user_error_messages = setmetatable({}, { __mode = "k" })

local function raise_user_error(message)
    if type(message) ~= "string" or message == "" then
        message = "操作无法安全完成，请返回本地书架后重试。"
    end
    local token = {}
    user_error_messages[token] = message
    error(token, 0)
end

local function user_error_detail(prefix, detail)
    if type(detail) ~= "string" or detail == "" then
        return prefix .. "操作没有返回可安全显示的错误说明，请返回本地书架确认状态后重试。"
    end
    return prefix .. detail
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

function FanqieLite:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/fanqielite.lua")
    local loaded_settings = type(self.settings.data) == "table"
        and Persistence.copy(self.settings.data) or nil
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
    self.persisted_settings = changed and loaded_settings or normalized_settings
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
end

function FanqieLite:onFanqieLiteOpen()
    self:show_home()
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
    if type(import_path) == "string" and #import_path <= 1024
            and not import_path:find("[%z\1-\31]") then
        state.import_path = import_path
    end
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
    local saved, save_err = Persistence.write(
        self.settings.file, candidate, self.persisted_settings)
    if not saved then
        self:restore_persisted_state()
        local detail = type(save_err) == "string" and save_err
            or "设置写入没有返回可安全显示的错误说明"
        return nil, "无法安全保存插件设置：" .. detail
            .. "\n\n本次书架或阅读进度变更已撤销，上一版设置仍被保留。"
            .. "请检查 Kindle 剩余空间或只读状态后重试。"
    end
    self.persisted_settings = Persistence.copy(candidate)
    self.settings.data = Persistence.copy(candidate)
    return true
end

function FanqieLite:with_network(callback)
    local function boundary_failure()
        self.network_busy = false
        self:info("无法启动安全的网络操作。为避免显示不受信任的错误内容，详细信息已隐藏。"
            .. "\n\n本地书架、阅读进度和缓存没有改变。"
            .. "请返回本地书架后重试；若持续出现，请重启 KOReader。")
    end

    local manager_ok = pcall(NetworkMgr.runWhenOnline, NetworkMgr, function()
        if self.network_busy then
            self:info("已有网络操作正在进行，请先完成或点按取消。", 3)
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
                local message = user_error_messages[err]
                if not message then
                    message = "发生未预期的插件错误。为避免显示不受信任的错误内容，详细信息已隐藏。"
                        .. "请返回本地书架确认状态后重试；若持续出现，请停止操作并重启 KOReader。"
                end
                self:info("操作未完成：\n" .. message)
            end
        end)
        if not wrapped_ok then
            self.network_busy = false
            pcall(Trapper.reset, Trapper)
            boundary_failure()
        end
    end)
    if not manager_ok then boundary_failure() end
end

function FanqieLite:fetch_book(book_id)
    local html, page_err = NetworkTask.get(
        BASE .. "/page/" .. book_id, nil, "正在读取书籍信息……")
    if not html then raise_user_error(user_error_detail("获取书籍页面失败：", page_err)) end
    local json_text, state_err = Parser.extract_initial_state(html)
    if not json_text then raise_user_error(state_err) end
    local state, decode_err = Parser.decode_json(json_text)
    if not state then raise_user_error(decode_err) end
    local book, book_err = Parser.book_from_state(state, book_id)
    if not book then raise_user_error(book_err) end

    local directory_text, directory_err = NetworkTask.get(
        BASE .. "/api/reader/directory/detail?bookId=" .. book_id,
        "application/json", "正在读取目录……")
    if not directory_text then raise_user_error(user_error_detail("获取目录失败：", directory_err)) end
    local payload, payload_err = Parser.decode_json(directory_text)
    if not payload then raise_user_error(payload_err) end
    local chapters, chapters_err = Parser.directory_from_payload(payload)
    if not chapters then raise_user_error(chapters_err) end
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
    self:info("已加入《" .. record.title .. "》\n共 " .. tostring(#record.chapters) .. " 章", 3)
    UIManager:nextTick(function() self:show_book(record.id) end)
end

function FanqieLite:refresh_book(book_id)
    local book, chapters = self:fetch_book(book_id)
    local record, save_err = Library.upsert(self.library, book, chapters)
    if not record then raise_user_error(save_err) end
    self.active_book_id = record.id
    local saved, state_err = self:save_state()
    if not saved then raise_user_error(state_err) end
    self:info("目录已刷新，共 " .. tostring(#record.chapters) .. " 章", 3)
end

function FanqieLite:prompt_book()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索或添加一本书"),
        description = _("输入书名或作者名搜索；也可以直接粘贴番茄官网书籍链接。"),
        input_hint = _("书名、作者名或番茄官网链接"),
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
    local book_id = Parser.book_id(value)
    if book_id then
        self:with_network(function() self:load_book(book_id) end)
        return
    end
    local url, query_or_err = Search.build_url(value)
    if not url then self:info(query_or_err); return end
    self:with_network(function() self:search_books(url, query_or_err) end)
end

function FanqieLite:search_books(url, query)
    local json_text, request_err = NetworkTask.get(
        url, "application/json", "正在番茄官网搜索“" .. query .. "”……")
    if not json_text then raise_user_error(user_error_detail("搜索未完成：", request_err)) end
    local payload, decode_err = Parser.decode_json(json_text)
    if not payload then raise_user_error(decode_err) end
    local results, results_err = Search.parse(payload)
    if not results then raise_user_error(results_err) end
    UIManager:nextTick(function() self:show_search_results(query, results) end)
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
    self.settings:saveSetting("import_path", path:match("^(.*)/") or Device.home_dir)
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
                self:info("每本书最多保留 12 个章节缓存；写入新章节后会优先清理较早写入的缓存。\n\n清理入口位于对应书籍页面；清理缓存不会删除书籍、目录或阅读进度。离线时只能打开仍有完整缓存的章节。")
            end,
        },
        {
            text = _("隐私与使用边界"), callback = function()
                self:info("只读取番茄官方网页公开内容。\n\n不保存账号、不接入第三方书源、不下载全本，也不绕过付费、登录或章节锁定。JSON 导入会拒绝凭证字段和异常数据；本地导出不含账号凭证、正文或缓存。")
            end,
        },
        {
            text = _("完全卸载与安全回退"), callback = function()
                self:info("插件不会自动删除任何文件。完全卸载时请先退出 KOReader，再由电脑仅删除：\n\n"
                    .. "1. koreader/plugins/fanqielite.koplugin\n"
                    .. "2. 可选：koreader/fanqielite\n"
                    .. "3. 可选：koreader/settings/fanqielite.lua、fanqielite.lua.old、fanqielite.lua.tmp、fanqielite.lua.old.tmp\n"
                    .. "4. 可选：用户盘根目录的 fanqielite-bookshelf.json\n\n"
                    .. "第 1 项删除插件；其余项只删除插件数据和你主动导出的文件。不会影响 Kindle 系统、KOReader、书籍或其他插件。")
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
    local items = {
        {
            text = _("扫码导入我的番茄书架（实验性）"),
            callback = function() self:show_qr_import_status() end,
        },
        { text = _("搜索或添加一本书"), callback = function() self:prompt_book() end },
        {
            text = _("从文件导入书架"),
            callback = function() self:choose_import_file() end,
        },
    }
    if #self.library.books > 0 then
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
    else
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
    local items = {{
        text = self:book_local_status(book, cached_count),
        callback = function() end,
    }}
    if #book.chapters > 0 then
        items[#items + 1] = {
            text = "继续阅读（第 " .. tostring(book.current_index) .. " 章）",
            callback = function() self:open_chapter(book.id, book.current_index) end,
        }
        items[#items + 1] = { text = _("章节目录"), callback = function() self:show_catalog(book.id) end }
        items[#items + 1] = { text = _("上一章"), callback = function() self:open_chapter(book.id, book.current_index - 1) end }
        items[#items + 1] = { text = _("下一章"), callback = function() self:open_chapter(book.id, book.current_index + 1) end }
    else
        items[#items + 1] = {
            text = _("联网获取目录并开始阅读"), callback = function()
                self:with_network(function()
                    self:refresh_book(book.id)
                    UIManager:nextTick(function() self:show_book(book.id) end)
                end)
            end,
        }
    end
    if #book.chapters > 0 then
        items[#items + 1] = {
            text = _("刷新书籍信息与目录"), callback = function()
                self:with_network(function() self:refresh_book(book.id) end)
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
    UIManager:show(ConfirmBox:new{
        text = "确定从本地书架移除《" .. book.title .. "》吗？\n\n已缓存章节不会同时删除，可稍后单独清理。",
        ok_text = _("移除"),
        ok_callback = function()
            Library.remove(self.library, book_id)
            if self.active_book_id == book_id then
                self.active_book_id = self.library.books[1] and self.library.books[1].id or nil
            end
            local saved, save_err = self:save_state()
            if not saved then self:info(save_err); return end
            self:info("已从本地书架移除", 2)
            UIManager:nextTick(function() self:show_home() end)
        end,
    })
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

function FanqieLite:show_catalog(book_id)
    local book = Library.find(self.library, book_id)
    if not book or #book.chapters == 0 then self:info("目录为空，请联网刷新"); return end
    local items = {}
    for index, chapter in ipairs(book.chapters) do
        local chapter_index = index
        items[#items + 1] = {
            text = chapter.title,
            callback = function() self:open_chapter(book.id, chapter_index) end,
        }
    end
    local menu = Menu:new{ title = book.title, item_table = items, is_borderless = true }
    UIManager:show(menu)
    if menu.onGotoPage then menu:onGotoPage(menu:getPageNumber(book.current_index)) end
end

function FanqieLite:open_file(path, imported_position)
    local after_open_callback
    if imported_position ~= nil then
        after_open_callback = function(reader_ui)
            reader_ui:handleEvent(Event:new("GotoPercent", imported_position * 100))
        end
    end
    FileManager.openFile(self.ui, path, nil, nil, nil, after_open_callback)
end

function FanqieLite:prepare_chapter_open(book, index, path)
    local imported_position = Library.take_imported_position(
        book, index, DocSettings:hasSidecarFile(path))
    Library.touch(self.library, book.id, index)
    self.active_book_id = book.id
    local saved, save_err = self:save_state()
    if not saved then return nil, save_err end
    return true, imported_position
end

function FanqieLite:open_chapter(book_id, index)
    local book = Library.find(self.library, book_id)
    index = tonumber(index)
    if not book or not index or not book.chapters[index] then
        self:info("已经到达目录边界", 2)
        return
    end
    local chapter = book.chapters[index]
    local cached, cache_err = self.storage:cached_chapter(book.id, chapter.id)
    if cached then
        local ready, position_or_err = self:prepare_chapter_open(book, index, cached)
        if not ready then self:info(position_or_err); return end
        self:open_file(cached, position_or_err)
        return
    end
    local loading_label = "正在读取第 " .. tostring(index) .. " 章……"
    if cache_err then
        loading_label = "缓存损坏，已拒绝打开；书架和进度未改变。\n正在联网重新获取……"
    end
    self:with_network(function()
        local html, fetch_err = NetworkTask.get(
            BASE .. "/reader/" .. chapter.id, nil, loading_label)
        if not html then raise_user_error(user_error_detail("读取章节失败：", fetch_err)) end
        local json_text, state_err = Parser.extract_initial_state(html)
        if not json_text then raise_user_error(state_err) end
        local state, decode_err = Parser.decode_json(json_text)
        if not state then raise_user_error(decode_err) end
        local parsed, chapter_err = Parser.chapter_from_state(state, chapter.id)
        if not parsed then raise_user_error(chapter_err) end
        parsed.title = chapter.title ~= "" and chapter.title or parsed.title
        local path, write_err, prune_warning = self.storage:write_chapter(
            book.id, chapter.id, Parser.to_xhtml(book, parsed))
        if not path then
            raise_user_error(user_error_detail("保存章节失败：", write_err)
                .. "\n未完整写入的临时文件已清理。请检查存储空间或只读状态后重试。")
        end
        local ready, position_or_err = self:prepare_chapter_open(book, index, path)
        if not ready then raise_user_error(position_or_err) end
        UIManager:nextTick(function()
            self:open_file(path, position_or_err)
            if prune_warning then
                UIManager:nextTick(function() self:show_cache_prune_warning(prune_warning) end)
            end
        end)
    end)
end

return FanqieLite

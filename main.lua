local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Http = require("fanqielite.http")
local Import = require("fanqielite.import")
local Library = require("fanqielite.library")
local Parser = require("fanqielite.parser")
local Storage = require("fanqielite.storage")

local FanqieLite = WidgetContainer:extend{
    name = "fanqielite",
    is_doc_only = false,
}

local BASE = "https://fanqienovel.com"

function FanqieLite:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/fanqielite.lua")
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
    if changed then self:save_state() end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
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

function FanqieLite:active_book()
    return Library.find(self.library, self.active_book_id)
end

function FanqieLite:save_state()
    self.settings:saveSetting("library", self.library)
    self.settings:saveSetting("active_book_id", self.active_book_id)

    -- Keep the 0.1.0 fields in sync so downgrading does not lose the active book.
    local active = self:active_book()
    if active then
        self.settings:saveSetting("book", {
            id = active.id, title = active.title, author = active.author,
        })
        self.settings:saveSetting("chapters", active.chapters)
        self.settings:saveSetting("current_index", active.current_index)
    else
        self.settings:delSetting("book")
        self.settings:delSetting("chapters")
        self.settings:delSetting("current_index")
        self.settings:delSetting("active_book_id")
    end
    self.settings:flush()
end

function FanqieLite:with_network(label, callback)
    NetworkMgr:runWhenOnline(function()
        local loading = InfoMessage:new{ text = label }
        UIManager:show(loading)
        UIManager:nextTick(function()
            local ok, err = xpcall(callback, debug.traceback)
            UIManager:close(loading)
            if not ok then self:info("操作失败：\n" .. tostring(err)) end
        end)
    end)
end

function FanqieLite:fetch_book(book_id)
    local html, page_err = Http.get(BASE .. "/page/" .. book_id)
    if not html then error("获取书籍页面失败：" .. tostring(page_err)) end
    local json_text, state_err = Parser.extract_initial_state(html)
    if not json_text then error(state_err) end
    local state, decode_err = Parser.decode_json(json_text)
    if not state then error(decode_err) end
    local book, book_err = Parser.book_from_state(state, book_id)
    if not book then error(book_err) end

    local directory_text, directory_err = Http.get(
        BASE .. "/api/reader/directory/detail?bookId=" .. book_id, "application/json")
    if not directory_text then error("获取目录失败：" .. tostring(directory_err)) end
    local payload, payload_err = Parser.decode_json(directory_text)
    if not payload then error(payload_err) end
    local chapters, chapters_err = Parser.directory_from_payload(payload)
    if not chapters then error(chapters_err) end
    return book, chapters
end

function FanqieLite:load_book(input)
    local book_id, input_err = Parser.book_id(input)
    if not book_id then error(input_err) end
    local book, chapters = self:fetch_book(book_id)
    local record, save_err = Library.upsert(self.library, book, chapters)
    if not record then error(save_err) end
    self.active_book_id = record.id
    self:save_state()
    self:info("已加入《" .. record.title .. "》\n共 " .. tostring(#record.chapters) .. " 章", 3)
    UIManager:nextTick(function() self:show_book(record.id) end)
end

function FanqieLite:refresh_book(book_id)
    local book, chapters = self:fetch_book(book_id)
    local record, save_err = Library.upsert(self.library, book, chapters)
    if not record then error(save_err) end
    self.active_book_id = record.id
    self:save_state()
    self:info("目录已刷新，共 " .. tostring(#record.chapters) .. " 章", 3)
end

function FanqieLite:prompt_book()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索或添加一本书"),
        description = _("当前版本支持粘贴番茄官方书籍链接或书籍 ID。"),
        input_hint = "https://fanqienovel.com/page/...",
        buttons = {{
            { text = _("取消"), callback = function() UIManager:close(dialog) end },
            { text = _("添加"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                self:with_network("正在读取官方书籍与目录……", function() self:load_book(value) end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanqieLite:unavailable(feature)
    self:info(feature .. "仍在安全开发中。\n\n它不会影响现有本地书架；功能通过审计和实机验证后才会开放。")
end

function FanqieLite:choose_import_file()
    UIManager:show(PathChooser:new{
        title = _("长按 fanqielite-bookshelf.json 选择导入"),
        select_directory = false,
        select_file = true,
        path = self.settings:readSetting("import_path") or Device.home_dir or DataStorage:getDataDir(),
        file_filter = function(filename) return filename == Import.FILENAME end,
        onConfirm = function(path) self:prepare_file_import(path) end,
    })
end

function FanqieLite:prepare_file_import(path)
    local books, import_err = Import.read_file(path)
    if not books then
        self:info("导入失败：\n" .. tostring(import_err) .. "\n\n现有本地书架没有改变。")
        return
    end
    local new_count, update_count = 0, 0
    for _, book in ipairs(books) do
        if Library.find(self.library, book.id) then update_count = update_count + 1
        else new_count = new_count + 1 end
    end
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
    self:save_state()
    self:info("导入完成：新增 " .. tostring(added) .. " 本，更新 " .. tostring(updated)
        .. " 本。\n\n首次打开新书时需要联网获取目录。", 5)
    UIManager:nextTick(function() self:show_home() end)
end

function FanqieLite:cycle_sort()
    local next_mode = { recent = "title", title = "added", added = "recent" }
    self.library.sort = next_mode[self.library.sort] or "recent"
    self:save_state()
    self:show_home()
end

function FanqieLite:show_home()
    local sort_names = { recent = "最近阅读", title = "书名", added = "最近添加" }
    local items = {
        {
            text = _("扫码导入我的番茄书架（实验性）"),
            callback = function() self:unavailable("一次性扫码导入") end,
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
    items[#items + 1] = {
        text = _("隐私与使用边界"), callback = function()
            self:info("只读取番茄官方网页公开内容。\n\n不保存账号、不接入第三方书源、不下载全本，也不绕过付费、登录或章节锁定。JSON 导入会先拒绝凭证字段和异常数据。每本书最多保留最近 12 个章节缓存。")
        end,
    }
    UIManager:show(Menu:new{ title = _("我的本地书架"), item_table = items, is_borderless = true })
end

function FanqieLite:show_book(book_id)
    local book = Library.find(self.library, book_id)
    if not book then self:info("这本书已不在本地书架中"); return end
    local cached_count = self.storage:cached_count(book.id) or 0
    self.active_book_id = book.id
    self:save_state()
    local items = {}
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
                self:with_network("正在读取官方书籍与目录……", function()
                    self:refresh_book(book.id)
                    UIManager:nextTick(function() self:show_book(book.id) end)
                end)
            end,
        }
    end
    if #book.chapters > 0 then
        items[#items + 1] = {
            text = _("刷新书籍信息与目录"), callback = function()
                self:with_network("正在刷新官方目录……", function() self:refresh_book(book.id) end)
            end,
        }
    end
    items[#items + 1] = {
            text = "清理章节缓存（" .. tostring(cached_count) .. " 个）",
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
            self:save_state()
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
            if not count then self:info("清理失败：" .. tostring(err)); return end
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

function FanqieLite:open_file(path)
    FileManager.openFile(self.ui, path)
end

function FanqieLite:open_chapter(book_id, index)
    local book = Library.find(self.library, book_id)
    index = tonumber(index)
    if not book or not index or not book.chapters[index] then
        self:info("已经到达目录边界", 2)
        return
    end
    local chapter = book.chapters[index]
    local cached = self.storage:chapter_path(book.id, chapter.id)
    local file = io.open(cached, "rb")
    if file then
        file:close()
        Library.touch(self.library, book.id, index)
        self.active_book_id = book.id
        self:save_state()
        self:open_file(cached)
        return
    end
    self:with_network("正在读取第 " .. tostring(index) .. " 章……", function()
        local html, fetch_err = Http.get(BASE .. "/reader/" .. chapter.id)
        if not html then error("读取章节失败：" .. tostring(fetch_err)) end
        local json_text, state_err = Parser.extract_initial_state(html)
        if not json_text then error(state_err) end
        local state, decode_err = Parser.decode_json(json_text)
        if not state then error(decode_err) end
        local parsed, chapter_err = Parser.chapter_from_state(state, chapter.id)
        if not parsed then error(chapter_err) end
        parsed.title = chapter.title ~= "" and chapter.title or parsed.title
        local path, write_err = self.storage:write_chapter(
            book.id, chapter.id, Parser.to_xhtml(book, parsed))
        if not path then error("保存章节失败：" .. tostring(write_err)) end
        Library.touch(self.library, book.id, index)
        self.active_book_id = book.id
        self:save_state()
        UIManager:nextTick(function() self:open_file(path) end)
    end)
end

return FanqieLite

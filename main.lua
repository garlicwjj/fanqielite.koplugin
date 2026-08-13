local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local _ = require("gettext")

local Http = require("fanqielite.http")
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
    self.book = self.settings:readSetting("book")
    self.chapters = self.settings:readSetting("chapters")
    self.current_index = tonumber(self.settings:readSetting("current_index"))
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

function FanqieLite:save_state()
    self.settings:saveSetting("book", self.book)
    self.settings:saveSetting("chapters", self.chapters)
    self.settings:saveSetting("current_index", self.current_index)
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

function FanqieLite:load_book(input)
    local book_id, input_err = Parser.book_id(input)
    if not book_id then error(input_err) end
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
    local directory_payload, directory_decode_err = Parser.decode_json(directory_text)
    if not directory_payload then error(directory_decode_err) end
    local chapters, chapters_err = Parser.directory_from_payload(directory_payload)
    if not chapters then error(chapters_err) end

    self.book, self.chapters, self.current_index = book, chapters, 1
    self:save_state()
    self:info("已载入《" .. book.title .. "》\n共 " .. tostring(#chapters) .. " 章", 3)
    UIManager:nextTick(function() self:show_catalog() end)
end

function FanqieLite:prompt_book()
    local dialog
    dialog = InputDialog:new{
        title = _("输入番茄书籍链接或 ID"),
        input_hint = "https://fanqienovel.com/page/...",
        buttons = {{
            { text = _("取消"), callback = function() UIManager:close(dialog) end },
            { text = _("载入"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                self:with_network("正在读取官方书籍页面……", function() self:load_book(value) end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanqieLite:show_home()
    local items = {
        { text = _("添加或更换书籍"), callback = function() self:prompt_book() end },
    }
    if self.book and self.chapters and #self.chapters > 0 then
        items[#items + 1] = {
            text = "继续阅读《" .. self.book.title .. "》",
            callback = function() self:open_chapter(self.current_index or 1) end,
        }
        items[#items + 1] = { text = _("章节目录"), callback = function() self:show_catalog() end }
        items[#items + 1] = { text = _("上一章"), callback = function() self:open_chapter((self.current_index or 1) - 1) end }
        items[#items + 1] = { text = _("下一章"), callback = function() self:open_chapter((self.current_index or 1) + 1) end }
    end
    items[#items + 1] = {
        text = _("关于与限制"), callback = function()
            self:info("第一版只读取番茄官方网页公开章节。\n\n不登录、不接入第三方书源、不下载全本、不绕过付费或登录限制。每本书最多保留最近 12 个章节缓存。")
        end,
    }
    UIManager:show(Menu:new{ title = _("番茄小说（实验版）"), item_table = items, is_borderless = true })
end

function FanqieLite:show_catalog()
    if not self.chapters then self:info("请先添加书籍"); return end
    local items = {}
    for index, chapter in ipairs(self.chapters) do
        items[#items + 1] = {
            text = chapter.title,
            callback = function() self:open_chapter(index) end,
        }
    end
    local menu = Menu:new{
        title = self.book and self.book.title or _("章节目录"),
        item_table = items, is_borderless = true,
    }
    UIManager:show(menu)
    if self.current_index and menu.onGotoPage then
        menu:onGotoPage(menu:getPageNumber(self.current_index))
    end
end

function FanqieLite:open_file(path)
    FileManager.openFile(self.ui, path)
end

function FanqieLite:open_chapter(index)
    index = tonumber(index)
    if not index or not self.chapters or not self.chapters[index] then
        self:info("已经到达目录边界", 2)
        return
    end
    local chapter = self.chapters[index]
    local cached = self.storage:chapter_path(self.book.id, chapter.id)
    local file = io.open(cached, "rb")
    if file then
        file:close()
        self.current_index = index
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
            self.book.id, chapter.id, Parser.to_xhtml(self.book, parsed))
        if not path then error("保存章节失败：" .. tostring(write_err)) end
        self.current_index = index
        self:save_state()
        UIManager:nextTick(function() self:open_file(path) end)
    end)
end

return FanqieLite

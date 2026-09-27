package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, info_message
local Menu = {}
function Menu:new(options) return options end
local ConfirmBox = {}
function ConfirmBox:new(options) return options end
local InputDialog = {}
function InputDialog:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    close = function() end,
}
local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local Library = require("fanqielite.library")
local stubs = {
    ["ui/widget/confirmbox"] = ConfirmBox,
    datastorage = {}, device = {}, dispatcher = {}, docsettings = {},
    ["ui/event"] = {}, ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {}, ["ui/widget/inputdialog"] = InputDialog,
    logger = {}, luasettings = {}, ["ui/widget/menu"] = Menu,
    ["ui/network/manager"] = {}, ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {}, ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {}, ["fanqielite.import"] = {},
    ["fanqielite.library"] = Library, ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {}, ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = {}, ["fanqielite.storage"] = {},
}
for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local book_id = "7134567890123456789"
local target_id = "7134567890123456702"
local book = {
    id = book_id, title = "章节查找测试", author = "",
    chapters = {
        { id = "7134567890123456701", title = "第1章 离家" },
        { id = target_id, title = "第2章 家乡美" },
        { id = "7134567890123456703", title = "第3章 回家" },
    },
    current_index = 2,
}
local opened_id, opened_index, returned_book_id
local plugin = setmetatable({
    library = { version = 1, sort = "recent", books = { book } },
    storage = { cached_count = function() return 0 end },
    info = function(_, message) info_message = message end,
    open_chapter = function(_, id, index) opened_id, opened_index = id, index end,
}, { __index = FanqieLite })

plugin:show_book(book_id)
local search_entry
for _, item in ipairs(shown.item_table or {}) do
    if item.text == "查找章节（不联网）" then search_entry = item; break end
end
assert(search_entry, "book details did not expose offline chapter search")

plugin:submit_chapter_search(book_id, "家乡", nil)
assert(shown.title == "章节查找：“家乡”", "chapter search results did not open")
assert(shown.item_table[1].text == "第 2 章 · 第2章 家乡美  [当前]",
    "chapter search result lost its absolute index or current marker")
table.insert(book.chapters, 1, {
    id = "7134567890123456799", title = "新增序章",
})
shown.item_table[1].callback()
assert(opened_id == book_id and opened_index == 3,
    "chapter search result did not revalidate its chapter ID after a directory change")

plugin:submit_chapter_search(book_id, "不存在", nil)
assert(shown.text:find("没有找到标题包含“不存在”的章节", 1, true),
    "empty chapter search did not explain the result")
assert(shown.text:find("没有联网", 1, true)
        and shown.text:find("阅读进度和缓存没有改变", 1, true),
    "empty chapter search did not explain local data safety")
assert(shown.ok_text == "重新输入" and shown.cancel_text == "返回书籍",
    "empty chapter search did not offer both recovery paths")
plugin.show_book = function(_, id) returned_book_id = id end
shown.cancel_callback()
assert(returned_book_id == book_id, "empty chapter search did not return to the book page")

plugin.library.books = {}
plugin:open_chapter_by_id(book_id, target_id)
assert(info_message:find("已不在本地书架", 1, true),
    "removed book search result did not stop safely")

local search_book = { chapters = {} }
for index = 1, 105 do
    search_book.chapters[index] = {
        id = tostring(8000000000000000000 + index),
        title = "共同标题 " .. tostring(index),
    }
end
local matches, query, truncated = Library.search_chapters(search_book, "共同标题", 100)
assert(#matches == 100 and query == "共同标题" and truncated == true,
    "chapter search did not cap oversized result sets")
assert(Library.search_chapters(search_book, "") == nil,
    "chapter search accepted an empty query")
assert(Library.search_chapters(search_book, "坏\n输入") == nil,
    "chapter search accepted control characters")

print("chapter search flow tests passed")

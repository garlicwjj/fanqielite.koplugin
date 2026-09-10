package.path = "./?.lua;./?/init.lua;" .. package.path

local shown
local Menu = {}
function Menu:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local Library = {}
function Library.find(library, book_id)
    for _, book in ipairs(library.books or {}) do
        if book.id == book_id then return book end
    end
end

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = {},
    device = {},
    dispatcher = {},
    docsettings = {},
    ["ui/event"] = {},
    ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = {},
    logger = {},
    luasettings = {},
    ["ui/widget/menu"] = Menu,
    ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {},
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.import"] = {},
    ["fanqielite.library"] = Library,
    ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {},
    ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = {},
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local book_id = "7134567890123456789"
local opened_id, opened_index
local book = {
    id = book_id,
    title = "详情页测试书",
    author = "测试作者",
    chapters = {
        { id = "7134567890123456701", title = "第一章" },
        { id = "7134567890123456702", title = "第二章" },
        { id = "7134567890123456703", title = "第三章" },
    },
    current_index = 2,
    directory_updated_at = 100,
}
local plugin = setmetatable({
    library = { version = 1, books = { book } },
    storage = { cached_count = function() return 1 end },
    save_state = function() return true end,
    open_chapter = function(_, id, index) opened_id, opened_index = id, index end,
}, { __index = FanqieLite })

plugin:show_book(book_id)
assert(shown and shown.title == "详情页测试书\n测试作者", "book details did not open")
assert(shown.item_table[1].text == "继续阅读（第 2 章）",
    "book details do not lead with the primary reading action")
assert(shown.item_table[2].text:find("本地状态：目录 3 章", 1, true),
    "local status did not immediately follow the primary action")
assert(shown.item_table[3].text == "章节目录", "chapter actions changed order")
assert(shown.item_table[4].text == "上一章" and shown.item_table[5].text == "下一章",
    "middle chapter did not expose both valid adjacent actions")
shown.item_table[1].callback()
assert(opened_id == book_id and opened_index == 2,
    "book primary action did not open the current chapter")

local function has_item(text)
    for _, item in ipairs(shown.item_table or {}) do
        if item.text == text then return true end
    end
    return false
end

book.current_index = 1
plugin:show_book(book_id)
assert(not has_item("上一章"), "first chapter exposed an unavailable previous action")
assert(has_item("下一章"), "first chapter hid the available next action")

book.current_index = 3
plugin:show_book(book_id)
assert(has_item("上一章"), "last chapter hid the available previous action")
assert(not has_item("下一章"), "last chapter exposed an unavailable next action")

book.chapters = {}
book.current_index = 1
plugin:show_book(book_id)
assert(shown.item_table[1].text == "联网获取目录并开始阅读",
    "book without a directory does not lead with the safe network action")
assert(shown.item_table[2].text:find("尚未获取目录", 1, true),
    "pending-directory status did not follow the primary action")
assert(shown.item_table[3].text:find("清理章节缓存", 1, true),
    "management actions changed order for a pending book")

print("book flow tests passed")

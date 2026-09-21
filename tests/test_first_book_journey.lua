package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, input_text, info_message

local InputDialog = {}
function InputDialog:new(options)
    options.getInputText = function() return input_text end
    options.onShowKeyboard = function() end
    return options
end

local Menu = {}
function Menu:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    close = function() end,
    nextTick = function(_, callback) callback() end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local Library = require("fanqielite.library")
local Parser = {
    book_id = function(value)
        if type(value) ~= "string" then return nil, "请输入有效内容" end
        local trimmed = value:match("^%s*(.-)%s*$")
        local id = trimmed:match("^(%d+)$")
            or trimmed:match("^https://fanqienovel%.com/page/(%d+)$")
        if id and #id >= 10 and #id <= 64 then return id end
        return nil, "请输入番茄小说官方书籍链接或书籍 ID"
    end,
}

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = {},
    device = {},
    dispatcher = {},
    docsettings = {},
    ["ui/event"] = {},
    ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = InputDialog,
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
    ["fanqielite.parser"] = Parser,
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
local plugin = setmetatable({
    library = { version = 1, sort = "recent", books = {} },
    storage = { cached_count = function() return 0 end },
    info = function(_, message) info_message = message end,
    save_state = function() return true end,
    with_network = function(_, callback) callback() end,
    fetch_book = function()
        return { id = book_id, title = "首本测试书", author = "测试作者" }, {
            { id = "7134567890123456701", title = "第一章" },
            { id = "7134567890123456702", title = "第二章" },
        }
    end,
    open_chapter = function(_, id, index)
        opened_id, opened_index = id, index
    end,
}, { __index = FanqieLite })

plugin:show_home()
assert(shown.title == "我的本地书架", "first-use journey did not start at the local bookshelf")
assert(shown.item_table[1].text == "搜索或添加一本书（推荐）",
    "first-use journey did not lead with the recommended no-login path")
assert(shown.item_table[2].text == "从文件导入书架",
    "first-use journey did not expose the available import fallback next")
assert(shown.item_table[3].text:find("尚未开放", 1, true),
    "first-use journey did not identify the unavailable QR path")

shown.item_table[1].callback()
assert(shown.title == "搜索或添加一本书", "recommended entry did not open the input dialog")
assert(shown.description:find("推荐粘贴番茄官网书籍链接", 1, true),
    "input dialog did not explain the most reliable path")
assert(shown.description:find("官网可能要求验证", 1, true),
    "input dialog hid the search verification fallback")

input_text = "https://fanqienovel.com/page/" .. book_id
shown.buttons[1][2].callback()
assert(info_message:find("已加入《首本测试书》", 1, true),
    "successful first add did not identify the saved book")
assert(info_message:find("请选择“开始阅读”", 1, true),
    "successful first add did not explain the next action")
assert(#plugin.library.books == 1, "successful first add did not update the local bookshelf")
assert(shown.title == "首本测试书\n测试作者", "successful first add did not open book details")
assert(shown.item_table[1].text == "开始阅读（第 1 章）",
    "freshly added book was incorrectly presented as continued reading")

shown.item_table[1].callback()
assert(opened_id == book_id and opened_index == 1,
    "first-use primary action did not open the first chapter")

plugin.library.books[1].last_opened_at = 100
plugin:load_book(book_id)
assert(info_message:find("请选择“继续阅读”", 1, true),
    "re-adding a started book incorrectly suggested starting over")
assert(shown.item_table[1].text == "继续阅读（第 1 章）",
    "re-added started book lost its continue-reading action")

print("first book journey tests passed")

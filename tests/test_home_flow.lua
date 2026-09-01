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

local parser_result, parser_error
local search_calls = 0
local Parser = {
    book_id = function() return parser_result, parser_error end,
}
local Search = {
    build_url = function(value)
        search_calls = search_calls + 1
        return "https://fanqienovel.com/search", value
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
    ["fanqielite.library"] = {},
    ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = Parser,
    ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = Search,
    ["fanqielite.storage"] = {},
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local info_message
local prompted, imported = false, false
local loaded_book_id, searched_query
local plugin = setmetatable({
    library = { version = 1, sort = "recent", books = {} },
    info = function(_, message) info_message = message end,
    prompt_book = function() prompted = true end,
    choose_import_file = function() imported = true end,
    with_network = function(_, callback) callback() end,
    load_book = function(_, book_id) loaded_book_id = book_id end,
    search_books = function(_, _, query) searched_query = query end,
}, { __index = FanqieLite })

plugin:show_home()
assert(shown and shown.title == "我的本地书架", "home did not open the local bookshelf")
assert(shown.item_table[1].text == "扫码导入我的番茄书架（实验性）",
    "QR import is not the first onboarding entry")
assert(shown.item_table[2].text == "搜索或添加一本书",
    "search/add is not the second onboarding entry")
assert(shown.item_table[3].text == "从文件导入书架",
    "file import is not the third onboarding entry")

shown.item_table[1].callback()
assert(info_message:find("尚未开放", 1, true), "QR status did not say the feature is unavailable")
assert(info_message:find("没有发起账号授权", 1, true),
    "QR status did not explain the current account state")
assert(info_message:find("没有请求或保存任何登录信息", 1, true),
    "QR status did not explain credential handling")
assert(info_message:find("搜索或添加一本书", 1, true),
    "QR status did not point to the no-login path")
assert(info_message:find("从文件导入书架", 1, true),
    "QR status did not point to the file-import fallback")
assert(info_message:find("已有本地书架不受影响", 1, true),
    "QR status did not explain local bookshelf safety")

shown.item_table[2].callback()
shown.item_table[3].callback()
assert(prompted, "search/add onboarding entry is not wired")
assert(imported, "file-import onboarding entry is not wired")

parser_result, parser_error = nil, "请输入番茄小说官方书籍链接或书籍 ID"
plugin:submit_book_input("https://evil.example/page/7633875868615461950")
assert(info_message == parser_error, "invalid URL did not show the official-link error")
assert(search_calls == 0 and searched_query == nil,
    "invalid URL was incorrectly submitted as a title search")

plugin:submit_book_input("fanqienovel.com/page/7633875868615461950")
assert(info_message == parser_error, "incomplete official URL did not show the link error")
assert(search_calls == 0, "incomplete official URL was incorrectly submitted as a title search")

plugin:submit_book_input(string.rep("9", 65))
assert(info_message == parser_error, "oversized numeric ID did not show the ID error")
assert(search_calls == 0, "oversized numeric ID was incorrectly submitted as a title search")

plugin:submit_book_input("1984")
assert(search_calls == 1 and searched_query == "1984",
    "short numeric book title did not use official search")

plugin:submit_book_input("三体 刘慈欣")
assert(search_calls == 2 and searched_query == "三体 刘慈欣",
    "ordinary title input did not use official search")

parser_result = "7633875868615461950"
plugin:submit_book_input("https://fanqienovel.com/page/7633875868615461950")
assert(loaded_book_id == parser_result, "valid official link did not load the parsed book")

print("home flow tests passed")

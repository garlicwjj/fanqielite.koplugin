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
local Library = {}
function Library.find(library, book_id)
    for _, book in ipairs(library.books or {}) do
        if book.id == book_id then return book end
    end
end
function Library.sorted(library)
    local books = {}
    for _, book in ipairs(library.books or {}) do books[#books + 1] = book end
    table.sort(books, function(a, b)
        if library.sort == "title" and a.title ~= b.title then return a.title < b.title end
        if a.last_opened_at ~= b.last_opened_at then return a.last_opened_at > b.last_opened_at end
        return a.id < b.id
    end)
    return books
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

local unread_id = "7134567890123456789"
local recent_id = "7234567890123456789"
local opened_id, opened_index, selected_id
plugin.library = { version = 1, sort = "title", books = {
    {
        id = unread_id, title = "A 未读书", author = "", chapters = {
            { id = "7134567890123456701", title = "第一章" },
        }, current_index = 1, last_opened_at = 0,
    },
    {
        id = recent_id, title = "B 最近阅读", author = "作者乙", chapters = {
            { id = "7234567890123456701", title = "第一章" },
            { id = "7234567890123456702", title = "第二章" },
        }, current_index = 2, last_opened_at = 900,
    },
} }
plugin.active_book_id = unread_id
plugin.open_chapter = function(_, book_id, index)
    opened_id, opened_index = book_id, index
end
plugin.show_book = function(_, book_id) selected_id = book_id end
plugin:show_home()
assert(shown.item_table[1].text == "继续阅读：《B 最近阅读》（第 2 章）",
    "non-empty home does not lead with the most recently read book")
shown.item_table[1].callback()
assert(opened_id == recent_id and opened_index == 2,
    "home primary action did not directly continue the recent chapter")
assert(shown.item_table[2].text == "排序：书名", "sort control did not follow the primary action")
assert(shown.item_table[3].text:find("A 未读书", 1, true), "sorted bookshelf did not follow controls")
shown.item_table[3].callback()
assert(selected_id == unread_id, "book row no longer opens its details")
assert(shown.item_table[5].text == "搜索或添加一本书", "visible add action missing below books")
assert(shown.item_table[6].text == "从文件导入书架", "visible file import missing below books")
assert(shown.item_table[7].text == "扫码导入我的番茄书架（实验性）",
    "visible QR import missing below books")

plugin.library = { version = 1, sort = "recent", books = {{
    id = unread_id, title = "尚未开始", author = "", chapters = {
        { id = "7134567890123456701", title = "第一章" },
    }, current_index = 1, last_opened_at = 0,
}} }
opened_id, opened_index = nil, nil
plugin:show_home()
assert(shown.item_table[1].text == "开始阅读：《尚未开始》（第 1 章）",
    "unread book was incorrectly presented as continued reading")
shown.item_table[1].callback()
assert(opened_id == unread_id and opened_index == 1,
    "start-reading action did not open the first current chapter")

plugin.library = { version = 1, sort = "recent", books = {{
    id = unread_id, title = "等待目录", author = "", chapters = {},
    current_index = 1, last_opened_at = 0,
}} }
selected_id = nil
plugin:show_home()
assert(shown.item_table[1].text == "打开：《等待目录》（待获取目录）",
    "book without a directory was presented as directly readable")
shown.item_table[1].callback()
assert(selected_id == unread_id, "pending-directory action did not open safe book details")

plugin:show_settings()
assert(shown and shown.title == "设置与数据", "settings menu did not open")
local expected_settings = {
    "从文件导入书架", "导出本地书架", "缓存管理说明",
    "隐私与使用边界", "完全卸载与安全回退",
}
for index, expected in ipairs(expected_settings) do
    assert(shown.item_table[index] and shown.item_table[index].text == expected,
        "settings entry order changed at index " .. tostring(index))
end

shown.item_table[4].callback()
assert(info_message:find("默认阅读只访问番茄官网公开内容", 1, true),
    "privacy notice did not explain the default public-reading boundary")
assert(info_message:find("扫码导入目前尚未开放", 1, true),
    "privacy notice did not explain the current QR state")
assert(info_message:find("不会保存账号登录", 1, true),
    "privacy notice did not state the credential persistence boundary")

shown.item_table[5].callback()
assert(info_message:find("先导出本地书架", 1, true),
    "uninstall notice did not recommend a recoverable backup")
assert(info_message:find("第 1 项即可停用插件", 1, true),
    "uninstall notice did not distinguish disable from data deletion")
assert(info_message:find("离线章节和对应的 .sdr 阅读位置", 1, true),
    "uninstall notice hid cache and sidecar data loss")
assert(info_message:find("本地书架、目录和阅读进度", 1, true),
    "uninstall notice hid settings data loss")

print("home flow tests passed")

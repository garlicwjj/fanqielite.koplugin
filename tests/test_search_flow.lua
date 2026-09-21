package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, payload
local prompted, opened_book, added_book = 0

local ConfirmBox = {}
function ConfirmBox:new(options) return options end
local Menu = {}
function Menu:new(options) return options end
local UIManager = {
    show = function(_, widget) shown = widget end,
    nextTick = function(_, callback) callback() end,
}
local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end
local Parser = { decode_json = function() return payload end }
local NetworkTask = { get = function() return "{}" end }
local Library = {
    find = function(library, book_id)
        for _, book in ipairs(library.books) do
            if book.id == book_id then return book end
        end
    end,
}

local stubs = {
    ["ui/widget/confirmbox"] = ConfirmBox,
    datastorage = {}, device = {}, dispatcher = {}, docsettings = {},
    ["ui/event"] = {}, ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {}, ["ui/widget/inputdialog"] = {},
    logger = {}, luasettings = {}, ["ui/widget/menu"] = Menu,
    ["ui/network/manager"] = {}, ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {}, ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(value) return value end,
    ["fanqielite.export"] = {}, ["fanqielite.import"] = {},
    ["fanqielite.library"] = Library, ["fanqielite.networktask"] = NetworkTask,
    ["fanqielite.parser"] = Parser, ["fanqielite.persistence"] = {},
    ["fanqielite.storage"] = {},
}
for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local existing_id = "7134567890123456789"
local new_id = "7234567890123456789"
local plugin = setmetatable({
    library = { books = {{ id = existing_id }} },
    prompt_book = function() prompted = prompted + 1 end,
    show_book = function(_, id) opened_book = id end,
    load_book = function(_, id) added_book = id end,
    with_network = function(_, callback) callback() end,
}, { __index = FanqieLite })

payload = { code = 0, data = { search_book_data_list = {} } }
plugin:search_books("https://fanqienovel.com/api/search", "不存在的书")
assert(type(shown.text) == "string" and shown.text:find("没有找到", 1, true),
    "zero-result search did not show a no-results explanation")
assert(not shown.text:find("解析搜索结果失败", 1, true),
    "zero-result search was mislabeled as a parser failure")
assert(shown.text:find("本地书架、阅读进度和缓存没有改变", 1, true),
    "zero-result search did not state local data safety")
assert(shown.ok_text == "重新输入" and shown.cancel_text == "返回",
    "zero-result search did not offer a clear retry choice")
shown.ok_callback()
assert(prompted == 1, "zero-result retry did not reopen the input")

payload = { code = 0, data = { search_book_data_list = {
    { book_id = existing_id, book_name = "已在书架", author = "" },
    { book_id = new_id, book_name = "新书", author = "作者" },
} } }
plugin:search_books("https://fanqienovel.com/api/search", "测试")
assert(shown.title == "搜索：“测试”" and #shown.item_table == 3,
    "search results did not keep both books and a visible refinement entry")
assert(shown.item_table[3].text:find("重新输入", 1, true),
    "search results did not expose a refinement action")
shown.item_table[3].callback()
assert(prompted == 2, "result refinement did not reopen the input")
shown.item_table[1].callback()
assert(opened_book == existing_id, "existing search result no longer opens its book")
shown.item_table[2].callback()
assert(added_book == new_id, "new search result no longer adds its book")

print("search flow tests passed")

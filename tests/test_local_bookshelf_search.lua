package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, input_text, info_message, selected_book, home_opened

local ConfirmBox = {}
function ConfirmBox:new(options) return options end
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
    gettext = function(value) return value end,
    ["fanqielite.export"] = {}, ["fanqielite.import"] = {},
    ["fanqielite.library"] = Library, ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {}, ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = {}, ["fanqielite.storage"] = {},
}
for name, module in pairs(stubs) do package.preload[name] = function() return module end end

local FanqieLite = assert(loadfile("main.lua"))()
local first_id = "7134567890123456789"
local second_id = "7234567890123456789"
local plugin = setmetatable({
    library = { version = 1, sort = "title", books = {
        {
            id = first_id, title = "星河旅人", author = "林舟", chapters = {
                { id = "7134567890123456701", title = "第一章" },
            }, current_index = 1, last_opened_at = 0,
        },
        {
            id = second_id, title = "海边旧事", author = "周林", chapters = {
                { id = "7234567890123456701", title = "第一章" },
                { id = "7234567890123456702", title = "第二章" },
            }, current_index = 2, last_opened_at = 100,
        },
    } },
    info = function(_, message) info_message = message end,
    show_book = function(_, id) selected_book = id end,
    show_home = function() home_opened = true end,
}, { __index = FanqieLite })

plugin:prompt_local_search()
assert(shown.title == "查找本地书架", "local search dialog did not open")
assert(shown.description:find("不会联网", 1, true),
    "local search dialog did not explain its offline boundary")

input_text = " 林 "
shown.buttons[1][2].callback()
assert(shown.title == "本地查找：“林”", "trimmed query was not used in result title")
assert(#shown.item_table == 4, "author/title matches or navigation entries are missing")
assert(shown.item_table[1].text == "星河旅人 · 林舟  [未开始 · 共 1 章]",
    "unread local result lost its bookshelf state")
assert(shown.item_table[2].text == "海边旧事 · 周林  [2/2]",
    "read local result lost its bookshelf progress")
shown.item_table[2].callback()
assert(selected_book == second_id, "local result did not open the selected book")
shown.item_table[3].callback()
assert(shown.title == "查找本地书架", "result refinement did not reopen local search")

input_text = "不存在"
shown.buttons[1][2].callback()
assert(shown.text:find("没有找到", 1, true), "empty local result lacked an explanation")
assert(shown.text:find("没有联网", 1, true), "empty local result hid the offline boundary")
assert(shown.text:find("没有改变", 1, true), "empty local result hid data safety")
assert(shown.ok_text == "重新输入" and shown.cancel_text == "返回书架",
    "empty local result lacked clear navigation")
shown.ok_callback()
assert(shown.title == "查找本地书架", "empty-result retry did not reopen the dialog")

input_text = "\n"
shown.buttons[1][2].callback()
assert(info_message == "请输入本地书名或作者名", "empty local query was not rejected")

plugin:show_local_search_results("海边", { plugin.library.books[2] })
shown.item_table[3].callback()
assert(home_opened == true, "local result did not expose a visible bookshelf return")

local matches, query = Library.search(plugin.library, "海边")
assert(query == "海边" and #matches == 1 and matches[1].id == second_id,
    "library search did not match a title")
assert(Library.search(plugin.library, string.rep("a", 241)) == nil,
    "oversized local query was not rejected")
assert(Library.search(plugin.library, "bad\0query") == nil,
    "control characters in local query were not rejected")

print("local bookshelf search tests passed")

package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, input_text, info_message, opened_id, opened_index, closed

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
    close = function() closed = true end,
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
    ["ui/widget/confirmbox"] = {}, datastorage = {}, device = {}, dispatcher = {},
    docsettings = {}, ["ui/event"] = {}, ["apps/filemanager/filemanager"] = {},
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
local book_id = "7134567890123456789"
local chapters = {}
for index = 1, 250 do
    chapters[index] = { id = string.format("8%010d", index), title = "第 " .. index .. " 章" }
end
local book = {
    id = book_id, title = "长目录测试书", author = "", chapters = chapters,
    current_index = 1, directory_updated_at = 100,
}
local plugin = setmetatable({
    library = { version = 1, books = { book } },
    storage = { cached_count = function() return 0 end },
    save_state = function() return true end,
    info = function(_, message) info_message = message end,
    open_chapter = function(_, id, index) opened_id, opened_index = id, index end,
}, { __index = FanqieLite })

local function find_item(prefix)
    for _, item in ipairs(shown.item_table or {}) do
        if item.text:sub(1, #prefix) == prefix then return item end
    end
end

plugin:show_book(book_id)
local jump = assert(find_item("跳到指定章节"),
    "segmented long directory did not expose direct chapter jump")
jump.callback()
assert(shown.title == "跳到指定章节", "chapter jump input did not open")
assert(shown.description:find("1 到 250", 1, true), "chapter jump did not show its valid range")
assert(shown.description:find("不会预先修改阅读进度", 1, true),
    "chapter jump did not explain its non-mutating input stage")

for _, invalid in ipairs({ "", "0", "251", "1.5", "abc", "2\0" }) do
    input_text = invalid
    shown.buttons[1][2].callback()
    assert(info_message == "请输入 1 到 250 之间的整数章节序号；"
            .. "尚未打开章节或修改阅读进度。",
        "invalid chapter number did not receive a fixed range error")
    assert(opened_id == nil and opened_index == nil,
        "invalid chapter number opened or changed a chapter")
end

input_text = " 205 "
closed = false
shown.buttons[1][2].callback()
assert(closed == true, "valid chapter jump did not close the input")
assert(opened_id == book_id and opened_index == 205,
    "valid chapter jump did not open the requested directory position")

opened_id, opened_index, info_message = nil, nil, nil
plugin:prompt_chapter_jump(book_id)
input_text = "205"
for index = #book.chapters, 101, -1 do book.chapters[index] = nil end
shown.buttons[1][2].callback()
assert(info_message == "目录已变化。请输入 1 到 100 之间的整数章节序号；"
        .. "尚未打开章节或修改阅读进度。",
    "chapter jump did not revalidate a changed live directory")
assert(opened_id == nil, "stale chapter jump opened a removed chapter")

plugin.library.books = {}
plugin:submit_chapter_jump(book_id, "1")
assert(info_message:find("这本书已不在本地书架中", 1, true)
        and info_message:find("未打开章节或修改阅读进度", 1, true)
        and info_message:find("返回本地书架", 1, true),
    "chapter jump did not handle a removed book safely")

plugin.library.books = { book }
book.chapters = {}
plugin:submit_chapter_jump(book_id, "1", 100)
assert(info_message:find("目录已变化", 1, true)
        and info_message:find("未打开章节或修改阅读进度", 1, true)
        and info_message:find("联网刷新目录", 1, true),
    "chapter jump did not explain an emptied live directory")
book.chapters = chapters
for index = #book.chapters, 101, -1 do book.chapters[index] = nil end
plugin:show_book(book_id)
assert(find_item("跳到指定章节") == nil,
    "direct directory did not avoid an unnecessary jump control")

print("chapter jump flow tests passed")

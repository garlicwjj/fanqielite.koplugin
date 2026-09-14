package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, goto_index
local Menu = {}
function Menu:new(options)
    options.getPageNumber = function(_, index) return index end
    options.onGotoPage = function(_, index) goto_index = index end
    return options
end

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
local chapter_ids = {
    "7134567890123456701",
    "7134567890123456702",
    "7134567890123456703",
}
local inventory_mode = "readable"
local opened_id, opened_index
local plugin = setmetatable({
    library = { books = {{
        id = book_id,
        title = "目录测试书",
        current_index = 2,
        chapters = {
            { id = chapter_ids[1], title = "第一章" },
            { id = chapter_ids[2], title = "第二章" },
            { id = chapter_ids[3], title = "第三章" },
        },
    }} },
    storage = {
        verified_cached_chapter_ids = function()
            if inventory_mode == "unreadable" then
                return nil, nil, "FANQIELITE_CATALOG_ERROR_CANARY"
            end
            return { [chapter_ids[1]] = true }, { [chapter_ids[2]] = true }
        end,
    },
    open_chapter = function(_, id, index)
        opened_id, opened_index = id, index
    end,
}, { __index = FanqieLite })

plugin:show_catalog(book_id)
assert(shown.title == "目录测试书\n离线可读 1 章；1 章缓存需修复",
    "catalog did not summarize verified offline availability")
assert(shown.item_table[1].text == "第一章  [可离线]",
    "verified cache was not visible in the catalog")
assert(shown.item_table[2].text == "第二章  [当前]  [缓存需修复]",
    "current corrupt cache state was not visible in the catalog")
assert(shown.item_table[3].text == "第三章",
    "uncached chapter was incorrectly marked as offline")
assert(goto_index == 2, "catalog did not open near the current chapter")

shown.item_table[1].callback()
assert(opened_id == book_id and opened_index == 1,
    "offline catalog entry did not retain chapter navigation")

inventory_mode = "unreadable"
plugin:show_catalog(book_id)
assert(shown.title == "目录测试书\n离线缓存状态不可读",
    "unreadable cache inventory did not use a fixed catalog summary")
assert(not shown.title:find("CANARY", 1, true),
    "catalog exposed the raw cache inventory error")
assert(shown.item_table[2].text == "第二章  [当前]",
    "unreadable inventory removed the current chapter marker")
assert(not shown.item_table[1].text:find("可离线", 1, true),
    "unreadable inventory made an unverified offline claim")

print("offline catalog tests passed")

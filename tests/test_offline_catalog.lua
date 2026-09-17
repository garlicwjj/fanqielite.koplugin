package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, goto_index, info_message
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
    info = function(_, message)
        info_message = message
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

local long_chapters = {}
for index = 1, 10000 do
    long_chapters[index] = {
        id = string.format("9%018d", index),
        title = "长书第 " .. tostring(index) .. " 章",
    }
end
local long_book_id = "9234567890123456789"
plugin.library.books[#plugin.library.books + 1] = {
    id = long_book_id,
    title = "万章测试书",
    current_index = 5555,
    chapters = long_chapters,
}
inventory_mode = "readable"
plugin.storage.verified_cached_chapter_ids = function()
    return { [long_chapters[5555].id] = true }, {}
end
goto_index = nil
plugin:show_catalog(long_book_id)
assert(#shown.item_table == 100,
    "long catalog eagerly created one menu item per chapter")
assert(shown.item_table[1].text == "第 1–100 章",
    "long catalog did not start with a clear fixed-size range")
assert(shown.item_table[56].text == "第 5501–5600 章  [当前]",
    "long catalog did not identify the current chapter range")
assert(shown.item_table[100].text == "第 9901–10000 章",
    "long catalog did not retain the final range boundary")
assert(goto_index == 56, "long catalog did not open near the current range")

shown.item_table[56].callback()
assert(#shown.item_table == 100,
    "long catalog range did not keep chapter menu allocation bounded")
assert(shown.title:find("第 5501–5600 章", 1, true),
    "long catalog range did not explain its chapter boundary")
assert(shown.item_table[55].text == "长书第 5555 章  [当前]  [可离线]",
    "long catalog range lost current or offline chapter state")
assert(goto_index == 55, "long catalog range did not open near the current chapter")
shown.item_table[100].callback()
assert(opened_id == long_book_id and opened_index == 5600,
    "long catalog range callback did not retain the absolute chapter index")
local previous_menu = shown
plugin:show_catalog_range(long_book_id, 1, 101)
assert(shown == previous_menu,
    "oversized internal catalog range created an unbounded chapter menu")
assert(info_message == "章段范围已变化，请返回书籍页重新打开目录",
    "oversized internal catalog range did not provide a safe recovery action")

local threshold_chapters = {}
for index = 1, 201 do
    threshold_chapters[index] = {
        id = string.format("8%018d", index),
        title = "边界第 " .. tostring(index) .. " 章",
    }
end
local direct_book_id = "8234567890123456700"
plugin.library.books[#plugin.library.books + 1] = {
    id = direct_book_id,
    title = "直接目录边界测试书",
    current_index = 200,
    chapters = { unpack(threshold_chapters, 1, 200) },
}
plugin.storage.verified_cached_chapter_ids = function() return {}, {} end
goto_index = nil
plugin:show_catalog(direct_book_id)
assert(#shown.item_table == 200 and shown.item_table[200].text == "边界第 200 章  [当前]",
    "catalog changed the direct chapter list at its documented boundary")
assert(goto_index == 200, "direct catalog boundary did not select the current chapter")

local threshold_book_id = "8234567890123456789"
plugin.library.books[#plugin.library.books + 1] = {
    id = threshold_book_id,
    title = "分段边界测试书",
    current_index = 201,
    chapters = threshold_chapters,
}
goto_index = nil
plugin:show_catalog(threshold_book_id)
assert(#shown.item_table == 3,
    "catalog did not switch to bounded ranges immediately above the direct limit")
assert(shown.item_table[3].text == "第 201–201 章  [当前]",
    "catalog lost the final partial range or current marker")
assert(goto_index == 3, "catalog did not select the final partial range")
shown.item_table[3].callback()
assert(#shown.item_table == 1 and shown.item_table[1].text == "边界第 201 章  [当前]",
    "final partial range did not contain the exact remaining chapter")
shown.item_table[1].callback()
assert(opened_id == threshold_book_id and opened_index == 201,
    "final partial range opened the wrong absolute chapter")

print("offline catalog tests passed")

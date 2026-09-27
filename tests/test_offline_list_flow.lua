package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, info_message
local Menu = {}
function Menu:new(options) return options end
local UIManager = { show = function(_, widget) shown = widget end }
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
    ["ui/widget/infomessage"] = {}, ["ui/widget/inputdialog"] = {}, logger = {},
    luasettings = {}, ["ui/widget/menu"] = Menu, ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = {}, ["ui/trapper"] = {},
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(value) return value end,
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
local chapters = {
    { id = "7134567890123456701", title = "第一章" },
    { id = "7134567890123456702", title = "第二章" },
    { id = "7134567890123456703", title = "第三章" },
}
local book = {
    id = book_id, title = "离线章节测试书", author = "测试作者",
    current_index = 3, chapters = chapters, directory_updated_at = 100,
}
local cached = { [chapters[1].id] = true, [chapters[3].id] = true }
local inventory_mode = "normal"
local inventory_canary = "FANQIELITE_OFFLINE_LIST_CANARY"
local network_calls, prepared_index, opened_index = 0, nil, nil
local storage = {
    cached_count = function() return 2 end,
    verified_cached_chapter_ids = function()
        if inventory_mode == "throw" then error(inventory_canary) end
        if inventory_mode == "unreadable" then return nil, nil, inventory_canary end
        local readable = {}
        for chapter_id, available in pairs(cached) do
            if available then readable[chapter_id] = true end
        end
        return readable, { [chapters[2].id] = true }
    end,
    cached_chapter = function(_, _, chapter_id)
        if cached[chapter_id] then return "/safe/" .. chapter_id .. ".xhtml" end
        return nil, "缓存不完整", true
    end,
}
local plugin = setmetatable({
    library = { books = { book } },
    storage = storage,
    info = function(_, message) info_message = message end,
    with_network = function() network_calls = network_calls + 1 end,
    prepare_chapter_open = function(_, _, index)
        prepared_index = index
        return true, nil, false
    end,
    open_prepared_chapter = function(_, _, index)
        opened_index = index
        return true
    end,
}, { __index = FanqieLite })

local function find_item(text)
    for _, item in ipairs(shown.item_table or {}) do
        if item.text == text then return item end
    end
end

plugin:show_book(book_id)
local offline_item = find_item("查看可离线章节")
assert(offline_item, "book details did not expose the offline-only list")
offline_item.callback()
assert(shown.title == "离线章节测试书\n可离线章节（2 章）",
    "offline list did not show its verified chapter count")
assert(#shown.item_table == 3, "offline list included damaged or uncached chapters")
assert(shown.item_table[1].text == "第 1 章 · 第一章",
    "offline list lost the first absolute chapter position")
assert(shown.item_table[2].text == "第 3 章 · 第三章  [当前]",
    "offline list lost the current chapter marker")
assert(shown.item_table[3].text == "返回书籍",
    "offline list still depends on a hidden back gesture")

shown.item_table[1].callback()
assert(prepared_index == 1 and opened_index == 1,
    "offline list did not open the selected verified cache")
assert(network_calls == 0, "offline-only opening unexpectedly requested Wi-Fi")

plugin:show_offline_chapters(book_id)
local stale_menu = shown
cached[chapters[1].id] = nil
prepared_index, opened_index, info_message = nil, nil, nil
stale_menu.item_table[1].callback()
assert(prepared_index == nil and opened_index == nil and network_calls == 0,
    "stale offline result fell back to a network chapter open")
assert(info_message:find("缓存已经不存在或需要修复", 1, true)
        and info_message:find("没有联网", 1, true),
    "stale offline result did not explain its safe recovery path")

cached = {}
plugin:show_offline_chapters(book_id)
assert(info_message:find("暂无完整的可离线章节", 1, true)
        and info_message:find("准备离线阅读", 1, true),
    "empty offline list did not guide the user to prepare chapters")
assert(network_calls == 0, "empty offline list unexpectedly requested Wi-Fi")

inventory_mode = "unreadable"
plugin:show_offline_chapters(book_id)
assert(info_message:find("无法安全读取离线缓存列表", 1, true)
        and not info_message:find(inventory_canary, 1, true),
    "unreadable offline inventory exposed an internal error")

inventory_mode = "throw"
local contained = pcall(plugin.show_offline_chapters, plugin, book_id)
assert(contained and not info_message:find(inventory_canary, 1, true),
    "unexpected offline inventory exception escaped or leaked")

print("offline list flow tests passed")

package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, info_message
local home_shown = false
local cleared_book_id

local ConfirmBox = {}
function ConfirmBox:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    nextTick = function(_, callback) callback() end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local Library = {}
function Library.find(library, book_id)
    for index, book in ipairs(library.books or {}) do
        if book.id == book_id then return book, index end
    end
end
function Library.remove(library, book_id)
    local _, index = Library.find(library, book_id)
    if not index then return false end
    table.remove(library.books, index)
    return true
end

local stubs = {
    ["ui/widget/confirmbox"] = ConfirmBox,
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
    ["ui/widget/menu"] = {},
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
local plugin = setmetatable({
    library = { version = 1, books = {{ id = book_id, title = "待移除书籍" }} },
    active_book_id = book_id,
    storage = {
        cached_count = function(_, id)
            assert(id == book_id)
            return 2
        end,
        clear_book = function(_, id)
            cleared_book_id = id
            return 2
        end,
    },
    save_state = function() return true end,
    show_home = function() home_shown = true end,
    info = function(_, message) info_message = message end,
}, { __index = FanqieLite })

plugin:confirm_remove(book_id)
assert(shown and shown.ok_text == "移除", "remove confirmation was not shown")
assert(shown.text:find("移除后可选择是否立即清理", 1, true),
    "remove confirmation still promises an unavailable later cleanup path")
assert(not shown.text:find("可稍后单独清理", 1, true),
    "remove confirmation retained the false later-cleanup promise")

shown.ok_callback()
assert(#plugin.library.books == 0, "book was not removed")
assert(home_shown, "home was not restored behind the cache decision")
assert(shown and shown.ok_text == "清理缓存", "post-remove cache choice was not shown")
assert(shown.text:find("2 个章节缓存", 1, true), "post-remove cache count missing")
assert(shown.text:find("取消将保留缓存", 1, true), "cache preservation choice is unclear")
assert(shown.text:find("重新添加同一本书", 1, true), "cache reuse path is unclear")
assert(shown.text:find(".sdr", 1, true), "KOReader reading-position preservation is unclear")
assert(cleared_book_id == nil, "cache was deleted before separate confirmation")

shown.ok_callback()
assert(cleared_book_id == book_id, "confirmed removed-book cache was not cleared")
assert(info_message and info_message:find("已清理 2 个", 1, true),
    "removed-book cache cleanup result missing")

print("remove flow tests passed")

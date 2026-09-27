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

local exception_tostring_calls = 0
plugin.library.books = {{ id = book_id, title = "异常计数书籍" }}
plugin.storage.cached_count = function()
    error(setmetatable({}, { __tostring = function()
        exception_tostring_calls = exception_tostring_calls + 1
        return "CACHE_SECRET_CANARY"
    end }))
end
local count_contained = pcall(plugin.confirm_remove, plugin, book_id)
assert(count_contained and shown and shown.ok_text == "移除",
    "unexpected cache count exception blocked book removal")
shown.ok_callback()
assert(shown.text:find("缓存数量暂时无法读取", 1, true),
    "post-remove choice did not degrade an unexpected cache count safely")
assert(exception_tostring_calls == 0,
    "unexpected cache count exception invoked its unsafe __tostring method")

plugin.storage.clear_book = function()
    error(setmetatable({}, { __tostring = function()
        exception_tostring_calls = exception_tostring_calls + 1
        return "CACHE_SECRET_CANARY"
    end }))
end
local clear_contained = pcall(plugin.clear_removed_book_cache, plugin, book_id)
assert(clear_contained, "unexpected cache clear exception escaped the removal flow")
assert(info_message:find("缓存清理意外中断", 1, true)
        and info_message:find("部分数字 XHTML 可能已经删除", 1, true),
    "unexpected cache clear did not explain its uncertain partial outcome")
assert(info_message:find("书架和阅读进度没有改变", 1, true),
    "unexpected cache clear did not preserve the known data boundary")
assert(not info_message:find("CACHE_SECRET_CANARY", 1, true)
        and exception_tostring_calls == 0,
    "unexpected cache clear exposed or stringified its exception")

print("remove flow tests passed")

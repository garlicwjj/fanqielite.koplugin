package.path = "./?.lua;./?/init.lua;" .. package.path

local registered = {}
local Dispatcher = {
    registerAction = function(_, name, definition)
        registered[name] = definition
    end,
}

local Library = {}
function Library.find(library, book_id)
    for _, book in ipairs(library.books or {}) do
        if book.id == book_id then return book end
    end
end

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = {},
    device = {},
    dispatcher = Dispatcher,
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
    ["ui/uimanager"] = {},
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
FanqieLite:onDispatcherRegisterActions()

local previous_action = registered.fanqielite_previous_chapter
local next_action = registered.fanqielite_next_chapter
assert(previous_action and next_action, "reader chapter actions were not registered")
assert(previous_action.event == "FanqieLitePreviousChapter"
        and previous_action.title == "番茄小说：上一章",
    "previous chapter action metadata is not stable")
assert(next_action.event == "FanqieLiteNextChapter"
        and next_action.title == "番茄小说：下一章",
    "next chapter action metadata is not stable")
assert(previous_action.reader == true and next_action.reader == true,
    "Fanqie chapter actions were not limited to reader action lists")
assert(not previous_action.general and not next_action.general,
    "Fanqie chapter actions leaked into unrelated general action lists")

local root = "/mock/koreader/fanqielite"
local first_book_id = "7134567890123456789"
local second_book_id = "7234567890123456789"
local chapter_ids = {
    "7134567890123456701",
    "7134567890123456702",
    "7134567890123456703",
}
local first_book = {
    id = first_book_id,
    chapters = {
        { id = chapter_ids[1], title = "第一章" },
        { id = chapter_ids[2], title = "第二章" },
        { id = chapter_ids[3], title = "第三章" },
    },
    current_index = 1,
}
local second_chapter_id = "7234567890123456701"
local second_book = {
    id = second_book_id,
    chapters = {{ id = second_chapter_id, title = "另一册第一章" }},
    current_index = 1,
}

local cache_mode = "valid"
local cache_checks = 0
local storage = {
    root = root,
    cached_chapter = function(_, book_id, chapter_id)
        cache_checks = cache_checks + 1
        if cache_mode == "throw" then error("unsafe storage detail") end
        if cache_mode == "missing" then return nil end
        if cache_mode == "unsafe" then return nil, "unsafe cache detail" end
        return root .. "/" .. book_id .. "/" .. chapter_id .. ".xhtml"
    end,
}

local infos = {}
local opened = {}
local plugin = setmetatable({
    active_book_id = second_book_id,
    library = { books = { first_book, second_book } },
    storage = storage,
    ui = { document = {
        file = root .. "/" .. first_book_id .. "/" .. chapter_ids[2] .. ".xhtml",
    } },
    info = function(_, message) infos[#infos + 1] = message end,
    open_chapter = function(_, book_id, index)
        opened[#opened + 1] = { book_id = book_id, index = index }
    end,
}, { __index = FanqieLite })

plugin:onFanqieLiteNextChapter()
assert(#opened == 1 and opened[1].book_id == first_book_id and opened[1].index == 3,
    "next action did not follow the chapter actually open in the reader")
plugin:onFanqieLitePreviousChapter()
assert(#opened == 2 and opened[2].book_id == first_book_id and opened[2].index == 1,
    "previous action did not follow the chapter actually open in the reader")
assert(cache_checks == 2, "reader actions did not revalidate the current cache file")

plugin.ui.document.file = root .. "/" .. first_book_id .. "/" .. chapter_ids[1] .. ".xhtml"
plugin:onFanqieLitePreviousChapter()
assert(#opened == 2, "previous action crossed the first-chapter boundary")
assert(infos[#infos]:find("已经是本书第一章", 1, true),
    "first-chapter boundary was not explained")

plugin.ui.document.file = root .. "/" .. first_book_id .. "/" .. chapter_ids[3] .. ".xhtml"
plugin:onFanqieLiteNextChapter()
assert(#opened == 2, "next action crossed the last-chapter boundary")
assert(infos[#infos]:find("已经是本书最后一章", 1, true),
    "last-chapter boundary was not explained")

local checks_before_other_book = cache_checks
plugin.ui.document.file = "/mock/books/ordinary.epub"
plugin:onFanqieLiteNextChapter()
assert(#opened == 2 and cache_checks == checks_before_other_book,
    "ordinary document triggered Fanqie cache inspection or navigation")
assert(infos[#infos]:find("当前打开的不是 Fanqie Lite 章节", 1, true),
    "ordinary document rejection was not actionable")

plugin.ui.document.file = root .. "/" .. first_book_id .. "/" .. chapter_ids[2] .. ".xhtml"
cache_mode = "unsafe"
plugin:onFanqieLiteNextChapter()
assert(#opened == 2, "unsafe cache identity still navigated")
assert(infos[#infos]:find("无法安全确认当前章节缓存", 1, true),
    "unsafe cache identity did not stop with a fixed message")
assert(not infos[#infos]:find("unsafe cache detail", 1, true),
    "unsafe cache detail leaked to the reader action message")

cache_mode = "throw"
local contained = pcall(function() plugin:onFanqieLiteNextChapter() end)
assert(contained and #opened == 2, "cache inspection exception escaped the reader action")
assert(infos[#infos]:find("无法安全确认当前章节缓存", 1, true),
    "cache inspection exception did not use the fixed failure message")

cache_mode = "valid"
plugin.ui.document.file = root .. "/" .. first_book_id .. "/7999999999999999999.xhtml"
plugin:onFanqieLiteNextChapter()
assert(#opened == 2, "unknown chapter path navigated by current_index fallback")
assert(infos[#infos]:find("不在本地目录", 1, true),
    "unknown chapter path did not explain the stale directory state")

print("reader action tests passed")

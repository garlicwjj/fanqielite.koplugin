package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, info_message
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

local Library = {}
function Library.find(library, book_id)
    for _, book in ipairs(library.books or {}) do
        if book.id == book_id then return book end
    end
end

local network_calls, fail_at = 0, nil
local network_canary = "FANQIELITE_CACHE_AHEAD_NETWORK_CANARY"
local NetworkTask = {}
function NetworkTask.get()
    network_calls = network_calls + 1
    if fail_at and network_calls == fail_at then
        return nil, network_canary, "retryable"
    end
    return "official chapter page"
end

local Parser = {
    extract_initial_state = function() return "{}" end,
    decode_json = function() return {} end,
    chapter_from_state = function(_, chapter_id)
        return { id = chapter_id, title = "官网标题", content = "正文" }
    end,
    to_xhtml = function(_, chapter)
        return '<?xml version="1.0" encoding="utf-8"?>'
            .. '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            .. chapter.id .. "</body></html>"
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
    ["fanqielite.search"] = {}, ["fanqielite.storage"] = {},
}
for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local book_id = "7134567890123456789"
local chapters = {}
for index = 1, 7 do
    chapters[index] = {
        id = "71345678901234567" .. tostring(10 + index),
        title = "第 " .. tostring(index) .. " 章",
    }
end
local book = {
    id = book_id,
    title = "离线准备测试书",
    author = "测试作者",
    current_index = 1,
    chapters = chapters,
    directory_updated_at = 100,
}
local cached_ids = { [chapters[1].id] = true }
local cache_mode, prune_warning = "normal", nil
local cache_canary = "FANQIELITE_CACHE_AHEAD_CACHE_CANARY"
local writes, save_calls, open_calls = {}, 0, 0
local result_offline_book_id, result_return_book_id
local storage = {
    cached_count = function()
        local count = 0
        for _ in pairs(cached_ids) do count = count + 1 end
        return count
    end,
    cached_chapter = function(_, _, chapter_id)
        if cache_mode == "throw" then error(cache_canary) end
        if cached_ids[chapter_id] then return "/safe/" .. chapter_id .. ".xhtml" end
        return nil
    end,
    write_chapter = function(_, _, chapter_id)
        cached_ids[chapter_id] = true
        writes[#writes + 1] = chapter_id
        return "/safe/" .. chapter_id .. ".xhtml", nil, prune_warning
    end,
}
local plugin = setmetatable({
    library = { books = { book } },
    storage = storage,
    info = function(_, message) info_message = message end,
    with_network = function(_, callback) callback() end,
    save_state = function() save_calls = save_calls + 1; return true end,
    open_file = function() open_calls = open_calls + 1; return true end,
}, { __index = FanqieLite })

local function find_item(text)
    for _, item in ipairs(shown.item_table or {}) do
        if item.text == text then return item end
    end
end

plugin:show_book(book_id)
local prepare_item = find_item("准备离线阅读（最多 5 章）")
assert(prepare_item, "book details did not expose explicit offline preparation")
prepare_item.callback()
assert(shown.text:find("5 个尚未缓存章节", 1, true),
    "offline preparation did not state its exact network scope")
assert(shown.text:find("不会打开正文或改变当前章节", 1, true),
    "offline preparation did not protect reading progress in its confirmation")
assert(shown.text:find("不下载整本书", 1, true),
    "offline preparation did not state its full-book boundary")
shown.ok_callback()
assert(network_calls == 5 and #writes == 5,
    "offline preparation did not limit itself to five missing chapters")
for index = 1, 5 do
    assert(writes[index] == chapters[index + 1].id,
        "offline preparation did not preserve chapter order or skip existing cache")
end
assert(shown.text:find("新增 5 章", 1, true)
        and shown.text:find("已存在 1 章", 1, true),
    "offline preparation did not summarize its result")
assert(shown.ok_text == "查看可离线章节" and shown.cancel_text == "返回书籍",
    "offline preparation result did not provide both useful next actions")
local success_result = shown
plugin.show_offline_chapters = function(_, id) result_offline_book_id = id end
plugin.show_book = function(_, id) result_return_book_id = id end
success_result.ok_callback()
success_result.cancel_callback()
assert(result_offline_book_id == book_id and result_return_book_id == book_id,
    "offline preparation result actions lost the current book")
assert(save_calls == 0 and open_calls == 0 and book.current_index == 1,
    "offline preparation changed reading progress or opened a chapter")

cached_ids, writes, network_calls, fail_at = {}, {}, 0, 3
plugin:confirm_cache_ahead(book_id)
shown.ok_callback()
assert(#writes == 2, "partial network failure did not preserve completed cache writes")
assert(shown.text:find("第 3 章", 1, true)
        and shown.text:find("新增 2 章", 1, true),
    "partial network failure did not report the exact stopping point")
assert(not shown.text:find(network_canary, 1, true),
    "partial network failure exposed an untrusted transport error")
assert(shown.text:find("书架和阅读进度没有改变", 1, true)
        and shown.ok_text == "查看可离线章节",
    "partial network failure did not explain durable local state")

cached_ids, writes, network_calls, fail_at = {}, {}, 0, nil
plugin:confirm_cache_ahead(book_id)
local expected_first_id = chapters[1].id
chapters[1].id = "7234567890123456711"
shown.ok_callback()
assert(network_calls == 0 and #writes == 0,
    "changed directory reused a stale offline preparation plan")
assert(info_message:find("目录已经变化", 1, true),
    "changed directory did not provide a safe restart action")
chapters[1].id = expected_first_id

cached_ids, writes, network_calls = {}, {}, 0
for _, chapter in ipairs(chapters) do cached_ids[chapter.id] = true end
plugin:confirm_cache_ahead(book_id)
assert(network_calls == 0 and #writes == 0,
    "already cached chapters unnecessarily requested Wi-Fi")
assert(info_message:find("已经可以离线阅读", 1, true),
    "already cached range did not provide a useful local result")

cached_ids, writes, network_calls, cache_mode = {}, {}, 0, "throw"
plugin:confirm_cache_ahead(book_id)
assert(network_calls == 0 and #writes == 0,
    "unsafe cache inventory started an offline network operation")
assert(info_message:find("无法安全检查本地缓存", 1, true)
        and not info_message:find(cache_canary, 1, true),
    "unsafe cache inventory did not use a fixed local error")

cached_ids, writes, network_calls, cache_mode = {}, {}, 0, "normal"
prune_warning = "FANQIELITE_CACHE_AHEAD_PRUNE_CANARY"
plugin:confirm_cache_ahead(book_id)
shown.ok_callback()
assert(network_calls == 1 and #writes == 1,
    "cache cleanup warning did not stop further chapter requests")
assert(info_message:find("较早缓存自动清理未完成", 1, true)
        and not info_message:find(prune_warning, 1, true),
    "cache cleanup warning did not use a bounded summary")
prune_warning = nil

print("cache ahead flow tests passed")

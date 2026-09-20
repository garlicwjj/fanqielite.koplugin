package.path = "./?.lua;./?/init.lua;" .. package.path

local sidecar_mode = "throw"
local canary = "FANQIELITE_SIDECAR_ERROR_CANARY_4f21"
local tostring_calls = 0
local function unsafe_error()
    return setmetatable({}, { __tostring = function()
        tostring_calls = tostring_calls + 1
        return canary
    end })
end

local DocSettings = {
    hasSidecarFile = function()
        if sidecar_mode == "throw" then error(unsafe_error()) end
        return sidecar_mode == "present"
    end,
}

local file_open_mode = "throw"
local file_open_calls = 0
local pending_after_open_callback
local FileManager = {
    openFile = function(_, _, _, _, _, after_open_callback)
        file_open_calls = file_open_calls + 1
        if file_open_mode == "throw" then error(unsafe_error()) end
        pending_after_open_callback = after_open_callback
    end,
}

local Event = {}
function Event:new(name, value) return { name = name, value = value } end

local inspect_calls, take_calls, touch_calls = 0, 0, 0
local pending_position
local Library = {
    find = function(library, book_id)
        for _, candidate in ipairs(library.books or {}) do
            if candidate.id == book_id then return candidate end
        end
    end,
    inspect_imported_position = function(_, _, has_local_position)
        inspect_calls = inspect_calls + 1
        if pending_position ~= nil and not has_local_position then
            return pending_position, true
        end
        return nil, pending_position ~= nil
    end,
    take_imported_position = function()
        take_calls = take_calls + 1
        pending_position = nil
        return nil, true
    end,
    touch = function()
        touch_calls = touch_calls + 1
        return true
    end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = {},
    device = {},
    dispatcher = {},
    docsettings = DocSettings,
    ["ui/event"] = Event,
    ["apps/filemanager/filemanager"] = FileManager,
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
local save_calls = 0
local save_failure_on_call
local restored_pending_position
local infos = {}
local plugin = setmetatable({
    library = { books = {} },
    info = function(_, message) infos[#infos + 1] = message end,
    save_state = function()
        save_calls = save_calls + 1
        if save_calls == save_failure_on_call then
            pending_position = restored_pending_position
            return nil, "fixed save failure"
        end
        return true
    end,
}, { __index = FanqieLite })
local book = { id = "7134567890123456789", chapters = {{ id = "7134567890123456701" }} }
plugin.library.books = { book }

local contained, ready, sidecar_err = pcall(function()
    return plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
end)
assert(contained, "sidecar inspection exception escaped the plugin boundary")
assert(ready == nil and type(sidecar_err) == "string",
    "sidecar inspection failure did not stop the chapter open")
assert(sidecar_err:find("本机阅读位置", 1, true),
    "sidecar inspection failure did not identify the failed operation")
assert(sidecar_err:find("没有改变", 1, true),
    "sidecar inspection failure did not explain local data safety")
assert(sidecar_err:find("重试", 1, true),
    "sidecar inspection failure did not provide a next action")
assert(not sidecar_err:find(canary, 1, true), "sidecar inspection error leaked raw content")
assert(tostring_calls == 0, "sidecar inspection error invoked __tostring")
assert(inspect_calls == 0 and take_calls == 0 and touch_calls == 0 and save_calls == 0,
    "sidecar inspection failure changed reading state")

local cache_written_ready, cache_written_err = plugin:prepare_chapter_open(
    book, 1, "/safe/cache.xhtml", true, "旧缓存清理失败")
assert(cache_written_ready == nil, "post-write sidecar failure reported success")
assert(cache_written_err:find("章节缓存已经写入", 1, true),
    "post-write sidecar failure hid the successful cache write")
assert(cache_written_err:find("缓存状态已改变", 1, true),
    "post-write sidecar failure claimed the cache was unchanged")
assert(cache_written_err:find("旧缓存清理失败", 1, true),
    "post-write sidecar failure lost the prune warning")
assert(not cache_written_err:find("缓存没有改变", 1, true),
    "post-write sidecar failure retained the false unchanged-cache claim")

sidecar_mode = "present"
local normal_ready = assert(plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml"))
assert(normal_ready == true, "normal sidecar inspection did not prepare the chapter")
assert(inspect_calls == 1 and take_calls == 0 and touch_calls == 1 and save_calls == 1,
    "normal chapter preparation lifecycle changed")

sidecar_mode = "missing"
pending_position = 0.6
local pending_ready, imported_position, pending_consumption =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(pending_ready == true and imported_position == 0.6 and pending_consumption == true,
    "chapter preparation did not preserve the pending imported position")
local open_contained, opened = pcall(function()
    return plugin:open_prepared_chapter(
        book, 1, "/safe/cache.xhtml", imported_position, pending_consumption)
end)
assert(open_contained, "chapter file open exception escaped the plugin boundary")
assert(opened == nil, "failed chapter file open reported success")
local open_err = infos[#infos]
assert(type(open_err) == "string" and open_err:find("章节文件", 1, true),
    "chapter file open failure did not identify the failed operation")
assert(open_err:find("书架和缓存没有删除", 1, true),
    "chapter file open failure did not explain retained data")
assert(open_err:find("导入的阅读位置仍会保留", 1, true),
    "chapter file open failure did not explain imported-position retention")
assert(open_err:find("可能已记录为本章", 1, true),
    "chapter file open failure hid the possible chapter-index change")
assert(open_err:find("重试", 1, true),
    "chapter file open failure did not provide a next action")
assert(not open_err:find(canary, 1, true), "chapter file open error leaked raw content")
assert(tostring_calls == 0, "chapter file open error invoked __tostring")
assert(pending_position == 0.6 and take_calls == 0,
    "failed chapter file open consumed the imported position")
assert(save_calls == 2, "failed chapter file open performed a cleanup settings write")

file_open_mode = "success"
pending_ready, imported_position, pending_consumption =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
local saves_before_scheduled_open = save_calls
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", imported_position, pending_consumption),
    "normal prepared chapter open was not scheduled")
assert(file_open_calls == 2, "chapter file open call count changed")
assert(type(pending_after_open_callback) == "function",
    "pending imported position did not install a ReaderReady callback")
assert(pending_position == 0.6 and take_calls == 0,
    "queued reader open consumed the imported position before ReaderReady")
assert(save_calls == saves_before_scheduled_open,
    "queued reader open performed cleanup before ReaderReady")
local goto_event
pending_after_open_callback({
    handleEvent = function(_, event) goto_event = event end,
})
assert(goto_event and goto_event.name == "GotoPercent" and goto_event.value == 60,
    "ReaderReady callback did not apply the imported position")
assert(pending_position == nil and take_calls == 1,
    "ReaderReady callback did not consume the imported position")
assert(save_calls == saves_before_scheduled_open + 1,
    "ReaderReady callback did not persist imported-position cleanup")

pending_position = 0.45
restored_pending_position = pending_position
local apply_failure_ready, apply_failure_position, apply_failure_pending =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(apply_failure_ready and apply_failure_position == 0.45 and apply_failure_pending,
    "position-application failure fixture did not prepare the imported position")
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", apply_failure_position, apply_failure_pending),
    "position-application failure reader open was not scheduled")
local takes_before_apply_failure = take_calls
local saves_before_apply_failure = save_calls
pending_after_open_callback({ handleEvent = function() error(unsafe_error()) end })
assert(pending_position == 0.45 and take_calls == takes_before_apply_failure,
    "failed GotoPercent consumed the imported position")
assert(save_calls == saves_before_apply_failure,
    "failed GotoPercent persisted imported-position cleanup")
local apply_warning = infos[#infos]
assert(apply_warning:find("无法应用", 1, true)
        and apply_warning:find("导入位置仍保留", 1, true),
    "failed GotoPercent did not explain the retained position")
assert(not apply_warning:find(canary, 1, true) and tostring_calls == 0,
    "failed GotoPercent leaked or stringified the raw error")

pending_position = 0.35
local handoff_ready, handoff_position, handoff_pending =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(handoff_ready and handoff_position == 0.35 and handoff_pending,
    "active-plugin handoff fixture did not prepare the imported position")
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", handoff_position, handoff_pending),
    "active-plugin handoff reader open was not scheduled")
local replacement_saves = 0
local replacement_plugin = setmetatable({
    library = { books = { book } },
    info = function(_, message) infos[#infos + 1] = message end,
    save_state = function() replacement_saves = replacement_saves + 1; return true end,
}, { __index = FanqieLite })
local old_saves_before_handoff = save_calls
local handoff_event
pending_after_open_callback({
    fanqielite = replacement_plugin,
    handleEvent = function(_, event) handoff_event = event end,
})
assert(handoff_event and handoff_event.value == 35,
    "active ReaderUI plugin did not apply the imported position")
assert(replacement_saves == 1 and save_calls == old_saves_before_handoff,
    "ReaderReady cleanup used the stale FileManager plugin instance")
assert(pending_position == nil,
    "active ReaderUI plugin did not consume the imported position")

pending_position = 0.25
restored_pending_position = pending_position
local cleanup_ready, cleanup_position, cleanup_pending =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(cleanup_ready == true and cleanup_position == 0.25 and cleanup_pending == true,
    "cleanup-failure fixture did not prepare the imported position")
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", cleanup_position, cleanup_pending),
    "cleanup-failure reader open was not scheduled")
save_failure_on_call = save_calls + 1
pending_after_open_callback({ handleEvent = function() end })
save_failure_on_call = nil
assert(pending_position == 0.25,
    "cleanup settings failure did not restore the persisted imported position")
local cleanup_warning = infos[#infos]
assert(type(cleanup_warning) == "string"
        and cleanup_warning:find("章节已经打开", 1, true),
    "cleanup settings failure did not distinguish the successful reader open")
assert(cleanup_warning:find("导入位置没有丢失", 1, true),
    "cleanup settings failure did not explain restored data safety")

sidecar_mode = "present"
pending_position = 0.2
local local_ready, local_position, local_pending =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(local_ready and local_position == nil and local_pending,
    "local-sidecar fixture did not defer stale imported-position cleanup")
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", local_position, local_pending),
    "local-sidecar reader open was not scheduled")
local local_handle_calls = 0
pending_after_open_callback({ handleEvent = function() local_handle_calls = local_handle_calls + 1 end })
assert(local_handle_calls == 0 and pending_position == nil,
    "local-sidecar ReaderReady cleanup reapplied or retained imported position")

local ordinary_save_calls = save_calls
local ordinary_ready, ordinary_position, ordinary_pending =
    plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml")
assert(ordinary_ready == true and ordinary_position == nil and ordinary_pending == false,
    "ordinary chapter preparation unexpectedly created imported-position cleanup")
assert(plugin:open_prepared_chapter(
    book, 1, "/safe/cache.xhtml", ordinary_position, ordinary_pending),
    "ordinary prepared chapter open was not scheduled")
assert(save_calls == ordinary_save_calls + 1,
    "ordinary chapter open performed a second settings write")
assert(pending_after_open_callback == nil,
    "ordinary chapter open installed an unnecessary ReaderReady callback")

save_failure_on_call = save_calls + 1
local post_write_ready, post_write_save_err = plugin:prepare_chapter_open(
    book, 1, "/safe/cache.xhtml", true, "旧缓存清理失败")
save_failure_on_call = nil
assert(post_write_ready == nil, "post-write settings failure reported success")
assert(post_write_save_err:find("章节缓存已经写入", 1, true),
    "post-write settings failure hid the successful cache write")
assert(post_write_save_err:find("无法保存继续阅读位置", 1, true),
    "post-write settings failure did not identify the failed stage")
assert(post_write_save_err:find("缓存状态已改变", 1, true),
    "post-write settings failure did not explain the cache state")
assert(post_write_save_err:find("旧缓存清理失败", 1, true),
    "post-write settings failure lost the prune warning")

print("chapter open flow tests passed")

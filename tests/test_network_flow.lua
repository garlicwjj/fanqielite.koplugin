package.path = "./?.lua;./?/init.lua;" .. package.path

local online_calls, wrap_calls, reset_calls = 0, 0, 0
local infos = {}
local shown_widgets = {}
local network_error
local network_error_kind
local network_urls = {}
local credential_canary = "COOKIE_SESSION_TOKEN_CANARY_4d91"
local tostring_calls = 0
local network_manager_mode = "success"
local trapper_mode = "success"
local scheduler_mode = "success"
local pending_online_callback
local scheduled_callbacks = {}
local scheduled_delays = {}
local unscheduled_callbacks = {}

local NetworkMgr = {
    runWhenOnline = function(_, callback)
        online_calls = online_calls + 1
        if network_manager_mode == "throw" then
            error(setmetatable({}, { __tostring = function()
                tostring_calls = tostring_calls + 1
                return credential_canary
            end }))
        end
        if network_manager_mode == "pending" then
            pending_online_callback = callback
            return
        end
        callback()
    end,
}

local Trapper = {
    wrap = function(_, callback)
        wrap_calls = wrap_calls + 1
        if trapper_mode == "wrap_throw" then
            error(setmetatable({}, { __tostring = function()
                tostring_calls = tostring_calls + 1
                return credential_canary
            end }))
        end
        callback()
    end,
    reset = function()
        reset_calls = reset_calls + 1
        if trapper_mode == "reset_throw" then
            error(setmetatable({}, { __tostring = function()
                tostring_calls = tostring_calls + 1
                return credential_canary
            end }))
        end
    end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local NetworkTask = {
    get = function(url)
        network_urls[#network_urls + 1] = url
        return nil, network_error, network_error_kind
    end,
}

local ConfirmBox = {}
function ConfirmBox:new(definition) return definition end

local Parser = {
    book_id = function(value) return value end,
}
local Export = {}
local Import = {}
local Library = {
    find = function(library, book_id)
        for _, book in ipairs(library.books or {}) do
            if book.id == book_id then return book end
        end
    end,
}

local UIManager = {
    scheduleIn = function(_, delay, callback)
        if scheduler_mode == "throw" then error("scheduler unavailable") end
        scheduled_callbacks[#scheduled_callbacks + 1] = callback
        scheduled_delays[#scheduled_delays + 1] = delay
    end,
    unschedule = function(_, callback)
        unscheduled_callbacks[callback] = true
    end,
    show = function(_, widget)
        shown_widgets[#shown_widgets + 1] = widget
    end,
    nextTick = function(_, callback)
        callback()
    end,
}

local stubs = {
    ["ui/widget/confirmbox"] = ConfirmBox,
    datastorage = { getDataDir = function() return "/mnt/us/koreader" end },
    device = { home_dir = "/mnt/us" },
    dispatcher = {},
    docsettings = {},
    ["ui/event"] = {},
    ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = {},
    logger = { info = function() end },
    luasettings = {},
    ["ui/widget/menu"] = {},
    ["ui/network/manager"] = NetworkMgr,
    ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = Trapper,
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = Export,
    ["fanqielite.import"] = Import,
    ["fanqielite.library"] = Library,
    ["fanqielite.networktask"] = NetworkTask,
    ["fanqielite.parser"] = Parser,
    ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = {},
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local plugin = setmetatable({
    info = function(_, message) infos[#infos + 1] = message end,
}, { __index = FanqieLite })

local completed = false
plugin:with_network(function()
    assert(plugin.network_busy == true, "network gate was not active during callback")
    completed = true
end)
assert(completed, "online callback did not run")
assert(plugin.network_busy == false, "network gate remained active after success")
assert(online_calls == 1 and wrap_calls == 1 and reset_calls == 1,
    "success did not use the expected network wrapper lifecycle")

local nested_ran = false
plugin:with_network(function()
    plugin:with_network(function() nested_ran = true end)
end)
assert(not nested_ran, "nested network operation bypassed the busy gate")
assert(infos[#infos]:find("已有网络操作", 1, true), "busy gate did not explain the rejection")
assert(plugin.network_busy == false, "network gate remained active after nested rejection")

network_error = "操作已取消；本地书架、阅读进度和缓存没有改变。"
network_error_kind = "cancelled"
local shown_before_cancel = #shown_widgets
plugin:with_network(function() plugin:load_book("1234567890") end)
local cancelled = infos[#infos]
assert(cancelled:find("操作未完成", 1, true), "cancellation did not use the safe failure heading")
assert(cancelled:find("操作已取消", 1, true), "cancellation reason was lost")
assert(cancelled:find("没有改变", 1, true), "cancellation safety detail was lost")
assert(not cancelled:find("test_network_flow.lua", 1, true), "cancellation leaked a Lua file path")
assert(plugin.network_busy == false, "network gate remained active after cancellation")
assert(#shown_widgets == shown_before_cancel, "user cancellation incorrectly offered one-tap retry")

network_error = "网络连接超时，请检查 Kindle 的 Wi-Fi 和系统时间后重试；本地数据未改变"
network_error_kind = "retryable"
local shown_before_retryable = #shown_widgets
local online_before_retry = online_calls
local network_urls_before_retry = #network_urls
plugin:with_network(function() plugin:load_book("1234567890") end)
assert(#shown_widgets == shown_before_retryable + 1,
    "retryable network failure did not show an in-place retry dialog")
local retry_dialog = shown_widgets[#shown_widgets]
assert(retry_dialog.ok_text == "重试" and retry_dialog.cancel_text == "返回",
    "retry dialog actions were not explicit")
assert(retry_dialog.text:find("操作未完成", 1, true), "retry dialog lost the failure heading")
assert(retry_dialog.text:find("本地数据未改变", 1, true), "retry dialog lost the safety detail")
assert(retry_dialog.text:find("是否重试同一操作", 1, true), "retry dialog did not explain the action")
retry_dialog.ok_callback()
assert(online_calls == online_before_retry + 2,
    "retry action did not run the exact network operation again")
assert(#network_urls == network_urls_before_retry + 2
        and network_urls[network_urls_before_retry + 1]
            == "https://fanqienovel.com/page/1234567890"
        and network_urls[network_urls_before_retry + 2]
            == "https://fanqienovel.com/page/1234567890",
    "retry action changed the original official request target")

network_error = "官方服务拒绝访问，内容可能需要登录或授权；本地数据未改变"
network_error_kind = nil
local shown_before_blocked = #shown_widgets
plugin:with_network(function() plugin:load_book("1234567890") end)
assert(#shown_widgets == shown_before_blocked,
    "non-retryable platform boundary incorrectly offered one-tap retry")
assert(infos[#infos]:find("需要登录或授权", 1, true),
    "non-retryable platform boundary lost its actionable message")

network_error = setmetatable({}, { __tostring = function()
    tostring_calls = tostring_calls + 1
    return credential_canary
end })
network_error_kind = nil
plugin:with_network(function() plugin:load_book("1234567890") end)
local unsafe_dependency = infos[#infos]
assert(unsafe_dependency:find("可安全显示的错误说明", 1, true), "unsafe dependency error did not use fixed message")
assert(not unsafe_dependency:find(credential_canary, 1, true), "unsafe dependency error leaked raw content")
assert(tostring_calls == 0, "unsafe dependency error invoked __tostring")

plugin:with_network(function()
    error(setmetatable({}, { __tostring = function()
        tostring_calls = tostring_calls + 1
        return credential_canary
    end }))
end)
local failed = infos[#infos]
assert(failed:find("操作未完成", 1, true), "failure heading missing")
assert(failed:find("未预期", 1, true), "unexpected failure did not use fixed message")
assert(not failed:find(credential_canary, 1, true), "unexpected failure leaked raw content")
assert(tostring_calls == 0, "unexpected failure invoked __tostring")
assert(not failed:find("test_network_flow.lua", 1, true), "failure leaked a Lua file path")
assert(plugin.network_busy == false, "network gate remained active after failure")
assert(reset_calls == 8, "Trapper was not reset after every completed wrapper")

network_manager_mode = "throw"
local manager_contained = pcall(function()
    plugin:with_network(function() error("must not run") end)
end)
assert(manager_contained, "network manager exception escaped the plugin boundary")
local manager_failure = infos[#infos]
assert(manager_failure:find("无法启动安全的网络操作", 1, true),
    "network manager exception did not use a fixed recovery message")
assert(not manager_failure:find(credential_canary, 1, true), "network manager exception leaked")
assert(tostring_calls == 0, "network manager exception invoked __tostring")
assert(plugin.network_busy == false, "network manager exception left the busy gate active")
network_manager_mode = "success"

trapper_mode = "wrap_throw"
local wrapper_contained = pcall(function()
    plugin:with_network(function() error("must not run") end)
end)
assert(wrapper_contained, "Trapper wrapper exception escaped the plugin boundary")
local wrapper_failure = infos[#infos]
assert(wrapper_failure:find("无法启动安全的网络操作", 1, true),
    "Trapper wrapper exception did not use a fixed recovery message")
assert(not wrapper_failure:find(credential_canary, 1, true), "Trapper wrapper exception leaked")
assert(tostring_calls == 0, "Trapper wrapper exception invoked __tostring")
assert(plugin.network_busy == false, "Trapper wrapper exception left the busy gate active")

trapper_mode = "reset_throw"
local reset_contained = pcall(function()
    plugin:with_network(function() end)
end)
assert(reset_contained, "Trapper reset exception escaped the plugin boundary")
local reset_failure = infos[#infos]
assert(reset_failure:find("无法启动安全的网络操作", 1, true),
    "Trapper reset exception did not use a fixed recovery message")
assert(not reset_failure:find(credential_canary, 1, true), "Trapper reset exception leaked")
assert(tostring_calls == 0, "Trapper reset exception invoked __tostring")
assert(plugin.network_busy == false, "Trapper reset exception left the busy gate active")
trapper_mode = "success"

network_manager_mode = "pending"
pending_online_callback = nil
local waiting_ran = false
plugin:with_network(function() waiting_ran = true end)
assert(plugin.network_wait ~= nil, "offline request did not enter the waiting state")
assert(type(pending_online_callback) == "function", "offline request did not retain the delayed callback")
assert(scheduled_delays[#scheduled_delays] == 50, "offline request used an unexpected wait timeout")
local cancelled_timeout = plugin.network_wait.timeout_callback
local stale_after_cancel = pending_online_callback
local online_calls_before_repeat = online_calls
local wrap_calls_before_repeat = wrap_calls
plugin:with_network(function() error("repeated tap must not replace the first request") end)
assert(plugin.network_wait == nil, "repeated tap did not cancel the pending request")
assert(online_calls == online_calls_before_repeat,
    "repeated tap scheduled another network-manager request")
assert(infos[#infos]:find("已取消等待联网", 1, true),
    "repeated tap did not explain that the pending request was cancelled")
assert(unscheduled_callbacks[cancelled_timeout], "cancelled request left its timeout scheduled")
stale_after_cancel()
assert(not waiting_ran, "cancelled request ran after a late network callback")
assert(wrap_calls == wrap_calls_before_repeat,
    "cancelled request reached the task wrapper after a late callback")

pending_online_callback = nil
local timed_out_ran = false
plugin:with_network(function() timed_out_ran = true end)
local stale_after_timeout = pending_online_callback
local timeout_callback = scheduled_callbacks[#scheduled_callbacks]
assert(type(timeout_callback) == "function", "offline request did not install a timeout")
timeout_callback()
assert(plugin.network_wait == nil, "waiting state remained active after timeout")
assert(infos[#infos]:find("等待 Wi%-Fi 超时"), "timeout did not provide a recovery message")
local wrap_calls_before_stale_timeout = wrap_calls
stale_after_timeout()
assert(not timed_out_ran, "timed-out request ran after a late network callback")
assert(wrap_calls == wrap_calls_before_stale_timeout,
    "timed-out request reached the task wrapper after a late callback")

network_manager_mode = "success"
local recovered_after_wait = false
plugin:with_network(function() recovered_after_wait = true end)
assert(recovered_after_wait, "a new operation could not start after cancelling or timing out")
assert(plugin.network_busy == false and plugin.network_wait == nil,
    "network lifecycle did not fully recover after a new successful operation")

scheduler_mode = "throw"
local online_calls_before_scheduler_failure = online_calls
local scheduler_contained = pcall(function()
    plugin:with_network(function() error("must not run") end)
end)
assert(scheduler_contained, "timeout scheduler exception escaped the plugin boundary")
assert(online_calls == online_calls_before_scheduler_failure,
    "network manager ran without a recoverable wait timeout")
assert(plugin.network_wait == nil, "scheduler failure left the waiting gate active")
assert(infos[#infos]:find("无法启动安全的网络操作", 1, true),
    "scheduler failure did not use the fixed recovery message")
scheduler_mode = "success"

local parser_detail = plugin:parser_failure_message(
    "解析目录失败", "目录结构无效", "请稍后重试；若持续出现，请检查插件更新。")
assert(parser_detail:find("解析目录失败：目录结构无效", 1, true),
    "parser failure did not identify the operation and reason")
assert(parser_detail:find("本地书架、阅读进度和缓存没有改变", 1, true),
    "parser failure did not explain local data safety")
assert(parser_detail:find("请稍后重试", 1, true),
    "parser failure did not provide the requested next action")

local parser_detail_tostring_calls = 0
local unsafe_parser_detail = setmetatable({}, { __tostring = function()
    parser_detail_tostring_calls = parser_detail_tostring_calls + 1
    return credential_canary
end })
local fixed_parser_detail = plugin:parser_failure_message(
    "解析官方内容失败", unsafe_parser_detail, unsafe_parser_detail)
assert(fixed_parser_detail:find("未返回可安全显示的失败原因", 1, true),
    "unsafe parser reason did not use a fixed fallback")
assert(fixed_parser_detail:find("请返回本地书架后重试", 1, true),
    "unsafe parser next action did not use a fixed fallback")
assert(not fixed_parser_detail:find(credential_canary, 1, true),
    "unsafe parser failure exposed the canary")
assert(parser_detail_tostring_calls == 0, "unsafe parser failure invoked __tostring")

local original_network_get = NetworkTask.get
local original_extract_initial_state = Parser.extract_initial_state
NetworkTask.get = function() return "<html>changed</html>" end
Parser.extract_initial_state = function() return nil, "页面缺少 INITIAL_STATE" end
plugin:with_network(function() plugin:load_book("1234567890") end)
local book_parse_failure = infos[#infos]
assert(book_parse_failure:find("解析书籍页面失败", 1, true),
    "book parsing call site did not identify the operation")
assert(book_parse_failure:find("本地书架、阅读进度和缓存没有改变", 1, true),
    "book parsing call site did not explain local data safety")
assert(book_parse_failure:find("确认链接仍可在番茄官网打开", 1, true),
    "book parsing call site did not provide an actionable next step")
NetworkTask.get = original_network_get
Parser.extract_initial_state = original_extract_initial_state

local original_decode_json = Parser.decode_json
local original_book_from_state = Parser.book_from_state
local original_directory_from_payload = Parser.directory_from_payload
local original_library_upsert = Library.upsert
local original_save_state = plugin.save_state
local directory_decode_calls = 0
local directory_upsert_calls = 0
local directory_save_calls = 0
local old_chapters = {{ id = "10000000001", title = "旧目录第一章" }}
plugin.library = { books = {{
    id = "1234567890",
    title = "旧书名",
    chapters = old_chapters,
}} }
NetworkTask.get = function() return "{}" end
Parser.extract_initial_state = function() return "{}" end
Parser.decode_json = function()
    directory_decode_calls = directory_decode_calls + 1
    if directory_decode_calls == 1 then return { page = "book" } end
    return { data = { chapterList = {} } }
end
Parser.book_from_state = function()
    return { id = "1234567890", title = "官网新书名", author = "作者" }
end
Parser.directory_from_payload = function()
    return nil, "目录章节数量超过 10000 章安全上限，已停止更新"
end
Library.upsert = function()
    directory_upsert_calls = directory_upsert_calls + 1
    return nil, "must not update"
end
plugin.save_state = function()
    directory_save_calls = directory_save_calls + 1
    return true
end
plugin:with_network(function() plugin:refresh_book("1234567890") end)
local directory_limit_failure = infos[#infos]
assert(directory_limit_failure:find("解析目录失败", 1, true),
    "directory limit did not identify the stopped operation")
assert(directory_limit_failure:find("10000 章安全上限", 1, true),
    "directory limit did not explain the fixed boundary")
assert(directory_limit_failure:find("本地书架、阅读进度和缓存没有改变", 1, true),
    "directory limit did not explain local data safety")
assert(directory_limit_failure:find("稍后重试", 1, true),
    "directory limit did not provide an actionable next step")
assert(directory_upsert_calls == 0 and directory_save_calls == 0,
    "oversized directory reached a local mutation boundary")
assert(plugin.library.books[1].title == "旧书名"
        and plugin.library.books[1].chapters == old_chapters
        and #plugin.library.books[1].chapters == 1,
    "oversized directory changed the existing local record")
NetworkTask.get = original_network_get
Parser.extract_initial_state = original_extract_initial_state
Parser.decode_json = original_decode_json
Parser.book_from_state = original_book_from_state
Parser.directory_from_payload = original_directory_from_payload
Library.upsert = original_library_upsert
plugin.save_state = original_save_state

NetworkTask.get = function() return "{}" end
Parser.decode_json = function() return nil, "官方响应格式发生变化" end
plugin:with_network(function()
    plugin:search_books("https://fanqienovel.com/api/search", "测试")
end)
local search_parse_failure = infos[#infos]
assert(search_parse_failure:find("解析搜索结果失败", 1, true),
    "search parsing call site did not identify the operation")
assert(search_parse_failure:find("改用番茄官网书籍链接", 1, true),
    "search parsing call site did not provide its safe fallback")
NetworkTask.get = original_network_get
Parser.decode_json = original_decode_json

NetworkTask.get = function() return "<html>changed chapter</html>" end
Parser.extract_initial_state = function() return nil, "页面状态 JSON 不完整" end
plugin.library = { books = {{
    id = "1234567890",
    chapters = {{ id = "10000000001", title = "第一章" }},
}} }
plugin.storage = { cached_chapter = function() return nil end }

local unsafe_cache_network_calls = 0
plugin.storage.cached_chapter = function()
    return nil, "缓存目录超出插件安全范围，已拒绝操作", false
end
NetworkTask.get = function()
    unsafe_cache_network_calls = unsafe_cache_network_calls + 1
    return nil, "must not fetch"
end
plugin:open_chapter("1234567890", 1)
local unsafe_cache_failure = infos[#infos]
assert(unsafe_cache_network_calls == 0,
    "unsafe cache boundary started a network recovery request")
assert(unsafe_cache_failure:find("无法安全检查本地缓存", 1, true),
    "unsafe cache boundary did not identify the stopped operation")
assert(unsafe_cache_failure:find("没有改变", 1, true),
    "unsafe cache boundary did not explain local data safety")
assert(unsafe_cache_failure:find("重启 KOReader", 1, true),
    "unsafe cache boundary did not provide a recovery action")

local recoverable_loading_label
plugin.storage.cached_chapter = function()
    return nil, "章节缓存不完整", true
end
NetworkTask.get = function(_, _, label)
    recoverable_loading_label = label
    return nil, "联网恢复失败；本地数据没有改变。"
end
plugin:open_chapter("1234567890", 1)
assert(recoverable_loading_label
        and recoverable_loading_label:find("缓存损坏", 1, true),
    "recoverable damaged cache did not start the safe network rebuild path")

plugin.storage.cached_chapter = function() return nil end
NetworkTask.get = function() return "<html>changed chapter</html>" end
plugin:open_chapter("1234567890", 1)
local chapter_parse_failure = infos[#infos]
assert(chapter_parse_failure:find("解析章节失败", 1, true),
    "chapter parsing call site did not identify the operation")
assert(chapter_parse_failure:find("本地书架、阅读进度和缓存没有改变", 1, true),
    "chapter parsing call site did not explain local data safety")
assert(chapter_parse_failure:find("需要登录或解锁时请使用番茄官方客户端", 1, true),
    "chapter parsing call site did not preserve the platform boundary")
NetworkTask.get = original_network_get
Parser.extract_initial_state = original_extract_initial_state

local no_directory = plugin:book_local_status({ chapters = {} }, 0, 1000)
assert(no_directory:find("尚未获取目录", 1, true), "missing directory state not explained")
assert(no_directory:find("首次阅读需要联网", 1, true), "first online requirement missing")

local local_status = plugin:book_local_status({
    chapters = { {}, {} }, directory_updated_at = 500,
}, 1, 1000)
assert(local_status:find("目录 2 章", 1, true), "directory count missing")
assert(local_status:find("缓存文件 1 个", 1, true), "cache count missing")
assert(local_status:find("离线仅能打开完整缓存", 1, true), "offline boundary missing")
assert(not local_status:find("未知", 1, true), "valid directory time reported as unknown")

local unreadable_cache = plugin:book_local_status({
    chapters = { {} }, directory_updated_at = 500,
}, nil, 1000)
assert(unreadable_cache:find("缓存状态不可读", 1, true), "unreadable cache state hidden")

local unknown_time = plugin:book_local_status({ chapters = { {} } }, 0, 1000)
assert(unknown_time:find("下次联网刷新后记录", 1, true), "legacy timestamp fallback missing")

local future_time = plugin:book_local_status({
    chapters = { {} }, directory_updated_at = 90000,
}, 0, 1000)
assert(future_time:find("设备时间异常", 1, true), "future device timestamp not rejected")

local cache_tostring_calls = 0
plugin:show_cache_prune_warning(setmetatable({}, { __tostring = function()
    cache_tostring_calls = cache_tostring_calls + 1
    return credential_canary
end }))
local prune_warning = infos[#infos]
assert(prune_warning:find("章节已保存", 1, true), "successful chapter write was hidden")
assert(prune_warning:find("旧缓存自动清理未完成", 1, true), "cache prune warning heading missing")
assert(prune_warning:find("书架和当前章节没有损坏", 1, true), "cache safety state missing")
assert(prune_warning:find("清理章节缓存", 1, true), "cache warning has no next action")
assert(prune_warning:find("可安全显示", 1, true), "unsafe cache warning did not use fixed detail")
assert(not prune_warning:find(credential_canary, 1, true), "cache warning leaked raw content")
assert(cache_tostring_calls == 0, "cache warning invoked __tostring")

local export_tostring_calls = 0
Export.write = function()
    return nil, setmetatable({}, { __tostring = function()
        export_tostring_calls = export_tostring_calls + 1
        return credential_canary
    end })
end
plugin.library = { books = {} }
plugin:write_local_export("/mnt/us/fanqielite-bookshelf.json")
local export_failure = infos[#infos]
assert(export_failure:find("可安全显示", 1, true), "unsafe export error did not use fixed detail")
assert(not export_failure:find(credential_canary, 1, true), "export UI leaked raw content")
assert(export_tostring_calls == 0, "export UI invoked __tostring")

local import_tostring_calls = 0
Import.read_file = function()
    return nil, setmetatable({}, { __tostring = function()
        import_tostring_calls = import_tostring_calls + 1
        return credential_canary
    end })
end
plugin:prepare_file_import("/mnt/us/fanqielite-bookshelf.json")
local import_failure = infos[#infos]
assert(import_failure:find("可安全显示", 1, true), "unsafe import error did not use fixed detail")
assert(not import_failure:find(credential_canary, 1, true), "import UI leaked raw content")
assert(import_tostring_calls == 0, "import UI invoked __tostring")

print("network flow tests passed")

package.path = "./?.lua;./?/init.lua;" .. package.path

local online_calls, wrap_calls, reset_calls = 0, 0, 0
local infos = {}
local network_error
local credential_canary = "COOKIE_SESSION_TOKEN_CANARY_4d91"
local tostring_calls = 0

local NetworkMgr = {
    runWhenOnline = function(_, callback)
        online_calls = online_calls + 1
        callback()
    end,
}

local Trapper = {
    wrap = function(_, callback)
        wrap_calls = wrap_calls + 1
        callback()
    end,
    reset = function()
        reset_calls = reset_calls + 1
    end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local NetworkTask = {
    get = function() return nil, network_error end,
}

local Parser = {
    book_id = function(value) return value end,
}

local stubs = {
    ["ui/widget/confirmbox"] = {},
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
    ["ui/uimanager"] = {},
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.import"] = {},
    ["fanqielite.library"] = {},
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
plugin:with_network(function() plugin:load_book("1234567890") end)
local cancelled = infos[#infos]
assert(cancelled:find("操作未完成", 1, true), "cancellation did not use the safe failure heading")
assert(cancelled:find("操作已取消", 1, true), "cancellation reason was lost")
assert(cancelled:find("没有改变", 1, true), "cancellation safety detail was lost")
assert(not cancelled:find("test_network_flow.lua", 1, true), "cancellation leaked a Lua file path")
assert(plugin.network_busy == false, "network gate remained active after cancellation")

network_error = setmetatable({}, { __tostring = function()
    tostring_calls = tostring_calls + 1
    return credential_canary
end })
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
assert(reset_calls == 5, "Trapper was not reset after every completed wrapper")

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

plugin:show_cache_prune_warning("2 个旧缓存无法删除：read-only filesystem")
local prune_warning = infos[#infos]
assert(prune_warning:find("章节已保存", 1, true), "successful chapter write was hidden")
assert(prune_warning:find("旧缓存自动清理未完成", 1, true), "cache prune warning heading missing")
assert(prune_warning:find("书架和当前章节没有损坏", 1, true), "cache safety state missing")
assert(prune_warning:find("清理章节缓存", 1, true), "cache warning has no next action")
assert(prune_warning:find("read%-only filesystem"), "cache prune reason missing")

print("network flow tests passed")

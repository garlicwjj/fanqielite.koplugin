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

local take_calls, touch_calls = 0, 0
local Library = {
    take_imported_position = function(_, _, has_local_position)
        take_calls = take_calls + 1
        assert(has_local_position == true, "sidecar result was not forwarded")
        return nil, false
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
local save_calls = 0
local plugin = setmetatable({
    library = { books = {} },
    save_state = function()
        save_calls = save_calls + 1
        return true
    end,
}, { __index = FanqieLite })
local book = { id = "7134567890123456789", chapters = {{ id = "7134567890123456701" }} }

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
assert(take_calls == 0 and touch_calls == 0 and save_calls == 0,
    "sidecar inspection failure changed reading state")

sidecar_mode = "present"
local normal_ready = assert(plugin:prepare_chapter_open(book, 1, "/safe/cache.xhtml"))
assert(normal_ready == true, "normal sidecar inspection did not prepare the chapter")
assert(take_calls == 1 and touch_calls == 1 and save_calls == 1,
    "normal chapter preparation lifecycle changed")

print("chapter open flow tests passed")

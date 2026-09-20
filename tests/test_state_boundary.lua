package.path = "./?.lua;./?/init.lua;" .. package.path

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do output[copy(key, seen)] = copy(child, seen) end
    return output
end

local Library = {
    find = function(library, book_id)
        for _, book in ipairs(library.books or {}) do
            if book.id == book_id then return book end
        end
    end,
    load = function(library) return copy(library) end,
}

local persistence_error
local persistence_state
local persistence_tostring_calls = 0
local plugin
local import_path_value = "/mnt/us"

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
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
    ["fanqielite.persistence"] = {
        copy = copy,
        equal = function() return false end,
        write = function() return nil, persistence_error, persistence_state end,
    },
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = {},
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
plugin = setmetatable({
    settings = {
        file = "/mock/fanqielite.lua",
        data = {},
        readSetting = function(_, key)
            if key == "import_path" then return import_path_value end
            return plugin and plugin.settings.data[key]
        end,
    },
    library = {
        version = 1,
        sort = "recent",
        books = {{
            id = "70000000001", title = "本地书籍", author = "测试作者",
            chapters = {{ id = "71000000001", title = "第一章" }}, current_index = 1,
        }},
    },
    active_book_id = "70000000001",
    ephemeral_session = {
        cookie = canary,
        sessionid = canary,
        csrf_token = canary,
        authorization = canary,
        qr_payload = canary,
    },
}, { __index = FanqieLite })

local state = plugin:state_table()
local allowed_top = {
    library = true, active_book_id = true, book = true,
    chapters = true, current_index = true, import_path = true,
}
for key in pairs(state) do assert(allowed_top[key], "unexpected persisted top-level field: " .. tostring(key)) end

local function inspect(value, seen)
    if value == canary then error("ephemeral credential value reached persisted state") end
    if type(value) ~= "table" then return end
    seen = seen or {}
    if seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
        local normalized = type(key) == "string" and key:lower():gsub("[^%a%d]", "") or ""
        assert(not normalized:find("cookie", 1, true), "cookie field reached persisted state")
        assert(not normalized:find("session", 1, true), "session field reached persisted state")
        assert(not normalized:find("csrf", 1, true), "csrf field reached persisted state")
        assert(not normalized:find("authorization", 1, true), "authorization field reached persisted state")
        assert(not normalized:find("token", 1, true), "token field reached persisted state")
        inspect(child, seen)
    end
end
inspect(state)
assert(plugin.ephemeral_session.cookie == canary, "state projection mutated the in-memory session")

import_path_value = "/mnt/us/unsafe\127directory"
local unsafe_path_state = plugin:state_table()
assert(unsafe_path_state.import_path == nil,
    "DEL control character reached persisted import directory")
import_path_value = "/mnt/us"

plugin.persisted_settings = copy(state)
plugin.settings.data = copy(state)
plugin.library.books[1].title = "未保存的新标题"
persistence_error = setmetatable({}, { __tostring = function()
    persistence_tostring_calls = persistence_tostring_calls + 1
    return canary
end })
local saved, save_err = plugin:save_state(true)
assert(saved == nil, "unsafe persistence error reported as success")
assert(save_err:find("无法安全保存插件设置", 1, true), "save failure heading missing")
assert(save_err:find("可安全显示", 1, true), "unsafe persistence error did not use fixed detail")
assert(not save_err:find(canary, 1, true), "unsafe persistence error leaked raw content")
assert(persistence_tostring_calls == 0, "unsafe persistence error invoked __tostring")
assert(plugin.library.books[1].title == "本地书籍", "failed save did not restore persisted library")

plugin.library.books[1].title = "磁盘状态未知的新标题"
persistence_error = "主设置已替换，但恢复上一版失败"
persistence_state = "uncertain"
local uncertain_saved, uncertain_save_err = plugin:save_state(true)
persistence_state = nil
assert(uncertain_saved == nil, "uncertain disk state reported save success")
assert(uncertain_save_err:find("磁盘上的主设置文件可能已经改变", 1, true),
    "uncertain disk state did not disclose the possible replacement")
assert(uncertain_save_err:find("停止继续操作", 1, true)
        and uncertain_save_err:find("重启 KOReader", 1, true),
    "uncertain disk state did not provide a safe recovery action")
assert(not uncertain_save_err:find("上一版设置仍被保留", 1, true),
    "uncertain disk state falsely promised the previous settings")
assert(plugin.library.books[1].title == "本地书籍",
    "uncertain save did not restore the in-memory persisted library")

print("state boundary tests passed")

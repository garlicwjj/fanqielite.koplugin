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

local raw_settings = {
    library = {
        version = 1,
        books = {
            [1] = {
                id = "7134567890123456789", title = "恢复测试一", chapters = {
                    [1] = { id = "50000000001", title = "第一章" },
                    [3] = { id = "50000000003", title = "第三章" },
                },
                imported_progress = {
                    chapter_id = "50000000001", chapter_title = "第一章", position = 0 / 0,
                },
            },
            [3] = { id = "7134567890123456790", title = "恢复测试二", chapters = {} },
        },
    },
    active_book_id = "7134567890123456790",
    unknown_startup_field = "must remain in the pre-migration backup",
}

local settings = {
    file = "/mock/fanqielite.lua",
    data = copy(raw_settings),
    readSetting = function(self, key) return self.data[key] end,
}
local written_candidate, written_previous, persistence_failure

local function has_sensitive_fields(value, seen)
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, child in pairs(value) do
        if type(key) == "string" then
            local normalized = key:lower():gsub("[^%a%d]", "")
            if normalized:find("cookie", 1, true)
                    or normalized:find("session", 1, true)
                    or normalized:find("token", 1, true)
                    or normalized:find("authorization", 1, true) then
                return true
            end
        end
        if has_sensitive_fields(child, seen) then return true end
    end
    return false
end

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = { getSettingsDir = function() return "/mock" end },
    device = {},
    dispatcher = { registerAction = function() end },
    docsettings = {},
    ["ui/event"] = {},
    ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = {},
    logger = {},
    luasettings = { open = function() return settings end },
    ["ui/widget/menu"] = {},
    ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {},
    ["ui/uimanager"] = { nextTick = function(_, callback) callback() end },
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.import"] = {},
    ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {},
    ["fanqielite.persistence"] = {
        copy = copy,
        equal = function() return false end,
        has_sensitive_fields = has_sensitive_fields,
        write = function(_, candidate, previous)
            written_candidate = copy(candidate)
            written_previous = copy(previous)
            if persistence_failure then return nil, persistence_failure end
            return true
        end,
    },
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = { new = function() return {} end },
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local plugin = setmetatable({
    ui = { menu = { registerToMainMenu = function() end } },
    info = function() end,
}, { __index = FanqieLite })
plugin:init()

assert(written_candidate, "startup normalization was not saved")
assert(#written_candidate.library.books == 2, "startup normalization lost a sparse book")
assert(#written_candidate.library.books[1].chapters == 2,
    "startup normalization lost a sparse chapter")
assert(written_candidate.library.books[1].imported_progress.position == nil,
    "startup normalization retained an invalid imported position")
assert(written_candidate.active_book_id == "7134567890123456790",
    "startup normalization changed a recoverable active book")
assert(written_previous, "startup normalization did not create a previous-state backup")
assert(written_previous.unknown_startup_field == raw_settings.unknown_startup_field,
    "startup backup did not preserve the raw settings object")
assert(written_previous.library.books[3].id == "7134567890123456790",
    "startup backup did not preserve the original sparse layout")
local backed_up_position = written_previous.library.books[1].imported_progress.position
assert(backed_up_position ~= backed_up_position,
    "startup backup did not preserve the raw invalid imported position")

local credential_canary = "FANQIELITE_STARTUP_CREDENTIAL_CANARY_82ad"
local unsafe_settings = copy(written_candidate)
unsafe_settings.sessionid = credential_canary
unsafe_settings.library.books[1].auth_headers = { Cookie = credential_canary }
settings.data = unsafe_settings
written_candidate, written_previous = nil, nil

local unsafe_plugin = setmetatable({
    ui = { menu = { registerToMainMenu = function() end } },
    info = function() end,
}, { __index = FanqieLite })
unsafe_plugin:init()

assert(written_candidate, "credential-bearing loaded settings were not sanitized")
assert(written_candidate.sessionid == nil,
    "top-level credential reached sanitized startup settings")
assert(written_candidate.library.books[1].auth_headers == nil,
    "nested credential reached sanitized startup settings")
assert(written_previous,
    "credential-bearing loaded settings did not replace the previous backup safely")
assert(written_previous.sessionid == nil,
    "top-level credential reached sanitized startup backup")
assert(written_previous.library.books[1].auth_headers == nil,
    "nested credential reached sanitized startup backup")
assert(unsafe_plugin.persisted_settings.sessionid == nil,
    "credential remained reachable from persisted startup state")
assert(unsafe_plugin.settings.data.sessionid == nil,
    "credential remained reachable from active settings state")
assert(unsafe_plugin.startup_sensitive_cleanup == nil,
    "successful startup cleanup retained a sensitive-cleanup flag")

settings.data = copy(unsafe_settings)
written_candidate, written_previous = nil, nil
persistence_failure = "无法原子替换设置文件"
local failed_cleanup_plugin = setmetatable({
    ui = { menu = { registerToMainMenu = function() end } },
    info = function() end,
}, { __index = FanqieLite })
failed_cleanup_plugin:init()
persistence_failure = nil

assert(failed_cleanup_plugin.startup_save_error
        and failed_cleanup_plugin.startup_save_error:find("无法完成安全清理", 1, true),
    "failed credential cleanup did not explain the startup risk")
assert(failed_cleanup_plugin.startup_save_error:find("原设置文件可能仍未更新", 1, true),
    "failed credential cleanup claimed the disk copy was clean")
assert(not failed_cleanup_plugin.startup_save_error:find(credential_canary, 1, true),
    "failed credential cleanup leaked the canary")
assert(written_previous and written_previous.sessionid == nil,
    "failed credential cleanup attempted to back up the unsafe settings")
assert(failed_cleanup_plugin.settings.data.sessionid == nil,
    "failed credential cleanup restored unsafe settings into active memory")

print("startup recovery tests passed")

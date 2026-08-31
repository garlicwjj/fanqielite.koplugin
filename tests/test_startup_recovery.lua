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
local written_candidate, written_previous

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
        write = function(_, candidate, previous)
            written_candidate = copy(candidate)
            written_previous = copy(previous)
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
assert(written_candidate.active_book_id == "7134567890123456790",
    "startup normalization changed a recoverable active book")
assert(written_previous, "startup normalization did not create a previous-state backup")
assert(written_previous.unknown_startup_field == raw_settings.unknown_startup_field,
    "startup backup did not preserve the raw settings object")
assert(written_previous.library.books[3].id == "7134567890123456790",
    "startup backup did not preserve the original sparse layout")

print("startup recovery tests passed")

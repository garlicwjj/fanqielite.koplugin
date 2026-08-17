package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, queued
local log_messages = {}
local PathChooser = {}
function PathChooser:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    tickAfterNext = function(_, callback) queued = callback end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

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
    logger = { info = function(message) log_messages[#log_messages + 1] = message end },
    luasettings = {},
    ["ui/widget/menu"] = {},
    ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = PathChooser,
    ["ui/trapper"] = {},
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.import"] = { FILENAME = "fanqielite-bookshelf.json" },
    ["fanqielite.library"] = {},
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
local selected
local plugin = setmetatable({
    settings = { readSetting = function() return nil end },
    prepare_file_import = function(_, path) selected = path end,
}, { __index = FanqieLite })

plugin:choose_import_file()
assert(shown and shown.onConfirm, "file chooser was not shown")
shown.onConfirm("/mnt/us/fanqielite-bookshelf.json")
assert(selected == nil, "import confirmation must wait until PathChooser closes")
assert(type(queued) == "function", "import confirmation was not queued after the next UI tick")
queued()
assert(selected == "/mnt/us/fanqielite-bookshelf.json", "queued import path was not preserved")
assert(#log_messages == 2, "chooser flow did not emit the expected fixed stage markers")
for _, message in ipairs(log_messages) do
    assert(not message:find("/mnt/", 1, true), "stage log leaked the selected path")
    assert(not message:lower():find("cookie", 1, true), "stage log mentioned credential material")
    assert(not message:lower():find("token", 1, true), "stage log mentioned credential material")
    assert(not message:lower():find("session", 1, true), "stage log mentioned credential material")
end

print("import flow tests passed")

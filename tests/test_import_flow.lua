package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, queued
local PathChooser = {}
function PathChooser:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    nextTick = function(_, callback) queued = callback end,
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
assert(type(queued) == "function", "import confirmation was not queued for the next UI tick")
queued()
assert(selected == "/mnt/us/fanqielite-bookshelf.json", "queued import path was not preserved")

print("import flow tests passed")

package.path = "./?.lua;./?/init.lua;" .. package.path

local shown, queued
local log_messages = {}
local PathChooser = {}
function PathChooser:new(options) return options end

local UIManager = {
    show = function(_, widget) shown = widget end,
    tickAfterNext = function(_, callback) queued = callback end,
    nextTick = function(_, callback) callback() end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local Library = {
    import_books = function() return 1, 0 end,
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

local remembered_directory, save_calls, home_shown = nil, 0, false
local import_message
local import_plugin = setmetatable({
    settings = {
        saveSetting = function(_, key, value)
            assert(key == "import_path", "unexpected setting changed during import")
            remembered_directory = value
        end,
    },
    library = { version = 1, books = {} },
    save_state = function() save_calls = save_calls + 1; return true end,
    info = function(_, message) import_message = message end,
    show_home = function() home_shown = true end,
}, { __index = FanqieLite })
local imported_books = {{ id = "7633875868615461950" }}

import_plugin:apply_file_import(
    "/mnt/us/unsafe\127directory/fanqielite-bookshelf.json", imported_books)
assert(remembered_directory == nil,
    "unsafe selected directory replaced the remembered import path")
assert(save_calls == 1, "safe bookshelf state was not saved after ignoring an unsafe directory")
assert(import_message and import_message:find("导入完成", 1, true),
    "unsafe remembered directory incorrectly failed the validated bookshelf import")
assert(home_shown, "successful import did not return to the local bookshelf")

import_plugin:apply_file_import(
    "/mnt/us/safe-books/fanqielite-bookshelf.json", imported_books)
assert(remembered_directory == "/mnt/us/safe-books",
    "safe selected directory was not remembered")
assert(save_calls == 2, "safe remembered directory was not saved with the bookshelf")

print("import flow tests passed")

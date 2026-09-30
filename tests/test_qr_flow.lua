package.path = "./?.lua;./?/init.lua;" .. package.path

local Library = require("fanqielite.library")
local Session = require("fanqielite.ephemeral_session")

local shown, dismissed, info_message, home_calls = nil, nil, nil, 0
local ConfirmBox = {}
function ConfirmBox:new(options) return options end
local Menu = {}
function Menu:new(options) return options end
local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end
local UIManager = {
    show = function(_, widget) shown = widget end,
    nextTick = function(_, callback) callback() end,
}

local stubs = {
    ["ui/widget/confirmbox"] = ConfirmBox,
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
    ["ui/widget/menu"] = Menu,
    ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {},
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {},
    ["fanqielite.persistence"] = {},
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = {},
}
for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local QrTask = {}
function QrTask.begin()
    return {
        qr_payload = "https://reading.snssdk.com/ucenter_web/app/sdk-next?token=test",
        poll_ticket = "bounded-poll-ticket",
        expires_at = os.time() + 60,
    }
end
function QrTask.finish(ticket)
    assert(ticket == "bounded-poll-ticket")
    return {{
        id = "7134567890123456789",
        title = "扫码导入测试书",
        author = "测试作者",
        cover_url = "https://example.invalid/cover.jpg",
        imported_progress = {
            chapter_id = "7134567890123456701",
            chapter_title = "第一章",
        },
    }}, { logout_ok = true, progress_found = true }
end
package.preload["fanqielite.qr_import_task"] = function() return QrTask end

local QRDisplay = {}
function QRDisplay.new()
    return { show = function(_, payload, timeout, callback)
        assert(payload:find("reading.snssdk.com", 1, true))
        assert(timeout >= 1 and timeout <= 60)
        dismissed = callback
        return true
    end }
end
package.preload["fanqielite.qrdisplay"] = function() return QRDisplay end

local FanqieLite = assert(loadfile("main.lua"))()
local plugin = setmetatable({
    library = Library.new(),
    qr_session = Session.new(),
    with_network = function(_, callback) callback() end,
    save_state = function() return true end,
    info = function(_, message) info_message = message end,
    show_home = function() home_calls = home_calls + 1 end,
}, { __index = FanqieLite })

plugin:show_qr_import_status()
assert(shown.text:find("不写入设置、缓存或日志", 1, true))
assert(shown.ok_text == "显示二维码")
shown.ok_callback()
assert(type(dismissed) == "function", "QR was not displayed")
assert(plugin.qr_session:status().state == "qr_pending")

dismissed()
assert(shown.text:find("新增 1 本，更新 0 本", 1, true))
assert(shown.text:find("账号凭证已从插件内存中清除", 1, true))
assert(plugin.qr_session:status().state == "ready_to_confirm")
shown.ok_callback()

assert(#plugin.library.books == 1 and plugin.library.books[1].title == "扫码导入测试书")
assert(plugin.library.books[1].imported_progress.chapter_id == "7134567890123456701")
assert(plugin.qr_session:status().state == "done")
assert(info_message:find("扫码导入完成", 1, true))
assert(home_calls == 1, "successful import did not return to the local bookshelf")

print("QR flow tests passed")

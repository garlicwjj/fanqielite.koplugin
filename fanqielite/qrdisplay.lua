local Device = require("device")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")

local QRDisplay = {}
QRDisplay.__index = QRDisplay

-- KOReader 2026.03 QRWidget silently truncates after 2953 bytes. Keep a lower
-- explicit limit so an authorization payload is either exact or not shown.
QRDisplay.MAX_BYTES = 2048
QRDisplay.MAX_TIMEOUT = 5 * 60

local function notify(callback, reason)
    if type(callback) == "function" then pcall(callback, reason) end
end

function QRDisplay.new()
    return setmetatable({}, QRDisplay)
end

function QRDisplay:status()
    return { visible = self._message ~= nil }
end

function QRDisplay:show(payload, timeout, on_dismiss)
    if self._message then return nil, "已有二维码正在显示，请先关闭" end
    if type(payload) ~= "string" or payload == ""
            or payload:find("[%z\1-\31\127]") then
        return nil, "二维码内容无效，未显示任何二维码"
    end
    if #payload > QRDisplay.MAX_BYTES then
        return nil, "二维码内容过长，为避免截断已拒绝显示"
    end
    timeout = tonumber(timeout)
    if not timeout or timeout ~= timeout or timeout < 1
            or timeout > QRDisplay.MAX_TIMEOUT then
        return nil, "二维码有效时间无效，未显示任何二维码"
    end

    local message
    local function dismissed()
        if self._message ~= message then return end
        self._message = nil
        self._on_dismiss = nil
        message.text = nil
        message.dismiss_callback = nil
        notify(on_dismiss, "dismissed")
    end
    local constructed, result = pcall(function()
        return QRMessage:new{
            text = payload,
            width = Device.screen:getWidth(),
            height = Device.screen:getHeight(),
            timeout = timeout,
            dismiss_callback = dismissed,
        }
    end)
    if not constructed or type(result) ~= "table" then
        return nil, "无法生成二维码；本地书架和账号状态没有改变"
    end
    message = result
    self._message = message
    self._on_dismiss = on_dismiss
    local displayed = pcall(UIManager.show, UIManager, message)
    if not displayed then
        self._message = nil
        self._on_dismiss = nil
        message.text = nil
        message.dismiss_callback = nil
        if type(message.free) == "function" then pcall(message.free, message) end
        return nil, "无法显示二维码；本地书架和账号状态没有改变"
    end
    return true
end

function QRDisplay:hide(reason)
    local message = self._message
    if not message then return true end
    local callback = self._on_dismiss
    local widget_callback = message.dismiss_callback
    message.text = nil
    message.dismiss_callback = nil
    local closed = pcall(UIManager.close, UIManager, message)
    if not closed then
        message.dismiss_callback = widget_callback
        return nil, "无法关闭二维码，请重试或退出 KOReader"
    end
    self._message = nil
    self._on_dismiss = nil
    notify(callback, reason or "closed")
    return true
end

return QRDisplay

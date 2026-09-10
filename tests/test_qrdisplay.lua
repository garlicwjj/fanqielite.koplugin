package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_SYNTHETIC_QR_CANARY"
local constructed, shown, closed = {}, {}, {}
local construct_error, show_error, close_error = false, false, false

package.preload["device"] = function()
    return { screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
    } }
end

package.preload["ui/widget/qrmessage"] = function()
    local QRMessage = {}
    function QRMessage:new(options)
        if construct_error then error("construct " .. canary) end
        options.free = function(self)
            self.freed = true
            self.text = nil
        end
        constructed[#constructed + 1] = options
        return options
    end
    return QRMessage
end

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, message)
            if show_error then error("show " .. canary) end
            shown[#shown + 1] = message
        end,
        close = function(_, message)
            if close_error then error("close " .. canary) end
            closed[#closed + 1] = message
        end,
    }
end

local QRDisplay = require("fanqielite.qrdisplay")

local function contains(value, needle, seen)
    if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, child in pairs(value) do
        if contains(key, needle, seen) or contains(child, needle, seen) then return true end
    end
    return false
end

local display = QRDisplay.new()
local dismiss_count, dismiss_reason = 0
local payload = "https://passport.example.invalid/qr?ticket=" .. canary
assert(display:show(payload, 30, function(reason)
    dismiss_count = dismiss_count + 1
    dismiss_reason = reason
end))
assert(display:status().visible == true, "display did not report visible QR")
local message = constructed[#constructed]
assert(message == shown[#shown], "constructed QR was not shown")
assert(message.text == payload, "QR payload changed before display")
assert(message.width == 1072 and message.height == 1448, "QR did not use the full screen")
assert(message.timeout == 30, "QR expiry was not passed to KOReader")

local duplicate, duplicate_err = display:show("https://example.invalid/other", 10)
assert(duplicate == nil and duplicate_err:find("正在显示", 1, true), "parallel QR accepted")
assert(message.text == payload, "parallel QR replaced the active payload")

assert(display:hide("cancelled"))
assert(display:status().visible == false, "hide left QR visible")
assert(message.text == nil and message.dismiss_callback == nil, "hide retained QR text or callback")
assert(closed[#closed] == message, "hide did not close the KOReader widget")
assert(dismiss_count == 1 and dismiss_reason == "cancelled", "hide callback result missing")
assert(not contains(display, canary), "hide retained QR canary in display adapter")
assert(display:hide("cancelled"), "repeated hide was not idempotent")
assert(dismiss_count == 1, "repeated hide repeated callback")

-- Tap, key press, or KOReader timeout all close QRMessage through its own
-- dismiss callback. The adapter must drop its payload and report one dismissal.
local passive = QRDisplay.new()
local passive_count, passive_reason = 0
assert(passive:show(payload, 20, function(reason)
    passive_count = passive_count + 1
    passive_reason = reason
end))
local passive_message = constructed[#constructed]
assert(type(passive_message.dismiss_callback) == "function")
passive_message.dismiss_callback()
assert(passive:status().visible == false, "KOReader dismissal left adapter active")
assert(passive_message.text == nil and passive_message.dismiss_callback == nil,
    "KOReader dismissal retained QR text or callback")
assert(passive_count == 1 and passive_reason == "dismissed", "passive dismissal not reported")
assert(not contains(passive, canary), "passive dismissal retained QR canary")

-- Reject anything KOReader might silently truncate, as well as empty/control
-- text and invalid timeouts, before constructing a QR widget.
local rejected = QRDisplay.new()
local constructed_before = #constructed
local invalid_cases = {
    { "", 10, "二维码内容无效" },
    { "https://example.invalid/\nnext", 10, "二维码内容无效" },
    { string.rep("x", QRDisplay.MAX_BYTES + 1), 10, "二维码内容过长" },
    { "https://example.invalid", 0, "有效时间无效" },
    { "https://example.invalid", QRDisplay.MAX_TIMEOUT + 1, "有效时间无效" },
}
for _, case in ipairs(invalid_cases) do
    local ok, err = rejected:show(case[1], case[2])
    assert(ok == nil and err:find(case[3], 1, true), "invalid QR input accepted")
    assert(not err:find(canary, 1, true), "invalid QR error leaked canary")
end
assert(#constructed == constructed_before, "invalid input constructed a QR widget")

construct_error = true
local construct_failed, construct_err = rejected:show(payload, 10)
construct_error = false
assert(construct_failed == nil and construct_err:find("无法生成", 1, true), "construction error escaped")
assert(not construct_err:find(canary, 1, true), "construction error leaked canary")
assert(not contains(rejected, canary), "construction failure retained QR canary")

show_error = true
local show_failed, show_err = rejected:show(payload, 10)
show_error = false
local failed_message = constructed[#constructed]
assert(show_failed == nil and show_err:find("无法显示", 1, true), "show error escaped")
assert(not show_err:find(canary, 1, true), "show error leaked canary")
assert(failed_message.freed and failed_message.text == nil, "show failure did not free QR widget")
assert(not contains(rejected, canary), "show failure retained QR canary")

-- If KOReader cannot close the widget, keep a handle so the caller can retry;
-- do not falsely report dismissal or echo the underlying exception.
local retry = QRDisplay.new()
local retry_callbacks = 0
assert(retry:show(payload, 10, function() retry_callbacks = retry_callbacks + 1 end))
close_error = true
local close_failed, close_err = retry:hide("cancelled")
close_error = false
assert(close_failed == nil and close_err:find("无法关闭", 1, true), "close failure not reported")
assert(not close_err:find(canary, 1, true), "close error leaked canary")
assert(retry:status().visible == true, "close failure falsely reported hidden QR")
assert(retry_callbacks == 0, "close failure falsely invoked dismissal callback")
assert(retry:hide("cancelled"), "close retry failed")
assert(retry:status().visible == false and retry_callbacks == 1, "close retry did not finish")
assert(not contains(retry, canary), "close retry retained QR canary")

print("QR display tests passed")

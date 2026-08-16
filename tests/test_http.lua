package.path = "./?.lua;./?/init.lua;" .. package.path

local handler
local timeout_calls, reset_calls = {}, 0

package.preload["ssl.https"] = function()
    return { request = function(request) return handler(request) end }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_, block, total)
            timeout_calls[#timeout_calls + 1] = { block = block, total = total }
        end,
        reset_timeout = function() reset_calls = reset_calls + 1 end,
    }
end

local Http = require("fanqielite.http")

local function contains(text, expected, label)
    if not text or not text:find(expected, 1, true) then
        error((label or "assertion") .. ": expected text containing " .. expected .. ", got " .. tostring(text))
    end
end

local called = false
handler = function() called = true end
local rejected, rejected_err = Http.get("http://fanqienovel.com/page/1234567890")
assert(rejected == nil and not called, "non-HTTPS request was attempted")
contains(rejected_err, "已拒绝", "scheme rejection")

rejected, rejected_err = Http.get("https://evil.example/fanqienovel.com/page/1234567890")
assert(rejected == nil and not called, "non-official host request was attempted")
contains(rejected_err, "非番茄官方", "host rejection")

handler = function(request)
    assert(request.redirect == false, "redirects must be disabled")
    assert(request.method == "GET")
    assert(request.headers["Connection"] == "close")
    assert(request.sink("hello") == 1)
    assert(request.sink(nil) == 1)
    return 1, 200, { ["content-length"] = "5" }, "OK"
end
local body = assert(Http.get("https://fanqienovel.com/page/1234567890"))
assert(body == "hello", "successful body mismatch")
assert(timeout_calls[#timeout_calls].block == 10 and timeout_calls[#timeout_calls].total == 20)
assert(reset_calls == 1, "timeout not reset after success")

handler = function(request)
    local ok, err = request.sink(string.rep("x", 1024 * 1024 + 1))
    assert(ok == nil and err == "response too large")
    return nil, err
end
local oversized, oversized_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(oversized == nil)
contains(oversized_err, "1 MB", "size limit message")
contains(oversized_err, "本地数据未改变", "safe failure message")

handler = function() return nil, "timeout" end
local timed_out, timeout_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(timed_out == nil)
contains(timeout_err, "网络连接超时", "timeout message")

local original_time = os.time
local now = 100
os.time = function() return now end
handler = function(request)
    assert(request.sink("first") == 1)
    now = 121
    local ok, err = request.sink("late")
    assert(ok == nil and err == "sink timeout")
    return nil, err
end
local deadline, deadline_err = Http.get("https://fanqienovel.com/page/1234567890")
os.time = original_time
assert(deadline == nil)
contains(deadline_err, "网络连接超时", "total timeout message")

handler = function(request)
    request.sink("short")
    return 1, 200, { ["content-length"] = "99" }, "OK"
end
local incomplete, incomplete_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(incomplete == nil)
contains(incomplete_err, "传输不完整", "incomplete response message")

handler = function() return 1, 302, { location = "https://example.com" }, "Found" end
local redirected, redirect_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(redirected == nil)
contains(redirect_err, "重定向", "redirect message")

local status_cases = {
    { 403, "需要登录或授权" },
    { 404, "检查书籍链接" },
    { 429, "稍后再试" },
    { 503, "官方服务暂时异常" },
}
for _, case in ipairs(status_cases) do
    handler = function() return 1, case[1], {}, "Error" end
    local result, err = Http.get("https://fanqienovel.com/page/1234567890")
    assert(result == nil)
    contains(err, case[2], "HTTP " .. tostring(case[1]) .. " message")
end

handler = function() error("certificate verify failed") end
local crashed, certificate_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(crashed == nil)
contains(certificate_err, "证书验证失败", "certificate message")
assert(reset_calls == 11, "timeout must reset after every attempted request")

print("http tests passed")

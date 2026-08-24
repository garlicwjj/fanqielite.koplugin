package.path = "./?.lua;./?/init.lua;" .. package.path

local handler
local http_stub = {}
local timeout_calls, reset_calls = {}, 0
local certificate_names = { "fanqienovel.com" }
local certificate_mode = "valid"
local tls_config, closed_tls_connections = nil, 0

package.preload["ssl.https"] = function()
    return { tcp = function(config)
        tls_config = config
        return function()
            local connection = {}
            function connection:connect(host, port)
                assert(host == "fanqienovel.com" and port == 443, "unexpected TLS destination")
                return 1
            end
            function connection:getpeercertificate()
                if certificate_mode == "missing" then return nil end
                return { extensions = function()
                    if certificate_mode == "extensions_error" then error("malformed certificate") end
                    if certificate_mode == "no_san" then return {} end
                    return { subject_alt_name = { dNSName = certificate_names } }
                end }
            end
            function connection:close()
                closed_tls_connections = closed_tls_connections + 1
                return 1
            end
            return connection
        end
    end }
end
package.preload["socket.http"] = function()
    http_stub.request = function(request)
        local connection = request.create()
        local connected, connect_err = connection:connect("fanqienovel.com", 443)
        if not connected then return nil, connect_err end
        return handler(request)
    end
    return http_stub
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/mock/koreader" end }
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
    assert(tls_config.verify == "peer", "certificate chain verification not enabled")
    assert(tls_config.cafile == "/mock/koreader/data/ca-bundle.crt", "KOReader CA bundle not used")
    assert(type(tls_config.options) == "table", "TLS protocol restrictions missing")
    local options = {}
    for _, option in ipairs(tls_config.options) do options[option] = true end
    assert(options.no_sslv2 and options.no_sslv3 and options.no_tlsv1 and options.no_tlsv1_1,
        "obsolete TLS protocols not disabled")
    assert(request.sink("hello") == 1)
    assert(request.sink(nil) == 1)
    return 1, 200, { ["content-length"] = "5" }, "OK"
end
local body = assert(Http.get("https://fanqienovel.com/page/1234567890"))
assert(body == "hello", "successful body mismatch")
assert(timeout_calls[#timeout_calls].block == 10 and timeout_calls[#timeout_calls].total == 20)
assert(reset_calls == 1, "timeout not reset after success")

http_stub.PROXY = "http://proxy.invalid:8080"
handler = function() error("request continued through HTTP proxy") end
local proxied, proxy_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(proxied == nil)
contains(proxy_err, "HTTP 代理", "proxy rejection message")
http_stub.PROXY = nil

certificate_names = { "evil.example" }
handler = function() error("request continued after hostname mismatch") end
local mismatch, mismatch_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(mismatch == nil)
contains(mismatch_err, "证书验证失败", "hostname mismatch message")
assert(closed_tls_connections == 1, "hostname mismatch did not close TLS connection")

certificate_mode = "no_san"
certificate_names = { "fanqienovel.com" }
local no_san, no_san_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(no_san == nil)
contains(no_san_err, "证书验证失败", "missing SAN message")
assert(closed_tls_connections == 2, "missing SAN did not close TLS connection")

certificate_mode = "valid"
certificate_names = { "*.fanqienovel.com" }
local apex_wildcard, apex_wildcard_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(apex_wildcard == nil)
contains(apex_wildcard_err, "证书验证失败", "wildcard apex mismatch message")
assert(closed_tls_connections == 3, "wildcard apex mismatch did not close TLS connection")

certificate_mode = "missing"
local missing_certificate, missing_certificate_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(missing_certificate == nil)
contains(missing_certificate_err, "证书验证失败", "missing certificate message")
assert(closed_tls_connections == 4, "missing certificate did not close TLS connection")

certificate_mode = "extensions_error"
local malformed_certificate, malformed_certificate_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(malformed_certificate == nil)
contains(malformed_certificate_err, "证书验证失败", "malformed certificate message")
assert(closed_tls_connections == 5, "malformed certificate did not close TLS connection")

certificate_mode = "valid"
certificate_names = { "fanqienovel.com" }

handler = function()
    return 1, 200, {
        ["content-length"] = "0",
        ["Bdturing-Verify"] = "private-challenge-value",
        ["x-ms-token"] = "private-response-token",
    }, "OK"
end
local challenged, challenge_err = Http.get("https://fanqienovel.com/api/author/search/search_book/v1")
assert(challenged == nil)
contains(challenge_err, "官方安全验证", "verification challenge message")
contains(challenge_err, "Kindle 无法显示", "verification action message")
assert(not challenge_err:find("private%-challenge%-value"), "challenge value leaked into error")
assert(not challenge_err:find("private%-response%-token"), "response token leaked into error")

handler = function() return 1, 200, { ["content-length"] = "0" }, "OK" end
local empty, empty_err = Http.get("https://fanqienovel.com/page/1234567890")
assert(empty == nil)
contains(empty_err, "返回空内容", "empty response message")
contains(empty_err, "本地数据未改变", "empty response safety message")

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
assert(reset_calls == 18, "timeout must reset after every attempted request")

print("http tests passed")

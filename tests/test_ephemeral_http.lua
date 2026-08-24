package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local handler, last_request
local timeout_calls, reset_calls = 0, 0
local http_stub = {}
local tls_create = function() return {} end

package.preload["socket.http"] = function()
    http_stub.request = function(request)
        last_request = request
        return handler(request)
    end
    return http_stub
end
package.preload["ltn12"] = function()
    return { source = { string = function(value)
        local sent = false
        return function()
            if sent then return nil end
            sent = true
            return value
        end
    end } }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_, block, total)
            assert(block == 10 and total == 20, "sensitive timeout mismatch")
            timeout_calls = timeout_calls + 1
        end,
        reset_timeout = function() reset_calls = reset_calls + 1 end,
    }
end
package.preload["fanqielite.verified_tls"] = function()
    return { create = tls_create }
end

local Client = require("fanqielite.ephemeral_http")

local source_file = assert(io.open("fanqielite/ephemeral_http.lua", "rb"))
local source = assert(source_file:read("*a"))
assert(source_file:close())
assert(not source:find('require("logger")', 1, true), "sensitive HTTP imported logger")
assert(not source:find("logger.", 1, true), "sensitive HTTP writes logger output")
assert(not source:match("[^%w_]print%s*%(") and not source:match("^print%s*%("),
    "sensitive HTTP writes process output")
assert(not source:find("io.", 1, true) and not source:find("os.", 1, true),
    "sensitive HTTP directly accesses filesystem or process APIs")
assert(not source:match("tostring%s*%("), "sensitive HTTP stringifies raw errors")
local main_file = assert(io.open("main.lua", "rb"))
local main_source = assert(main_file:read("*a"))
assert(main_file:close())
assert(not main_source:find("ephemeral_http", 1, true), "sensitive HTTP was enabled from the UI")

local invalid, invalid_err = Client.new({})
assert(invalid == nil and invalid_err:find("白名单无效", 1, true))
invalid = Client.new({ bad = { method = "POST", path = "https://evil.example/" } })
assert(invalid == nil, "absolute URL policy accepted")
invalid = Client.new({ bad = { method = "POST", path = "/safe?next=https://evil.example" } })
assert(invalid == nil, "dynamic query policy accepted")
invalid = Client.new({ bad = { method = "POST", path = "/safe/%2e%2e/evil" } })
assert(invalid == nil, "encoded path ambiguity accepted")
invalid = Client.new({ bad = { method = "POST", path = "/safe/../evil" } })
assert(invalid == nil, "path traversal policy accepted")

local policies = {
    synthetic_post = {
        method = "POST",
        path = "/__synthetic__/authorization",
        content_type = "application/json",
        allow_cookie = true,
        request_headers = { "X-CSRF-Token" },
        response_headers = { "Set-Cookie" },
    },
    synthetic_get = {
        method = "GET",
        path = "/__synthetic__/status",
        allow_empty = true,
    },
}
local client = assert(Client.new(policies))
policies.synthetic_post.path = "/mutated"

local network_calls = 0
handler = function(request)
    network_calls = network_calls + 1
    assert(request.url == "https://fanqienovel.com/__synthetic__/authorization",
        "request escaped the copied fixed endpoint")
    assert(request.method == "POST" and request.redirect == false)
    assert(request.create == tls_create, "verified TLS connector not reused")
    assert(request.headers.Cookie == "sessionid=" .. canary, "Cookie changed")
    assert(request.headers["X-CSRF-Token"] == canary, "CSRF header changed")
    assert(request.headers["Content-Type"] == "application/json")
    assert(request.headers["Content-Length"] == 2)
    assert(request.source() == "{}" and request.source() == nil, "request body source changed")
    assert(request.sink("{\"books\":[]}") == 1)
    assert(request.sink(nil) == 1)
    return 1, 200, {
        ["content-length"] = "12",
        ["set-cookie"] = "sessionid=" .. canary .. "; Secure; HttpOnly",
        ["x-private-account"] = canary,
    }, "OK"
end

local response = assert(client:request("synthetic_post", {
    body = "{}",
    cookie = "sessionid=" .. canary,
    headers = { ["X-CSRF-Token"] = canary },
}))
assert(response.body == "{\"books\":[]}")
assert(response.status == 200)
assert(response.headers["set-cookie"]:find(canary, 1, true), "allowed Cookie not held in child memory")
assert(response.headers["x-private-account"] == nil, "unlisted response header exposed")
assert(timeout_calls == 1 and reset_calls == 1, "timeouts not set and reset")

local rejected, rejected_err = client:request("missing_operation", { body = canary })
assert(rejected == nil and network_calls == 1)
assert(not rejected_err:find(canary, 1, true), "unknown operation leaked credentials")
rejected = client:request("synthetic_post", { body = "{}", url = "https://evil.example/" })
assert(rejected == nil and network_calls == 1, "dynamic URL input accepted")
rejected = client:request("synthetic_post", { body = "{}", headers = { Authorization = canary } })
assert(rejected == nil and network_calls == 1, "unlisted credential header accepted")
rejected = client:request("synthetic_post", { body = "{}", cookie = "bad\r\nX-Leak: " .. canary })
assert(rejected == nil and network_calls == 1, "header injection accepted")
rejected = client:request("synthetic_get", { body = canary })
assert(rejected == nil and network_calls == 1, "GET body accepted")

http_stub.PROXY = "http://proxy.invalid:8080"
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and network_calls == 1 and rejected_err:find("HTTP 代理", 1, true))
http_stub.PROXY = nil

handler = function() error("raw network failure " .. canary) end
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and not rejected_err:find(canary, 1, true), "raw exception leaked")
assert(reset_calls == 2, "timeout not reset after exception")

handler = function() return nil, "certificate verify failed " .. canary end
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and rejected_err:find("证书验证失败", 1, true))
assert(not rejected_err:find(canary, 1, true), "TLS error leaked")

handler = function(request)
    assert(request.sink(string.rep("x", Client.MAX_RESPONSE_BYTES + 1)) == nil)
    return nil, "response too large " .. canary
end
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and rejected_err:find("超过 256 KB", 1, true))
assert(not rejected_err:find(canary, 1, true), "oversized response error leaked")

handler = function() return 1, 302, { location = "https://evil.example/" }, "Found " .. canary end
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and rejected_err:find("重定向", 1, true))
assert(not rejected_err:find(canary, 1, true), "redirect status leaked")

handler = function(request)
    assert(request.sink("ok") == 1)
    return 1, 200, { ["content-length"] = "3" }, "OK"
end
rejected, rejected_err = client:request("synthetic_get")
assert(rejected == nil and rejected_err:find("传输不完整", 1, true))

assert(timeout_calls == 6 and reset_calls == 6, "attempted requests did not reset timeouts")
print("ephemeral HTTP tests passed")

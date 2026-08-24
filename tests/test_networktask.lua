package.path = "./?.lua;./?/init.lua;" .. package.path

local completed = true
local http_mode = "success"
local received_label
local credential_canary = "COOKIE_SESSION_TOKEN_CANARY_4d91"
local tostring_calls = 0

package.preload["fanqielite.http"] = function()
    return {
        get = function(url, accept)
            assert(url == "https://fanqienovel.com/page/1234567890")
            assert(accept == "text/html")
            if http_mode == "throw" then error("unexpected socket failure") end
            if http_mode == "error" then return nil, "请求超时，本地数据未改变" end
            if http_mode == "unsafe_error" then
                return nil, setmetatable({}, { __tostring = function()
                    tostring_calls = tostring_calls + 1
                    return credential_canary
                end })
            end
            return "official response"
        end,
    }
end

package.preload["ui/trapper"] = function()
    return {
        dismissableRunInSubprocess = function(_, task, label)
            received_label = label
            if not completed then return false end
            return true, task()
        end,
    }
end

local NetworkTask = require("fanqielite.networktask")
local url = "https://fanqienovel.com/page/1234567890"

local body = assert(NetworkTask.get(url, "text/html", "正在读取……（点按取消）"))
assert(body == "official response")
assert(received_label:find("点按取消", 1, true), "cancel instruction missing")

http_mode = "error"
local failed, request_err = NetworkTask.get(url, "text/html", "读取")
assert(failed == nil)
assert(request_err:find("本地数据未改变", 1, true), "HTTP safety detail lost")

http_mode = "throw"
local crashed, crash_err = NetworkTask.get(url, "text/html", "读取")
assert(crashed == nil)
assert(crash_err:find("网络子任务异常", 1, true), "unexpected child error not contained")

http_mode = "unsafe_error"
local unsafe, unsafe_err = NetworkTask.get(url, "text/html", "读取")
assert(unsafe == nil)
assert(unsafe_err:find("官方服务请求失败", 1, true), "unsafe child error did not use fixed message")
assert(not unsafe_err:find(credential_canary, 1, true), "unsafe child error leaked")
assert(tostring_calls == 0, "unsafe child error invoked __tostring")

completed = false
http_mode = "success"
local cancelled, cancel_err = NetworkTask.get(url, "text/html", "读取")
assert(cancelled == nil)
assert(cancel_err:find("已取消", 1, true), "cancellation not reported")
assert(cancel_err:find("没有改变", 1, true), "cancellation safety detail missing")

print("network task tests passed")

local Http = require("fanqielite.http")
local Trapper = require("ui/trapper")

local NetworkTask = {}

function NetworkTask.get(url, accept, label)
    local prompt = tostring(label or "正在连接番茄官方服务……")
    if not prompt:find("取消", 1, true) then prompt = prompt .. "（点按取消）" end

    local completed, result = Trapper:dismissableRunInSubprocess(function()
        local called, body, request_err = pcall(Http.get, url, accept)
        if not called then return { ok = false, error = "网络子任务异常" } end
        if not body then return { ok = false, error = tostring(request_err or "官方服务没有返回内容") } end
        return { ok = true, body = body }
    end, prompt)

    if not completed then
        return nil, "操作已取消；本地书架、阅读进度和缓存没有改变。"
    end
    if type(result) ~= "table" then return nil, "网络子任务没有返回有效结果" end
    if not result.ok then return nil, tostring(result.error or "官方服务请求失败") end
    if type(result.body) ~= "string" then return nil, "官方服务返回内容无效" end
    return result.body
end

return NetworkTask

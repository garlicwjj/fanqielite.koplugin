local Trapper = require("ui/trapper")

local EphemeralTask = {}

EphemeralTask.MAX_BYTES = 256 * 1024

local SUCCESS = "\30FQL1O\31"
local FAILURE = "\30FQL1E\31"
local PROMPT = "正在处理一次性书架……（点按取消）"

function EphemeralTask.run(task)
    if type(task) ~= "function" then return nil, "一次性书架子任务无效" end

    local called, completed, wire = pcall(
        Trapper.dismissableRunInSubprocess,
        Trapper,
        function()
            local task_called, result = pcall(task)
            if not task_called or type(result) ~= "string" or result == ""
                    or #result > EphemeralTask.MAX_BYTES then
                return FAILURE
            end
            return SUCCESS .. result
        end,
        PROMPT,
        true)

    if not called then
        return nil, "一次性书架子任务异常；本地书架和阅读进度没有改变。"
    end
    if not completed then
        return nil, "操作已取消；本地书架、阅读进度和缓存没有改变。"
    end
    if type(wire) ~= "string" or wire == "" then
        return nil, "一次性书架子任务没有返回有效结果"
    end
    if wire == FAILURE then
        return nil, "一次性书架子任务失败；本地书架和阅读进度没有改变。"
    end
    if wire:sub(1, #SUCCESS) ~= SUCCESS then
        return nil, "一次性书架子任务返回格式无效"
    end
    local body_size = #wire - #SUCCESS
    if body_size < 1 then return nil, "一次性书架子任务没有返回有效结果" end
    if body_size > EphemeralTask.MAX_BYTES then
        return nil, "一次性书架子任务返回过大，已安全拒绝"
    end
    return wire:sub(#SUCCESS + 1)
end

return EphemeralTask

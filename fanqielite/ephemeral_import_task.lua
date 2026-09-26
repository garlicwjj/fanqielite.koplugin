local EphemeralTask = require("fanqielite.ephemeral_task")
local Result = require("fanqielite.ephemeral_result")

local ImportTask = {}

function ImportTask.run(producer)
    if type(producer) ~= "function" then return nil, "一次性书架生成任务无效" end
    local contents, task_err = EphemeralTask.run(function()
        local payload = producer()
        return Result.encode(payload)
    end)
    if not contents then return nil, task_err end
    local books = Result.decode(contents)
    if not books then
        return nil, "一次性书架返回内容无效；本地书架和阅读进度没有改变。"
    end
    return books
end

return ImportTask

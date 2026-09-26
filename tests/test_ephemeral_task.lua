package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local mode = "run"
local custom_wire
local received_label, received_simple, last_wire

package.preload["ui/trapper"] = function()
    return {
        dismissableRunInSubprocess = function(_, task, label, simple)
            received_label = label
            received_simple = simple
            if mode == "throw" then error("parent trapper failure " .. canary) end
            if mode == "cancel" then return false end
            if mode == "missing" then return true end
            if mode == "custom" then return true, custom_wire end
            last_wire = task()
            return true, last_wire
        end,
    }
end

local EphemeralTask = require("fanqielite.ephemeral_task")

local source_file = assert(io.open("fanqielite/ephemeral_task.lua", "rb"))
local source = assert(source_file:read("*a"))
assert(source_file:close())
assert(not source:find('require("logger")', 1, true), "credential task imported logger")
assert(not source:find("logger.", 1, true), "credential task writes logger output")
assert(
    not source:match("[^%w_]print%s*%(") and not source:match("^print%s*%("),
    "credential task writes process output")
assert(not source:match("tostring%s*%("), "credential task stringifies raw errors")
assert(not source:find("io.", 1, true) and not source:find("os.", 1, true),
    "credential task directly accesses filesystem or process APIs")

local result = assert(EphemeralTask.run(function() return canary end))
assert(result == canary, "successful sensitive string changed")
assert(received_simple == true, "credential task used complex serializer")
assert(received_label == "正在处理一次性书架……（点按取消）", "task prompt was not fixed")
assert(not received_label:find(canary, 1, true), "task prompt leaked credential canary")
local success_prefix = last_wire:sub(1, #last_wire - #canary)
assert(success_prefix ~= "", "wire result was not explicitly framed")

local invalid_task, invalid_task_err = EphemeralTask.run("not a function")
assert(invalid_task == nil and invalid_task_err:find("任务无效", 1, true), "invalid task accepted")

local crashed, crash_err = EphemeralTask.run(function()
    error("raw child failure " .. canary)
end)
assert(crashed == nil and crash_err:find("子任务失败", 1, true), "child error not contained")
assert(not crash_err:find(canary, 1, true), "child error leaked credential canary")
assert(not last_wire:find(canary, 1, true), "child error entered the anonymous pipe")

local wrong_type, wrong_type_err = EphemeralTask.run(function()
    return { cookie = canary }
end)
assert(wrong_type == nil and wrong_type_err:find("子任务失败", 1, true), "table result accepted")
assert(not wrong_type_err:find(canary, 1, true), "wrong-type error leaked credential canary")
assert(not last_wire:find(canary, 1, true), "wrong-type result entered the anonymous pipe")

local empty, empty_err = EphemeralTask.run(function() return "" end)
assert(empty == nil and empty_err:find("子任务失败", 1, true), "empty result accepted")

local too_large, too_large_err = EphemeralTask.run(function()
    return string.rep("x", EphemeralTask.MAX_BYTES + 1)
end)
assert(too_large == nil and too_large_err:find("子任务失败", 1, true), "oversized child result accepted")
assert(#last_wire < 100, "oversized child result entered the anonymous pipe")

mode = "cancel"
local cancelled, cancel_err = EphemeralTask.run(function() return canary end)
assert(cancelled == nil and cancel_err:find("已取消", 1, true), "cancellation not reported")
assert(cancel_err:find("没有改变", 1, true), "cancellation safety detail missing")
assert(not cancel_err:find(canary, 1, true), "cancellation error leaked credential canary")

mode = "throw"
local trapper_failed, trapper_err = EphemeralTask.run(function() return canary end)
assert(trapper_failed == nil and trapper_err:find("子任务异常", 1, true), "Trapper error escaped")
assert(not trapper_err:find(canary, 1, true), "Trapper error leaked credential canary")

mode = "missing"
local missing, missing_err = EphemeralTask.run(function() return canary end)
assert(missing == nil and missing_err:find("没有返回", 1, true), "missing pipe result accepted")
assert(not missing_err:find(canary, 1, true), "missing-result error leaked credential canary")

mode = "custom"
custom_wire = canary
local malformed, malformed_err = EphemeralTask.run(function() return "ignored" end)
assert(malformed == nil and malformed_err:find("返回格式无效", 1, true), "malformed frame accepted")
assert(not malformed_err:find(canary, 1, true), "malformed frame leaked credential canary")

custom_wire = success_prefix .. string.rep("x", EphemeralTask.MAX_BYTES + 1)
local oversized_wire, oversized_wire_err = EphemeralTask.run(function() return "ignored" end)
assert(oversized_wire == nil and oversized_wire_err:find("返回过大", 1, true), "oversized pipe accepted")
assert(not oversized_wire_err:find(canary, 1, true), "oversized-pipe error leaked credential canary")

print("ephemeral task tests passed")

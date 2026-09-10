package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local encoded_payload
local encode_mode, decode_mode = "ok", "ok"
local encoded_contents = "{\"safe\":true}"
local last_wire, wire_override

package.preload["rapidjson"] = function()
    return {
        encode = function(payload)
            if encode_mode == "throw" then error("encoder leaked " .. canary) end
            encoded_payload = payload
            return encoded_contents
        end,
        decode = function(contents)
            if decode_mode == "throw" then error("decoder leaked " .. canary) end
            if decode_mode == "credential" then
                return {
                    format = "fanqielite-bookshelf",
                    version = 1,
                    cookie = canary,
                    books = {{ id = "7000000000000000001", title = "测试书" }},
                }
            end
            if contents == encoded_contents then return encoded_payload end
            return nil, "malformed " .. canary
        end,
    }
end
package.preload["ui/trapper"] = function()
    return {
        dismissableRunInSubprocess = function(_, task, _, simple)
            assert(simple == true, "minimal bookshelf used complex IPC serialization")
            if wire_override ~= nil then return true, wire_override end
            last_wire = task()
            return true, last_wire
        end,
    }
end

local ImportTask = require("fanqielite.ephemeral_import_task")

for _, path in ipairs({
    "fanqielite/ephemeral_result.lua",
    "fanqielite/ephemeral_import_task.lua",
}) do
    local file = assert(io.open(path, "rb"))
    local source = assert(file:read("*a"))
    assert(file:close())
    assert(not source:find('require("logger")', 1, true), path .. " imported logger")
    assert(not source:find("logger.", 1, true), path .. " writes logger output")
    assert(not source:match("[^%w_]print%s*%(") and not source:match("^print%s*%("),
        path .. " writes process output")
    assert(not source:find("io.", 1, true) and not source:find("os.", 1, true),
        path .. " accesses files or process APIs")
    assert(not source:match("tostring%s*%("), path .. " stringifies raw errors")
end

local payload = {
    format = "fanqielite-bookshelf",
    version = 1,
    exported_at = "2026-08-24T10:00:00Z",
    books = {{
        id = "7000000000000000001",
        title = "  测试书  ",
        author = "测试作者",
        cover_url = "https://example.invalid/cover.jpg",
        current_chapter_id = "8000000000000000001",
        current_chapter_title = "第一章",
        reading_position = 0.5,
    }},
}
local books = assert(ImportTask.run(function() return payload end))
assert(#books == 1 and books[1].title == "测试书")
assert(books[1].imported_progress.chapter_id == "8000000000000000001")
assert(encoded_payload.format == "fanqielite-bookshelf" and encoded_payload.version == 1)
assert(encoded_payload.exported_at == nil, "unneeded timestamp crossed the pipe")
assert(encoded_payload.books[1].title == "测试书", "normalized title not encoded")
assert(encoded_payload.books[1].current_chapter_id == "8000000000000000001")
assert(not last_wire:find(canary, 1, true), "credential canary entered successful pipe")
local success_prefix = last_wire:sub(1, #last_wire - #encoded_contents)
assert(success_prefix ~= "", "minimal bookshelf IPC was not framed")

local invalid_task, invalid_task_err = ImportTask.run("not a function")
assert(invalid_task == nil and invalid_task_err:find("任务无效", 1, true))

local invalid, invalid_err = ImportTask.run(function()
    return {
        format = "fanqielite-bookshelf",
        version = 1,
        cookie = canary,
        books = payload.books,
    }
end)
assert(invalid == nil and invalid_err:find("子任务失败", 1, true))
assert(not invalid_err:find(canary, 1, true) and not last_wire:find(canary, 1, true),
    "credential-bearing payload crossed the pipe")

local crashed, crash_err = ImportTask.run(function() error("producer leaked " .. canary) end)
assert(crashed == nil and crash_err:find("子任务失败", 1, true))
assert(not crash_err:find(canary, 1, true) and not last_wire:find(canary, 1, true),
    "producer exception crossed the pipe")

encode_mode = "throw"
local encode_failed, encode_err = ImportTask.run(function() return payload end)
encode_mode = "ok"
assert(encode_failed == nil and encode_err:find("子任务失败", 1, true))
assert(not encode_err:find(canary, 1, true) and not last_wire:find(canary, 1, true),
    "encoder exception crossed the pipe")

decode_mode = "credential"
local roundtrip_failed, roundtrip_err = ImportTask.run(function() return payload end)
decode_mode = "ok"
assert(roundtrip_failed == nil and roundtrip_err:find("子任务失败", 1, true))
assert(not roundtrip_err:find(canary, 1, true) and not last_wire:find(canary, 1, true),
    "credential-bearing roundtrip crossed the pipe")

wire_override = success_prefix .. "tampered"
local tampered, tampered_err = ImportTask.run(function() return payload end)
wire_override = nil
assert(tampered == nil and tampered_err:find("返回内容无效", 1, true))
assert(not tampered_err:find(canary, 1, true), "parent decode error leaked raw content")

local main_file = assert(io.open("main.lua", "rb"))
local main_source = assert(main_file:read("*a"))
assert(main_file:close())
assert(not main_source:find("ephemeral_import_task", 1, true),
    "minimal bookshelf pipe was enabled from the UI")

print("ephemeral import task tests passed")

package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_QR_TASK_CREDENTIAL_CANARY"
local encoded, sequence = {}, 0
package.preload["rapidjson"] = function()
    return {
        encode = function(value)
            sequence = sequence + 1
            local key = "json:" .. tostring(sequence)
            encoded[key] = value
            return key
        end,
        decode = function(value) return encoded[value] end,
    }
end

package.preload["fanqielite.ephemeral_task"] = function()
    return {
        MAX_BYTES = 256 * 1024,
        run = function(task)
            local ok, result = pcall(task)
            if not ok then return nil, "一次性书架子任务失败；本地书架和阅读进度没有改变。" end
            return result
        end,
    }
end

local finish_mode = "success"
local Protocol = {
    safe_error_codes = {
        network = true,
        invalid_response = true,
        expired = true,
        refused = true,
        verification_required = true,
        bookshelf_failed = true,
        empty_bookshelf = true,
    },
    begin = function()
        return {
            qr_payload = "https://reading.snssdk.com/ucenter_web/app/sdk-next?token=" .. canary,
            token = canary,
            cookie = "passport_csrf_token=" .. canary,
            expires_at = 2000,
        }
    end,
    validate_start = function(start)
        if type(start) ~= "table" or start.token ~= canary
                or start.cookie ~= "passport_csrf_token=" .. canary then return nil end
        return start
    end,
    finish = function()
        if finish_mode == "network" then return { kind = "error", code = "network" } end
        if finish_mode == "logout" then
            return { kind = "error", code = "bookshelf_failed", logout_ok = false }
        end
        return {
            kind = "success",
            logout_ok = true,
            progress_found = true,
            payload = {
                format = "fanqielite-bookshelf",
                version = 1,
                books = {{
                    id = "7134567890123456789",
                    title = "任务测试书",
                    author = "测试作者",
                    current_chapter_id = "7134567890123456701",
                    current_chapter_title = "第一章",
                }},
            },
        }
    end,
}
package.preload["fanqielite.qr_protocol"] = function() return Protocol end

local Task = require("fanqielite.qr_import_task")
local start = assert(Task.begin())
assert(start.qr_payload:find(canary, 1, true) and start.expires_at == 2000)
assert(type(start.poll_ticket) == "string" and start.poll_ticket ~= "")

local books, result = assert(Task.finish(start.poll_ticket))
assert(#books == 1 and books[1].title == "任务测试书")
assert(books[1].imported_progress.chapter_id == "7134567890123456701")
assert(result.logout_ok == true and result.progress_found == true)

finish_mode = "network"
local failed, failure = Task.finish(start.poll_ticket)
assert(failed == nil and failure:find("检查 Wi%-Fi"), "network failure was not safely classified")
assert(not failure:find(canary, 1, true), "network failure leaked credential canary")

finish_mode = "logout"
failed, failure = Task.finish(start.poll_ticket)
assert(failed == nil and failure:find("退出未完成", 1, true),
    "logout failure did not provide the account-safety warning")
assert(not failure:find(canary, 1, true), "logout failure leaked credential canary")

local tampered, tampered_err = Task.finish("not-json-" .. canary)
assert(tampered == nil and tampered_err:find("结构已变化", 1, true))
assert(not tampered_err:find(canary, 1, true), "tampered poll ticket leaked")

local source_file = assert(io.open("fanqielite/qr_import_task.lua", "rb"))
local source = assert(source_file:read("*a"))
assert(source_file:close())
assert(not source:find('require("logger")', 1, true) and not source:find("logger.", 1, true))
assert(not source:match("[^%w_]print%s*%(") and not source:match("^print%s*%(") )
assert(not source:match("tostring%s*%("), "QR task stringifies raw errors")

print("QR import task tests passed")

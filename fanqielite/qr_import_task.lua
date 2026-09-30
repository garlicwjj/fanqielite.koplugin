local EphemeralTask = require("fanqielite.ephemeral_task")
local Protocol = require("fanqielite.qr_protocol")
local Result = require("fanqielite.ephemeral_result")
local rapidjson = require("rapidjson")

local Task = {}

local messages = {
    network = "无法连接番茄官方扫码服务，请检查 Wi-Fi 后重试。",
    invalid_response = "番茄官方扫码响应结构已变化，当前版本已安全停止。请更新插件后重试。",
    expired = "二维码已过期，请重新发起扫码导入。",
    refused = "手机端没有确认本次登录，扫码导入已取消。",
    verification_required = "本次登录需要短信、刷脸或其他二次验证，Kindle 端无法安全完成。请改用无凭证 JSON 导入。",
    bookshelf_failed = "登录确认成功，但官方书架无法安全读取；本地书架没有改变。",
    empty_bookshelf = "官方账号书架中没有可导入的小说。",
}

local function exact_fields(value, allowed)
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then return nil end
    end
    return true
end

local function encode(value)
    local called, text = pcall(rapidjson.encode, value)
    if not called or type(text) ~= "string" or text == ""
            or #text > EphemeralTask.MAX_BYTES then return nil end
    return text
end

local function decode(value)
    if type(value) ~= "string" or value == "" or #value > EphemeralTask.MAX_BYTES then return nil end
    local called, decoded = pcall(rapidjson.decode, value)
    if not called or type(decoded) ~= "table" then return nil end
    return decoded
end

local function error_envelope(code, logout_ok)
    if not Protocol.safe_error_codes[code] then code = "invalid_response" end
    local value = { kind = "error", code = code }
    if type(logout_ok) == "boolean" then value.logout_ok = logout_ok end
    return value
end

function Task.begin(options)
    local wire, task_err = EphemeralTask.run(function()
        local start, code = Protocol.begin(options)
        if not start then return encode(error_envelope(code)) end
        return encode({ kind = "start", start = start })
    end)
    if not wire then return nil, task_err end
    local envelope = decode(wire)
    if not exact_fields(envelope, { kind = true, code = true, start = true }) then
        return nil, messages.invalid_response
    end
    if envelope.kind == "error" then
        if envelope.start ~= nil or not Protocol.safe_error_codes[envelope.code] then
            return nil, messages.invalid_response
        end
        return nil, messages[envelope.code]
    end
    if envelope.kind ~= "start" or envelope.code ~= nil then return nil, messages.invalid_response end
    local start = Protocol.validate_start(envelope.start, options, true)
    if not start then return nil, messages.invalid_response end
    local poll_ticket = encode(start)
    if not poll_ticket or #poll_ticket > 4096 then return nil, messages.invalid_response end
    return {
        qr_payload = start.qr_payload,
        poll_ticket = poll_ticket,
        expires_at = start.expires_at,
    }
end

function Task.finish(poll_ticket, options)
    if type(poll_ticket) ~= "string" or poll_ticket == "" or #poll_ticket > 4096
            or poll_ticket:find("[%z\1-\31\127]") then
        return nil, messages.invalid_response
    end
    local wire, task_err = EphemeralTask.run(function()
        local start = Protocol.validate_start(decode(poll_ticket), options, false)
        if not start then return encode(error_envelope("invalid_response")) end
        local outcome = Protocol.finish(start, options)
        if type(outcome) ~= "table" or outcome.kind ~= "success" then
            local code = type(outcome) == "table" and outcome.code or "invalid_response"
            local logout_ok
            if type(outcome) == "table" and type(outcome.logout_ok) == "boolean" then
                logout_ok = outcome.logout_ok
            end
            return encode(error_envelope(code, logout_ok))
        end
        local payload = Result.encode(outcome.payload)
        if not payload then return encode(error_envelope("invalid_response", outcome.logout_ok)) end
        return encode({
            kind = "success",
            payload = payload,
            logout_ok = outcome.logout_ok == true,
            progress_found = outcome.progress_found == true,
        })
    end)
    if not wire then return nil, task_err end
    local envelope = decode(wire)
    if not exact_fields(envelope, {
            kind = true, code = true, payload = true,
            logout_ok = true, progress_found = true,
        }) then
        return nil, messages.invalid_response
    end
    if envelope.kind == "error" then
        if envelope.payload ~= nil or envelope.progress_found ~= nil
                or not Protocol.safe_error_codes[envelope.code]
                or (envelope.logout_ok ~= nil and type(envelope.logout_ok) ~= "boolean") then
            return nil, messages.invalid_response
        end
        local message = messages[envelope.code]
        if envelope.logout_ok == false then
            message = message .. "\n\n官方会话退出未完成；Kindle 未保存账号凭证，请稍后在账号安全页面检查会话。"
        end
        return nil, message
    end
    if envelope.kind ~= "success" or envelope.code ~= nil
            or type(envelope.logout_ok) ~= "boolean"
            or type(envelope.progress_found) ~= "boolean" then
        return nil, messages.invalid_response
    end
    local books = Result.decode(envelope.payload)
    if not books then return nil, messages.invalid_response end
    return books, {
        logout_ok = envelope.logout_ok,
        progress_found = envelope.progress_found,
    }
end

Task.messages = messages

return Task

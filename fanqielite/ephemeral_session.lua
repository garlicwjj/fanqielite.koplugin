local Import = require("fanqielite.import")

local Session = {}
Session.__index = Session

Session.MAX_DURATION = 5 * 60
Session.MAX_QR_BYTES = 2048
Session.MAX_POLL_TICKET_BYTES = 4096
Session.MAX_COOKIE_BYTES = 16 * 1024
Session.MAX_AUTHORIZATION_BYTES = 16 * 1024
Session.MAX_TOKEN_BYTES = 4096

local credential_limits = {
    cookie = Session.MAX_COOKIE_BYTES,
    authorization = Session.MAX_AUTHORIZATION_BYTES,
    csrf_token = Session.MAX_TOKEN_BYTES,
    logout_ticket = Session.MAX_TOKEN_BYTES,
}

local active_states = {
    initializing = true,
    qr_pending = true,
    authorized = true,
    fetching = true,
    logging_out = true,
    ready_to_confirm = true,
    committing = true,
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do output[copy(key, seen)] = copy(child, seen) end
    return output
end

local function current(self, run_id, expected)
    if run_id ~= self._run_id then return nil, "本次扫码已失效，请以当前页面为准" end
    if expected and self._state ~= expected then return nil, "扫码流程状态无效，请重新开始" end
    return true
end

local function bounded_text(value, maximum)
    return type(value) == "string" and value ~= "" and #value <= maximum
        and not value:find("[%z\1-\31\127]")
end

local function bounded_credentials(credentials)
    if type(credentials) ~= "table" then return nil end
    local output = {}
    for key, value in pairs(credentials) do
        local maximum = type(key) == "string" and credential_limits[key] or nil
        if not maximum or not bounded_text(value, maximum) then return nil end
        output[key] = value
    end
    if output.cookie == nil and output.authorization == nil then return nil end
    return output
end

local function cleanup_notice(cleaned)
    if cleaned == false then
        return "官方会话退出未完成；Kindle 未保留账号凭证，请稍后在账号安全页面检查会话。"
    end
end

local function attempt_cleanup(self, cleanup)
    local sensitive = self._sensitive
    local cleaned
    self._state = "logging_out"
    if sensitive ~= nil then
        if type(cleanup) ~= "function" then
            cleaned = false
        else
            local called, result = pcall(cleanup, sensitive)
            cleaned = called and result and true or false
        end
    end
    if type(sensitive) == "table" then
        for key in pairs(sensitive) do sensitive[key] = nil end
    end
    self._sensitive = nil
    self._qr_expires_at = nil
    self._deadline = nil
    self._logout_ok = cleaned
    return cleaned
end

local function terminate(self, cleanup)
    self._pending_books = nil
    local cleaned = attempt_cleanup(self, cleanup)
    self._state = "done"
    return true, cleanup_notice(cleaned)
end

function Session.new(clock)
    return setmetatable({
        _clock = type(clock) == "function" and clock or os.time,
        _state = "idle",
        _generation = 0,
    }, Session)
end

function Session:status()
    return {
        state = self._state,
        run_id = self._run_id,
        has_sensitive = self._sensitive ~= nil,
        has_books = self._pending_books ~= nil,
        logout_ok = self._logout_ok,
    }
end

function Session:start()
    if active_states[self._state] then return nil, "已有扫码导入正在进行，请先完成或取消" end
    local now = tonumber(self._clock()) or 0
    self._generation = self._generation + 1
    self._run_id = self._generation
    self._state = "initializing"
    self._deadline = now + Session.MAX_DURATION
    self._qr_expires_at = nil
    self._sensitive = nil
    self._pending_books = nil
    self._logout_ok = nil
    return self._run_id
end

function Session:qr_ready(run_id, qr_payload, poll_ticket, expires_at)
    local valid, valid_err = current(self, run_id, "initializing")
    if not valid then return nil, valid_err end
    local now = tonumber(self._clock()) or 0
    expires_at = tonumber(expires_at)
    if not bounded_text(qr_payload, Session.MAX_QR_BYTES)
            or not bounded_text(poll_ticket, Session.MAX_POLL_TICKET_BYTES)
            or not expires_at or expires_at ~= expires_at or expires_at <= now then
        return nil, "官方二维码数据无效，扫码导入没有开始"
    end
    self._sensitive = { qr_payload = qr_payload, poll_ticket = poll_ticket }
    self._qr_expires_at = math.min(expires_at, self._deadline)
    self._state = "qr_pending"
    return true
end

function Session:authorize(run_id, credentials)
    local valid, valid_err = current(self, run_id, "qr_pending")
    if not valid then return nil, valid_err end
    local bounded = bounded_credentials(credentials)
    if not bounded then return nil, "官方授权结果无效，未读取书架" end
    self._sensitive = bounded
    self._qr_expires_at = nil
    self._state = "authorized"
    return true
end

function Session:begin_fetch(run_id)
    local valid, valid_err = current(self, run_id, "authorized")
    if not valid then return nil, valid_err end
    self._state = "fetching"
    return true
end

function Session:prepare_import(run_id, books, cleanup)
    local valid, valid_err = current(self, run_id, "fetching")
    if not valid then return nil, valid_err end
    local normalized = Import.validate({
        format = Import.FORMAT,
        version = Import.VERSION,
        books = books,
    })
    if not normalized then
        terminate(self, cleanup)
        return nil, "官方书架数据验证失败；本地书架和阅读进度没有改变。"
    end
    self._pending_books = normalized
    local cleaned = attempt_cleanup(self, cleanup)
    self._state = "ready_to_confirm"
    return true, cleanup_notice(cleaned)
end

function Session:begin_commit(run_id)
    local valid, valid_err = current(self, run_id, "ready_to_confirm")
    if not valid then return nil, valid_err end
    self._state = "committing"
    return copy(self._pending_books)
end

function Session:complete_commit(run_id, succeeded)
    local valid, valid_err = current(self, run_id, "committing")
    if not valid then return nil, valid_err end
    if succeeded then
        self._pending_books = nil
        self._state = "done"
    else
        self._state = "ready_to_confirm"
    end
    return true
end

function Session:cancel(run_id, cleanup)
    if run_id == self._run_id and self._state == "done" then return true end
    local valid, valid_err = current(self, run_id)
    if not valid then return nil, valid_err end
    if not active_states[self._state] then return nil, "当前没有可取消的扫码导入" end
    return terminate(self, cleanup)
end

function Session:fail(run_id, cleanup)
    local valid, valid_err = current(self, run_id)
    if not valid then return nil, valid_err end
    if not active_states[self._state] then return nil, "当前扫码导入已经结束" end
    local _, notice = terminate(self, cleanup)
    local message = "扫码导入未完成；本地书架和阅读进度没有改变。"
    if notice then message = message .. "\n" .. notice end
    return true, message
end

function Session:check_timeout(run_id, cleanup)
    local valid, valid_err = current(self, run_id)
    if not valid then return nil, valid_err end
    if not active_states[self._state] then return false end
    local now = tonumber(self._clock()) or 0
    local qr_expired = self._qr_expires_at and now >= self._qr_expires_at
    local overall_expired = self._deadline and now >= self._deadline
    if not qr_expired and not overall_expired then return false end
    local _, notice = terminate(self, cleanup)
    local message = qr_expired
        and "二维码已过期；本地书架和阅读进度没有改变。"
        or "扫码导入已超时；本地书架和阅读进度没有改变。"
    if notice then message = message .. "\n" .. notice end
    return true, message
end

function Session:force_clear()
    self._sensitive = nil
    self._pending_books = nil
    self._qr_expires_at = nil
    self._deadline = nil
    self._logout_ok = nil
    self._state = "done"
    return true
end

return Session

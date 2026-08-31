local dump = require("dump")
local ffiUtil = require("ffi/util")
local SafeTemporary = require("fanqielite.safetemporary")

local Persistence = {}

local sensitive_exact_keys = {
    account = true,
    accountid = true,
    authheader = true,
    authheaders = true,
    avatar = true,
    bearer = true,
    deviceid = true,
    header = true,
    headers = true,
    login = true,
    loginticket = true,
    mobile = true,
    phone = true,
    qr = true,
    sid = true,
    telephone = true,
    ticket = true,
    uid = true,
    userid = true,
    username = true,
}

local sensitive_key_fragments = {
    "authorization",
    "cookie",
    "credential",
    "csrf",
    "passport",
    "password",
    "qrcode",
    "qrpayload",
    "secret",
    "session",
    "token",
}

local function contains_sensitive_field(value, seen)
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, child in pairs(value) do
        if type(key) == "string" then
            local normalized = key:lower():gsub("[^%a%d]", "")
            if sensitive_exact_keys[normalized] then return true end
            for _, fragment in ipairs(sensitive_key_fragments) do
                if normalized:find(fragment, 1, true) then return true end
            end
        end
        if contains_sensitive_field(child, seen) then return true end
    end
    return false
end

function Persistence.copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do
        output[Persistence.copy(key, seen)] = Persistence.copy(item, seen)
    end
    return output
end

function Persistence.equal(left, right, seen)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    seen = seen or {}
    if seen[left] then return seen[left] == right end
    seen[left] = right
    for key, value in pairs(left) do
        if not Persistence.equal(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function verify(path, expected)
    local ok, loaded = pcall(dofile, path)
    if not ok or type(loaded) ~= "table" then return nil, "写入后的设置文件无法读取" end
    if not Persistence.equal(loaded, expected) then return nil, "写入后的设置内容校验不一致" end
    return true
end

local function discard(path)
    pcall(os.remove, path)
end

local function atomic_write(path, data)
    local serialized_ok, serialized = pcall(dump, data, nil, true)
    if not serialized_ok or type(serialized) ~= "string" then
        return nil, "无法序列化插件设置"
    end
    local temporary = path .. ".tmp"
    local prepared, prepare_err = SafeTemporary.prepare(temporary, "临时设置文件")
    if not prepared then return nil, prepare_err end
    local open_call, file = pcall(io.open, temporary, "wb")
    if not open_call or not file then return nil, "无法创建临时设置文件" end

    local write_call, wrote = pcall(file.write, file, "return " .. serialized .. "\n")
    local sync_call, synced = pcall(ffiUtil.fsyncOpenedFile, file)
    local close_call, closed = pcall(file.close, file)
    if not write_call or not wrote then
        discard(temporary)
        return nil, "写入临时设置失败"
    end
    if not sync_call or not synced then
        discard(temporary)
        return nil, "同步临时设置失败"
    end
    if not close_call or not closed then
        discard(temporary)
        return nil, "完成设置写入失败"
    end
    local valid, validation_err = verify(temporary, data)
    if not valid then discard(temporary); return nil, validation_err end

    local rename_call, renamed = pcall(os.rename, temporary, path)
    if not rename_call or not renamed then
        discard(temporary)
        return nil, "无法原子替换设置文件"
    end
    local valid, validation_err = verify(path, data)
    if not valid then return nil, validation_err end
    -- The data file itself is already fsync'ed. Directory fsync is best-effort
    -- because a failed directory sync happens after the atomic rename.
    pcall(ffiUtil.fsyncDirectory, path)
    return true
end

function Persistence.write(path, candidate, previous)
    if type(path) ~= "string" or path == "" then return nil, "设置文件路径无效" end
    if type(candidate) ~= "table" then return nil, "插件设置必须是对象" end
    if contains_sensitive_field(candidate) or contains_sensitive_field(previous) then
        return nil, "拒绝保存账号凭证、二维码会话或授权请求头字段"
    end
    if previous ~= nil then
        local backup_ok, backup_err = atomic_write(path .. ".old", previous)
        if not backup_ok then
            local detail = type(backup_err) == "string" and backup_err or "备份写入失败"
            return nil, "无法保存上一版设置：" .. detail .. "；本次设置未写入"
        end
    end
    return atomic_write(path, candidate)
end

return Persistence

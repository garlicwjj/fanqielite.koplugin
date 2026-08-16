local dump = require("dump")
local ffiUtil = require("ffi/util")

local Persistence = {}

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

local function atomic_write(path, data)
    local serialized_ok, serialized = pcall(dump, data, nil, true)
    if not serialized_ok then return nil, "无法序列化插件设置" end
    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, "无法创建临时设置文件：" .. tostring(open_err) end

    local write_call, wrote, write_err = pcall(file.write, file, "return " .. serialized .. "\n")
    local sync_call, synced, sync_err = pcall(ffiUtil.fsyncOpenedFile, file)
    local close_call, closed, close_err = pcall(file.close, file)
    if not write_call or not wrote then
        os.remove(temporary)
        return nil, "写入临时设置失败：" .. tostring(write_call and write_err or wrote)
    end
    if not sync_call or not synced then
        os.remove(temporary)
        return nil, "同步临时设置失败：" .. tostring(sync_call and sync_err or synced)
    end
    if not close_call or not closed then
        os.remove(temporary)
        return nil, "完成设置写入失败：" .. tostring(close_call and close_err or closed)
    end
    local valid, validation_err = verify(temporary, data)
    if not valid then os.remove(temporary); return nil, validation_err end

    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, "无法原子替换设置文件：" .. tostring(rename_err)
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
    if previous ~= nil then
        local backup_ok, backup_err = atomic_write(path .. ".old", previous)
        if not backup_ok then return nil, "无法保存上一版设置：" .. tostring(backup_err) end
    end
    return atomic_write(path, candidate)
end

return Persistence

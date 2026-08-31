package.path = "./?.lua;./?/init.lua;" .. package.path

local function serialize(value)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    assert(kind == "table", "unsupported test value")
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local output = { "{" }
    for _, key in ipairs(keys) do
        output[#output + 1] = "[" .. serialize(key) .. "]=" .. serialize(value[key]) .. ","
    end
    output[#output + 1] = "}"
    return table.concat(output)
end

local dump_override
package.preload["dump"] = function()
    return function(value)
        if dump_override ~= nil then return dump_override end
        return serialize(value)
    end
end

local sync_ok, sync_err = true, nil
local symlink_modes = {}
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function() return sync_ok, sync_err end,
        fsyncDirectory = function() return true end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        symlinkattributes = function(path, attribute)
            if attribute == "mode" then return symlink_modes[path] end
        end,
    }
end

local Persistence = require("fanqielite.persistence")

local base = "/tmp/fanqielite-persistence-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000))
local path = base .. ".lua"
local previous = { library = { version = 1, books = {} }, active_book_id = "10000000001" }
local candidate = { library = { version = 1, books = { { id = "10000000002" } } } }

local initial_ok, initial_err = Persistence.write(path, previous, nil)
assert(initial_ok, "initial settings write failed: " .. tostring(initial_err))
local replace_ok, replace_err = Persistence.write(path, candidate, previous)
assert(replace_ok, "replacement settings write failed: " .. tostring(replace_err))

local loaded = assert(dofile(path))
assert(Persistence.equal(loaded, candidate), "main settings do not match candidate")
local backup = assert(dofile(path .. ".old"))
assert(Persistence.equal(backup, previous), "backup does not contain previous state")

local original_open = io.open
local original_rename = os.rename
local original_remove = os.remove
local main_rename_called = false
local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local error_tostring_calls = 0
local function unsafe_error()
    return setmetatable({}, { __tostring = function()
        error_tostring_calls = error_tostring_calls + 1
        return canary
    end })
end

local linked_path = base .. "-linked.lua"
local linked_temporary = linked_path .. ".tmp"
symlink_modes[linked_temporary] = "link"
local linked_removed = false
io.open = function(filename, mode)
    assert(filename ~= linked_temporary or mode ~= "wb" or symlink_modes[filename] == nil,
        "linked settings temporary was opened before removal")
    return original_open(filename, mode)
end
os.remove = function(filename)
    if filename == linked_temporary then
        linked_removed = true
        symlink_modes[filename] = nil
        return true
    end
    return original_remove(filename)
end
local linked_written = assert(Persistence.write(linked_path, candidate, nil))
io.open = original_open
os.remove = original_remove
assert(linked_written and linked_removed, "linked settings temporary was not safely replaced")

io.open = function(filename, mode)
    if filename == path .. ".tmp" and mode == "wb" then
        return {
            write = function() return true end,
            close = function() return nil, unsafe_error() end,
        }
    end
    return original_open(filename, mode)
end
os.rename = function(source, target)
    if target == path then main_rename_called = true end
    return original_rename(source, target)
end

local failed, failure_err = Persistence.write(path, previous, candidate)
io.open = original_open
os.rename = original_rename

assert(failed == nil, "close-time failure reported as success")
assert(failure_err:find("完成设置写入失败", 1, true), "close failure stage missing")
assert(not failure_err:find(canary, 1, true), "close error leaked raw content")
assert(error_tostring_calls == 0, "close error invoked __tostring")
assert(not main_rename_called, "main settings renamed after failed close")
assert(Persistence.equal(assert(dofile(path)), candidate), "failed write changed existing settings")
assert(original_open(path .. ".tmp", "rb") == nil, "close failure left main temporary file")

sync_ok, sync_err = false, unsafe_error()
local sync_failed, sync_failure_err = Persistence.write(path, previous, candidate)
sync_ok, sync_err = true, nil
assert(sync_failed == nil, "fsync failure reported as success")
assert(sync_failure_err:find("同步临时设置失败", 1, true), "fsync failure stage missing")
assert(not sync_failure_err:find(canary, 1, true), "fsync error leaked raw content")
assert(error_tostring_calls == 0, "fsync error invoked __tostring")
assert(Persistence.equal(assert(dofile(path)), candidate), "fsync failure changed existing settings")
assert(original_open(path .. ".old.tmp", "rb") == nil, "fsync failure left backup temporary file")

dump_override = unsafe_error()
local encode_failed, encode_err = Persistence.write(base .. "-encode.lua", candidate, nil)
dump_override = nil
assert(encode_failed == nil, "non-string serialization reported as success")
assert(encode_err:find("无法序列化", 1, true), "serialization failure stage missing")
assert(not encode_err:find(canary, 1, true), "serialization object leaked raw content")
assert(error_tostring_calls == 0, "serialization object invoked __tostring")

local open_path = base .. "-open.lua"
io.open = function(filename, mode)
    if filename == open_path .. ".tmp" and mode == "wb" then error(unsafe_error()) end
    return original_open(filename, mode)
end
local open_failed, open_failure_err = Persistence.write(open_path, candidate, nil)
io.open = original_open
assert(open_failed == nil, "open failure reported as success")
assert(open_failure_err:find("无法创建临时设置文件", 1, true), "open failure stage missing")
assert(not open_failure_err:find(canary, 1, true), "open error leaked raw content")
assert(error_tostring_calls == 0, "open error invoked __tostring")
assert(original_open(open_path, "rb") == nil, "open failure created settings file")

local rename_path = base .. "-rename.lua"
os.rename = function(source, target)
    if target == rename_path then error(unsafe_error()) end
    return original_rename(source, target)
end
local rename_failed, rename_failure_err = Persistence.write(rename_path, candidate, nil)
os.rename = original_rename
assert(rename_failed == nil, "rename failure reported as success")
assert(rename_failure_err:find("无法原子替换设置文件", 1, true), "rename failure stage missing")
assert(not rename_failure_err:find(canary, 1, true), "rename error leaked raw content")
assert(error_tostring_calls == 0, "rename error invoked __tostring")
assert(original_open(rename_path, "rb") == nil, "rename failure created main settings file")
assert(original_open(rename_path .. ".tmp", "rb") == nil, "rename failure left temporary file")

local forbidden_candidates = {
    { library = { version = 1, books = { { id = "10000000003", sessionid = canary } } } },
    { library = { version = 1, books = {} }, auth_headers = { Cookie = canary } },
    { library = { version = 1, books = {} }, qr_payload = canary },
    { library = { version = 1, books = {} }, login_ticket = canary },
}
for index, unsafe_candidate in ipairs(forbidden_candidates) do
    local unsafe_path = base .. "-unsafe-" .. tostring(index) .. ".lua"
    local unsafe_written, unsafe_err = Persistence.write(unsafe_path, unsafe_candidate, nil)
    assert(unsafe_written == nil, "credential-bearing settings were persisted")
    assert(unsafe_err and unsafe_err:find("账号凭证", 1, true),
        "credential persistence rejection is not actionable")
    assert(not unsafe_err:find(canary, 1, true), "credential canary leaked into persistence error")
    assert(io.open(unsafe_path, "rb") == nil, "credential-bearing settings file was created")
end

local unsafe_previous_path = base .. "-unsafe-previous.lua"
local unsafe_previous_written, unsafe_previous_err = Persistence.write(
    unsafe_previous_path,
    { library = { version = 1, books = {} } },
    { library = { version = 1, books = {} }, authorization = canary })
assert(unsafe_previous_written == nil, "credential-bearing previous settings were backed up")
assert(unsafe_previous_err and unsafe_previous_err:find("账号凭证", 1, true),
    "credential-bearing backup rejection is not actionable")
assert(not unsafe_previous_err:find(canary, 1, true),
    "credential canary leaked into unsafe backup error")
assert(io.open(unsafe_previous_path, "rb") == nil, "main file was created after unsafe backup rejection")
assert(io.open(unsafe_previous_path .. ".old", "rb") == nil,
    "credential-bearing backup file was created")

local safe_text_path = base .. "-safe-text.lua"
local safe_text = {
    library = { version = 1, books = { {
        id = "10000000004", title = "书名中可以出现 Cookie 和 Token 这些普通文字",
    } } },
}
local safe_text_written, safe_text_err = Persistence.write(safe_text_path, safe_text, nil)
assert(safe_text_written, "ordinary title text was rejected: " .. tostring(safe_text_err))
assert(Persistence.equal(assert(dofile(safe_text_path)), safe_text), "safe title text changed")

os.remove(path)
os.remove(path .. ".old")
os.remove(path .. ".tmp")
os.remove(path .. ".old.tmp")
os.remove(safe_text_path)
os.remove(open_path)
os.remove(open_path .. ".tmp")
os.remove(rename_path)
os.remove(rename_path .. ".tmp")
os.remove(base .. "-encode.lua")
os.remove(base .. "-encode.lua.tmp")
os.remove(linked_path)
os.remove(linked_temporary)

print("persistence tests passed")

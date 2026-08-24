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

package.preload["dump"] = function() return serialize end

local sync_ok, sync_err = true, nil
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function() return sync_ok, sync_err end,
        fsyncDirectory = function() return true end,
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
local main_rename_called = false
io.open = function(filename, mode)
    if filename == path .. ".tmp" and mode == "wb" then
        return {
            write = function() return true end,
            close = function() return nil, "simulated disk full" end,
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
assert(failure_err:find("simulated disk full", 1, true), "close error detail missing")
assert(not main_rename_called, "main settings renamed after failed close")
assert(Persistence.equal(assert(dofile(path)), candidate), "failed write changed existing settings")

sync_ok, sync_err = false, "simulated fsync failure"
local sync_failed, sync_failure_err = Persistence.write(path, previous, candidate)
sync_ok, sync_err = true, nil
assert(sync_failed == nil, "fsync failure reported as success")
assert(sync_failure_err:find("simulated fsync failure", 1, true), "fsync error detail missing")
assert(Persistence.equal(assert(dofile(path)), candidate), "fsync failure changed existing settings")

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
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

print("persistence tests passed")

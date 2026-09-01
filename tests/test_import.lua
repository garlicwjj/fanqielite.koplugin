package.path = "./?.lua;./?/init.lua;" .. package.path

local decode_handler
local filesystem_canary = "FANQIELITE_IMPORT_ERROR_CANARY_2c74"
local filesystem_tostring_calls = 0
local function unsafe_filesystem_error()
    return setmetatable({}, { __tostring = function()
        filesystem_tostring_calls = filesystem_tostring_calls + 1
        return filesystem_canary
    end })
end
package.preload["rapidjson"] = function()
    return { decode = function(contents) return decode_handler(contents) end }
end

local Import = require("fanqielite.import")

local function valid_payload()
    return {
        format = "fanqielite-bookshelf",
        version = 1,
        exported_at = "2026-08-16T12:00:00Z",
        books = {{
            id = "7633875868615461950",
            title = "  测试书籍  ",
            author = "测试作者",
            cover_url = "https://example.invalid/cover.jpg",
            current_chapter_id = "10000000002",
            current_chapter_title = "第二章",
            reading_position = 0.5,
        }},
    }
end

local function rejected(payload, expected)
    local result, err = Import.validate(payload)
    assert(result == nil, "unsafe payload accepted")
    assert(err and err:find(expected, 1, true), "expected error containing " .. expected .. ", got " .. tostring(err))
end

local books = assert(Import.validate(valid_payload()))
assert(#books == 1)
assert(books[1].title == "测试书籍", "title not trimmed")
assert(books[1].imported_progress.chapter_id == "10000000002")
assert(books[1].imported_progress.position == 0.5)

local payload = valid_payload()
payload.cookie = "secret"
rejected(payload, "禁止的账号凭证字段")

payload = valid_payload()
payload.books[1].access_token = "secret"
rejected(payload, "禁止的账号凭证字段")

payload = valid_payload()
payload.books[1].phone_number = "13800000000"
rejected(payload, "禁止的账号凭证字段")

payload = valid_payload()
payload.books[1].unknown = "data"
rejected(payload, "未知字段")

payload = valid_payload()
payload.books[1]["unknown_" .. filesystem_canary] = "data"
local unknown_result, unknown_err = Import.validate(payload)
assert(unknown_result == nil and unknown_err:find("未知字段", 1, true),
    "unknown field was not rejected")
assert(not unknown_err:find(filesystem_canary, 1, true),
    "unknown field name leaked into the import error")

payload = valid_payload()
payload.books[1]["cookie_" .. filesystem_canary] = "secret"
local credential_result, credential_err = Import.validate(payload)
assert(credential_result == nil and credential_err:find("凭证字段", 1, true),
    "credential field was not rejected")
assert(not credential_err:find(filesystem_canary, 1, true),
    "credential field name leaked into the import error")

payload = valid_payload()
payload[unsafe_filesystem_error()] = "data"
local object_key_result, object_key_err = Import.validate(payload)
assert(object_key_result == nil and object_key_err:find("未知字段", 1, true),
    "object field key was not rejected")
assert(not object_key_err:find(filesystem_canary, 1, true),
    "object field key leaked into the import error")
assert(filesystem_tostring_calls == 0, "object field key invoked __tostring")

payload = valid_payload()
payload.books[1].id = 7633875868615461950
rejected(payload, "数字字符串")

payload = valid_payload()
payload.books[1].title = string.rep("x", 301)
rejected(payload, "过长")

payload = valid_payload()
payload.books[1].title = "标题\n伪造提示"
rejected(payload, "控制字符")

payload = valid_payload()
payload.books[2] = payload.books[1]
rejected(payload, "重复书籍 ID")

payload = valid_payload()
payload.books[1].cover_url = "http://example.invalid/cover.jpg"
rejected(payload, "必须使用 HTTPS")

payload = valid_payload()
payload.books[1].reading_position = 1.1
rejected(payload, "0 到 1")

payload = valid_payload()
payload.books[1].reading_position = 0 / 0
rejected(payload, "0 到 1")

payload = valid_payload()
payload.books.extra = payload.books[1]
rejected(payload, "连续数组")

payload = valid_payload()
payload.books[3] = {
    id = "7334567890123456789",
    title = "稀疏数组",
}
rejected(payload, "连续数组")

payload = valid_payload()
for index = 2, 501 do
    payload.books[index] = {
        id = tostring(7000000000000000000 + index),
        title = "书籍 " .. tostring(index),
    }
end
rejected(payload, "最多导入 500")

decode_handler = function() error("malformed") end
local decoded, decode_err = Import.decode("{")
assert(decoded == nil and decode_err:find("JSON 解析失败", 1, true))

local temporary = "/tmp/fanqielite-bookshelf.json"
local file = assert(io.open(temporary, "wb"))
assert(file:write("{}"))
file:close()
decode_handler = function() return valid_payload() end
local from_file = assert(Import.read_file(temporary))
assert(#from_file == 1, "valid file import failed")

file = assert(io.open(temporary, "wb"))
assert(file:write(string.rep("x", Import.MAX_BYTES + 1)))
file:close()
local oversized, oversized_err = Import.read_file(temporary)
assert(oversized == nil and oversized_err:find("256 KB", 1, true))

local real_open = io.open
io.open = function() error(unsafe_filesystem_error()) end
local open_failed, open_err = Import.read_file(temporary)
io.open = real_open
assert(open_failed == nil and open_err:find("无法打开导入文件", 1, true))
assert(not open_err:find(filesystem_canary, 1, true), "import open leaked raw content")
assert(filesystem_tostring_calls == 0, "import open invoked __tostring")

io.open = function()
    return {
        seek = function() error(unsafe_filesystem_error()) end,
        close = function() return true end,
    }
end
local size_failed, size_err = Import.read_file(temporary)
io.open = real_open
assert(size_failed == nil and size_err:find("无法确认导入文件大小", 1, true))
assert(not size_err:find(filesystem_canary, 1, true), "import size check leaked raw content")
assert(filesystem_tostring_calls == 0, "import size check invoked __tostring")

io.open = function()
    return {
        seek = function(_, whence)
            if whence == "end" then return 2 end
            error(unsafe_filesystem_error())
        end,
        read = function() error(unsafe_filesystem_error()) end,
        close = function() return true end,
    }
end
local seek_failed, seek_err = Import.read_file(temporary)
io.open = real_open
assert(seek_failed == nil and seek_err:find("无法读取导入文件", 1, true))
assert(not seek_err:find(filesystem_canary, 1, true), "import seek leaked raw content")
assert(filesystem_tostring_calls == 0, "import seek invoked __tostring")

io.open = function()
    return {
        seek = function(_, whence) return whence == "end" and 2 or 0 end,
        read = function() error(unsafe_filesystem_error()) end,
        close = function() return true end,
    }
end
local read_failed, read_err = Import.read_file(temporary)
io.open = real_open
assert(read_failed == nil and read_err:find("无法读取导入文件", 1, true))
assert(not read_err:find(filesystem_canary, 1, true), "import read leaked raw content")
assert(filesystem_tostring_calls == 0, "import read invoked __tostring")

io.open = function()
    return {
        seek = function(_, whence) return whence == "end" and 2 or 0 end,
        read = function() return "{}" end,
        close = function() return nil, unsafe_filesystem_error() end,
    }
end
local close_failed, close_err = Import.read_file(temporary)
io.open = real_open
assert(close_failed == nil and close_err:find("无法关闭导入文件", 1, true))
assert(not close_err:find(filesystem_canary, 1, true), "import close leaked raw content")
assert(filesystem_tostring_calls == 0, "import close invoked __tostring")

os.remove(temporary)

local wrong_name, wrong_name_err = Import.read_file("/tmp/books.json")
assert(wrong_name == nil and wrong_name_err:find(Import.FILENAME, 1, true))

print("import tests passed")

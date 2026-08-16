package.path = "./?.lua;./?/init.lua;" .. package.path

local decode_handler
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
os.remove(temporary)

local wrong_name, wrong_name_err = Import.read_file("/tmp/books.json")
assert(wrong_name == nil and wrong_name_err:find(Import.FILENAME, 1, true))

print("import tests passed")

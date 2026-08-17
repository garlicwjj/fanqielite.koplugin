package.path = "./?.lua;./?/init.lua;" .. package.path

local encoded_payload
local encoded_contents = "{\"format\":\"fanqielite-bookshelf\"}"
local decode_handler
local sync_ok, sync_err = true, nil
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function() return sync_ok, sync_err end,
        fsyncDirectory = function() return true end,
    }
end
package.preload["rapidjson"] = function()
    return {
        encode = function(payload)
            encoded_payload = payload
            return encoded_contents
        end,
        decode = function(contents) return decode_handler(contents) end,
    }
end

local Export = require("fanqielite.export")
local Import = require("fanqielite.import")

local library = {
    books = {
        {
            id = "7633875868615461950",
            title = "本地书",
            author = "作者甲",
            cover_url = "https://example.invalid/cover.jpg",
            chapters = {
                { id = "10000000001", title = "第一章" },
                { id = "10000000002", title = "第二章" },
            },
            current_index = 2,
            imported_progress = {
                chapter_id = "10000000001", chapter_title = "第一章", position = 0.75,
            },
            cookie = "must-never-be-exported",
        },
        {
            id = "7334567890123456789",
            title = "待获取目录",
            author = "",
            chapters = {},
            current_index = 1,
            imported_progress = {
                chapter_id = "20000000001", chapter_title = "导入章节", position = 0.25,
            },
        },
    },
}

local payload = assert(Export.build(library, "2026-08-17T12:00:00Z"))
assert(payload.format == Import.FORMAT and payload.version == Import.VERSION)
assert(#payload.books == 2)
assert(payload.books[1].current_chapter_id == "10000000002")
assert(payload.books[1].current_chapter_title == "第二章")
assert(payload.books[1].reading_position == nil, "must not invent local within-chapter position")
assert(payload.books[1].cookie == nil, "non-whitelisted credential field was exported")
assert(payload.books[2].current_chapter_id == "20000000001")
assert(payload.books[2].reading_position == 0.25)
assert(Import.validate(payload), "export must satisfy the import whitelist")

local empty, empty_err = Export.build({ books = {} }, "2026-08-17T12:00:00Z")
assert(empty == nil and empty_err:find("书架为空", 1, true))

local path = "/tmp/" .. Import.FILENAME
local old = assert(io.open(path, "wb"))
assert(old:write("previous export"))
old:close()

decode_handler = function() return encoded_payload end
local count = assert(Export.write(path, library, "2026-08-17T12:00:00Z"))
assert(count == 2)
local verified = assert(Import.read_file(path))
assert(#verified == 2, "written export did not pass import validation")
assert(io.open(path .. ".tmp", "rb") == nil, "temporary export was left behind")

sync_ok, sync_err = nil, "disk full"
local unsynced, unsynced_err = Export.write(path, library, "2026-08-17T12:00:00Z")
sync_ok, sync_err = true, nil
assert(unsynced == nil and unsynced_err:find("同步临时导出文件失败", 1, true))
local after_sync_failure = assert(io.open(path, "rb"))
assert(after_sync_failure:read("*a") == encoded_contents, "sync failure replaced old export")
after_sync_failure:close()
assert(io.open(path .. ".tmp", "rb") == nil, "sync failure left a temporary file")

encoded_contents = string.rep("x", Import.MAX_BYTES + 1)
local oversized, oversized_err = Export.write(path, library, "2026-08-17T12:00:00Z")
encoded_contents = "{\"format\":\"fanqielite-bookshelf\"}"
assert(oversized == nil and oversized_err:find("256 KB", 1, true))
local after_oversized = assert(io.open(path, "rb"))
assert(after_oversized:read("*a") == encoded_contents, "oversized export replaced old file")
after_oversized:close()

local real_rename = os.rename
os.rename = function() return nil, "read-only filesystem" end
local failed, failed_err = Export.write(path, library, "2026-08-17T12:00:00Z")
os.rename = real_rename
assert(failed == nil and failed_err:find("无法替换导出文件", 1, true))
local preserved = assert(io.open(path, "rb"))
assert(preserved:read("*a") == encoded_contents, "failed export replaced old file")
preserved:close()
assert(io.open(path .. ".tmp", "rb") == nil, "failed export left a temporary file")

local wrong, wrong_err = Export.write("/tmp/books.json", library, "2026-08-17T12:00:00Z")
assert(wrong == nil and wrong_err:find(Import.FILENAME, 1, true))

os.remove(path)
print("local export tests passed")

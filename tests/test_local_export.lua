package.path = "./?.lua;./?/init.lua;" .. package.path

local encoded_payload
local encoded_contents = "{\"format\":\"fanqielite-bookshelf\"}"
local encode_error
local encode_tostring_calls = 0
local filesystem_tostring_calls = 0
local filesystem_canary = "FANQIELITE_EXPORT_ERROR_CANARY_63bd"
local function unsafe_filesystem_error()
    return setmetatable({}, { __tostring = function()
        filesystem_tostring_calls = filesystem_tostring_calls + 1
        return filesystem_canary
    end })
end
local decode_handler
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
package.preload["rapidjson"] = function()
    return {
        encode = function(payload)
            if encode_error then error(encode_error) end
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

local sparse, sparse_err = Export.build({ books = {
    [1] = library.books[1],
    [3] = library.books[2],
} }, "2026-08-17T12:00:00Z")
assert(sparse == nil and sparse_err:find("结构", 1, true),
    "sparse in-memory library was partially exported")

local mixed, mixed_err = Export.build({ books = {
    library.books[1],
    unexpected = library.books[2],
} }, "2026-08-17T12:00:00Z")
assert(mixed == nil and mixed_err:find("结构", 1, true),
    "mixed-key in-memory library was partially exported")

local malformed_call, malformed, malformed_err = pcall(
    Export.build, { books = { "not-a-book" } }, "2026-08-17T12:00:00Z")
assert(malformed_call, "malformed in-memory library escaped the export boundary")
assert(malformed == nil and malformed_err:find("结构", 1, true),
    "malformed in-memory book did not return a fixed export error")

local hostile_book = setmetatable({}, {
    __index = function() error(unsafe_filesystem_error()) end,
})
local hostile, hostile_err = Export.build(
    { books = { hostile_book } }, "2026-08-17T12:00:00Z")
assert(hostile == nil and hostile_err:find("结构", 1, true),
    "hostile in-memory book escaped the export boundary")
assert(not hostile_err:find(filesystem_canary, 1, true),
    "hostile in-memory book leaked raw exception content")
assert(filesystem_tostring_calls == 0, "hostile in-memory book invoked __tostring")

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

local real_open = io.open
local real_remove = os.remove
local linked_temporary = path .. ".tmp"
symlink_modes[linked_temporary] = "link"
local linked_removed = false
io.open = function(target, mode)
    assert(target ~= linked_temporary or mode ~= "wb" or symlink_modes[target] == nil,
        "linked export temporary was opened before removal")
    return real_open(target, mode)
end
os.remove = function(target)
    if target == linked_temporary then
        linked_removed = true
        symlink_modes[target] = nil
        return true
    end
    return real_remove(target)
end
local linked_count = assert(Export.write(path, library, "2026-08-17T12:00:00Z"))
io.open = real_open
os.remove = real_remove
assert(linked_count == 2 and linked_removed, "linked export temporary was not safely replaced")

encode_error = setmetatable({}, { __tostring = function()
    encode_tostring_calls = encode_tostring_calls + 1
    return "encoder exposed FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
end })
local encode_failed, encode_failed_err = Export.write(path, library, "2026-08-17T12:00:00Z")
encode_error = nil
assert(encode_failed == nil and encode_failed_err:find("无法生成书架 JSON", 1, true))
assert(not encode_failed_err:find("FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY", 1, true),
    "export error leaked encoder context")
assert(encode_tostring_calls == 0, "export stringified the raw encoder exception")
assert(io.open(path .. ".tmp", "rb") == nil, "encode failure created a temporary file")

sync_ok, sync_err = nil, unsafe_filesystem_error()
local unsynced, unsynced_err = Export.write(path, library, "2026-08-17T12:00:00Z")
sync_ok, sync_err = true, nil
assert(unsynced == nil and unsynced_err:find("同步临时导出文件失败", 1, true))
assert(not unsynced_err:find(filesystem_canary, 1, true), "export sync leaked raw content")
assert(filesystem_tostring_calls == 0, "export sync invoked __tostring")
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
os.rename = function() error(unsafe_filesystem_error()) end
local failed, failed_err = Export.write(path, library, "2026-08-17T12:00:00Z")
os.rename = real_rename
assert(failed == nil and failed_err:find("无法替换导出文件", 1, true))
assert(not failed_err:find(filesystem_canary, 1, true), "export rename leaked raw content")
assert(filesystem_tostring_calls == 0, "export rename invoked __tostring")
local preserved = assert(io.open(path, "rb"))
assert(preserved:read("*a") == encoded_contents, "failed export replaced old file")
preserved:close()
assert(io.open(path .. ".tmp", "rb") == nil, "failed export left a temporary file")

io.open = function(target, mode)
    if target == path .. ".tmp" and mode == "wb" then error(unsafe_filesystem_error()) end
    return real_open(target, mode)
end
local create_failed, create_err = Export.write(path, library, "2026-08-17T12:00:00Z")
io.open = real_open
assert(create_failed == nil and create_err:find("无法创建临时导出文件", 1, true))
assert(not create_err:find(filesystem_canary, 1, true), "export create leaked raw content")
assert(filesystem_tostring_calls == 0, "export create invoked __tostring")

io.open = function(target, mode)
    if target == path .. ".tmp" and mode == "wb" then
        return {
            write = function() error(unsafe_filesystem_error()) end,
            close = function() return true end,
        }
    end
    return real_open(target, mode)
end
local write_failed, write_err = Export.write(path, library, "2026-08-17T12:00:00Z")
io.open = real_open
assert(write_failed == nil and write_err:find("写入临时导出文件失败", 1, true))
assert(not write_err:find(filesystem_canary, 1, true), "export write leaked raw content")
assert(filesystem_tostring_calls == 0, "export write invoked __tostring")

io.open = function(target, mode)
    if target == path .. ".tmp" and mode == "wb" then
        return {
            write = function() return true end,
            close = function() return nil, unsafe_filesystem_error() end,
        }
    end
    return real_open(target, mode)
end
os.remove = function() error(unsafe_filesystem_error()) end
local close_failed, close_err = Export.write(path, library, "2026-08-17T12:00:00Z")
io.open = real_open
os.remove = real_remove
assert(close_failed == nil and close_err:find("完成导出文件写入失败", 1, true))
assert(not close_err:find(filesystem_canary, 1, true), "export close leaked raw content")
assert(filesystem_tostring_calls == 0, "export close or cleanup invoked __tostring")

io.open = function(target, mode)
    if target == path .. ".tmp" and mode == "wb" then
        return {
            write = function() return true end,
            close = function() return true end,
        }
    end
    if target == path .. ".tmp" and mode == "rb" then
        return {
            read = function() error(unsafe_filesystem_error()) end,
            close = function() return true end,
        }
    end
    return real_open(target, mode)
end
local read_failed, read_err = Export.write(path, library, "2026-08-17T12:00:00Z")
io.open = real_open
assert(read_failed == nil and read_err:find("写入后的导出文件校验失败", 1, true))
assert(not read_err:find(filesystem_canary, 1, true), "export reread leaked raw content")
assert(filesystem_tostring_calls == 0, "export reread invoked __tostring")

local wrong, wrong_err = Export.write("/tmp/books.json", library, "2026-08-17T12:00:00Z")
assert(wrong == nil and wrong_err:find(Import.FILENAME, 1, true))

os.remove(path)
print("local export tests passed")

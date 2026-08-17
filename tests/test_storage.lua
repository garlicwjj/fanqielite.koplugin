package.path = "./?.lua;./?/init.lua;" .. package.path

local removed, rmdir_path = {}, nil
local cached_mode = nil
local dir_error = nil
local names = { ".", "..", "10000000001.xhtml", "10000000002.xhtml.tmp", "notes.txt", "../escape.xhtml" }

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/safe-data" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            if path == "/safe-data/fanqielite/7633875868615461950" and attribute == "mode" then
                return "directory"
            end
            if path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"
                    and attribute == "mode" then
                return cached_mode
            end
        end,
        dir = function()
            if dir_error then error(dir_error) end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        mkdir = function() return true end,
        rmdir = function(path) rmdir_path = path; return true end,
    }
end

local original_remove = os.remove
os.remove = function(path)
    removed[#removed + 1] = path
    return true
end

local Storage = require("fanqielite.storage")
local storage = setmetatable({ root = "/safe-data/fanqielite" }, { __index = Storage })

assert(Storage.is_cache_name("10000000001.xhtml"), "chapter cache name rejected")
assert(Storage.is_cache_name("10000000001.xhtml.tmp"), "temporary cache name rejected")
assert(not Storage.is_cache_name("notes.txt"), "unowned file accepted")
assert(not Storage.is_cache_name("../100.xhtml"), "path traversal accepted")
assert(storage:cached_count("7633875868615461950") == 1, "cached count must ignore temporary and unowned files")

local count = assert(storage:clear_book("7633875868615461950"))
os.remove = original_remove

assert(count == 2, "unexpected removed count")
assert(#removed == 2, "only owned cache files may be removed")
assert(removed[1] == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml")
assert(removed[2] == "/safe-data/fanqielite/7633875868615461950/10000000002.xhtml.tmp")
assert(rmdir_path == "/safe-data/fanqielite/7633875868615461950")

local invalid = storage:clear_book("../../outside")
assert(invalid == nil, "invalid book id accepted")

names = { ".", "..", "10000000001.xhtml", "10000000002.xhtml" }
removed = {}
os.remove = function(path)
    removed[#removed + 1] = path
    if path:match("10000000002%.xhtml$") then return nil, "read-only filesystem" end
    return true
end
local partial_count, partial_err = storage:clear_book("7633875868615461950")
os.remove = original_remove
assert(partial_count == 1, "partial clear removed count is wrong")
assert(partial_err and partial_err:find("1 个", 1, true), "partial clear count missing")
assert(partial_err:find("read%-only filesystem"), "partial clear reason missing")

dir_error = "permission denied while listing"
local unreadable, unreadable_err = storage:clear_book("7633875868615461950")
dir_error = nil
assert(unreadable == nil, "unreadable cache directory reported as clear")
assert(unreadable_err:find("permission denied", 1, true), "directory error detail missing")

local valid_xhtml = '<?xml version="1.0" encoding="utf-8"?>\n'
    .. '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">'
    .. '<head><meta charset="utf-8"/></head><body><p>正文</p></body></html>'
assert(Storage.validate_chapter_contents(valid_xhtml), "valid cache rejected")

local truncated, truncated_err = Storage.validate_chapter_contents(valid_xhtml:gsub("</body></html>$", ""))
assert(truncated == nil, "truncated cache accepted")
assert(truncated_err:find("不完整", 1, true), "truncated cache error is not actionable")

local oversized = valid_xhtml .. string.rep("x", Storage.MAX_CHAPTER_BYTES)
local large, large_err = Storage.validate_chapter_contents(oversized)
assert(large == nil, "oversized cache accepted")
assert(large_err:find("过大", 1, true), "oversized cache error missing")

local control, control_err = Storage.validate_chapter_contents(valid_xhtml:gsub("正文", "正" .. string.char(0) .. "文"))
assert(control == nil, "invalid XML control character accepted")
assert(control_err:find("控制字符", 1, true), "control character error missing")

local original_open = io.open
local original_rename = os.rename
cached_mode = "file"
io.open = function()
    return {
        read = function() return valid_xhtml end,
        close = function() return true end,
    }
end
local cached_path = assert(storage:cached_chapter("7633875868615461950", "10000000001"))
assert(cached_path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml")

io.open = function()
    return {
        read = function() return valid_xhtml:gsub("</body></html>$", "") end,
        close = function() return true end,
    }
end
local corrupt_path, corrupt_err = storage:cached_chapter("7633875868615461950", "10000000001")
assert(corrupt_path == nil, "corrupt cache returned as readable")
assert(corrupt_err:find("不完整", 1, true), "corrupt cache reason missing")

local temporary_removed = false
io.open = function()
    return {
        write = function() return true end,
        close = function() return nil, "disk full on close" end,
    }
end
os.remove = function(path)
    if path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml.tmp" then
        temporary_removed = true
    end
    return true
end
os.rename = function() error("rename must not run after close failure") end
storage.chapter_path = function()
    return "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"
end

local written, write_err = storage:write_chapter("7633875868615461950", "10000000001", valid_xhtml)
io.open = original_open
os.rename = original_rename
os.remove = original_remove

assert(written == nil, "close failure accepted as successful write")
assert(write_err:find("disk full", 1, true), "close failure detail missing")
assert(temporary_removed, "temporary cache not removed after close failure")

print("storage tests passed")

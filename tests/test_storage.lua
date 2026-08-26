package.path = "./?.lua;./?/init.lua;" .. package.path

local removed, rmdir_path = {}, nil
local cached_mode = nil
local dir_error = nil
local attribute_error = nil
local dir_iteration_error = nil
local modification_times = {}
local names = { ".", "..", "10000000001.xhtml", "10000000002.xhtml.tmp", "notes.txt", "../escape.xhtml" }
local canary = "FANQIELITE_CACHE_ERROR_CANARY_91af"
local error_tostring_calls = 0
local function unsafe_error()
    return setmetatable({}, { __tostring = function()
        error_tostring_calls = error_tostring_calls + 1
        return canary
    end })
end

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/safe-data" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            if attribute_error then error(attribute_error) end
            if attribute == "modification" then return modification_times[path] end
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
                if dir_iteration_error and index == 2 then error(dir_iteration_error) end
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
    if path:match("10000000002%.xhtml$") then error(unsafe_error()) end
    return true
end
local partial_count, partial_err = storage:clear_book("7633875868615461950")
os.remove = original_remove
assert(partial_count == 1, "partial clear removed count is wrong")
assert(partial_err and partial_err:find("1 个", 1, true), "partial clear count missing")
assert(not partial_err:find(canary, 1, true), "partial clear leaked raw delete error")
assert(error_tostring_calls == 0, "partial clear invoked delete error __tostring")

dir_error = unsafe_error()
local unreadable, unreadable_err = storage:clear_book("7633875868615461950")
dir_error = nil
assert(unreadable == nil, "unreadable cache directory reported as clear")
assert(unreadable_err:find("无法打开缓存目录", 1, true), "directory failure stage missing")
assert(not unreadable_err:find(canary, 1, true), "directory error leaked raw content")
assert(error_tostring_calls == 0, "directory error invoked __tostring")

dir_iteration_error = unsafe_error()
local iteration_failed, iteration_err = storage:clear_book("7633875868615461950")
dir_iteration_error = nil
assert(iteration_failed == nil, "directory iteration failure reported as clear")
assert(iteration_err:find("无法遍历缓存目录", 1, true), "iteration failure stage missing")
assert(not iteration_err:find(canary, 1, true), "iteration error leaked raw content")
assert(error_tostring_calls == 0, "iteration error invoked __tostring")

names = { ".", "..", "10000000001.xhtml", "10000000002.xhtml" }
os.remove = function() error(unsafe_error()) end
local pruned_count, prune_err = storage:prune("7633875868615461950", 0)
os.remove = original_remove
assert(pruned_count == 0, "failed cache eviction reported as removed")
assert(prune_err and prune_err:find("2 个", 1, true), "cache eviction failure count missing")
assert(not prune_err:find(canary, 1, true), "cache eviction leaked raw delete error")
assert(error_tostring_calls == 0, "cache eviction invoked delete error __tostring")

dir_error = unsafe_error()
local unpruned, unpruned_err = storage:prune("7633875868615461950", 12)
dir_error = nil
assert(unpruned == nil, "unreadable cache directory reported as pruned")
assert(unpruned_err:find("无法打开缓存目录", 1, true), "cache prune directory stage missing")
assert(not unpruned_err:find(canary, 1, true), "cache prune directory error leaked")
assert(error_tostring_calls == 0, "cache prune directory invoked __tostring")

attribute_error = unsafe_error()
local count_failed, count_err = storage:cached_count("7633875868615461950")
attribute_error = nil
assert(count_failed == nil, "cache attribute exception reported as zero")
assert(count_err:find("无法读取缓存目录", 1, true), "attribute failure stage missing")
assert(not count_err:find(canary, 1, true), "attribute error leaked raw content")
assert(error_tostring_calls == 0, "attribute error invoked __tostring")

names = { ".", ".." }
removed = {}
modification_times = {}
for index = 1, 13 do
    local name = tostring(10000000000 + index) .. ".xhtml"
    names[#names + 1] = name
    modification_times["/safe-data/fanqielite/7633875868615461950/" .. name] = 100
end
local protected_path = "/safe-data/fanqielite/7633875868615461950/10000000013.xhtml"
modification_times[protected_path] = -100
os.remove = function(path) removed[#removed + 1] = path; return true end
local protected_pruned, protected_err = storage:prune(
    "7633875868615461950", 12, protected_path)
os.remove = original_remove
assert(protected_pruned == 1 and protected_err == nil, "protected prune count is wrong")
assert(removed[1] ~= protected_path, "newly written chapter was evicted by an older timestamp")

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

io.open = function() error(unsafe_error()) end
local open_failed, open_err = storage:cached_chapter("7633875868615461950", "10000000001")
assert(open_failed == nil, "cache open exception reported as readable")
assert(open_err:find("无法打开章节缓存", 1, true), "cache open failure stage missing")
assert(not open_err:find(canary, 1, true), "cache open error leaked raw content")
assert(error_tostring_calls == 0, "cache open error invoked __tostring")

io.open = function()
    return {
        read = function() error(unsafe_error()) end,
        close = function() return true end,
    }
end
local read_failed, read_failure_err = storage:cached_chapter("7633875868615461950", "10000000001")
assert(read_failed == nil, "cache read exception reported as readable")
assert(read_failure_err:find("无法读取章节缓存", 1, true), "cache read failure stage missing")
assert(not read_failure_err:find(canary, 1, true), "cache read error leaked raw content")
assert(error_tostring_calls == 0, "cache read error invoked __tostring")

io.open = function()
    return {
        read = function() return valid_xhtml end,
        close = function() return nil, unsafe_error() end,
    }
end
local close_failed, close_err = storage:cached_chapter("7633875868615461950", "10000000001")
assert(close_failed == nil, "cache close failure reported as readable")
assert(close_err:find("无法关闭章节缓存", 1, true), "cache close failure stage missing")
assert(not close_err:find(canary, 1, true), "cache close error leaked raw content")
assert(error_tostring_calls == 0, "cache close error invoked __tostring")

local temporary_removed = false
io.open = function()
    return {
        write = function() return true end,
        close = function() return nil, unsafe_error() end,
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
assert(write_err:find("完成缓存写入失败", 1, true), "close failure stage missing")
assert(not write_err:find(canary, 1, true), "cache write close error leaked")
assert(error_tostring_calls == 0, "cache write close error invoked __tostring")
assert(temporary_removed, "temporary cache not removed after close failure")

io.open = function() error(unsafe_error()) end
local create_failed, create_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(create_failed == nil, "cache create exception reported as success")
assert(create_err:find("无法创建临时缓存", 1, true), "cache create failure stage missing")
assert(not create_err:find(canary, 1, true), "cache create error leaked")
assert(error_tostring_calls == 0, "cache create error invoked __tostring")

temporary_removed = false
io.open = function()
    return {
        write = function() error(unsafe_error()) end,
        close = function() return true end,
    }
end
os.remove = function(path)
    if path:match("%.tmp$") then temporary_removed = true end
    return true
end
local write_failed, write_failure_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(write_failed == nil, "cache write exception reported as success")
assert(write_failure_err:find("写入缓存失败", 1, true), "cache write failure stage missing")
assert(not write_failure_err:find(canary, 1, true), "cache write error leaked")
assert(error_tostring_calls == 0, "cache write error invoked __tostring")
assert(temporary_removed, "cache write failure left temporary file")

temporary_removed = false
io.open = function()
    return {
        write = function() return true end,
        close = function() return true end,
    }
end
os.remove = function(path)
    if path:match("%.tmp$") then temporary_removed = true end
    return true
end
os.rename = function() error(unsafe_error()) end
local rename_failed, rename_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(rename_failed == nil, "cache rename exception reported as success")
assert(rename_err:find("无法替换章节缓存", 1, true), "cache rename failure stage missing")
assert(not rename_err:find(canary, 1, true), "cache rename error leaked")
assert(error_tostring_calls == 0, "cache rename error invoked __tostring")
assert(temporary_removed, "cache rename failure left temporary file")
io.open = original_open
os.rename = original_rename
os.remove = original_remove

local original_prune = storage.prune
io.open = function()
    return {
        write = function() return true end,
        close = function() return true end,
    }
end
os.rename = function() return true end
local write_protected_path
storage.prune = function(_, _, _, protected_path)
    write_protected_path = protected_path
    return 0, "2 个旧缓存无法删除"
end
local safe_path, safe_write_err, prune_warning = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
storage.prune = original_prune
io.open = original_open
os.rename = original_rename

assert(safe_path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml",
    "valid new cache was discarded after eviction warning")
assert(safe_write_err == nil, "successful cache write returned an error")
assert(write_protected_path == safe_path, "newly written cache was not protected during eviction")
assert(prune_warning and prune_warning:find("2 个旧缓存无法删除", 1, true),
    "cache eviction warning was hidden after successful write")

print("storage tests passed")

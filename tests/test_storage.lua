package.path = "./?.lua;./?/init.lua;" .. package.path

local removed, rmdir_path = {}, nil
local cached_mode = nil
local book_mode = "directory"
local mkdir_paths = {}
local dir_error = nil
local attribute_error = nil
local dir_iteration_error = nil
local modification_times = {}
local sync_ok, sync_error = true, nil
local directory_sync_calls = 0
local directory_sync_error = nil
local realpaths = {}
local realpath_error = nil
local symlink_modes = {}
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
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function() return sync_ok, sync_error end,
        fsyncDirectory = function()
            directory_sync_calls = directory_sync_calls + 1
            if directory_sync_error then error(directory_sync_error) end
            return true
        end,
        realpath = function(path)
            if realpath_error then error(realpath_error) end
            return realpaths[path] or path
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            if attribute_error then error(attribute_error) end
            if attribute == "modification" then return modification_times[path] end
            if path == "/safe-data/fanqielite/7633875868615461950" and attribute == "mode" then
                return book_mode
            end
            if path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"
                    and attribute == "mode" then
                return cached_mode
            end
        end,
        symlinkattributes = function(path, attribute)
            if attribute_error then error(attribute_error) end
            if attribute == "mode" then return symlink_modes[path] end
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
        mkdir = function(path) mkdir_paths[#mkdir_paths + 1] = path; return true end,
        rmdir = function(path) rmdir_path = path; return true end,
    }
end

local original_remove = os.remove
os.remove = function(path)
    removed[#removed + 1] = path
    return true
end

local Storage = require("fanqielite.storage")
local storage = setmetatable({
    root = "/safe-data/fanqielite",
    parent = "/safe-data",
}, { __index = Storage })

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

realpaths["/safe-data/fanqielite"] = "/outside/shared-cache"
realpaths["/safe-data/fanqielite/7633875868615461950"] =
    "/outside/shared-cache/7633875868615461950"
realpaths["/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"] =
    "/outside/shared-cache/7633875868615461950/10000000001.xhtml"
removed = {}
mkdir_paths = {}
book_mode = nil
cached_mode = "file"
local linked_root_opened = false
local root_original_open = io.open
io.open = function()
    linked_root_opened = true
    error("linked cache root must not be opened")
end
os.remove = function(path) removed[#removed + 1] = path; return true end
local linked_root_count, linked_root_err = storage:clear_book("7633875868615461950")
local linked_root_directory, linked_root_directory_err = storage:book_dir("7633875868615461950")
local linked_root_cache, linked_root_cache_err = storage:cached_chapter(
    "7633875868615461950", "10000000001")
os.remove = original_remove
io.open = root_original_open
realpaths["/safe-data/fanqielite"] = nil
realpaths["/safe-data/fanqielite/7633875868615461950"] = nil
realpaths["/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"] = nil
book_mode = "directory"
cached_mode = nil
assert(linked_root_count == nil and linked_root_err:find("安全范围", 1, true),
    "linked cache root was accepted for deletion")
assert(linked_root_directory == nil and linked_root_directory_err:find("安全范围", 1, true),
    "linked cache root was accepted for writing")
assert(linked_root_cache == nil and linked_root_cache_err:find("安全范围", 1, true),
    "linked cache root was accepted for reading")
assert(#removed == 0, "linked cache root deleted files outside the owned data directory")
assert(#mkdir_paths == 0, "linked cache root created a book directory outside the owned data directory")
assert(not linked_root_opened, "linked cache root opened a file outside the owned data directory")

realpaths["/safe-data/fanqielite/7633875868615461950"] = "/outside/linked-book-cache"
removed = {}
os.remove = function(path) removed[#removed + 1] = path; return true end
local linked_count, linked_err = storage:clear_book("7633875868615461950")
local linked_directory, linked_directory_err = storage:book_dir("7633875868615461950")
local linked_cache, linked_cache_err = storage:cached_chapter(
    "7633875868615461950", "10000000001")
os.remove = original_remove
realpaths["/safe-data/fanqielite/7633875868615461950"] = nil
assert(linked_count == nil, "linked cache directory was accepted for deletion")
assert(linked_err and linked_err:find("安全范围", 1, true),
    "linked cache directory rejection was not actionable")
assert(#removed == 0, "linked cache directory deleted a file outside the owned root")
assert(linked_directory == nil and linked_directory_err:find("安全范围", 1, true),
    "linked cache directory was accepted for writing")
assert(linked_cache == nil and linked_cache_err:find("安全范围", 1, true),
    "linked cache directory was accepted for reading")

realpath_error = unsafe_error()
local unresolved, unresolved_err = storage:clear_book("7633875868615461950")
realpath_error = nil
assert(unresolved == nil and unresolved_err:find("安全范围", 1, true),
    "realpath exception did not fail closed")
assert(not unresolved_err:find(canary, 1, true), "realpath exception leaked raw content")
assert(error_tostring_calls == 0, "realpath exception invoked __tostring")

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

names = { ".", "..", "10000000001.xhtml" }
cached_mode = "file"
local linked_file = "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"
realpaths[linked_file] = "/outside/private.xhtml"
modification_times = { [linked_file] = 100 }
removed = {}
os.remove = function(path) removed[#removed + 1] = path; return true end
local linked_pruned, linked_prune_err = storage:prune("7633875868615461950", 0)
os.remove = original_remove
assert(linked_pruned == nil and linked_prune_err:find("安全范围", 1, true),
    "linked chapter cache was accepted for eviction inspection")
assert(#removed == 0, "linked chapter cache was selected for eviction")
realpaths[linked_file] = nil

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

realpaths[cached_path] = "/outside/private.xhtml"
local linked_opened = false
io.open = function()
    linked_opened = true
    error("linked cache must not be opened")
end
local linked_chapter, linked_chapter_err = storage:cached_chapter(
    "7633875868615461950", "10000000001")
realpaths[cached_path] = nil
assert(linked_chapter == nil and linked_chapter_err:find("安全范围", 1, true),
    "linked chapter cache was accepted for reading")
assert(not linked_opened, "linked chapter cache was opened before its real path was checked")

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

storage.chapter_path = function()
    return "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml"
end

local linked_temporary = "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml.tmp"
symlink_modes[linked_temporary] = "link"
local linked_temporary_removed = false
io.open = function(path)
    assert(path ~= linked_temporary or symlink_modes[path] == nil,
        "linked temporary cache was opened before its directory entry was removed")
    return {
        write = function() return true end,
        read = function() return valid_xhtml end,
        close = function() return true end,
    }
end
os.remove = function(path)
    if path == linked_temporary then
        linked_temporary_removed = true
        symlink_modes[path] = nil
    end
    return true
end
os.rename = function() return true end
local replaced_link = assert(storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml))
assert(replaced_link:match("10000000001%.xhtml$"), "safe cache write returned the wrong path")
assert(linked_temporary_removed, "existing linked temporary cache was not removed before writing")
io.open = original_open
os.rename = original_rename
os.remove = original_remove

attribute_error = unsafe_error()
local unchecked_temporary, unchecked_temporary_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
attribute_error = nil
assert(unchecked_temporary == nil and unchecked_temporary_err:find("无法检查临时缓存", 1, true),
    "temporary cache inspection exception did not fail closed")
assert(not unchecked_temporary_err:find(canary, 1, true),
    "temporary cache inspection leaked raw content")
assert(error_tostring_calls == 0, "temporary cache inspection invoked __tostring")

symlink_modes[linked_temporary] = "link"
io.open = function() error("occupied temporary cache must not be opened") end
os.remove = function() return nil end
local uncleared_temporary, uncleared_temporary_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(uncleared_temporary == nil and uncleared_temporary_err:find("无法清理", 1, true),
    "failed temporary cache removal was accepted")

os.remove = function() return true end
local occupied_temporary, occupied_temporary_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(occupied_temporary == nil and occupied_temporary_err:find("仍被占用", 1, true),
    "temporary cache remaining after removal was accepted")
symlink_modes[linked_temporary] = nil
io.open = original_open
os.remove = original_remove

local temporary_removed = false
io.open = function()
    return {
        write = function() return true end,
        close = function() return nil, unsafe_error() end,
    }
end
os.remove = function(path)
    if path == linked_temporary then temporary_removed = true end
    return true
end
os.rename = function() error("rename must not run after close failure") end
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
sync_ok, sync_error = nil, unsafe_error()
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
os.rename = function() error("rename must not run after sync failure") end
local sync_failed, sync_failure_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(sync_failed == nil, "cache sync failure reported as success")
assert(sync_failure_err:find("同步章节缓存失败", 1, true), "cache sync failure stage missing")
assert(not sync_failure_err:find(canary, 1, true), "cache sync error leaked")
assert(error_tostring_calls == 0, "cache sync error invoked __tostring")
assert(temporary_removed, "cache sync failure left temporary file")
sync_ok, sync_error = true, nil
os.rename = original_rename

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
local verify_open_count = 0
io.open = function()
    verify_open_count = verify_open_count + 1
    if verify_open_count == 1 then
        return {
            write = function() return true end,
            close = function() return true end,
        }
    end
    return {
        read = function() return valid_xhtml:gsub("</body></html>$", "") end,
        close = function() return true end,
    }
end
os.remove = function(path)
    if path:match("%.tmp$") then temporary_removed = true end
    return true
end
os.rename = function() error("rename must not run after verification failure") end
local verify_failed, verify_err = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
assert(verify_failed == nil, "invalid temporary cache reported as success")
assert(verify_err:find("写入后的章节缓存校验失败", 1, true), "cache verification stage missing")
assert(temporary_removed, "cache verification failure left temporary file")
os.rename = original_rename

temporary_removed = false
local rename_open_count = 0
io.open = function()
    rename_open_count = rename_open_count + 1
    if rename_open_count == 1 then
        return {
            write = function() return true end,
            close = function() return true end,
        }
    end
    return {
        read = function() return valid_xhtml end,
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
local directory_sync_before = directory_sync_calls
local success_open_count = 0
io.open = function()
    success_open_count = success_open_count + 1
    if success_open_count > 1 then
        return {
            read = function() return valid_xhtml end,
            close = function() return true end,
        }
    end
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
directory_sync_error = unsafe_error()
local safe_path, safe_write_err, prune_warning = storage:write_chapter(
    "7633875868615461950", "10000000001", valid_xhtml)
directory_sync_error = nil
storage.prune = original_prune
io.open = original_open
os.rename = original_rename

assert(safe_path == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml",
    "valid new cache was discarded after eviction warning")
assert(safe_write_err == nil, "successful cache write returned an error")
assert(write_protected_path == safe_path, "newly written cache was not protected during eviction")
assert(prune_warning and prune_warning:find("2 个旧缓存无法删除", 1, true),
    "cache eviction warning was hidden after successful write")
assert(directory_sync_calls == directory_sync_before + 1,
    "cache directory sync was not attempted after rename")
assert(error_tostring_calls == 0, "directory sync error invoked __tostring")

print("storage tests passed")

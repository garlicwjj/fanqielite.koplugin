local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Storage = {}
Storage.__index = Storage
Storage.MAX_CHAPTER_BYTES = 2 * 1024 * 1024
local XHTML_PREFIX = '<?xml version="1.0" encoding="utf-8"?>'

function Storage.validate_chapter_contents(contents)
    if type(contents) ~= "string" or contents == "" then
        return nil, "章节缓存为空"
    end
    if #contents > Storage.MAX_CHAPTER_BYTES then
        return nil, "章节缓存过大"
    end
    if contents:sub(1, #XHTML_PREFIX) ~= XHTML_PREFIX then
        return nil, "章节缓存格式无效"
    end
    for index = 1, #contents do
        local byte = contents:byte(index)
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            return nil, "章节缓存包含非法控制字符"
        end
    end
    if not contents:find('xmlns="http://www.w3.org/1999/xhtml"', 1, true)
            or not contents:find("<body>", 1, true) then
        return nil, "章节缓存格式无效"
    end
    if not contents:match("</body></html>%s*$") then
        return nil, "章节缓存不完整"
    end
    return true
end

function Storage.is_cache_name(name)
    return type(name) == "string"
        and (name:match("^%d+%.xhtml$") ~= nil or name:match("^%d+%.xhtml%.tmp$") ~= nil)
end

local function mkdir(path)
    local attributes_call, mode = pcall(lfs.attributes, path, "mode")
    if not attributes_call then return nil end
    if mode == "directory" then return true end
    local mkdir_call, created = pcall(lfs.mkdir, path)
    return mkdir_call and created or nil
end

local function directory_entries(path)
    local opened, iterator, state = pcall(lfs.dir, path)
    if not opened or type(iterator) ~= "function" then return nil, "无法打开缓存目录" end
    local entries = {}
    local iterated = pcall(function()
        for name in iterator, state do entries[#entries + 1] = name end
    end)
    if not iterated then return nil, "无法遍历缓存目录" end
    return entries
end

local function discard(path)
    pcall(os.remove, path)
end

local function remove_file(path)
    local called, removed = pcall(os.remove, path)
    return called and removed and true or false
end

local function safe_book_directory(storage, book_id, create)
    if type(book_id) ~= "string" or not book_id:match("^%d+$") then
        return nil, "缓存标识无效"
    end
    local path = storage.root .. "/" .. book_id
    local attributes_call, mode, attributes_err = pcall(lfs.attributes, path, "mode")
    if not attributes_call then return nil, "无法读取缓存目录" end
    if mode == nil then
        if attributes_err then return nil, "无法读取缓存目录" end
        if not create then return nil end
        if not mkdir(path) then return nil, "无法创建缓存目录" end
        mode = "directory"
    end
    if mode ~= "directory" then return nil, "缓存路径不是目录" end

    local root_call, real_root = pcall(ffiUtil.realpath, storage.root)
    local path_call, real_path = pcall(ffiUtil.realpath, path)
    if not root_call or type(real_root) ~= "string"
            or not path_call or type(real_path) ~= "string" then
        return nil, "无法确认缓存目录安全范围"
    end
    real_root = real_root:gsub("/+$", "")
    real_path = real_path:gsub("/+$", "")
    if real_path ~= real_root .. "/" .. book_id then
        return nil, "缓存目录超出插件安全范围，已拒绝操作"
    end
    return path
end

local function verify_chapter_file(path)
    local open_call, file = pcall(io.open, path, "rb")
    if not open_call or not file then return nil, "无法打开章节缓存" end
    local read_call, contents = pcall(file.read, file, Storage.MAX_CHAPTER_BYTES + 1)
    local close_call, closed = pcall(file.close, file)
    if not read_call or type(contents) ~= "string" then return nil, "无法读取章节缓存" end
    if not close_call or not closed then return nil, "无法关闭章节缓存" end
    return Storage.validate_chapter_contents(contents)
end

function Storage:new()
    local root = DataStorage:getDataDir() .. "/fanqielite"
    mkdir(root)
    return setmetatable({ root = root }, self)
end

function Storage:book_dir(book_id)
    return safe_book_directory(self, tostring(book_id or ""), true)
end

function Storage:chapter_path(book_id, item_id)
    item_id = tostring(item_id or "")
    if not item_id:match("^%d+$") then return nil, "缓存标识无效" end
    local directory, directory_err = self:book_dir(book_id)
    if not directory then return nil, directory_err end
    return directory .. "/" .. item_id .. ".xhtml"
end

function Storage:write_chapter(book_id, item_id, contents)
    local valid, validation_err = Storage.validate_chapter_contents(contents)
    if not valid then return nil, validation_err end
    local path, path_err = self:chapter_path(book_id, item_id)
    if not path then return nil, path_err end
    local temporary = path .. ".tmp"
    local open_call, file = pcall(io.open, temporary, "wb")
    if not open_call or not file then return nil, "无法创建临时缓存" end
    local write_call, ok = pcall(file.write, file, contents)
    local sync_call, synced = true, nil
    if write_call and ok then
        sync_call, synced = pcall(ffiUtil.fsyncOpenedFile, file)
    end
    local close_call, closed = pcall(file.close, file)
    if not write_call or not ok then
        discard(temporary)
        return nil, "写入缓存失败"
    end
    if not sync_call or not synced then
        discard(temporary)
        return nil, "同步章节缓存失败"
    end
    if not close_call or not closed then
        discard(temporary)
        return nil, "完成缓存写入失败"
    end
    local verified = verify_chapter_file(temporary)
    if not verified then
        discard(temporary)
        return nil, "写入后的章节缓存校验失败"
    end
    local rename_call, renamed = pcall(os.rename, temporary, path)
    if not rename_call or not renamed then
        discard(temporary)
        return nil, "无法替换章节缓存"
    end
    -- File contents were synced before rename. Directory sync is best-effort
    -- because failure is only observable after the atomic replacement.
    pcall(ffiUtil.fsyncDirectory, path)
    local _, prune_err = self:prune(book_id, 12, path)
    return path, nil, prune_err
end

function Storage:cached_chapter(book_id, item_id)
    book_id, item_id = tostring(book_id or ""), tostring(item_id or "")
    if not book_id:match("^%d+$") or not item_id:match("^%d+$") then
        return nil, "缓存标识无效"
    end
    local directory, directory_err = safe_book_directory(self, book_id, false)
    if not directory then return nil, directory_err end
    local path = directory .. "/" .. item_id .. ".xhtml"
    local attributes_call, mode = pcall(lfs.attributes, path, "mode")
    if not attributes_call then return nil, "无法读取缓存状态" end
    if mode == nil then return nil end
    if mode ~= "file" then return nil, "缓存路径不是普通文件" end
    local valid, validation_err = verify_chapter_file(path)
    if not valid then return nil, validation_err end
    return path
end

function Storage:prune(book_id, keep, protected_path)
    keep = tonumber(keep)
    if not keep or keep ~= keep or keep < 0 or keep ~= math.floor(keep) then
        return nil, "缓存保留数量无效"
    end
    local path, path_err = self:book_dir(book_id)
    if not path then return nil, path_err end
    local files = {}
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, entries_err end
    for _, name in ipairs(entries) do
        if name:match("^%d+%.xhtml$") then
            local full = path .. "/" .. name
            local attributes_call, modified = pcall(lfs.attributes, full, "modification")
            if not attributes_call then return nil, "无法读取缓存文件状态" end
            files[#files + 1] = {
                path = full,
                time = type(modified) == "number" and modified or 0,
            }
        end
    end
    table.sort(files, function(a, b)
        local a_protected = protected_path ~= nil and a.path == protected_path
        local b_protected = protected_path ~= nil and b.path == protected_path
        if a_protected ~= b_protected then return a_protected end
        if a.time ~= b.time then return a.time > b.time end
        return a.path < b.path
    end)
    local removed, failed = 0, 0
    for index = keep + 1, #files do
        if remove_file(files[index].path) then
            removed = removed + 1
        else
            failed = failed + 1
        end
    end
    if failed > 0 then
        return removed, "已自动清理 " .. tostring(removed) .. " 个旧缓存，但有 "
            .. tostring(failed) .. " 个无法删除"
    end
    return removed
end

function Storage:cached_count(book_id)
    local path, path_err = safe_book_directory(self, book_id, false)
    if not path then
        if path_err then return nil, path_err end
        return 0
    end
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, entries_err end
    local count = 0
    for _, name in ipairs(entries) do
        if name:match("^%d+%.xhtml$") then count = count + 1 end
    end
    return count
end

function Storage:clear_book(book_id)
    local path, path_err = safe_book_directory(self, book_id, false)
    if not path then
        if path_err then return nil, path_err end
        return 0
    end
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, entries_err end
    local removed, failed = 0, 0
    for _, name in ipairs(entries) do
        if Storage.is_cache_name(name) then
            if remove_file(path .. "/" .. name) then
                removed = removed + 1
            else
                failed = failed + 1
            end
        end
    end
    if failed > 0 then
        return removed, "已清理 " .. tostring(removed) .. " 个，但有 "
            .. tostring(failed) .. " 个无法删除"
    end
    pcall(lfs.rmdir, path) -- May remain when an unowned file is present; never delete that file.
    return removed
end

return Storage

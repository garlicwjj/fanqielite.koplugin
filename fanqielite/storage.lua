local DataStorage = require("datastorage")
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
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then return true end
    return lfs.mkdir(path)
end

local function directory_entries(path)
    local opened, iterator, state = pcall(lfs.dir, path)
    if not opened then return nil, tostring(iterator) end
    if type(iterator) ~= "function" then return nil, tostring(state or "无法打开目录") end
    local entries = {}
    local iterated, iterate_err = pcall(function()
        for name in iterator, state do entries[#entries + 1] = name end
    end)
    if not iterated then return nil, tostring(iterate_err) end
    return entries
end

function Storage:new()
    local root = DataStorage:getDataDir() .. "/fanqielite"
    mkdir(root)
    return setmetatable({ root = root }, self)
end

function Storage:book_dir(book_id)
    assert(tostring(book_id):match("^%d+$"), "invalid book id")
    local path = self.root .. "/" .. tostring(book_id)
    mkdir(path)
    return path
end

function Storage:chapter_path(book_id, item_id)
    assert(tostring(item_id):match("^%d+$"), "invalid item id")
    return self:book_dir(book_id) .. "/" .. tostring(item_id) .. ".xhtml"
end

function Storage:write_chapter(book_id, item_id, contents)
    local valid, validation_err = Storage.validate_chapter_contents(contents)
    if not valid then return nil, validation_err end
    local path = self:chapter_path(book_id, item_id)
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, "无法创建临时缓存：" .. tostring(err) end
    local write_call, ok, write_err = pcall(file.write, file, contents)
    local close_call, closed, close_err = pcall(file.close, file)
    if not write_call or not ok then
        os.remove(temporary)
        return nil, "写入缓存失败：" .. tostring(write_call and write_err or ok)
    end
    if not close_call or not closed then
        os.remove(temporary)
        return nil, "完成缓存写入失败：" .. tostring(close_call and close_err or closed)
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, "无法替换章节缓存：" .. tostring(rename_err)
    end
    self:prune(book_id, 12)
    return path
end

function Storage:cached_chapter(book_id, item_id)
    book_id, item_id = tostring(book_id or ""), tostring(item_id or "")
    if not book_id:match("^%d+$") or not item_id:match("^%d+$") then
        return nil, "缓存标识无效"
    end
    local path = self.root .. "/" .. book_id .. "/" .. item_id .. ".xhtml"
    local mode = lfs.attributes(path, "mode")
    if mode == nil then return nil end
    if mode ~= "file" then return nil, "缓存路径不是普通文件" end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, "无法读取缓存：" .. tostring(open_err) end
    local contents, read_err = file:read(Storage.MAX_CHAPTER_BYTES + 1)
    local closed, close_err = file:close()
    if not contents then return nil, "无法读取缓存：" .. tostring(read_err) end
    if not closed then return nil, "无法关闭缓存：" .. tostring(close_err) end
    local valid, validation_err = Storage.validate_chapter_contents(contents)
    if not valid then return nil, validation_err end
    return path
end

function Storage:prune(book_id, keep)
    local path = self:book_dir(book_id)
    local files = {}
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, entries_err end
    for _, name in ipairs(entries) do
        if name:match("^%d+%.xhtml$") then
            local full = path .. "/" .. name
            files[#files + 1] = { path = full, time = lfs.attributes(full, "modification") or 0 }
        end
    end
    table.sort(files, function(a, b) return a.time > b.time end)
    for index = keep + 1, #files do os.remove(files[index].path) end
    return true
end

function Storage:cached_count(book_id)
    book_id = tostring(book_id or "")
    if not book_id:match("^%d+$") then return nil, "invalid book id" end
    local path = self.root .. "/" .. book_id
    local mode, attributes_err = lfs.attributes(path, "mode")
    if mode ~= "directory" then
        if attributes_err then return nil, "无法读取缓存目录：" .. tostring(attributes_err) end
        return 0
    end
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, "无法列出缓存目录：" .. tostring(entries_err) end
    local count = 0
    for _, name in ipairs(entries) do
        if name:match("^%d+%.xhtml$") then count = count + 1 end
    end
    return count
end

function Storage:clear_book(book_id)
    book_id = tostring(book_id or "")
    if not book_id:match("^%d+$") then return nil, "invalid book id" end
    local path = self.root .. "/" .. book_id
    local mode, attributes_err = lfs.attributes(path, "mode")
    if mode ~= "directory" then
        if attributes_err then return nil, "无法读取缓存目录：" .. tostring(attributes_err) end
        return 0
    end
    local entries, entries_err = directory_entries(path)
    if not entries then return nil, "无法列出缓存目录：" .. tostring(entries_err) end
    local removed, failed, first_error = 0, 0, nil
    for _, name in ipairs(entries) do
        if Storage.is_cache_name(name) then
            local ok, remove_err = os.remove(path .. "/" .. name)
            if ok then
                removed = removed + 1
            else
                failed = failed + 1
                first_error = first_error or tostring(remove_err or "未知删除错误")
            end
        end
    end
    if failed > 0 then
        return removed, "已清理 " .. tostring(removed) .. " 个，但有 "
            .. tostring(failed) .. " 个无法删除：" .. first_error
    end
    lfs.rmdir(path) -- May remain when an unowned file is present; never delete that file.
    return removed
end

return Storage

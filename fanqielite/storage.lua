local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Storage = {}
Storage.__index = Storage

function Storage.is_cache_name(name)
    return type(name) == "string"
        and (name:match("^%d+%.xhtml$") ~= nil or name:match("^%d+%.xhtml%.tmp$") ~= nil)
end

local function mkdir(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then return true end
    return lfs.mkdir(path)
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
    local path = self:chapter_path(book_id, item_id)
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(contents)
    file:close()
    if not ok then os.remove(temporary); return nil, write_err end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_err end
    self:prune(book_id, 12)
    return path
end

function Storage:prune(book_id, keep)
    local path = self:book_dir(book_id)
    local files = {}
    for name in lfs.dir(path) do
        if name:match("^%d+%.xhtml$") then
            local full = path .. "/" .. name
            files[#files + 1] = { path = full, time = lfs.attributes(full, "modification") or 0 }
        end
    end
    table.sort(files, function(a, b) return a.time > b.time end)
    for index = keep + 1, #files do os.remove(files[index].path) end
end

function Storage:cached_count(book_id)
    book_id = tostring(book_id or "")
    if not book_id:match("^%d+$") then return nil, "invalid book id" end
    local path = self.root .. "/" .. book_id
    if lfs.attributes(path, "mode") ~= "directory" then return 0 end
    local count = 0
    for name in lfs.dir(path) do
        if name:match("^%d+%.xhtml$") then count = count + 1 end
    end
    return count
end

function Storage:clear_book(book_id)
    book_id = tostring(book_id or "")
    if not book_id:match("^%d+$") then return nil, "invalid book id" end
    local path = self.root .. "/" .. book_id
    if lfs.attributes(path, "mode") ~= "directory" then return 0 end
    local removed = 0
    for name in lfs.dir(path) do
        if Storage.is_cache_name(name) then
            if os.remove(path .. "/" .. name) then removed = removed + 1 end
        end
    end
    lfs.rmdir(path)
    return removed
end

return Storage

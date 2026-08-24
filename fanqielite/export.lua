local ffiUtil = require("ffi/util")
local Import = require("fanqielite.import")
local rapidjson = require("rapidjson")

local Export = {}

local function exported_book(book)
    local output = {
        id = book.id,
        title = book.title,
    }
    if type(book.author) == "string" and book.author ~= "" then output.author = book.author end
    if type(book.cover_url) == "string" and book.cover_url ~= "" then
        output.cover_url = book.cover_url
    end

    local current_index = math.floor(tonumber(book.current_index) or 0)
    local current = type(book.chapters) == "table" and book.chapters[current_index] or nil
    if type(current) == "table" then
        output.current_chapter_id = current.id
        output.current_chapter_title = current.title
    elseif type(book.imported_progress) == "table" then
        output.current_chapter_id = book.imported_progress.chapter_id
        output.current_chapter_title = book.imported_progress.chapter_title
        output.reading_position = book.imported_progress.position
    end
    return output
end

function Export.build(library, exported_at)
    if type(library) ~= "table" or type(library.books) ~= "table"
            or #library.books == 0 then
        return nil, "本地书架为空，没有可导出的书籍"
    end
    local payload = {
        format = Import.FORMAT,
        version = Import.VERSION,
        exported_at = exported_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        books = {},
    }
    for _, book in ipairs(library.books) do
        payload.books[#payload.books + 1] = exported_book(book)
    end
    local valid, validation_err = Import.validate(payload)
    if not valid then return nil, "本地书架无法安全导出：" .. tostring(validation_err) end
    return payload
end

local function verify_contents(contents)
    local decoded, decode_err = Import.decode(contents)
    if not decoded then return nil, decode_err end
    local books, validation_err = Import.validate(decoded)
    if not books then return nil, validation_err end
    return books
end

local function read_all(path)
    local file, open_err = io.open(path, "rb")
    if not file then return nil, "无法重新读取导出文件：" .. tostring(open_err) end
    local contents, read_err = file:read("*a")
    local closed, close_err = file:close()
    if not contents then return nil, "无法重新读取导出文件：" .. tostring(read_err) end
    if not closed then return nil, "无法关闭导出文件：" .. tostring(close_err) end
    return contents
end

function Export.write(path, library, exported_at)
    if type(path) ~= "string" or path:match("([^/]+)$") ~= Import.FILENAME then
        return nil, "导出文件必须命名为 " .. Import.FILENAME
    end
    local payload, payload_err = Export.build(library, exported_at)
    if not payload then return nil, payload_err end
    local encoded_ok, contents = pcall(rapidjson.encode, payload)
    if not encoded_ok or type(contents) ~= "string" then
        return nil, "无法生成书架 JSON；未显示本地书架内容"
    end
    if #contents > Import.MAX_BYTES then
        return nil, "导出文件超过 256 KB 安全限制，请减少书架数量后重试"
    end

    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, "无法创建临时导出文件：" .. tostring(open_err) end
    local write_call, wrote, write_err = pcall(file.write, file, contents)
    local sync_call, synced, sync_err = pcall(ffiUtil.fsyncOpenedFile, file)
    local close_call, closed, close_err = pcall(file.close, file)
    if not write_call or not wrote then
        os.remove(temporary)
        return nil, "写入临时导出文件失败：" .. tostring(write_call and write_err or wrote)
    end
    if not sync_call or not synced then
        os.remove(temporary)
        return nil, "同步临时导出文件失败：" .. tostring(sync_call and sync_err or synced)
    end
    if not close_call or not closed then
        os.remove(temporary)
        return nil, "完成导出文件写入失败：" .. tostring(close_call and close_err or closed)
    end

    local temporary_contents, temporary_err = read_all(temporary)
    local temporary_books, validation_err
    if temporary_contents then temporary_books, validation_err = verify_contents(temporary_contents)
    else validation_err = temporary_err end
    if not temporary_books then
        os.remove(temporary)
        return nil, "写入后的导出文件校验失败：" .. tostring(validation_err)
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, "无法替换导出文件：" .. tostring(rename_err)
    end
    local final_contents, final_err = read_all(path)
    local final_books, final_validation_err
    if final_contents then final_books, final_validation_err = verify_contents(final_contents)
    else final_validation_err = final_err end
    if not final_books then
        return nil, "导出文件最终校验失败：" .. tostring(final_validation_err)
    end
    pcall(ffiUtil.fsyncDirectory, path)
    return #final_books
end

return Export

local ffiUtil = require("ffi/util")
local Import = require("fanqielite.import")
local rapidjson = require("rapidjson")
local SafeTemporary = require("fanqielite.safetemporary")

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

local function exportable_books(library)
    if type(library) ~= "table" or type(library.books) ~= "table" then
        return nil, "本地书架结构无效，已停止导出"
    end
    local count, maximum_index = 0, 0
    for key, book in pairs(library.books) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key)
                or type(book) ~= "table" then
            return nil, "本地书架结构不完整，已停止导出"
        end
        count = count + 1
        if key > maximum_index then maximum_index = key end
    end
    if count == 0 then return nil, "本地书架为空，没有可导出的书籍" end
    if count > Import.MAX_BOOKS then return nil, "本地书架超过 500 本，已停止导出" end
    if maximum_index ~= count then return nil, "本地书架结构不完整，已停止导出" end
    return library.books, count
end

function Export.build(library, exported_at)
    local books, book_count_or_err = exportable_books(library)
    if not books then return nil, book_count_or_err end
    local payload = {
        format = Import.FORMAT,
        version = Import.VERSION,
        exported_at = exported_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        books = {},
    }
    for index = 1, book_count_or_err do
        local projected_ok, projected = pcall(exported_book, books[index])
        if not projected_ok or type(projected) ~= "table" then
            return nil, "本地书架结构无效，已停止导出"
        end
        payload.books[index] = projected
    end
    local valid, validation_err = Import.validate(payload)
    if not valid then
        local detail = type(validation_err) == "string" and validation_err
            or "本地书架校验没有返回可安全显示的错误说明"
        return nil, "本地书架无法安全导出：" .. detail
    end
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
    local open_call, file = pcall(io.open, path, "rb")
    if not open_call or not file then return nil, "无法重新打开导出文件" end
    local read_call, contents = pcall(file.read, file, "*a")
    local close_call, closed = pcall(file.close, file)
    if not read_call or type(contents) ~= "string" then return nil, "无法重新读取导出文件" end
    if not close_call or not closed then return nil, "无法关闭导出文件" end
    return contents
end

local function discard(path)
    pcall(os.remove, path)
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
    local prepared, prepare_err = SafeTemporary.prepare(temporary, "临时导出文件")
    if not prepared then return nil, prepare_err end
    local open_call, file = pcall(io.open, temporary, "wb")
    if not open_call or not file then return nil, "无法创建临时导出文件" end
    local write_call, wrote = pcall(file.write, file, contents)
    local sync_call, synced = true, nil
    if write_call and wrote then
        sync_call, synced = pcall(ffiUtil.fsyncOpenedFile, file)
    end
    local close_call, closed = pcall(file.close, file)
    if not write_call or not wrote then
        discard(temporary)
        return nil, "写入临时导出文件失败"
    end
    if not sync_call or not synced then
        discard(temporary)
        return nil, "同步临时导出文件失败"
    end
    if not close_call or not closed then
        discard(temporary)
        return nil, "完成导出文件写入失败"
    end

    local temporary_contents = read_all(temporary)
    local verify_call, temporary_books = false, nil
    if temporary_contents then verify_call, temporary_books = pcall(verify_contents, temporary_contents) end
    if not verify_call or not temporary_books then
        discard(temporary)
        return nil, "写入后的导出文件校验失败"
    end
    local rename_call, renamed = pcall(os.rename, temporary, path)
    if not rename_call or not renamed then
        discard(temporary)
        return nil, "无法替换导出文件"
    end
    local final_contents = read_all(path)
    local final_verify_call, final_books = false, nil
    if final_contents then final_verify_call, final_books = pcall(verify_contents, final_contents) end
    if not final_verify_call or not final_books then
        return nil, "导出文件最终校验失败"
    end
    pcall(ffiUtil.fsyncDirectory, path)
    return #final_books
end

return Export

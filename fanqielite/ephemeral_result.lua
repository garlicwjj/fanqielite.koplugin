local Import = require("fanqielite.import")
local rapidjson = require("rapidjson")

local Result = {}

local function minimal_payload(books)
    local payload = {
        format = Import.FORMAT,
        version = Import.VERSION,
        books = {},
    }
    for _, book in ipairs(books) do
        local output = {
            id = book.id,
            title = book.title,
        }
        if book.author ~= "" then output.author = book.author end
        if book.cover_url ~= "" then output.cover_url = book.cover_url end
        local progress = book.imported_progress
        if progress then
            output.current_chapter_id = progress.chapter_id
            if progress.chapter_title ~= "" then
                output.current_chapter_title = progress.chapter_title
            end
            if progress.position ~= nil then output.reading_position = progress.position end
        end
        payload.books[#payload.books + 1] = output
    end
    return payload
end

function Result.encode(payload)
    local books = Import.validate(payload)
    if not books then return nil, "一次性书架数据未通过最小字段验证" end
    local called, contents = pcall(rapidjson.encode, minimal_payload(books))
    if not called or type(contents) ~= "string" or contents == ""
            or #contents > Import.MAX_BYTES then
        return nil, "一次性书架数据无法安全编码"
    end
    local decoded = Import.decode(contents)
    if not decoded or not Import.validate(decoded) then
        return nil, "一次性书架编码复验失败"
    end
    return contents
end

function Result.decode(contents)
    if type(contents) ~= "string" or contents == "" or #contents > Import.MAX_BYTES then
        return nil, "一次性书架返回格式无效"
    end
    local payload = Import.decode(contents)
    local books = payload and Import.validate(payload)
    if not books then return nil, "一次性书架返回内容未通过验证" end
    return books
end

return Result

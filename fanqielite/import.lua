local Import = {}

Import.FORMAT = "fanqielite-bookshelf"
Import.VERSION = 1
Import.MAX_BYTES = 256 * 1024
Import.MAX_BOOKS = 500
Import.FILENAME = "fanqielite-bookshelf.json"

local forbidden_keys = {
    authorization = true,
    cookie = true,
    cookies = true,
    csrf = true,
    csrftoken = true,
    mobile = true,
    password = true,
    phone = true,
    session = true,
    sessionid = true,
    setcookie = true,
    telephone = true,
    token = true,
}

local top_fields = { format = true, version = true, exported_at = true, books = true }
local book_fields = {
    id = true,
    title = true,
    author = true,
    cover_url = true,
    current_chapter_id = true,
    current_chapter_title = true,
    reading_position = true,
}

local function normalized_key(key)
    return tostring(key or ""):lower():gsub("[^%a%d]", "")
end

local function find_forbidden(value, seen, depth)
    if type(value) ~= "table" then return nil end
    if depth > 8 then return "JSON 嵌套层级过深" end
    if seen[value] then return "JSON 包含循环引用" end
    seen[value] = true
    for key, child in pairs(value) do
        local normalized = normalized_key(key)
        if forbidden_keys[normalized]
                or normalized:find("authorization", 1, true)
                or normalized:find("cookie", 1, true)
                or normalized:find("csrf", 1, true)
                or normalized:find("mobile", 1, true)
                or normalized:find("password", 1, true)
                or normalized:find("phone", 1, true)
                or normalized:find("session", 1, true)
                or normalized:find("telephone", 1, true)
                or normalized:find("token", 1, true) then
            return "导入文件包含禁止的账号凭证字段：" .. tostring(key)
        end
        local err = find_forbidden(child, seen, depth + 1)
        if err then return err end
    end
    seen[value] = nil
end

local function check_fields(value, allowed, label)
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then
            return nil, label .. "包含未知字段：" .. tostring(key)
        end
    end
    return true
end

local function text(value, field, maximum, required)
    if value == nil and not required then return "" end
    if type(value) ~= "string" then return nil, field .. "必须是文本" end
    value = value:match("^%s*(.-)%s*$")
    if required and value == "" then return nil, field .. "不能为空" end
    if #value > maximum then return nil, field .. "过长" end
    if value:find("%c") then return nil, field .. "包含控制字符" end
    return value
end

local function id(value, field, optional)
    if value == nil and optional then return nil end
    if type(value) ~= "string" or not value:match("^%d%d%d%d%d%d%d%d%d%d+$") then
        return nil, field .. "必须是至少 10 位的数字字符串"
    end
    return value
end

function Import.decode(contents)
    local rapidjson = require("rapidjson")
    local ok, value = pcall(rapidjson.decode, contents)
    if not ok or value == nil then
        return nil, "书架 JSON 解析失败；未显示文件内容，现有本地书架没有改变"
    end
    return value
end

function Import.validate(payload)
    if type(payload) ~= "table" then return nil, "导入文件顶层必须是 JSON 对象" end
    local credential_err = find_forbidden(payload, {}, 1)
    if credential_err then return nil, credential_err end
    local fields_ok, fields_err = check_fields(payload, top_fields, "导入文件")
    if not fields_ok then return nil, fields_err end
    if payload.format ~= Import.FORMAT then return nil, "不是 Fanqie Lite 书架文件" end
    if payload.version ~= Import.VERSION then return nil, "不支持的书架文件版本" end
    if payload.exported_at ~= nil then
        local exported_at, exported_at_err = text(payload.exported_at, "exported_at", 64, false)
        if not exported_at then return nil, exported_at_err end
    end
    if type(payload.books) ~= "table" then return nil, "books 必须是数组" end
    local book_count, maximum_index = 0, 0
    for key in pairs(payload.books) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "books 必须是连续数组"
        end
        book_count = book_count + 1
        if key > maximum_index then maximum_index = key end
    end
    if book_count < 1 then return nil, "书架文件中没有书籍" end
    if book_count > Import.MAX_BOOKS then return nil, "单次最多导入 500 本书" end
    if maximum_index ~= book_count then return nil, "books 必须是连续数组" end

    local output, seen = {}, {}
    for index, source in ipairs(payload.books) do
        if type(source) ~= "table" then return nil, "第 " .. tostring(index) .. " 本书必须是对象" end
        local book_ok, book_err = check_fields(source, book_fields, "第 " .. tostring(index) .. " 本书")
        if not book_ok then return nil, book_err end
        local book_id, id_err = id(source.id, "第 " .. tostring(index) .. " 本书的 id")
        if not book_id then return nil, id_err end
        if seen[book_id] then return nil, "书架文件包含重复书籍 ID：" .. book_id end
        seen[book_id] = true
        local title, title_err = text(source.title, "第 " .. tostring(index) .. " 本书的 title", 300, true)
        if not title then return nil, title_err end
        local author, author_err = text(source.author, "第 " .. tostring(index) .. " 本书的 author", 150, false)
        if not author then return nil, author_err end
        local cover_url, cover_err = text(source.cover_url, "第 " .. tostring(index) .. " 本书的 cover_url", 2048, false)
        if not cover_url then return nil, cover_err end
        if cover_url ~= "" and not cover_url:match("^https://") then
            return nil, "第 " .. tostring(index) .. " 本书的 cover_url 必须使用 HTTPS"
        end
        local chapter_id, chapter_id_err = id(
            source.current_chapter_id, "第 " .. tostring(index) .. " 本书的 current_chapter_id", true)
        if source.current_chapter_id ~= nil and not chapter_id then return nil, chapter_id_err end
        local chapter_title, chapter_title_err = text(
            source.current_chapter_title, "第 " .. tostring(index) .. " 本书的 current_chapter_title", 300, false)
        if not chapter_title then return nil, chapter_title_err end
        local position = source.reading_position
        if position ~= nil and (type(position) ~= "number" or position ~= position
                or position == math.huge or position == -math.huge or position < 0 or position > 1) then
            return nil, "第 " .. tostring(index) .. " 本书的 reading_position 必须是 0 到 1 之间的数字"
        end
        output[#output + 1] = {
            id = book_id,
            title = title,
            author = author,
            cover_url = cover_url,
            imported_progress = chapter_id and {
                chapter_id = chapter_id,
                chapter_title = chapter_title,
                position = position,
            } or nil,
        }
    end
    if #output ~= book_count then return nil, "books 必须是连续数组" end
    return output
end

function Import.read_file(path)
    if type(path) ~= "string" or path:match("([^/]+)$") ~= Import.FILENAME then
        return nil, "请选择名为 " .. Import.FILENAME .. " 的文件"
    end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, "无法读取文件：" .. tostring(open_err) end
    local size = file:seek("end")
    if not size then file:close(); return nil, "无法确认导入文件大小" end
    if size > Import.MAX_BYTES then file:close(); return nil, "导入文件超过 256 KB 安全限制" end
    file:seek("set", 0)
    local contents = file:read("*a")
    file:close()
    if not contents or #contents ~= size then return nil, "导入文件读取不完整" end
    local payload, decode_err = Import.decode(contents)
    if not payload then return nil, decode_err end
    return Import.validate(payload)
end

return Import

local Pua = require("fanqielite.pua")

local Parser = {}

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function valid_id(value)
    return type(value) == "string" and value:match("^%d%d%d%d%d%d%d%d%d%d+$") ~= nil
end

local function optional_text(value)
    if value == nil then return "" end
    if type(value) ~= "string" then return nil end
    return trim(value)
end

local function nonnegative_integer(value, maximum)
    if type(value) == "string" then
        if #value > 10 or not value:match("^%d+$") then return nil end
        value = tonumber(value)
    elseif type(value) ~= "number" then
        return nil
    end
    if not value or value ~= value or value == math.huge or value == -math.huge
            or value ~= math.floor(value) or value < 0 or value > maximum then
        return nil
    end
    return value
end

local function boolean_flag(value)
    if value == nil or value == false or value == 0 or value == "0" or value == "false" then
        return false, true
    end
    if value == true or value == 1 or value == "1" or value == "true" then
        return true, true
    end
    return nil, false
end

local function valid_xml_codepoint(value)
    return value == 0x09 or value == 0x0A or value == 0x0D
        or (value >= 0x20 and value <= 0xD7FF)
        or (value >= 0xE000 and value <= 0xFFFD)
        or (value >= 0x10000 and value <= 0x10FFFF)
end

local function encode_codepoint(value)
    if value < 0x80 then return string.char(value) end
    if value < 0x800 then
        return string.char(0xC0 + math.floor(value / 0x40), 0x80 + value % 0x40)
    end
    if value < 0x10000 then
        return string.char(0xE0 + math.floor(value / 0x1000),
            0x80 + math.floor(value / 0x40) % 0x40, 0x80 + value % 0x40)
    end
    return string.char(0xF0 + math.floor(value / 0x40000),
        0x80 + math.floor(value / 0x1000) % 0x40,
        0x80 + math.floor(value / 0x40) % 0x40, 0x80 + value % 0x40)
end

local function html_entities(text)
    local invalid = 0
    local function numeric_entity(value, base)
        value = tonumber(value, base)
        if not value or not valid_xml_codepoint(value) then
            invalid = invalid + 1
            return ""
        end
        return encode_codepoint(value)
    end
    local decoded = text
        :gsub("&#[xX]([%da-fA-F]+);", function(value) return numeric_entity(value, 16) end)
        :gsub("&#(%d+);", function(value) return numeric_entity(value, 10) end)
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
    return decoded, invalid
end

local function xml_escape(text)
    return tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub("\"", "&quot;"):gsub("'", "&apos;")
end

function Parser.book_id(input)
    input = trim(input)
    local id = input:match("fanqienovel%.com/page/(%d+)")
        or input:match("bookId=(%d+)")
        or input:match("^(%d+)$")
    if not id or #id < 10 then return nil, "请输入番茄小说官方书籍链接或书籍 ID" end
    return id
end

function Parser.extract_initial_state(html)
    html = tostring(html or "")
    local marker = "window.__INITIAL_STATE__="
    local marker_start = html:find(marker, 1, true)
    if not marker_start then return nil, "页面缺少 INITIAL_STATE" end
    local start_at = html:find("{", marker_start + #marker, true)
    if not start_at then return nil, "页面状态不是 JSON 对象" end
    local depth, quoted, escaped = 0, false, false
    for index = start_at, #html do
        local char = html:sub(index, index)
        if quoted then
            if escaped then escaped = false
            elseif char == "\\" then escaped = true
            elseif char == "\"" then quoted = false end
        elseif char == "\"" then
            quoted = true
        elseif char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then return html:sub(start_at, index) end
        end
    end
    return nil, "页面状态 JSON 不完整"
end

function Parser.decode_json(text)
    local rapidjson = require("rapidjson")
    local ok, value = pcall(rapidjson.decode, text)
    if not ok or value == nil then
        return nil, "番茄官方响应格式发生变化，JSON 解析失败；"
            .. "请稍后重试或更新插件，本地数据未改变"
    end
    return value
end

local function utf8_length(text)
    local count = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
    end
    return count
end

function Parser.book_from_state(state, fallback_id)
    local page = type(state) == "table" and state.page or nil
    if type(page) ~= "table" then return nil, "页面没有书籍信息" end
    local id = page.bookId ~= nil and page.bookId or fallback_id
    if not valid_id(id) then return nil, "书籍 ID 无效" end
    if fallback_id and (not valid_id(fallback_id) or id ~= fallback_id) then
        return nil, "书籍 ID 与请求不一致"
    end
    local title = optional_text(page.bookName)
    if title == nil then return nil, "书籍书名格式无效" end
    local author = optional_text(page.author)
    if author == nil then return nil, "书籍作者格式无效" end
    return {
        id = id,
        title = title ~= "" and title or ("番茄书籍 " .. id),
        author = author,
    }
end

local function add_chapter(output, seen, chapter, fallback_index)
    if type(chapter) ~= "table" then return nil, "目录包含无效章节" end
    local id = chapter.itemId ~= nil and chapter.itemId or chapter.item_id
    if not valid_id(id) then return nil, "目录包含无效章节 ID" end
    if seen[id] then return nil, "目录包含重复章节 ID" end
    local title = optional_text(chapter.title)
    if title == nil then return nil, "目录包含无效章节标题" end
    local raw_index = chapter.index ~= nil and chapter.index or chapter.order
    local chapter_index = fallback_index
    if raw_index ~= nil then
        chapter_index = nonnegative_integer(raw_index, 2147483647)
        if not chapter_index then return nil, "目录包含无效章节序号" end
    end
    output[#output + 1] = {
        id = id,
        title = title ~= "" and title or ("第 " .. tostring(fallback_index) .. " 章"),
        index = chapter_index,
    }
    seen[id] = true
    return true
end

function Parser.directory_from_payload(payload)
    local data = type(payload) == "table" and payload.data or nil
    if type(data) ~= "table" then return nil, "目录接口没有返回数据" end
    local output, seen = {}, {}
    if data.chapterListWithVolume ~= nil and type(data.chapterListWithVolume) ~= "table" then
        return nil, "目录卷结构无效"
    end
    if type(data.chapterListWithVolume) == "table" then
        for _, volume in ipairs(data.chapterListWithVolume) do
            if type(volume) ~= "table" then return nil, "目录卷结构无效" end
            if volume.chapterList ~= nil and type(volume.chapterList) ~= "table" then
                return nil, "目录卷章节结构无效"
            end
            local list = volume.chapterList or volume
            for _, chapter in ipairs(list) do
                local added, add_err = add_chapter(output, seen, chapter, #output + 1)
                if not added then return nil, add_err end
            end
        end
    end
    if #output == 0 and data.chapterList ~= nil and type(data.chapterList) ~= "table" then
        return nil, "目录列表结构无效"
    end
    if #output == 0 and type(data.chapterList) == "table" then
        for _, chapter in ipairs(data.chapterList) do
            local added, add_err = add_chapter(output, seen, chapter, #output + 1)
            if not added then return nil, add_err end
        end
    end
    if #output == 0 and data.allItemIds ~= nil and type(data.allItemIds) ~= "table" then
        return nil, "目录 ID 列表结构无效"
    end
    if #output == 0 and type(data.allItemIds) == "table" then
        for _, id in ipairs(data.allItemIds) do
            local added, add_err = add_chapter(output, seen, { itemId = id }, #output + 1)
            if not added then return nil, add_err end
        end
    end
    if #output == 0 then return nil, "目录为空" end
    return output
end

local function plain_paragraphs(raw)
    raw = raw:gsub("<script[^>]*>.-</script>", "")
        :gsub("<style[^>]*>.-</style>", "")
        :gsub("<[bB][rR]%s*/?>", "\n")
        :gsub("</[pP]%s*>", "\n")
        :gsub("</[dD][iI][vV]%s*>", "\n")
        :gsub("<[^>]+>", "")
    local invalid_entities
    raw, invalid_entities = html_entities(raw)
    raw = raw:gsub("\r", "")
        :gsub("\226\128[\139\140\141\142\143]", "")
        :gsub("\239\187\191", "")
    local paragraphs = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then paragraphs[#paragraphs + 1] = line end
    end
    return paragraphs, invalid_entities
end

function Parser.chapter_from_state(state, expected_item_id)
    local reader = type(state) == "table" and state.reader or nil
    local chapter = type(reader) == "table" and reader.chapterData or nil
    if type(chapter) ~= "table" then return nil, "页面没有章节数据" end
    local item_id = chapter.itemId
    if not valid_id(item_id) then return nil, "章节 ID 无效" end
    if expected_item_id and (not valid_id(expected_item_id) or item_id ~= expected_item_id) then
        return nil, "章节 ID 与请求不一致"
    end
    local need_pay, pay_valid = boolean_flag(chapter.needPay)
    local chapter_locked, lock_valid = boolean_flag(chapter.isChapterLock)
    if not pay_valid or not lock_valid then return nil, "章节权限状态无效，已拒绝读取" end
    if need_pay or chapter_locked then
        return nil, "该章节需要在番茄官方客户端中解锁"
    end
    if type(chapter.content) ~= "string" then return nil, "章节正文格式无效" end
    local title = optional_text(chapter.title)
    if title == nil then return nil, "章节标题格式无效" end
    local claimed = 0
    if chapter.chapterWordNumber ~= nil then
        claimed = nonnegative_integer(chapter.chapterWordNumber, 10000000)
        if not claimed then return nil, "章节字数格式无效" end
    end
    local decoded, stats = Pua.decode(chapter.content)
    if stats.invalid > 0 then
        return nil, "官方正文包含无效 UTF-8，已拒绝保存异常章节"
    end
    if stats.unknown > 0 then
        return nil, "番茄字符映射已经变化，已拒绝保存乱码章节"
    end
    local paragraphs, invalid_entities = plain_paragraphs(decoded)
    if invalid_entities > 0 then
        return nil, "官方正文包含非法字符实体，已拒绝保存异常章节"
    end
    for index, paragraph in ipairs(paragraphs) do
        local normalized, entity_stats = Pua.decode(paragraph)
        if entity_stats.invalid > 0 then
            return nil, "官方正文包含无效 UTF-8，已拒绝保存异常章节"
        end
        if entity_stats.unknown > 0 then
            return nil, "番茄字符映射已经变化，已拒绝保存乱码章节"
        end
        paragraphs[index] = normalized
        stats.pua = stats.pua + entity_stats.pua
    end
    local visible = table.concat(paragraphs, "")
    local visible_length = utf8_length(visible)
    if visible_length < 500 or (claimed > 0 and visible_length < claimed * 0.45) then
        return nil, "官方网页只返回了预览或登录墙，当前章节不可公开读取"
    end
    return {
        id = item_id,
        title = title ~= "" and title or "番茄章节",
        paragraphs = paragraphs,
        pua_count = stats.pua,
    }
end

function Parser.to_xhtml(book, chapter)
    local body = {}
    for _, paragraph in ipairs(chapter.paragraphs or {}) do
        body[#body + 1] = "<p>" .. xml_escape(paragraph) .. "</p>"
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head>'
        .. '<meta charset="utf-8"/><title>' .. xml_escape(chapter.title) .. '</title>'
        .. '<style>body{line-height:1.65;margin:5%;}h1{text-align:center;font-size:1.35em;}'
        .. 'p{text-indent:2em;margin:.55em 0;} .meta{text-align:center;text-indent:0;font-size:.82em;}</style>'
        .. '</head><body><h1>' .. xml_escape(chapter.title) .. '</h1>'
        .. '<p class="meta">' .. xml_escape(book.title) .. '</p>'
        .. table.concat(body, "\n") .. '</body></html>'
end

return Parser

local Pua = require("fanqielite.pua")

local Parser = {}

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function valid_id(value)
    return type(value) == "string" and value:match("^%d%d%d%d%d%d%d%d%d%d+$") ~= nil
end

local function optional_text(value, label, maximum)
    if value == nil then return "" end
    if type(value) ~= "string" then return nil, label .. "格式无效" end
    if #value > maximum then return nil, label .. "过长" end
    if value:find("[%z\1-\31\127]") then return nil, label .. "包含控制字符" end
    return trim(value)
end

local function valid_content_controls(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return false
        end
    end
    return true
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
    local title, title_err = optional_text(page.bookName, "书籍书名", 300)
    if title == nil then return nil, title_err end
    local author, author_err = optional_text(page.author, "书籍作者", 150)
    if author == nil then return nil, author_err end
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
    local title, title_err = optional_text(chapter.title, "目录章节标题", 300)
    if title == nil then return nil, title_err end
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

local function array_count(value, label)
    local count, maximum_index = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. "不是连续数组"
        end
        count = count + 1
        if key > maximum_index then maximum_index = key end
    end
    if maximum_index ~= count then return nil, label .. "不是连续数组" end
    return count
end

function Parser.directory_from_payload(payload)
    local data = type(payload) == "table" and payload.data or nil
    if type(data) ~= "table" then return nil, "目录接口没有返回数据" end
    local output, seen = {}, {}
    if data.chapterListWithVolume ~= nil and type(data.chapterListWithVolume) ~= "table" then
        return nil, "目录卷结构无效"
    end
    if type(data.chapterListWithVolume) == "table" then
        local volume_count, volume_count_err = array_count(
            data.chapterListWithVolume, "目录卷列表")
        if not volume_count then return nil, volume_count_err end
        for volume_index = 1, volume_count do
            local volume = data.chapterListWithVolume[volume_index]
            if type(volume) ~= "table" then return nil, "目录卷结构无效" end
            if volume.chapterList ~= nil and type(volume.chapterList) ~= "table" then
                return nil, "目录卷章节结构无效"
            end
            local list = volume.chapterList or volume
            local chapter_count, chapter_count_err = array_count(list, "目录卷章节列表")
            if not chapter_count then return nil, chapter_count_err end
            for chapter_index = 1, chapter_count do
                local chapter = list[chapter_index]
                local added, add_err = add_chapter(output, seen, chapter, #output + 1)
                if not added then return nil, add_err end
            end
        end
    end
    if #output == 0 and data.chapterList ~= nil and type(data.chapterList) ~= "table" then
        return nil, "目录列表结构无效"
    end
    if #output == 0 and type(data.chapterList) == "table" then
        local chapter_count, chapter_count_err = array_count(data.chapterList, "目录章节列表")
        if not chapter_count then return nil, chapter_count_err end
        for chapter_index = 1, chapter_count do
            local chapter = data.chapterList[chapter_index]
            local added, add_err = add_chapter(output, seen, chapter, #output + 1)
            if not added then return nil, add_err end
        end
    end
    if #output == 0 and data.allItemIds ~= nil and type(data.allItemIds) ~= "table" then
        return nil, "目录 ID 列表结构无效"
    end
    if #output == 0 and type(data.allItemIds) == "table" then
        local id_count, id_count_err = array_count(data.allItemIds, "目录 ID 列表")
        if not id_count then return nil, id_count_err end
        for id_index = 1, id_count do
            local id = data.allItemIds[id_index]
            local added, add_err = add_chapter(output, seen, { itemId = id }, #output + 1)
            if not added then return nil, add_err end
        end
    end
    if #output == 0 then return nil, "目录为空" end
    return output
end

local function is_markup_space(byte)
    return byte == 32 or byte == 9 or byte == 13 or byte == 10 or byte == 12
end

local function is_attribute_name_byte(byte)
    return byte and ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90)
        or (byte >= 97 and byte <= 122) or byte == 95 or byte == 58
        or byte == 45 or byte == 46)
end

local function tag_has_explicit_hidden_markup(tag)
    local cursor = 2
    while is_markup_space(tag:byte(cursor)) do cursor = cursor + 1 end
    if tag:byte(cursor) == 47 then cursor = cursor + 1 end
    while is_markup_space(tag:byte(cursor)) do cursor = cursor + 1 end
    while is_attribute_name_byte(tag:byte(cursor)) do cursor = cursor + 1 end

    while cursor < #tag do
        while is_markup_space(tag:byte(cursor)) do cursor = cursor + 1 end
        local byte = tag:byte(cursor)
        if not byte or byte == 62 or byte == 47 then break end
        local name_start = cursor
        while is_attribute_name_byte(tag:byte(cursor)) do cursor = cursor + 1 end
        if cursor == name_start then
            cursor = cursor + 1
        else
            local name = tag:sub(name_start, cursor - 1):lower()
            while is_markup_space(tag:byte(cursor)) do cursor = cursor + 1 end
            local value = true
            if tag:byte(cursor) == 61 then
                cursor = cursor + 1
                while is_markup_space(tag:byte(cursor)) do cursor = cursor + 1 end
                local quote = tag:byte(cursor)
                if quote == 34 or quote == 39 then
                    local value_start = cursor + 1
                    local value_end = tag:find(string.char(quote), value_start, true)
                    if not value_end then return nil end
                    value = tag:sub(value_start, value_end - 1):lower()
                    cursor = value_end + 1
                else
                    local value_start = cursor
                    while cursor < #tag and not is_markup_space(tag:byte(cursor))
                            and tag:byte(cursor) ~= 62 do
                        cursor = cursor + 1
                    end
                    value = tag:sub(value_start, cursor - 1):lower()
                end
            end
            if name == "hidden"
                    or (name == "aria-hidden" and trim(value) == "true")
                    or (name == "style" and type(value) == "string"
                        and (value:find("display%s*:%s*none%f[%W]")
                        or value:find("visibility%s*:%s*hidden%f[%W]"))) then
                return true
            end
        end
    end
    return false
end

local function tag_end(raw, start_at)
    local quote
    for index = start_at + 1, #raw do
        local byte = raw:byte(index)
        if quote then
            if byte == quote then quote = nil end
        elseif byte == 34 or byte == 39 then
            quote = byte
        elseif byte == 62 then
            return index
        end
    end
end

local function strip_markup(raw)
    local output = {}
    local cursor = 1
    while cursor <= #raw do
        local start_at = raw:find("<", cursor, true)
        if not start_at then
            output[#output + 1] = raw:sub(cursor)
            break
        end
        output[#output + 1] = raw:sub(cursor, start_at - 1)
        local end_at = tag_end(raw, start_at)
        if not end_at then
            return nil, "官方正文包含未闭合 HTML 标签，已拒绝保存"
        end
        local tag = raw:sub(start_at, end_at)
        local hidden = tag_has_explicit_hidden_markup(tag)
        if hidden == nil then
            return nil, "官方正文包含畸形 HTML 属性，已拒绝保存"
        end
        if hidden then
            return nil, "官方正文包含隐藏内容标记，已拒绝保存"
        end
        local name = tag:match("^<%s*/?%s*([%a][%w_:%-%.]*)")
        local closing = tag:match("^<%s*/") ~= nil
        if name and (name:lower() == "br"
                or (closing and (name:lower() == "p" or name:lower() == "div"))) then
            output[#output + 1] = "\n"
        end
        cursor = end_at + 1
    end
    return table.concat(output)
end

local function plain_paragraphs(raw)
    raw = raw:gsub("<!%-%-.-%-%->", "")
    if raw:find("<!%-%-") or raw:find("%-%->") then
        return nil, 0, "官方正文包含未闭合 HTML 注释，已拒绝保存"
    end
    raw = raw:gsub("<%s*[sS][cC][rR][iI][pP][tT]%f[%s>][^>]*>.-"
            .. "</%s*[sS][cC][rR][iI][pP][tT]%s*>", "")
        :gsub("<%s*[sS][tT][yY][lL][eE]%f[%s>][^>]*>.-"
            .. "</%s*[sS][tT][yY][lL][eE]%s*>", "")
    if raw:find("<%s*/?%s*[sS][cC][rR][iI][pP][tT]%f[%s>]")
            or raw:find("<%s*/?%s*[sS][tT][yY][lL][eE]%f[%s>]") then
        return nil, 0, "官方正文包含未闭合脚本或样式，已拒绝保存"
    end
    local markup_err
    raw, markup_err = strip_markup(raw)
    if not raw then return nil, 0, markup_err end
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
    if #chapter.content > 1024 * 1024 then return nil, "章节正文过大" end
    if not valid_content_controls(chapter.content) then
        return nil, "章节正文包含非法控制字符"
    end
    local title, title_err = optional_text(chapter.title, "章节标题", 300)
    if title == nil then return nil, title_err end
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
    local paragraphs, invalid_entities, markup_err = plain_paragraphs(decoded)
    if markup_err then return nil, markup_err end
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

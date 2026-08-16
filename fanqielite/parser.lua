local Pua = require("fanqielite.pua")

local Parser = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function html_entities(text)
    return text:gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
        :gsub("&#(%d+);", function(n)
            n = tonumber(n)
            if not n or n > 0x10FFFF then return "" end
            if n < 0x80 then return string.char(n) end
            if n < 0x800 then
                return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
            end
            if n < 0x10000 then
                return string.char(0xE0 + math.floor(n / 0x1000),
                    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
            end
            return string.char(0xF0 + math.floor(n / 0x40000),
                0x80 + math.floor(n / 0x1000) % 0x40,
                0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
        end)
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
    local ok, value, err = pcall(rapidjson.decode, text)
    if not ok then return nil, "JSON 解析失败：" .. tostring(value) end
    if value == nil then return nil, err or "JSON 解析失败" end
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
    local id = tostring(page.bookId or fallback_id or "")
    if not id:match("^%d%d%d%d%d%d%d%d%d%d+$") then return nil, "书籍 ID 无效" end
    if fallback_id and id ~= tostring(fallback_id) then return nil, "书籍 ID 与请求不一致" end
    return {
        id = id,
        title = trim(page.bookName) ~= "" and trim(page.bookName) or ("番茄书籍 " .. id),
        author = trim(page.author),
    }
end

local function add_chapter(output, chapter, fallback_index)
    if type(chapter) ~= "table" then return end
    local id = tostring(chapter.itemId or chapter.item_id or "")
    if not id:match("^%d%d%d%d%d%d%d%d%d%d+$") then return end
    output[#output + 1] = {
        id = id,
        title = trim(chapter.title) ~= "" and trim(chapter.title)
            or ("第 " .. tostring(fallback_index) .. " 章"),
        index = tonumber(chapter.index or chapter.order) or fallback_index,
    }
end

function Parser.directory_from_payload(payload)
    local data = type(payload) == "table" and payload.data or nil
    if type(data) ~= "table" then return nil, "目录接口没有返回数据" end
    local output = {}
    if type(data.chapterListWithVolume) == "table" then
        for _, volume in ipairs(data.chapterListWithVolume) do
            if type(volume) == "table" then
                local list = volume.chapterList or volume
                if type(list) == "table" then
                    for _, chapter in ipairs(list) do add_chapter(output, chapter, #output + 1) end
                end
            end
        end
    end
    if #output == 0 and type(data.chapterList) == "table" then
        for _, chapter in ipairs(data.chapterList) do add_chapter(output, chapter, #output + 1) end
    end
    if #output == 0 and type(data.allItemIds) == "table" then
        for _, id in ipairs(data.allItemIds) do
            add_chapter(output, { itemId = id }, #output + 1)
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
    raw = html_entities(raw):gsub("\r", "")
        :gsub("\226\128[\139\140\141\142\143]", "")
        :gsub("\239\187\191", "")
    local paragraphs = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then paragraphs[#paragraphs + 1] = line end
    end
    return paragraphs
end

function Parser.chapter_from_state(state, expected_item_id)
    local reader = type(state) == "table" and state.reader or nil
    local chapter = type(reader) == "table" and reader.chapterData or nil
    if type(chapter) ~= "table" then return nil, "页面没有章节数据" end
    local item_id = tostring(chapter.itemId or "")
    if not item_id:match("^%d%d%d%d%d%d%d%d%d%d+$") then return nil, "章节 ID 无效" end
    if expected_item_id and item_id ~= tostring(expected_item_id) then
        return nil, "章节 ID 与请求不一致"
    end
    local function enabled(value)
        return value == true or value == 1 or value == "1" or value == "true"
    end
    if enabled(chapter.needPay) or enabled(chapter.isChapterLock) then
        return nil, "该章节需要在番茄官方客户端中解锁"
    end
    local decoded, stats = Pua.decode(chapter.content or "")
    if stats.invalid > 0 then
        return nil, "官方正文包含无效 UTF-8，已拒绝保存异常章节"
    end
    if stats.unknown > 0 then
        return nil, "番茄字符映射已经变化，已拒绝保存乱码章节"
    end
    local paragraphs = plain_paragraphs(decoded)
    local visible = table.concat(paragraphs, "")
    local visible_length = utf8_length(visible)
    local claimed = tonumber(chapter.chapterWordNumber) or 0
    if visible_length < 500 or (claimed > 0 and visible_length < claimed * 0.45) then
        return nil, "官方网页只返回了预览或登录墙，当前章节不可公开读取"
    end
    return {
        id = item_id,
        title = trim(chapter.title) ~= "" and trim(chapter.title) or "番茄章节",
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

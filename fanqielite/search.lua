local Search = {}

local BASE = "https://fanqienovel.com/api/author/search/search_book/v1"
local MAX_QUERY_BYTES = 240
local MAX_RESULTS = 10

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function percent_encode(value)
    return (value:gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function Search.build_url(input)
    if type(input) ~= "string" then return nil, "请输入书名或作者名" end
    local query = trim(input)
    if query == "" then return nil, "请输入书名或作者名" end
    if query:find("[%z\1-\31\127]") then return nil, "搜索内容包含控制字符" end
    if #query > MAX_QUERY_BYTES then return nil, "搜索内容过长，请缩短书名或作者名" end
    return BASE .. "?filter=127%2C127%2C127%2C127&page_count=10&page_index=0"
        .. "&query_type=0&query_word=" .. percent_encode(query), query
end

local function clean_text(value, maximum, required)
    if value == nil and not required then return "" end
    if type(value) ~= "string" then return nil end
    value = trim(value)
    if required and value == "" then return nil end
    if #value > maximum or value:find("[%z\1-\31\127]") then return nil end
    return value
end

local function valid_id(value)
    return type(value) == "string" and value:match("^%d%d%d%d%d%d%d%d%d%d+$") and value or nil
end

local function status_code(value)
    local value_type = type(value)
    if value_type == "string" then
        if #value > 11 or not value:match("^%-?%d+$") then return nil end
        value = tonumber(value)
    elseif value_type ~= "number" then
        return nil
    end
    if not value or value ~= value or value == math.huge or value == -math.huge
            or value ~= math.floor(value) or value < -2147483648 or value > 2147483647 then
        return nil
    end
    return value
end

function Search.parse(payload)
    if type(payload) ~= "table" then return nil, "官方搜索响应不是 JSON 对象" end
    local code = status_code(payload.code)
    if code == -5 then
        return nil, "番茄官方要求完成安全验证，Kindle 无法显示；请稍后重试或粘贴官网书籍链接"
    end
    if code ~= 0 then
        local code_text = code and ("（代码 " .. tostring(code) .. "）") or ""
        return nil, "番茄官方搜索暂时不可用" .. code_text
    end
    local data = payload.data
    local source = type(data) == "table" and data.search_book_data_list or nil
    if type(source) ~= "table" then return nil, "官方搜索响应缺少结果列表" end

    local count, maximum_index = 0, 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "官方搜索结果不是连续数组"
        end
        count = count + 1
        if key > maximum_index then maximum_index = key end
    end
    if maximum_index ~= count then return nil, "官方搜索结果不是连续数组" end
    if count > MAX_RESULTS then return nil, "官方搜索结果数量异常，已拒绝显示" end
    if count == 0 then return nil, "没有找到相关书籍，请尝试完整书名、作者名或官网链接" end

    local output, seen = {}, {}
    for _, item in ipairs(source) do
        local id = type(item) == "table" and valid_id(item.book_id) or nil
        local title = type(item) == "table" and clean_text(item.book_name, 300, true) or nil
        local author = type(item) == "table" and clean_text(item.author, 150, false) or nil
        if id and title and author and not seen[id] then
            output[#output + 1] = { id = id, title = title, author = author }
            seen[id] = true
        end
    end
    if #output == 0 then return nil, "官方搜索结果格式异常，已拒绝显示" end
    return output
end

return Search

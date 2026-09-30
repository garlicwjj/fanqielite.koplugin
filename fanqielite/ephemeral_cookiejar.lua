local CookieJar = {}
CookieJar.__index = CookieJar

CookieJar.MAX_COOKIES = 64
CookieJar.MAX_NAME_BYTES = 128
CookieJar.MAX_VALUE_BYTES = 4096
CookieJar.MAX_HEADER_BYTES = 16 * 1024

local function valid_name(value)
    return type(value) == "string" and value ~= ""
        and #value <= CookieJar.MAX_NAME_BYTES
        and value:match("^[%w!#$%%&'*+.^_`|~%-]+$") ~= nil
end

local function valid_value(value)
    return type(value) == "string" and #value <= CookieJar.MAX_VALUE_BYTES
        and not value:find("[%z\1-\32\127;,]")
end

local function cookie_lines(value)
    if type(value) == "table" then
        local output = {}
        for index, item in ipairs(value) do
            if index > 32 or type(item) ~= "string" then return nil end
            output[#output + 1] = item
        end
        return #output > 0 and output or nil
    end
    if type(value) ~= "string" or value == "" then return nil end
    local output, start = {}, 1
    while true do
        local comma = value:find(",%s*[%w!#$%%&'*+.^_`|~%-]+%s*=", start)
        if not comma then
            output[#output + 1] = value:sub(start)
            break
        end
        output[#output + 1] = value:sub(start, comma - 1)
        start = value:find("[^,%s]", comma)
        if not start then return nil end
    end
    return output
end

function CookieJar.new()
    return setmetatable({ _values = {} }, CookieJar)
end

function CookieJar.from_header(header)
    if type(header) ~= "string" or header == "" or #header > CookieJar.MAX_HEADER_BYTES
            or header:find("[%z\1-\31\127]") then
        return nil, "一次性授权 Cookie 无效"
    end
    local jar = CookieJar.new()
    local count = 0
    for pair in header:gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=]+)=([^;]*)%s*$")
        if not valid_name(name) or not valid_value(value) or jar._values[name] ~= nil then
            return nil, "一次性授权 Cookie 无效"
        end
        count = count + 1
        if count > CookieJar.MAX_COOKIES then return nil, "一次性授权 Cookie 过多" end
        jar._values[name] = value
    end
    if count == 0 then return nil, "一次性授权 Cookie 无效" end
    return jar
end

function CookieJar:merge_set_cookie(value)
    local lines = cookie_lines(value)
    if not lines then return nil, "一次性授权响应 Cookie 无效" end
    local pending = {}
    for _, line in ipairs(lines) do
        if #line > CookieJar.MAX_HEADER_BYTES or line:find("[%z\1-\31\127]") then
            return nil, "一次性授权响应 Cookie 无效"
        end
        local first = line:match("^%s*([^;]+)")
        local name, cookie_value
        if first then name, cookie_value = first:match("^([^=]+)=(.*)$") end
        name = type(name) == "string" and name:match("^%s*(.-)%s*$") or nil
        cookie_value = type(cookie_value) == "string"
            and cookie_value:match("^%s*(.-)%s*$") or nil
        if not valid_name(name) or not valid_value(cookie_value) then
            return nil, "一次性授权响应 Cookie 无效"
        end
        local remove = cookie_value == ""
            or line:lower():find(";%s*max%-age%s*=%s*0", 1) ~= nil
        pending[#pending + 1] = { name = name, value = cookie_value, remove = remove }
    end

    local next_values, count = {}, 0
    for name, item in pairs(self._values) do next_values[name] = item end
    for _, item in ipairs(pending) do
        if item.remove then next_values[item.name] = nil
        else next_values[item.name] = item.value end
    end
    for _ in pairs(next_values) do
        count = count + 1
        if count > CookieJar.MAX_COOKIES then return nil, "一次性授权 Cookie 过多" end
    end
    self._values = next_values
    local header = self:header()
    if not header then return nil, "一次性授权 Cookie 过大" end
    return true
end

function CookieJar:get(name)
    if not valid_name(name) then return nil end
    return self._values[name]
end

function CookieJar:has_any(names)
    for _, name in ipairs(names or {}) do
        if self._values[name] ~= nil then return true end
    end
    return false
end

function CookieJar:header()
    local names = {}
    for name in pairs(self._values) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. self._values[name] end
    local value = table.concat(parts, "; ")
    if value == "" or #value > CookieJar.MAX_HEADER_BYTES then return nil end
    return value
end

function CookieJar:clear()
    for name in pairs(self._values) do self._values[name] = nil end
end

return CookieJar

local SafeURL = {}

local forbidden_query_keys = {
    authorization = true,
    cookie = true,
    csrf = true,
    mobile = true,
    password = true,
    phone = true,
    session = true,
    telephone = true,
    token = true,
}

local function decode_component(value)
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function forbidden_query_key(value)
    local normalized = decode_component(value):lower():gsub("[^%a%d]", "")
    if normalized == "auth" then return true end
    for fragment in pairs(forbidden_query_keys) do
        if normalized:find(fragment, 1, true) then return true end
    end
    return false
end

local function valid_port(suffix)
    if suffix == "" then return true end
    local digits = suffix:match("^:(%d+)$")
    if not digits then return false end
    local port = tonumber(digits)
    return port ~= nil and port >= 1 and port <= 65535
end

local function valid_authority(authority)
    if authority:find("@", 1, true) then return false end
    if authority:sub(1, 1) == "[" then return false end
    local host, suffix = authority:match("^([%a%d%.%-]+)(.*)$")
    if not host or host == "" or #host > 253 or host:sub(1, 1) == "." or host:sub(-1) == "."
            or host:find("..", 1, true) then
        return false
    end
    for label in host:gmatch("[^%.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return false
        end
    end
    return valid_port(suffix)
end

local function valid_percent_encoding(value)
    local offset = 1
    while true do
        local position = value:find("%", offset, true)
        if not position then return true end
        local hex = value:sub(position + 1, position + 2)
        if #hex ~= 2 or not hex:match("^%x%x$") then return false end
        local byte = tonumber(hex, 16)
        if byte < 32 or byte == 127 then return false end
        offset = position + 3
    end
end

function SafeURL.https(value, maximum)
    if type(value) ~= "string" or value == "" or (maximum and #value > maximum)
            or value:find("[%z\1-\32\127]") or value:find("#", 1, true)
            or not valid_percent_encoding(value) then
        return nil
    end
    local authority = value:match("^https://([^/%?#]+)")
    if not authority or not valid_authority(authority) then return nil end
    local query = value:match("%?([^#]*)")
    if query then
        for pair in query:gmatch("[^&;]+") do
            local key = pair:match("^([^=]*)") or ""
            if forbidden_query_key(key) then return nil end
        end
    end
    return value
end

return SafeURL

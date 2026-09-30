local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local VerifiedTLS = require("fanqielite.verified_tls")

local Client = {}
Client.__index = Client

Client.MAX_REQUEST_BYTES = 64 * 1024
Client.MAX_RESPONSE_BYTES = 2 * 1024 * 1024
Client.MAX_CREDENTIAL_HEADER_BYTES = 16 * 1024
Client.MAX_QUERY_VALUE_BYTES = 4096

local HOST = "fanqienovel.com"
local BLOCK_TIMEOUT = 10
local TOTAL_TIMEOUT = 20
local TIMEOUT_SETUP_ERROR = "无法安全配置一次性授权网络超时，已停止请求；"
    .. "请重启 KOReader 后重试。"
local TIMEOUT_RESET_ERROR = "一次性授权请求已经停止，但无法恢复 KOReader 网络超时设置；"
    .. "为避免影响后续联网操作，请重启 KOReader。"

local function configure_timeout()
    local configured = pcall(
        socketutil.set_timeout, socketutil, BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    if configured then return true end
    pcall(socketutil.reset_timeout, socketutil)
    return nil, TIMEOUT_SETUP_ERROR
end

local function restore_timeout()
    return pcall(socketutil.reset_timeout, socketutil)
end

local USER_AGENT = "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 Chrome/120 Safari/537.36"

local reserved_headers = {
    ["connection"] = true,
    ["content-length"] = true,
    ["content-type"] = true,
    ["cookie"] = true,
    ["host"] = true,
    ["transfer-encoding"] = true,
}

local function valid_value(value, maximum)
    return type(value) == "string" and value ~= "" and #value <= maximum
        and not value:find("[%z\1-\31\127]")
end

local function header_set(values, response)
    if values == nil then return {} end
    if type(values) ~= "table" then return nil end
    local output = {}
    for _, name in ipairs(values) do
        if type(name) ~= "string" or not name:match("^[%a%d%-]+$") then return nil end
        name = name:lower()
        if output[name] or (not response and reserved_headers[name]) then return nil end
        output[name] = true
    end
    return output
end

local function name_set(values)
    if values == nil then return {}, 0 end
    if type(values) ~= "table" then return nil end
    local output, count = {}, 0
    for _, name in ipairs(values) do
        if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$")
                or output[name] then
            return nil
        end
        output[name] = true
        count = count + 1
    end
    return output, count
end

local function validate_policy(operations)
    if type(operations) ~= "table" then return nil end
    local output, count = {}, 0
    for operation, policy in pairs(operations) do
        if type(operation) ~= "string" or not operation:match("^[a-z][a-z0-9_]*$")
                or type(policy) ~= "table" then
            return nil
        end
        local method = policy.method
        local path = policy.path
        if (method ~= "GET" and method ~= "POST") or type(path) ~= "string"
                or #path > 512 or not path:match("^/[A-Za-z0-9_:./%-]+$")
                or path:find("..", 1, true) or path:find("//", 1, true)
                or path:find("/./", 1, true) or path:sub(-2) == "/." then
            return nil
        end
        local request_headers = header_set(policy.request_headers, false)
        local response_headers = header_set(policy.response_headers, true)
        local query_fields, query_count = name_set(policy.query_fields)
        local required_query_fields = name_set(policy.required_query_fields)
        if not request_headers or not response_headers or not query_fields
                or not required_query_fields then
            return nil
        end
        for name in pairs(required_query_fields) do
            if not query_fields[name] then return nil end
        end
        local content_type = policy.content_type
        if content_type ~= nil and (method ~= "POST" or not valid_value(content_type, 128)) then
            return nil
        end
        output[operation] = {
            method = method,
            path = path,
            content_type = content_type or "application/octet-stream",
            allow_cookie = policy.allow_cookie == true,
            allow_empty = policy.allow_empty == true,
            request_headers = request_headers,
            response_headers = response_headers,
            query_fields = query_fields,
            required_query_fields = required_query_fields,
            query_count = query_count,
        }
        count = count + 1
    end
    if count == 0 then return nil end
    return output
end

local function encode_query_component(value)
    return (value:gsub("([^%w%-._~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function build_query(policy, query)
    if query == nil then query = {} end
    if type(query) ~= "table" then return nil end
    local keys, count = {}, 0
    for key, value in pairs(query) do
        if type(key) ~= "string" or not policy.query_fields[key]
                or not valid_value(value, Client.MAX_QUERY_VALUE_BYTES) then
            return nil
        end
        count = count + 1
        keys[#keys + 1] = key
    end
    if count > policy.query_count then return nil end
    for name in pairs(policy.required_query_fields) do
        if query[name] == nil then return nil end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = encode_query_component(key)
            .. "=" .. encode_query_component(query[key])
    end
    return table.concat(parts, "&")
end

local function response_header_value(name, value)
    if type(value) == "string" then
        if not valid_value(value, Client.MAX_CREDENTIAL_HEADER_BYTES * 2) then return nil end
        return value
    end
    if name ~= "set-cookie" or type(value) ~= "table" then return nil end
    local output, total = {}, 0
    for index, item in ipairs(value) do
        if index > 32 or not valid_value(item, Client.MAX_CREDENTIAL_HEADER_BYTES * 2) then
            return nil
        end
        total = total + #item
        if total > Client.MAX_CREDENTIAL_HEADER_BYTES * 2 then return nil end
        output[index] = item
    end
    if #output == 0 then return nil end
    return output
end

local function fixed_request_error(value)
    local lower = type(value) == "string" and value:lower() or ""
    if lower == "timeout" or lower == "wantread" or lower == "sink timeout" then
        return "一次性授权网络请求超时，已安全停止"
    end
    if lower:find("certificate", 1, true) or lower:find("verify", 1, true)
            or lower:find("hostname", 1, true) or lower:find("issuer", 1, true)
            or lower:find("self signed", 1, true) or lower:find("ca locations", 1, true) then
        return "一次性授权 HTTPS 证书验证失败，已安全停止"
    end
    return "一次性授权网络请求失败，已安全停止"
end

local function fixed_status_error(code)
    code = tonumber(code)
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        return "一次性授权返回重定向，已安全停止"
    end
    if code == 401 or code == 403 then return "一次性授权已失效或被拒绝" end
    if code == 429 then return "一次性授权请求过于频繁，请稍后重试" end
    if code and code >= 500 then return "一次性授权官方服务暂时异常，请稍后重试" end
    return "一次性授权返回未接受的状态，已安全停止"
end

function Client.new(operations)
    local policy = validate_policy(operations)
    if not policy then return nil, "一次性授权请求白名单无效" end
    return setmetatable({ _operations = policy }, Client)
end

function Client:request(operation, input)
    local policy = self._operations[operation]
    if not policy or (input ~= nil and type(input) ~= "table") then
        return nil, "一次性授权请求不在固定白名单中"
    end
    input = input or {}
    for key in pairs(input) do
        if key ~= "body" and key ~= "cookie" and key ~= "headers" and key ~= "query" then
            return nil, "一次性授权请求参数无效"
        end
    end
    local query = build_query(policy, input.query)
    if query == nil then return nil, "一次性授权请求参数无效" end
    local body = input.body
    if policy.method == "GET" then
        if body ~= nil then return nil, "一次性授权请求参数无效" end
    elseif type(body) ~= "string" or #body > Client.MAX_REQUEST_BYTES then
        return nil, "一次性授权请求正文无效"
    end

    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json",
        ["Connection"] = "close",
    }
    if input.cookie ~= nil then
        if not policy.allow_cookie
                or not valid_value(input.cookie, Client.MAX_CREDENTIAL_HEADER_BYTES) then
            return nil, "一次性授权 Cookie 无效"
        end
        headers["Cookie"] = input.cookie
    end
    if input.headers ~= nil then
        if type(input.headers) ~= "table" then return nil, "一次性授权请求头无效" end
        local seen = {}
        for name, value in pairs(input.headers) do
            local lower = type(name) == "string" and name:lower() or ""
            if not policy.request_headers[lower] or seen[lower]
                    or not valid_value(value, Client.MAX_CREDENTIAL_HEADER_BYTES) then
                return nil, "一次性授权请求头无效"
            end
            seen[lower] = true
            headers[name] = value
        end
    end
    if body ~= nil then
        headers["Content-Type"] = policy.content_type
        headers["Content-Length"] = #body
    end
    if http.PROXY then return nil, "检测到 HTTP 代理，一次性授权已安全停止" end

    local chunks, size, too_large = {}, 0, false
    local function sink(chunk)
        if chunk then
            size = size + #chunk
            if size > Client.MAX_RESPONSE_BYTES then
                too_large = true
                return nil, "response too large"
            end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local request = {
        url = "https://" .. HOST .. policy.path .. (query ~= "" and ("?" .. query) or ""),
        method = policy.method,
        redirect = false,
        create = VerifiedTLS.create,
        headers = headers,
        sink = sink,
    }
    if body ~= nil then request.source = ltn12.source.string(body) end

    local timeout_ready, timeout_err = configure_timeout()
    if not timeout_ready then return nil, timeout_err end
    local called, ok, code, response_headers, status = pcall(http.request, request)
    if not restore_timeout() then return nil, TIMEOUT_RESET_ERROR end
    if too_large then return nil, "一次性授权响应超过 2 MB，已安全停止" end
    if not called then return nil, fixed_request_error(ok) end
    if not ok then return nil, fixed_request_error(code or status) end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then return nil, fixed_status_error(code) end
    if size == 0 and not policy.allow_empty then return nil, "一次性授权返回空响应，已安全停止" end
    local content_length = type(response_headers) == "table"
        and tonumber(response_headers["content-length"] or response_headers["Content-Length"])
    if content_length and content_length ~= size then
        return nil, "一次性授权响应传输不完整，已安全停止"
    end

    local exposed = {}
    for name, value in pairs(type(response_headers) == "table" and response_headers or {}) do
        local lower = type(name) == "string" and name:lower() or ""
        if policy.response_headers[lower] then
            local accepted = response_header_value(lower, value)
            if accepted == nil then
                return nil, "一次性授权响应头无效，已安全停止"
            end
            exposed[lower] = accepted
        end
    end
    return { body = table.concat(chunks), headers = exposed, status = code }
end

return Client

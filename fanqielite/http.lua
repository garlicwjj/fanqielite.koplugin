local http = require("socket.http")
local socketutil = require("socketutil")
local VerifiedTLS = require("fanqielite.verified_tls")

local Http = {}

local USER_AGENT = "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 Chrome/120 Safari/537.36"
local MAX_BYTES = 1024 * 1024
local BLOCK_TIMEOUT = 10
local TOTAL_TIMEOUT = 20

local function request_error(value)
    value = tostring(value or "")
    if value == "response too large" then
        return "官方响应超过 1 MB 安全限制，已停止读取；本地数据未改变"
    end
    if value == "timeout" or value == "sink timeout" or value == "wantread" then
        return "网络连接超时，请检查 Kindle 的 Wi-Fi 和系统时间后重试；本地数据未改变"
    end
    local lower = value:lower()
    if lower:find("certificate", 1, true) or lower:find("verify", 1, true)
            or lower:find("hostname", 1, true) or lower:find("issuer", 1, true)
            or lower:find("self signed", 1, true) or lower:find("ca locations", 1, true) then
        return "HTTPS 证书验证失败，请先让 Kindle 联网校准系统时间；本地数据未改变"
    end
    return "网络请求失败：" .. (value ~= "" and value or "原因未知") .. "；本地数据未改变"
end

local function status_error(code)
    code = tonumber(code)
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        return "官方地址返回重定向（HTTP " .. tostring(code) .. "），已为安全起见停止请求；本地数据未改变"
    elseif code == 401 or code == 403 then
        return "官方服务拒绝访问（HTTP " .. tostring(code) .. "），内容可能需要登录或授权；本地数据未改变"
    elseif code == 404 then
        return "官方页面不存在（HTTP 404），请检查书籍链接或稍后刷新目录；本地数据未改变"
    elseif code == 429 then
        return "请求过于频繁（HTTP 429），请稍后再试；本地数据未改变"
    elseif code and code >= 500 then
        return "番茄官方服务暂时异常（HTTP " .. tostring(code) .. "），请稍后重试；本地数据未改变"
    end
    return "官方服务返回异常（HTTP " .. tostring(code or "未知") .. "）；本地数据未改变"
end

local function has_header(headers, expected)
    if type(headers) ~= "table" then return false end
    expected = expected:lower()
    for name, value in pairs(headers) do
        if tostring(name):lower() == expected and value ~= nil and tostring(value) ~= "" then
            return true
        end
    end
    return false
end

function Http.get(url, accept)
    if type(url) ~= "string" or not url:match("^https://fanqienovel%.com/") then
        return nil, "已拒绝访问非番茄官方 HTTPS 地址；本地数据未改变"
    end
    if http.PROXY then
        return nil, "检测到 HTTP 代理，已为安全起见停止请求；本地数据未改变"
    end
    local chunks, size = {}, 0
    local started_at = os.time()
    local function sink(chunk)
        if chunk then
            if os.time() - started_at > TOTAL_TIMEOUT then return nil, "sink timeout" end
            size = size + #chunk
            if size > MAX_BYTES then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local called, ok, code, headers, status = pcall(http.request, {
            url = url,
            method = "GET",
            redirect = false,
            create = VerifiedTLS.create,
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = accept or "text/html,application/xhtml+xml",
                ["Accept-Language"] = "zh-CN,zh;q=0.9",
                ["Connection"] = "close",
            },
            sink = sink,
        })
    socketutil:reset_timeout()
    if not called then return nil, request_error(ok) end
    if not ok then return nil, request_error(code or status) end
    if tonumber(code) ~= 200 then return nil, status_error(code) end
    if has_header(headers, "bdturing-verify")
            or has_header(headers, "x-vc-bdturing-parameters") then
        return nil, "番茄官方安全验证需要在浏览器中完成，Kindle 无法显示该验证。"
            .. "请稍后重试；添加书籍时也可以从番茄官网复制官方链接。"
            .. "本地数据未改变"
    end
    if size == 0 then
        return nil, "番茄官方服务返回空内容，可能正在限制访问；请稍后重试；本地数据未改变"
    end
    local content_length = headers and tonumber(headers["content-length"] or headers["Content-Length"])
    if content_length and content_length ~= size then
        return nil, "官方响应传输不完整，已拒绝解析；本地数据未改变"
    end
    return table.concat(chunks), headers
end

return Http

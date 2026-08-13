local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")

local Http = {}

local USER_AGENT = "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 Chrome/120 Safari/537.36"
local MAX_BYTES = 1024 * 1024

function Http.get(url, accept)
    local chunks, size = {}, 0
    local function sink(chunk)
        if chunk then
            size = size + #chunk
            if size > MAX_BYTES then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    socketutil:set_timeout(10, 20)
    local called, ok, code, headers, status = pcall(https.request, {
            url = url,
            method = "GET",
            redirect = false,
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = accept or "text/html,application/xhtml+xml",
                ["Accept-Language"] = "zh-CN,zh;q=0.9",
                ["Connection"] = "close",
            },
            sink = sink,
        })
    socketutil:reset_timeout()
    if not called then return nil, tostring(ok) end
    if not ok then return nil, tostring(code or status or "网络请求失败") end
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(chunks), headers
end

return Http

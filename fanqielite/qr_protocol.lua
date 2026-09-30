local Client = require("fanqielite.ephemeral_http")
local CookieJar = require("fanqielite.ephemeral_cookiejar")
local Import = require("fanqielite.import")
local SafeURL = require("fanqielite.safeurl")
local rapidjson = require("rapidjson")
local socket = require("socket")

local Protocol = {}

Protocol.AID = "2503"
Protocol.SDK_VERSION = "2.2.6-beta.2"
Protocol.NEXT = "https://fanqienovel.com/bookshelf"
Protocol.MAX_QR_SECONDS = 5 * 60
Protocol.POLL_INTERVAL = 1

local COMMON_QUERY = {
    aid = Protocol.AID,
    account_sdk_source = "web",
    sdk_version = Protocol.SDK_VERSION,
}

local POLICIES = {
    qr_init = {
        method = "GET",
        path = "/passport/web/get_qrcode/",
        query_fields = { "next", "aid", "account_sdk_source", "sdk_version" },
        required_query_fields = { "next", "aid", "account_sdk_source", "sdk_version" },
        request_headers = { "Referer" },
        response_headers = { "Set-Cookie" },
    },
    qr_poll = {
        method = "GET",
        path = "/passport/web/check_qrconnect/",
        query_fields = { "next", "token", "aid", "account_sdk_source", "sdk_version" },
        required_query_fields = { "next", "token", "aid", "account_sdk_source", "sdk_version" },
        allow_cookie = true,
        request_headers = { "Referer", "X-TT-Passport-CSRF-Token" },
        response_headers = { "Set-Cookie" },
    },
    shelf = {
        method = "GET",
        path = "/reading/bookapi/bookshelf/info/v:version/",
        allow_cookie = true,
        request_headers = { "Referer" },
        response_headers = { "Set-Cookie" },
    },
    details = {
        method = "POST",
        path = "/api/book/simple/info",
        content_type = "application/json",
        allow_cookie = true,
        request_headers = { "Referer" },
        response_headers = { "Set-Cookie" },
    },
    progress = {
        method = "GET",
        path = "/api/reader/book/progress",
        allow_cookie = true,
        request_headers = { "Referer" },
        response_headers = { "Set-Cookie" },
    },
    logout = {
        method = "GET",
        path = "/passport/web/logout/",
        query_fields = { "need_redirect", "aid", "account_sdk_source", "sdk_version" },
        required_query_fields = { "need_redirect", "aid", "account_sdk_source", "sdk_version" },
        allow_cookie = true,
        allow_empty = true,
        request_headers = { "Referer", "X-TT-Passport-CSRF-Token" },
        response_headers = { "Set-Cookie" },
    },
}

local safe_error_codes = {
    network = true,
    invalid_response = true,
    expired = true,
    refused = true,
    verification_required = true,
    bookshelf_failed = true,
    empty_bookshelf = true,
}

local function now(options)
    local clock = type(options) == "table" and options.clock or os.time
    local called, value = pcall(clock)
    value = called and tonumber(value) or nil
    return value and value == value and math.floor(value) or 0
end

local function pause(options)
    local sleeper = type(options) == "table" and options.sleep or socket.sleep
    return pcall(sleeper, Protocol.POLL_INTERVAL)
end

local function client(options)
    if type(options) == "table" and type(options.client) == "table" then
        return options.client
    end
    return Client.new(POLICIES)
end

local function query(extra)
    local output = {}
    for key, value in pairs(COMMON_QUERY) do output[key] = value end
    for key, value in pairs(extra or {}) do output[key] = value end
    return output
end

local function decode_json(text)
    if type(text) ~= "string" or text == "" or #text > Client.MAX_RESPONSE_BYTES then return nil end
    local called, value = pcall(rapidjson.decode, text)
    if not called or type(value) ~= "table" then return nil end
    return value
end

local function encode_json(value)
    local called, text = pcall(rapidjson.encode, value)
    if not called or type(text) ~= "string" or text == "" then return nil end
    return text
end

local function merge_response_cookies(jar, response)
    local value = type(response) == "table" and type(response.headers) == "table"
        and response.headers["set-cookie"] or nil
    if value == nil then return true end
    return jar:merge_set_cookie(value)
end

local function request_headers(jar, include_csrf)
    local output = { Referer = Protocol.NEXT }
    if include_csrf then
        local csrf = jar:get("passport_csrf_token")
            or jar:get("passport_csrf_token_default")
        if not csrf then return nil end
        output["X-TT-Passport-CSRF-Token"] = csrf
    end
    return output
end

local function percent_decode(value)
    if type(value) ~= "string" then return nil end
    local offset = 1
    while true do
        local position = value:find("%", offset, true)
        if not position then break end
        if not value:sub(position + 1, position + 2):match("^%x%x$") then return nil end
        offset = position + 3
    end
    local output = value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    if output:find("[%z\1-\31\127]") then return nil end
    return output
end

local qr_query_fields = {
    _isTopFullScreen = true,
    _needManualDomReady = true,
    _showAppBar = true,
    custom_brightness = true,
    hide_bar = true,
    hide_nav_bar = true,
    hide_status_bar = true,
    need_custom_brightness = true,
    next_url = true,
    outSideAppName = true,
    qr_source_aid = true,
    token = true,
    uc_sdk = true,
    version_code = true,
}

local function valid_qr_url(value, token)
    if type(value) ~= "string" or #value > 2048 or value:find("[%z\1-\32\127#]") then return nil end
    local raw_query = value:match("^https://reading%.snssdk%.com/ucenter_web/app/sdk%-next%?(.+)$")
    if not raw_query then return nil end
    local seen, qr_token = {}, nil
    for pair in raw_query:gmatch("[^&]+") do
        local key, item = pair:match("^([^=]+)=?(.*)$")
        key = percent_decode(key)
        if not key or not qr_query_fields[key] or seen[key] then return nil end
        seen[key] = true
        if key == "token" then qr_token = percent_decode(item) end
    end
    if qr_token ~= token or not seen.next_url or not seen.qr_source_aid then return nil end
    return value
end

local function valid_token(value)
    return type(value) == "string" and value ~= "" and #value <= 512
        and value:match("^[%w._%-]+$") ~= nil
end

local function start_error(code)
    return nil, safe_error_codes[code] and code or "invalid_response"
end

function Protocol.begin(options)
    local transport = client(options)
    if not transport then return start_error("invalid_response") end
    local response = transport:request("qr_init", {
        query = query({ next = Protocol.NEXT }),
        headers = { Referer = Protocol.NEXT },
    })
    if not response then return start_error("network") end
    local payload = decode_json(response.body)
    local data = payload and payload.data
    if payload == nil or payload.message ~= "success" or type(data) ~= "table"
            or tonumber(data.error_code) ~= 0 or not valid_token(data.token) then
        return start_error("invalid_response")
    end
    local current = now(options)
    local expires_at = tonumber(data.expire_time)
    if not expires_at or expires_at ~= math.floor(expires_at)
            or expires_at <= current or expires_at > current + Protocol.MAX_QR_SECONDS then
        return start_error("invalid_response")
    end
    local qr_payload = valid_qr_url(data.qrcode_index_url, data.token)
    if not qr_payload then return start_error("invalid_response") end
    local jar = CookieJar.new()
    if not merge_response_cookies(jar, response) then return start_error("invalid_response") end
    local cookie = jar:header()
    if not cookie or not request_headers(jar, true) then return start_error("invalid_response") end
    return {
        qr_payload = qr_payload,
        token = data.token,
        cookie = cookie,
        expires_at = expires_at,
    }
end

function Protocol.validate_start(start, options, require_fresh)
    if type(start) ~= "table" or not valid_token(start.token)
            or type(start.cookie) ~= "string" or type(start.expires_at) ~= "number"
            or start.expires_at ~= math.floor(start.expires_at)
            or not valid_qr_url(start.qr_payload, start.token) then
        return nil
    end
    local current = now(options)
    if require_fresh and (start.expires_at <= current
            or start.expires_at > current + Protocol.MAX_QR_SECONDS) then
        return nil
    end
    local jar = CookieJar.from_header(start.cookie)
    if not jar or not request_headers(jar, true) then return nil end
    return {
        qr_payload = start.qr_payload,
        token = start.token,
        cookie = start.cookie,
        expires_at = start.expires_at,
    }
end

local function clean_text(value, maximum, required)
    if type(value) ~= "string" or value:find("[%z\1-\31\127]") then
        return required and nil or ""
    end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or #value > maximum then return required and nil or "" end
    return value
end

local function valid_id(value)
    return type(value) == "string" and value:match("^%d+$")
        and #value >= 10 and #value <= 64
end

local function shelf_ids(payload)
    if type(payload) ~= "table" or tonumber(payload.code) ~= 0
            or type(payload.data) ~= "table"
            or type(payload.data.book_shelf_info) ~= "table" then return nil end
    local list = payload.data.book_shelf_info
    if #list > Import.MAX_BOOKS then return nil end
    local output, seen = {}, {}
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #list then return nil end
    end
    for _, item in ipairs(list) do
        if type(item) ~= "table" then return nil end
        local book_type = item.book_type
        if book_type == nil or book_type == 0 or book_type == "0" then
            if not valid_id(item.book_id) then return nil end
            if not seen[item.book_id] then
                seen[item.book_id] = true
                output[#output + 1] = item.book_id
            end
        elseif not ((type(book_type) == "number" and book_type == math.floor(book_type))
                or (type(book_type) == "string" and book_type:match("^%d%d?%d?$"))) then
            return nil
        end
    end
    return output
end

local function clean_cover(value)
    if type(value) ~= "string" then return "" end
    if value:sub(1, 2) == "//" then value = "https:" .. value end
    return SafeURL.https(value, 2048) or ""
end

local function details_by_id(payload, ids)
    if type(payload) ~= "table" or tonumber(payload.code) ~= 0
            or type(payload.data) ~= "table" then return nil end
    local list = payload.data.bookList or payload.data.book_list
    if type(list) ~= "table" or #list > Import.MAX_BOOKS then return nil end
    local requested, output = {}, {}
    for _, id in ipairs(ids) do requested[id] = true end
    for _, item in ipairs(list) do
        if type(item) ~= "table" or not valid_id(item.book_id)
                or not requested[item.book_id] or output[item.book_id] then return nil end
        local title = clean_text(item.book_name, 300, true)
        if not title then return nil end
        output[item.book_id] = {
            id = item.book_id,
            title = title,
            author = clean_text(item.author or item.author_name, 150, false),
            cover_url = clean_cover(item.thumb_url or item.thumb_uri),
        }
    end
    for _, id in ipairs(ids) do if not output[id] then return nil end end
    return output
end

local function progress_by_id(payload, ids)
    if type(payload) ~= "table" or tonumber(payload.code) ~= 0
            or type(payload.data) ~= "table" or #payload.data > Import.MAX_BOOKS then return nil end
    local requested, output = {}, {}
    for _, id in ipairs(ids) do requested[id] = true end
    for _, item in ipairs(payload.data) do
        if type(item) ~= "table" or not valid_id(item.book_id) then return nil end
        if requested[item.book_id] then
            if output[item.book_id] or not valid_id(item.item_id) then return nil end
            local title = ""
            for _, field in ipairs({ "origin_chapter_title", "title", "item_title", "chapter_title" }) do
                title = clean_text(item[field], 300, false)
                if title ~= "" then break end
            end
            output[item.book_id] = { chapter_id = item.item_id, chapter_title = title }
        end
    end
    return output
end

local function authenticated_request(transport, operation, jar, input)
    input = input or {}
    input.cookie = jar:header()
    input.headers = input.headers or request_headers(jar, false)
    if not input.cookie or not input.headers then return nil end
    local response = transport:request(operation, input)
    if not response or not merge_response_cookies(jar, response) then return nil end
    return response
end

local function fetch_books(transport, jar)
    local shelf_response = authenticated_request(transport, "shelf", jar)
    local ids = shelf_response and shelf_ids(decode_json(shelf_response.body))
    if not ids then return nil, "bookshelf_failed" end
    if #ids == 0 then return nil, "empty_bookshelf" end
    local body = encode_json({ book_ids = ids })
    if not body then return nil, "bookshelf_failed" end
    local detail_response = authenticated_request(transport, "details", jar, { body = body })
    local details = detail_response and details_by_id(decode_json(detail_response.body), ids)
    if not details then return nil, "bookshelf_failed" end

    local progress, progress_found = {}, false
    local progress_response = authenticated_request(transport, "progress", jar)
    if progress_response then
        local parsed = progress_by_id(decode_json(progress_response.body), ids)
        if parsed then progress, progress_found = parsed, true end
    end
    local books = {}
    for _, id in ipairs(ids) do
        local detail, current = details[id], progress[id]
        local book = {
            id = id,
            title = detail.title,
            author = detail.author,
            cover_url = detail.cover_url,
        }
        if current then
            book.current_chapter_id = current.chapter_id
            if current.chapter_title ~= "" then
                book.current_chapter_title = current.chapter_title
            end
        end
        books[#books + 1] = book
    end
    return {
        format = Import.FORMAT,
        version = Import.VERSION,
        books = books,
    }, nil, progress_found
end

local function logout(transport, jar)
    local headers = request_headers(jar, true)
    local cookie = jar:header()
    if not headers or not cookie then jar:clear(); return false end
    local response = transport:request("logout", {
        query = {
            aid = Protocol.AID,
            account_sdk_source = "web",
            need_redirect = "0",
            sdk_version = Protocol.SDK_VERSION,
        },
        cookie = cookie,
        headers = headers,
    })
    jar:clear()
    return response ~= nil
end

function Protocol.finish(start, options)
    start = Protocol.validate_start(start, options, false)
    if not start then
        return { kind = "error", code = "invalid_response" }
    end
    local transport = client(options)
    local jar = CookieJar.from_header(start.cookie)
    if not transport or not jar then return { kind = "error", code = "invalid_response" } end
    local confirmed = false
    while now(options) < start.expires_at do
        local headers = request_headers(jar, true)
        local cookie = jar:header()
        if not headers or not cookie then jar:clear(); return { kind = "error", code = "invalid_response" } end
        local response = transport:request("qr_poll", {
            query = query({ next = Protocol.NEXT, token = start.token }),
            cookie = cookie,
            headers = headers,
        })
        if not response then jar:clear(); return { kind = "error", code = "network" } end
        if not merge_response_cookies(jar, response) then
            jar:clear(); return { kind = "error", code = "invalid_response" }
        end
        local payload = decode_json(response.body)
        local data = payload and payload.data
        local error_code = type(data) == "table" and tonumber(data.error_code) or nil
        local status = type(data) == "table" and data.status or nil
        if error_code == 2046 then
            jar:clear(); return { kind = "error", code = "verification_required" }
        end
        if payload == nil or payload.message ~= "success" or error_code ~= 0
                or type(status) ~= "string" then
            jar:clear(); return { kind = "error", code = "invalid_response" }
        end
        if status == "confirmed" then confirmed = true; break end
        if status == "expired" then jar:clear(); return { kind = "error", code = "expired" } end
        if status == "refused" or status == "canceled" or status == "cancelled" then
            jar:clear(); return { kind = "error", code = "refused" }
        end
        if status ~= "new" and status ~= "scanned" then
            jar:clear(); return { kind = "error", code = "invalid_response" }
        end
        if not pause(options) then jar:clear(); return { kind = "error", code = "network" } end
    end
    if not confirmed then jar:clear(); return { kind = "error", code = "expired" } end

    local payload, fetch_err, progress_found = fetch_books(transport, jar)
    local logout_ok = logout(transport, jar)
    if not payload then
        return { kind = "error", code = fetch_err or "bookshelf_failed", logout_ok = logout_ok }
    end
    return {
        kind = "success",
        payload = payload,
        logout_ok = logout_ok,
        progress_found = progress_found,
    }
end

Protocol.safe_error_codes = safe_error_codes
Protocol.policies = POLICIES

return Protocol

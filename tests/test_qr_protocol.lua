package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["socket"] = function()
    return { sleep = function() return true end }
end
package.preload["fanqielite.ephemeral_http"] = function()
    return {
        MAX_RESPONSE_BYTES = 2 * 1024 * 1024,
        new = function() error("test must inject a client") end,
    }
end

local encoded, sequence = {}, 0
package.preload["rapidjson"] = function()
    return {
        encode = function(value)
            sequence = sequence + 1
            local key = "json:" .. tostring(sequence)
            encoded[key] = value
            return key
        end,
        decode = function(value) return encoded[value] end,
    }
end

local rapidjson = require("rapidjson")
local Protocol = require("fanqielite.qr_protocol")

local token = "official-test-token-1234567890"
local qr = "https://reading.snssdk.com/ucenter_web/app/sdk-next?"
    .. "next_url=https%3A%2F%2Ffanqienovel.com%2Fbookshelf"
    .. "&token=" .. token .. "&qr_source_aid=2503"
local now = 1000
local calls = {}
local poll_count = 0
local client = {}

local function response(value, cookies)
    return {
        status = 200,
        body = rapidjson.encode(value),
        headers = cookies and { ["set-cookie"] = cookies } or {},
    }
end

function client:request(operation, input)
    calls[#calls + 1] = { operation = operation, input = input }
    if operation == "qr_init" then
        return response({ message = "success", data = {
            error_code = 0,
            expire_time = 1060,
            qrcode_index_url = qr,
            token = token,
        } }, {
            "passport_csrf_token=csrf-value; Path=/; Secure",
            "reg-store-region=cn; Path=/; HttpOnly",
        })
    elseif operation == "qr_poll" then
        poll_count = poll_count + 1
        assert(input.query.token == token and input.query.aid == "2503")
        assert(input.headers["X-TT-Passport-CSRF-Token"] == "csrf-value")
        if poll_count == 1 then
            return response({ message = "success", data = { error_code = 0, status = "new" } })
        elseif poll_count == 2 then
            return response({ message = "success", data = { error_code = 0, status = "scanned" } })
        end
        return response({ message = "success", data = { error_code = 0, status = "confirmed" } },
            "sessionid=session-value; Path=/; HttpOnly")
    elseif operation == "shelf" then
        assert(input.cookie:find("sessionid=session%-value"), "authenticated Cookie missing")
        return response({ code = 0, data = { book_shelf_info = {
            { book_id = "7134567890123456789", book_type = 0 },
            { book_id = "7134567890123456789", book_type = "0" },
        } } })
    elseif operation == "details" then
        local posted = rapidjson.decode(input.body)
        assert(#posted.book_ids == 1 and posted.book_ids[1] == "7134567890123456789")
        return response({ code = 0, data = { book_list = {{
            book_id = "7134567890123456789",
            book_name = "协议测试书",
            author_name = "测试作者",
            thumb_url = "//example.invalid/cover.jpg",
        }} } })
    elseif operation == "progress" then
        return response({ code = 0, data = {{
            book_id = "7134567890123456789",
            item_id = "7134567890123456701",
            origin_chapter_title = "第一章",
        }} })
    elseif operation == "logout" then
        assert(input.query.need_redirect == "0" and input.query.sdk_version == Protocol.SDK_VERSION)
        assert(input.cookie:find("sessionid=session%-value"), "logout lost authenticated Cookie")
        return response({ message = "success", data = { error_code = 0 } })
    end
end

local options = {
    client = client,
    clock = function() return now end,
    sleep = function() now = now + 1; return true end,
}
local start = assert(Protocol.begin(options))
assert(start.qr_payload == qr and start.token == token and start.expires_at == 1060)
assert(start.cookie:find("passport_csrf_token=csrf%-value"))
assert(Protocol.validate_start(start, options, true))

local outcome = Protocol.finish(start, options)
assert(outcome.kind == "success" and outcome.logout_ok == true)
assert(outcome.progress_found == true and #outcome.payload.books == 1)
local book = outcome.payload.books[1]
assert(book.id == "7134567890123456789" and book.title == "协议测试书")
assert(book.author == "测试作者" and book.cover_url == "https://example.invalid/cover.jpg")
assert(book.current_chapter_id == "7134567890123456701"
    and book.current_chapter_title == "第一章")
assert(poll_count == 3, "poll status sequence did not complete")

local invalid_start = {
    qr_payload = qr:gsub("token=[^&]+", "token=wrong", 1),
    token = token,
    cookie = "passport_csrf_token=csrf-value",
    expires_at = 1060,
}
assert(Protocol.validate_start(invalid_start, options, true) == nil,
    "mismatched QR token was accepted")

local verification_client = { request = function(_, operation)
    if operation == "qr_poll" then
        return response({ message = "error", data = { error_code = 2046, status = "new" } })
    end
end }
local verification = Protocol.finish(start, {
    client = verification_client,
    clock = function() return 1001 end,
    sleep = function() return true end,
})
assert(verification.kind == "error" and verification.code == "verification_required")

print("QR protocol tests passed")

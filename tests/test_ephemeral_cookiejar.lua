package.path = "./?.lua;./?/init.lua;" .. package.path

local CookieJar = require("fanqielite.ephemeral_cookiejar")

local jar = CookieJar.new()
assert(jar:merge_set_cookie({
    "passport_csrf_token=csrf-one; Path=/; Secure; SameSite=None",
    "reg-store-region=cn; Path=/; HttpOnly",
}))
assert(jar:get("passport_csrf_token") == "csrf-one")
assert(jar:get("reg-store-region") == "cn")
assert(jar:header() == "passport_csrf_token=csrf-one; reg-store-region=cn",
    "Cookie header was not deterministic")

assert(jar:merge_set_cookie(
    "passport_csrf_token=csrf-two; Path=/, sessionid=temporary-session; Path=/; HttpOnly"))
assert(jar:get("passport_csrf_token") == "csrf-two")
assert(jar:get("sessionid") == "temporary-session")
assert(jar:has_any({ "sid_tt", "sessionid" }))

assert(jar:merge_set_cookie("sessionid=; Max-Age=0; Path=/"))
assert(jar:get("sessionid") == nil, "expired Cookie was retained")

local restored = assert(CookieJar.from_header(jar:header()))
assert(restored:get("passport_csrf_token") == "csrf-two")
assert(restored:get("reg-store-region") == "cn")

for _, invalid in ipairs({
    "bad name=value; Path=/",
    "safe=bad\r\nInjected; Path=/",
    "safe=comma,value; Path=/",
    string.rep("x", CookieJar.MAX_NAME_BYTES + 1) .. "=value; Path=/",
}) do
    local accepted = CookieJar.new():merge_set_cookie(invalid)
    assert(accepted == nil, "invalid Set-Cookie input was accepted")
end

local duplicate, duplicate_err = CookieJar.from_header("same=one; same=two")
assert(duplicate == nil and duplicate_err:find("Cookie 无效", 1, true))

jar:clear()
assert(jar:header() == nil and jar:get("passport_csrf_token") == nil,
    "Cookie clear retained values")

print("ephemeral Cookie jar tests passed")

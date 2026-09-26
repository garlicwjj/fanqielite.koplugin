package.path = "./?.lua;./?/init.lua;" .. package.path

local Session = require("fanqielite.ephemeral_session")

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local now = 1000
local function clock() return now end

local function valid_books()
    return {{
        id = "7633875868615461950",
        title = "测试书籍",
        author = "测试作者",
        cover_url = "https://example.invalid/cover.jpg",
        current_chapter_id = "70000000001",
        current_chapter_title = "第一章",
        reading_position = 0.75,
    }}
end

local function contains(value, needle, seen)
    if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, child in pairs(value) do
        if contains(key, needle, seen) or contains(child, needle, seen) then return true end
    end
    return false
end

local function reach_state(session, credentials)
    local run_id = assert(session:start())
    assert(session:qr_ready(run_id, "qr:" .. canary, "poll:" .. canary, now + 30))
    assert(session:authorize(run_id, credentials or {
        cookie = canary,
        csrf_token = canary,
        authorization = "Bearer " .. canary,
        logout_ticket = canary,
    }))
    assert(session:begin_fetch(run_id))
    return run_id
end

-- Success holds credentials only until the cleanup/logout attempt, then exposes
-- a copy of strictly validated bookshelf data for a separate atomic commit.
local success = Session.new(clock)
local success_id = assert(success:start())
local duplicate, duplicate_err = success:start()
assert(duplicate == nil and duplicate_err:find("正在进行", 1, true), "parallel session accepted")
assert(not duplicate_err:find(canary, 1, true), "parallel-session error leaked credentials")
assert(success:qr_ready(success_id, "qr:" .. canary, "poll:" .. canary, now + 30))
local supplied_credentials = { cookie = canary, csrf_token = canary }
assert(success:authorize(success_id, supplied_credentials))
supplied_credentials.cookie = "caller-mutated-cookie"
assert(success:begin_fetch(success_id))
local cleanup_calls = 0
local cleanup_credentials
local prepared, prepare_notice = success:prepare_import(success_id, valid_books(), function(credentials)
    cleanup_calls = cleanup_calls + 1
    cleanup_credentials = credentials
    assert(credentials.cookie == canary, "session retained the caller-owned credential table")
    assert(credentials.csrf_token == canary, "cleanup did not receive the bounded CSRF token")
    return true
end)
assert(prepared and prepare_notice == nil, "successful preparation reported a warning")
assert(cleanup_calls == 1, "successful flow did not attempt cleanup exactly once")
assert(next(cleanup_credentials) == nil, "successful cleanup left credentials in a retained table")
assert(not contains(cleanup_credentials, canary), "retained cleanup table contains credential canary")
local success_status = success:status()
assert(success_status.state == "ready_to_confirm", "successful flow not ready for confirmation")
assert(success_status.logout_ok == true, "successful logout result missing")
assert(success_status.has_sensitive == false, "credentials remain reachable after logout")
assert(not contains(success, canary), "credential canary remains in successful session")
assert(not contains(success, "caller-mutated-cookie"), "caller mutation reached the session")
now = now + Session.MAX_DURATION
local ready_expired = success:check_timeout(success_id)
assert(ready_expired == false, "safe confirmation data expired after credentials were cleared")

local commit_books = assert(success:begin_commit(success_id))
assert(commit_books[1].imported_progress.position == 0.75, "normalized progress missing")
commit_books[1].title = "调用方修改"
assert(success:complete_commit(success_id, false))
local retry_books = assert(success:begin_commit(success_id))
assert(retry_books[1].title == "测试书籍", "failed commit mutated retained confirmation data")
assert(success:complete_commit(success_id, true))
assert(success:status().state == "done", "successful commit did not finish session")

-- Logout failure is not allowed to retain credentials or block a safe local
-- confirmation. Raw callback errors must never reach the returned warning.
local logout_failure = Session.new(clock)
local logout_failure_id = reach_state(logout_failure)
local failed_cleanup_credentials
local logout_prepared, logout_notice = logout_failure:prepare_import(
    logout_failure_id, valid_books(), function(credentials)
        failed_cleanup_credentials = credentials
        error("logout failed " .. canary)
    end)
assert(logout_prepared, "logout failure incorrectly discarded validated books")
assert(logout_notice and logout_notice:find("退出未完成", 1, true), "logout warning missing")
assert(not logout_notice:find(canary, 1, true), "logout error leaked credential canary")
assert(logout_failure:status().logout_ok == false, "logout failure status missing")
assert(next(failed_cleanup_credentials) == nil, "failed cleanup left credentials in a retained table")
assert(not contains(logout_failure, canary), "logout failure retained credential canary")

-- Cancellation and repeated termination are idempotent. Cleanup failure is
-- reported only as a fixed category and never changes the terminal result.
local cancelled = Session.new(clock)
local cancelled_id = reach_state(cancelled)
local cancel_calls = 0
local cancelled_credentials
local cancelled_ok, cancel_notice = cancelled:cancel(cancelled_id, function(credentials)
    cancel_calls = cancel_calls + 1
    cancelled_credentials = credentials
    return nil, "cancel cleanup failed " .. canary
end)
assert(cancelled_ok and cancel_notice:find("退出未完成", 1, true), "cancel warning missing")
assert(not cancel_notice:find(canary, 1, true), "cancel error leaked credential canary")
assert(cancelled:status().state == "done", "cancel did not terminate session")
assert(next(cancelled_credentials) == nil, "cancel left credentials in a retained table")
assert(not contains(cancelled, canary), "cancel retained credential canary")
assert(cancelled:cancel(cancelled_id), "repeated cancel was not idempotent")
assert(cancel_calls == 1, "repeated cancel repeated credential cleanup")

-- Timeout uses both the QR expiry and overall deadline, performs cleanup once,
-- and leaves the session terminal without exposing the expired payload.
local timed_out = Session.new(clock)
local timeout_id = assert(timed_out:start())
local invalid_qr, invalid_qr_err = timed_out:qr_ready(
    timeout_id, "", "poll:" .. canary, now + 5)
assert(invalid_qr == nil and invalid_qr_err:find("二维码数据无效", 1, true), "invalid QR accepted")
assert(not contains(timed_out, canary), "rejected QR retained its poll ticket")
invalid_qr, invalid_qr_err = timed_out:qr_ready(
    timeout_id, "qr\nforged", "poll:" .. canary, now + 5)
assert(invalid_qr == nil and invalid_qr_err:find("二维码数据无效", 1, true),
    "control-bearing QR accepted")
assert(not contains(timed_out, canary), "control-bearing QR retained its poll ticket")
invalid_qr, invalid_qr_err = timed_out:qr_ready(
    timeout_id, string.rep("q", Session.MAX_QR_BYTES + 1), "poll:" .. canary, now + 5)
assert(invalid_qr == nil and invalid_qr_err:find("二维码数据无效", 1, true),
    "oversized QR accepted")
assert(not contains(timed_out, canary), "oversized QR retained its poll ticket")
invalid_qr, invalid_qr_err = timed_out:qr_ready(
    timeout_id, "qr:safe", "poll\n" .. canary, now + 5)
assert(invalid_qr == nil and invalid_qr_err:find("二维码数据无效", 1, true),
    "control-bearing poll ticket accepted")
assert(not contains(timed_out, canary), "control-bearing poll ticket was retained")
invalid_qr, invalid_qr_err = timed_out:qr_ready(
    timeout_id, "qr:safe", string.rep("p", Session.MAX_POLL_TICKET_BYTES + 1), now + 5)
assert(invalid_qr == nil and invalid_qr_err:find("二维码数据无效", 1, true),
    "oversized poll ticket accepted")
assert(timed_out:qr_ready(timeout_id, "qr:" .. canary, "poll:" .. canary, now + 5))
local early, early_err = timed_out:check_timeout(timeout_id, function() return true end)
assert(early == false and early_err == nil, "session timed out before its deadline")
now = now + 6
local timeout_cleanup_calls = 0
local expired, expired_notice = timed_out:check_timeout(timeout_id, function()
    timeout_cleanup_calls = timeout_cleanup_calls + 1
    return true
end)
assert(expired and expired_notice:find("二维码已过期", 1, true), "QR expiry not reported")
assert(timeout_cleanup_calls == 1, "QR expiry did not clean up exactly once")
assert(timed_out:status().state == "done", "timeout did not terminate session")
assert(not contains(timed_out, canary), "timeout retained credential canary")

local overall_timeout = Session.new(clock)
local overall_timeout_id = assert(overall_timeout:start())
now = now + Session.MAX_DURATION
local overall_expired, overall_notice = overall_timeout:check_timeout(overall_timeout_id)
assert(overall_expired and overall_notice:find("扫码导入已超时", 1, true), "overall timeout missing")
assert(overall_timeout:status().logout_ok == nil, "timeout without a session claimed logout success")

-- Authorization only accepts a copied, bounded set of credential fields. A
-- sessionid must be carried inside the Cookie header rather than as an
-- unreviewed parallel field.
local bounded = Session.new(clock)
local bounded_id = assert(bounded:start())
assert(bounded:qr_ready(bounded_id, "qr:" .. canary, "poll:" .. canary, now + 30))
for _, case in ipairs({
    { value = "not a table" },
    { value = { sessionid = canary } },
    { value = { csrf_token = canary } },
    { value = { cookie = "safe\r\nX-Leak: " .. canary } },
    { value = { cookie = string.rep("x", Session.MAX_COOKIE_BYTES + 1) } },
    { value = { authorization = string.rep("x", Session.MAX_AUTHORIZATION_BYTES + 1) } },
    { value = { cookie = "safe", csrf_token = string.rep("x", Session.MAX_TOKEN_BYTES + 1) } },
    { value = { cookie = "safe", logout_ticket = "" } },
    { value = { cookie = 12345 } },
    { value = { cookie = "safe", [1] = canary } },
}) do
    local accepted, authorization_err = bounded:authorize(bounded_id, case.value)
    assert(accepted == nil and authorization_err:find("授权结果无效", 1, true),
        "invalid credential bag accepted")
    assert(not authorization_err:find(canary, 1, true), "credential validation error leaked canary")
    assert(bounded:status().state == "qr_pending", "invalid credentials advanced the session")
end
assert(bounded:authorize(bounded_id, { authorization = "Bearer " .. canary }))
assert(bounded:cancel(bounded_id, function(credentials)
    return credentials.authorization == "Bearer " .. canary
end))
assert(not contains(bounded, canary), "bounded authorization cleanup retained canary")

local failed = Session.new(clock)
local failed_id = assert(failed:start())
local failed_ok, failed_notice = failed:fail(failed_id)
assert(failed_ok and failed_notice:find("没有改变", 1, true), "fixed failure safety notice missing")
assert(failed:status().state == "done", "fixed failure did not terminate session")

-- A stale result from an older run cannot advance or corrupt a newer run.
local stale = Session.new(clock)
local old_id = assert(stale:start())
assert(stale:cancel(old_id))
local new_id = assert(stale:start())
assert(new_id ~= old_id, "new session reused an old run id")
local stale_result, stale_err = stale:qr_ready(old_id, "qr:" .. canary, "poll:" .. canary, now + 30)
assert(stale_result == nil and stale_err:find("已失效", 1, true), "stale result accepted")
assert(not stale_err:find(canary, 1, true), "stale-result error leaked credential canary")
assert(stale:status().state == "initializing", "stale result changed current session")
assert(not contains(stale, canary), "stale result became reachable from current session")

-- Malformed or credential-bearing bookshelf data fails closed, clears the
-- active session, and returns a fixed error without echoing the payload.
local invalid = Session.new(clock)
local invalid_id = reach_state(invalid)
local unsafe_books = valid_books()
unsafe_books[1].cookie = canary
local invalid_result, invalid_err = invalid:prepare_import(
    invalid_id, unsafe_books, function() return true end)
assert(invalid_result == nil and invalid_err:find("数据验证失败", 1, true), "unsafe data accepted")
assert(not invalid_err:find(canary, 1, true), "validation error leaked credential canary")
assert(invalid:status().state == "done", "validation failure left session active")
assert(not contains(invalid, canary), "validation failure retained credential canary")

-- Force-clear is the local crash/forced-exit boundary: it cannot promise a
-- remote logout, but it must drop all plugin-reachable sensitive references.
local forced = Session.new(clock)
reach_state(forced)
assert(forced:force_clear())
assert(forced:status().state == "done", "force clear did not terminate session")
assert(forced:status().logout_ok == nil, "force clear claimed a remote logout result")
assert(not contains(forced, canary), "force clear retained credential canary")

print("ephemeral session tests passed")

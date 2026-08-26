package.path = "./?.lua;./?/init.lua;" .. package.path

local Parser = require("fanqielite.parser")
local Pua = require("fanqielite.pua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "assertion") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

equal(Parser.book_id("7633875868615461950"), "7633875868615461950", "plain id")
equal(Parser.book_id("https://fanqienovel.com/page/7633875868615461950"), "7633875868615461950", "page url")

local json = assert(Parser.extract_initial_state([[<script>window.__INITIAL_STATE__={"text":"a}\\\"b","nested":{"ok":true}};</script>]]))
equal(json, [[{"text":"a}\\\"b","nested":{"ok":true}}]], "balanced JSON")

local chapters = assert(Parser.directory_from_payload({ data = {
    chapterListWithVolume = { { { itemId = "10000000001", title = "第一章" } } },
} }))
equal(#chapters, 1, "chapter count")
equal(chapters[1].title, "第一章", "chapter title")

local malformed_directory, malformed_directory_err = Parser.directory_from_payload({ data = {
    chapterList = { { itemId = "7", title = "非法章节" }, { itemId = "../escape" } },
} })
equal(malformed_directory, nil, "malformed chapter ids accepted")
assert(malformed_directory_err:find("无效", 1, true), "malformed directory error missing")

local wrong_book, wrong_book_err = Parser.book_from_state({ page = {
    bookId = "10000000002", bookName = "错误书籍",
} }, "10000000001")
equal(wrong_book, nil, "mismatched book id accepted")
assert(wrong_book_err:find("不一致", 1, true), "mismatched book error missing")

local field_tostring_calls = 0
local field_canary = "FANQIELITE_PARSER_FIELD_CANARY_85ae"
local unsafe_field = setmetatable({}, { __tostring = function()
    field_tostring_calls = field_tostring_calls + 1
    return field_canary
end })
local unsafe_title, unsafe_title_err = Parser.book_from_state({ page = {
    bookId = "10000000003", bookName = unsafe_field,
} }, "10000000003")
equal(unsafe_title, nil, "object book title accepted")
assert(unsafe_title_err:find("书名格式无效", 1, true), "object book title error missing")
equal(field_tostring_calls, 0, "book title object invoked __tostring")

local unsafe_content, unsafe_content_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000004", title = "对象正文", content = unsafe_field,
    chapterWordNumber = 600,
} } }, "10000000004")
equal(unsafe_content, nil, "object chapter content accepted")
assert(unsafe_content_err:find("正文格式", 1, true), "object chapter content error missing")
equal(field_tostring_calls, 0, "chapter content object invoked __tostring")

local decoded, stats = Pua.decode("\238\143\168\238\143\169\238\143\170")
equal(decoded, "D在主", "PUA mapping")
equal(stats.pua, 3, "PUA count")
equal(stats.unknown, 0, "unknown count")

local invalid_decoded, invalid_stats = Pua.decode("正文\255结尾")
assert(invalid_decoded:find("�", 1, true), "invalid UTF-8 not replaced")
equal(invalid_stats.invalid, 1, "invalid UTF-8 count")

local emoji = "有效😀字符"
local emoji_decoded, emoji_stats = Pua.decode(emoji)
equal(emoji_decoded, emoji, "valid four-byte UTF-8 changed")
equal(emoji_stats.invalid, 0, "valid four-byte UTF-8 rejected")

local body = string.rep("在", 600)
local chapter = assert(Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000001", title = "测试章", content = "<p>" .. body .. "</p>",
    chapterWordNumber = 600, needPay = false, isChapterLock = false,
} } }, "10000000001"))
equal(chapter.title, "测试章", "parsed chapter")

local rejected, err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000002", title = "预览", content = "<p>" .. string.rep("短", 200) .. "</p>",
    chapterWordNumber = 200,
} } }, "10000000002")
equal(rejected, nil, "preview rejected")
assert(err:find("预览", 1, true), "preview error missing")

local locked, locked_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000003", title = "锁定", content = "<p>" .. body .. "</p>",
    chapterWordNumber = 600, isChapterLock = true,
} } }, "10000000003")
equal(locked, nil, "locked chapter rejected")
assert(locked_err:find("解锁", 1, true), "locked error missing")

local numeric_lock, numeric_lock_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000004", title = "数字锁定", content = "<p>" .. body .. "</p>",
    chapterWordNumber = 600, needPay = 1,
} } }, "10000000004")
equal(numeric_lock, nil, "numeric paywall flag accepted")
assert(numeric_lock_err:find("解锁", 1, true), "numeric paywall error missing")

local string_lock, string_lock_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000005", title = "字符串锁定", content = "<p>" .. body .. "</p>",
    chapterWordNumber = 600, isChapterLock = "1",
} } }, "10000000005")
equal(string_lock, nil, "string lock flag accepted")
assert(string_lock_err:find("解锁", 1, true), "string lock error missing")

local mismatch, mismatch_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000006", title = "错误章节", content = "<p>" .. body .. "</p>",
    chapterWordNumber = 600,
} } }, "10000000007")
equal(mismatch, nil, "mismatched chapter id accepted")
assert(mismatch_err:find("不一致", 1, true), "mismatched chapter error missing")

local unknown_pua, unknown_pua_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000008", title = "未知映射", content = "<p>" .. body .. "\238\128\128</p>",
    chapterWordNumber = 600,
} } }, "10000000008")
equal(unknown_pua, nil, "unknown PUA accepted")
assert(unknown_pua_err:find("字符映射", 1, true), "unknown PUA error missing")

local invalid_utf8, invalid_utf8_err = Parser.chapter_from_state({ reader = { chapterData = {
    itemId = "10000000009", title = "无效编码", content = "<p>" .. body .. "\255</p>",
    chapterWordNumber = 600,
} } }, "10000000009")
equal(invalid_utf8, nil, "invalid UTF-8 accepted")
assert(invalid_utf8_err:find("UTF%-8"), "invalid UTF-8 error missing")

print("core tests passed")

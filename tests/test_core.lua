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

local decoded, stats = Pua.decode("\238\143\168\238\143\169\238\143\170")
equal(decoded, "D在主", "PUA mapping")
equal(stats.pua, 3, "PUA count")
equal(stats.unknown, 0, "unknown count")

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

print("core tests passed")

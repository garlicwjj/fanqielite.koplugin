package.path = "./?.lua;./?/init.lua;" .. package.path

local Library = require("fanqielite.library")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "assertion") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function chapter(id, title)
    return { id = id, title = title or ("章节 " .. id) }
end

local legacy_book = { id = "7633875868615461950", title = "旧版书籍", author = "作者甲" }
local legacy_chapters = {
    chapter("10000000001", "第一章"),
    chapter("10000000002", "第二章"),
}

local library, migrated = Library.load(nil, legacy_book, legacy_chapters, 2, 100)
equal(migrated, true, "legacy migration reported")
equal(#library.books, 1, "legacy book count")
equal(library.books[1].title, "旧版书籍", "legacy title")
equal(library.books[1].current_index, 2, "legacy progress")
equal(#library.books[1].chapters, 2, "legacy chapters")

local same, changed = Library.load(library, legacy_book, legacy_chapters, 1, 200)
equal(changed, false, "migration is idempotent")
equal(#same.books, 1, "legacy not duplicated")
equal(same.books[1].current_index, 2, "new data wins over stale legacy fields")

local second = assert(Library.upsert(same, {
    id = "7234567890123456789", title = "新书", author = "作者乙",
}, { chapter("20000000001"), chapter("20000000002") }, nil, 300))
equal(#same.books, 2, "second book retained")
equal(second.current_index, 1, "new book starts at first chapter")

assert(Library.touch(same, second.id, 2, 400))
equal(second.current_index, 2, "per-book progress updated")
equal(same.books[1].current_index, 2, "other book progress unchanged")

local refreshed = assert(Library.upsert(same, {
    id = second.id, title = "新书（改名）", author = "作者乙",
}, {
    chapter("20000000000", "新增序章"),
    chapter("20000000001"),
    chapter("20000000002"),
}, nil, 500))
equal(#same.books, 2, "refresh does not duplicate")
equal(refreshed.current_index, 3, "refresh follows current chapter id")
equal(refreshed.title, "新书（改名）", "refreshes metadata")

same.sort = "recent"
equal(Library.sorted(same)[1].id, second.id, "recent sort")
same.sort = "title"
equal(Library.sorted(same)[1].title, "新书（改名）", "title sort")
same.sort = "added"
equal(Library.sorted(same)[1].id, second.id, "added sort")

equal(Library.remove(same, legacy_book.id), true, "remove existing")
equal(#same.books, 1, "remove only one book")
equal(Library.remove(same, legacy_book.id), false, "remove missing")

local invalid = Library.load({
    version = 1,
    books = {
        { id = "../../bad", title = "unsafe" },
        { id = second.id, title = "kept", chapters = {
            chapter("not-an-id"), chapter("20000000003", "valid"), chapter("20000000003", "duplicate"),
        }, current_index = 99 },
    },
}, nil, nil, nil, 600)
equal(#invalid.books, 1, "invalid book rejected")
equal(#invalid.books[1].chapters, 1, "invalid and duplicate chapters rejected")
equal(invalid.books[1].current_index, 1, "progress clamped")

local missing, err = Library.upsert(invalid, { id = "bad" }, {}, nil, 700)
equal(missing, nil, "invalid upsert rejected")
assert(err:find("ID", 1, true), "invalid upsert error missing")

print("library tests passed")

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
equal(library.books[1].directory_updated_at, 0, "legacy directory time stays unknown")

local same, changed = Library.load(library, legacy_book, legacy_chapters, 1, 200)
equal(changed, false, "migration is idempotent")
equal(#same.books, 1, "legacy not duplicated")
equal(same.books[1].current_index, 2, "new data wins over stale legacy fields")

local second = assert(Library.upsert(same, {
    id = "7234567890123456789", title = "新书", author = "作者乙",
}, { chapter("20000000001"), chapter("20000000002") }, nil, 300))
equal(#same.books, 2, "second book retained")
equal(second.current_index, 1, "new book starts at first chapter")
equal(second.directory_updated_at, 300, "new directory refresh time recorded")

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
equal(refreshed.directory_updated_at, 500, "directory refresh time updated")

same.sort = "recent"
equal(Library.sorted(same)[1].id, second.id, "recent sort")
same.sort = "title"
equal(Library.sorted(same)[1].title, "新书（改名）", "title sort")
same.sort = "added"
equal(Library.sorted(same)[1].id, second.id, "added sort")

equal(Library.remove(same, legacy_book.id), true, "remove existing")
equal(#same.books, 1, "remove only one book")
equal(Library.remove(same, legacy_book.id), false, "remove missing")

local lookup_tostring_calls = 0
local forged_lookup_id = setmetatable({}, { __tostring = function()
    lookup_tostring_calls = lookup_tostring_calls + 1
    return second.id
end })
equal(Library.find(same, forged_lookup_id), nil, "object book ID forged a library lookup")
equal(lookup_tostring_calls, 0, "object book ID invoked __tostring")
equal(Library.find(same, 1234567890), nil, "numeric book ID accepted by library lookup")

local invalid = Library.load({
    version = 1,
    books = {
        { id = "../../bad", title = "unsafe" },
        { id = string.rep("9", 65), title = "oversized" },
        { id = second.id, title = "kept", chapters = {
            chapter("not-an-id"), chapter(string.rep("8", 65)),
            chapter("20000000003", "valid"), chapter("20000000003", "duplicate"),
        }, current_index = 99 },
    },
}, nil, nil, nil, 600)
equal(#invalid.books, 1, "invalid book rejected")
equal(#invalid.books[1].chapters, 1, "invalid and duplicate chapters rejected")
equal(invalid.books[1].current_index, 1, "progress clamped")

local damaged_numbers, numbers_changed = Library.load({
    version = 1,
    books = {
        {
            id = "7134567890123456788", title = "异常数值书籍",
            chapters = {
                { id = "50000000000", title = "第一章", index = 1 },
                { id = "50000000001", title = "第二章", index = 2 },
            },
            current_index = 0 / 0,
            added_at = math.huge,
            updated_at = -math.huge,
            directory_updated_at = math.huge,
            last_opened_at = 0 / 0,
        },
        [math.huge] = {
            id = "7134567890123456786", title = "无穷索引不应进入书架",
        },
    },
}, nil, nil, nil, 625)
equal(numbers_changed, true, "non-finite saved numbers require repair")
equal(#damaged_numbers.books, 1, "infinite saved array key rejected")
local repaired_numbers = damaged_numbers.books[1]
equal(repaired_numbers.current_index, 1, "NaN progress repaired")
equal(repaired_numbers.added_at, 625, "infinite added time repaired")
equal(repaired_numbers.updated_at, 625, "negative infinite update time repaired")
equal(repaired_numbers.directory_updated_at, 0, "infinite directory time repaired")
equal(repaired_numbers.last_opened_at, 0, "NaN opened time repaired")
equal(Library.sorted(damaged_numbers)[1].id, repaired_numbers.id,
    "repaired saved numbers remain sortable")

local damaged_chapter_index, chapter_index_changed = Library.load({
    version = 1,
    books = {
        {
            id = "7134567890123456787", title = "异常章节序号书籍",
            chapters = {
                { id = "50000000002", title = "第一章", index = math.huge },
            },
            current_index = 1,
            added_at = 625,
            updated_at = 625,
            directory_updated_at = 625,
            last_opened_at = 0,
        },
    },
}, nil, nil, nil, 625)
equal(chapter_index_changed, true, "infinite chapter index requires repair")
equal(damaged_chapter_index.books[1].chapters[1].index, 1,
    "infinite chapter index repaired")

local damaged_text, text_changed = Library.load({
    version = 1,
    books = {
        {
            id = "7134567890123456785",
            title = "伪造\n菜单项",
            author = "作者\127伪造",
            cover_url = "https://example.invalid/cover.jpg\nInjected",
            chapters = {
                { id = "50000000003", title = "第一章\0伪造", index = 1 },
            },
            current_index = 1,
            added_at = 625,
            updated_at = 625,
            directory_updated_at = 625,
            last_opened_at = 0,
            imported_progress = {
                chapter_id = "50000000003",
                chapter_title = "导入章节\t伪造",
                position = 0.5,
            },
        },
        {
            id = "7134567890123456784",
            title = "超长封面书籍",
            author = "",
            cover_url = "https://" .. string.rep("x", 2049),
            chapters = {},
            current_index = 1,
            added_at = 625,
            updated_at = 625,
            directory_updated_at = 0,
            last_opened_at = 0,
        },
    },
}, nil, nil, nil, 625)
equal(text_changed, true, "saved control characters require repair")
local repaired_text = damaged_text.books[1]
equal(repaired_text.title, "番茄书籍 7134567890123456785",
    "control character book title repaired")
equal(repaired_text.author, "", "control character author repaired")
equal(repaired_text.chapters[1].title, "第 1 章",
    "control character chapter title repaired")
equal(repaired_text.cover_url, nil, "control character cover URL removed")
equal(repaired_text.imported_progress.chapter_title, "",
    "control character imported chapter title repaired")
equal(Library.find(damaged_text, "7134567890123456784").cover_url, nil,
    "oversized cover URL removed")
local repaired_text_again, text_changed_again =
    Library.load(damaged_text, nil, nil, nil, 700)
equal(text_changed_again, false, "repaired saved text is idempotent")
equal(repaired_text_again.books[1].title, repaired_text.title,
    "repaired saved text remains stable")

local function load_saved_progress(progress)
    return Library.load({
        version = 1,
        books = {
            {
                id = "7134567890123456783",
                title = "导入进度修复书籍",
                author = "",
                chapters = {},
                current_index = 1,
                added_at = 625,
                updated_at = 625,
                directory_updated_at = 0,
                last_opened_at = 0,
                imported_progress = progress,
            },
        },
    }, nil, nil, nil, 625)
end

local invalid_position, invalid_position_changed = load_saved_progress({
    chapter_id = "50000000004", chapter_title = "第四章", position = 0 / 0,
})
equal(invalid_position_changed, true, "NaN imported position requires repair")
equal(invalid_position.books[1].imported_progress.position, nil,
    "NaN imported position removed")
local repaired_position_again, repaired_position_changed =
    Library.load(invalid_position, nil, nil, nil, 700)
equal(repaired_position_changed, false, "repaired imported position is idempotent")
equal(repaired_position_again.books[1].imported_progress.position, nil,
    "repaired imported position stayed removed")

local string_position, string_position_changed = load_saved_progress({
    chapter_id = "50000000004", chapter_title = "第四章", position = "0.5",
})
equal(string_position_changed, true, "string imported position requires normalization")
equal(string_position.books[1].imported_progress.position, 0.5,
    "compatible string imported position normalized")

local invalid_progress, invalid_progress_changed = load_saved_progress("invalid")
equal(invalid_progress_changed, true, "non-object imported progress requires repair")
equal(invalid_progress.books[1].imported_progress, nil,
    "non-object imported progress removed")

local invalid_progress_id, invalid_progress_id_changed = load_saved_progress({
    chapter_id = "invalid", chapter_title = "错误章节", position = 0.5,
})
equal(invalid_progress_id_changed, true, "invalid imported chapter ID requires repair")
equal(invalid_progress_id.books[1].imported_progress, nil,
    "invalid imported chapter ID removed")

local optional_position, optional_position_changed = load_saved_progress({
    chapter_id = "50000000004", chapter_title = "第四章",
})
equal(optional_position_changed, false, "missing optional imported position was changed")
equal(optional_position.books[1].imported_progress.position, nil,
    "missing optional imported position was invented")

local sparse, sparse_changed = Library.load({
    version = 1,
    books = {
        [1] = {
            id = "7134567890123456789", title = "稀疏书籍一", chapters = {
                [1] = chapter("50000000001", "第一章"),
                [3] = chapter("50000000003", "第三章"),
            },
        },
        [3] = { id = "7134567890123456790", title = "稀疏书籍二" },
        unexpected = "must not become a book",
    },
}, nil, nil, nil, 650)
equal(sparse_changed, true, "sparse saved state not marked for normalization")
equal(#sparse.books, 2, "sparse saved books were silently truncated")
equal(sparse.books[1].id, "7134567890123456789", "first sparse book changed")
equal(sparse.books[2].id, "7134567890123456790", "later sparse book was not recovered")
equal(#sparse.books[1].chapters, 2, "sparse saved chapters were silently truncated")
equal(sparse.books[1].chapters[2].id, "50000000003", "later sparse chapter was not recovered")

local missing, err = Library.upsert(invalid, { id = "bad" }, {}, nil, 700)
equal(missing, nil, "invalid upsert rejected")
assert(err:find("ID", 1, true), "invalid upsert error missing")

local import_target = Library.new()
local credential_canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local existing = assert(Library.upsert(import_target, {
    id = "7234567890123456789", title = "本地书名", author = "本地作者",
}, { chapter("20000000001"), chapter("20000000002") }, 2, 800))
local added, updated = Library.import_books(import_target, {
    {
        id = existing.id, title = "导入书名", author = "", cover_url = "",
        imported_progress = { chapter_id = "20000000001", chapter_title = "第一章", position = 0.2 },
        cookie = credential_canary,
    },
    {
        id = "7334567890123456789", title = "导入新书", author = "作者丙",
        cover_url = "https://example.invalid/cover.jpg",
        imported_progress = { chapter_id = "30000000002", chapter_title = "第二章", position = 0.4 },
        sessionid = credential_canary,
        auth_headers = { Cookie = credential_canary },
    },
}, 900)
equal(added, 1, "import added count")
equal(updated, 1, "import updated count")
equal(existing.title, "导入书名", "import updates title")
equal(existing.author, "本地作者", "empty import author does not erase local author")
equal(#existing.chapters, 2, "import preserves local directory")
equal(existing.current_index, 2, "import preserves local progress")
equal(existing.imported_progress, nil, "import must not attach remote progress to locally read book")
equal(existing.directory_updated_at, 800, "metadata import preserves directory refresh time")
equal(existing.cookie, nil, "credential field reached existing local book")

local imported = assert(Library.find(import_target, "7334567890123456789"))
equal(#imported.chapters, 0, "new import starts without fabricated directory")
equal(imported.directory_updated_at, 0, "new import has no fabricated directory refresh time")
equal(imported.sessionid, nil, "credential field reached new local book")
equal(imported.auth_headers, nil, "authorization headers reached new local book")
equal(imported.imported_progress.chapter_id, "30000000002", "imported chapter retained")
local refreshed_import = assert(Library.upsert(import_target, {
    id = imported.id, title = imported.title, author = imported.author,
}, {
    chapter("30000000001"), chapter("30000000002"), chapter("30000000003"),
}, nil, 1000))
equal(refreshed_import.current_index, 2, "first refresh follows imported chapter id")
equal(refreshed_import.cover_url, "https://example.invalid/cover.jpg", "refresh preserves imported cover")
equal(refreshed_import.directory_updated_at, 1000, "first directory fetch records refresh time")

local reloaded = Library.load(import_target, nil, nil, nil, 1100)
local reloaded_import = assert(Library.find(reloaded, imported.id))
equal(reloaded_import.directory_updated_at, 1000, "directory refresh time survives reload")
equal(reloaded_import.imported_progress.position, 0.4, "reload preserves imported position")

local wrong_position, wrong_consumed = Library.take_imported_position(reloaded_import, 1, false)
equal(wrong_position, nil, "wrong chapter does not apply imported position")
equal(wrong_consumed, false, "wrong chapter does not consume imported position")
equal(reloaded_import.imported_progress.position, 0.4, "wrong chapter preserves imported position")

local local_position, local_consumed = Library.take_imported_position(reloaded_import, 2, true)
equal(local_position, nil, "existing KOReader sidecar wins over imported position")
equal(local_consumed, true, "local sidecar discards stale imported position")
equal(reloaded_import.imported_progress, nil, "discarded imported position cannot override later opens")

local fresh_import = Library.new()
Library.import_books(fresh_import, {
    {
        id = "7434567890123456789", title = "首次导入",
        imported_progress = { chapter_id = "40000000002", chapter_title = "第二章", position = 0.6 },
    },
}, 1200)
local fresh_book = assert(Library.find(fresh_import, "7434567890123456789"))
fresh_book = assert(Library.upsert(fresh_import, {
    id = fresh_book.id, title = fresh_book.title,
}, { chapter("40000000001"), chapter("40000000002") }, nil, 1300))
local fresh_position, fresh_consumed = Library.take_imported_position(fresh_book, 2, false)
equal(fresh_position, 0.6, "first open applies validated imported position")
equal(fresh_consumed, true, "first open consumes imported position")
equal(fresh_book.imported_progress, nil, "imported position is one-shot")
local repeated_position, repeated_consumed = Library.take_imported_position(fresh_book, 2, false)
equal(repeated_position, nil, "later open does not reapply imported position")
equal(repeated_consumed, false, "later open has nothing left to consume")

print("library tests passed")

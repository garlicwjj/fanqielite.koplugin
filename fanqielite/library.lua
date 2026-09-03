local Identifier = require("fanqielite.identifier")

local Library = {}

Library.VERSION = 1

local function valid_id(value)
    return Identifier.normalize(value)
end

local function clean_text(value, fallback, maximum)
    local replacement = fallback or ""
    if value == nil and fallback == nil then return replacement, false end
    if type(value) ~= "string" or value:find("[%z\1-\31\127]") then
        return replacement, value ~= replacement
    end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" or (maximum and #text > maximum) then
        return replacement, value ~= replacement
    end
    return text, text ~= value
end

local function clean_cover_url(value)
    if value == nil then return nil, false end
    local url, changed = clean_text(value, nil, 2048)
    if url == "" or not url:match("^https://") then return nil, true end
    return url, changed
end

local function finite_number(value)
    local value_type = type(value)
    if value_type ~= "number" and value_type ~= "string" then return nil end
    local number = tonumber(value)
    if not number or number ~= number
            or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function normalize_index(value, fallback)
    local number = finite_number(value)
    if not number then return fallback, true end
    local index = math.floor(number)
    return index, type(value) ~= "number" or index ~= value
end

local function normalize_timestamp(value, fallback)
    local number = finite_number(value)
    if not number or number < 0 then return fallback, true end
    return number, type(value) ~= "number"
end

local function normalize_position(value)
    if value == nil then return nil, false end
    local number = finite_number(value)
    if not number or number < 0 or number > 1 then return nil, true end
    return number, type(value) ~= "number"
end

local function current_time(value)
    local number = finite_number(value)
    if number and number >= 0 then return number end
    return os.time()
end

local function ordered_numeric_keys(value)
    local keys, changed = {}, false
    if type(value) ~= "table" then return keys, value ~= nil end
    for key in pairs(value) do
        if type(key) == "number" and finite_number(key)
                and key >= 1 and key == math.floor(key) then
            keys[#keys + 1] = key
        else
            changed = true
        end
    end
    table.sort(keys)
    for index, key in ipairs(keys) do
        if key ~= index then changed = true end
    end
    return keys, changed
end

local function normalize_chapters(chapters)
    local output, seen = {}, {}
    local keys, changed = ordered_numeric_keys(chapters)
    for _, key in ipairs(keys) do
        local chapter = chapters[key]
        local id = type(chapter) == "table" and valid_id(chapter.id) or nil
        if id and not seen[id] then
            local index, index_changed = normalize_index(chapter.index, #output + 1)
            if index < 1 then index, index_changed = #output + 1, true end
            local title, title_changed = clean_text(
                chapter.title, "第 " .. tostring(#output + 1) .. " 章", 300)
            output[#output + 1] = {
                id = id,
                title = title,
                index = index,
            }
            if index_changed or title_changed then changed = true end
            seen[id] = true
        else
            changed = true
        end
    end
    return output, changed
end

local function normalize_book(record, now)
    if type(record) ~= "table" then return nil, true end
    local source = type(record.book) == "table" and record.book or record
    local id = valid_id(source.id)
    if not id then return nil, true end
    local chapters, changed = normalize_chapters(record.chapters)
    local directory_updated_at, directory_time_changed =
        normalize_timestamp(record.directory_updated_at, 0)
    local current_index, current_index_changed = normalize_index(record.current_index, 1)
    if current_index < 1 then current_index, current_index_changed = 1, true end
    if #chapters > 0 and current_index > #chapters then
        current_index, current_index_changed = #chapters, true
    end
    local added_at, added_time_changed = normalize_timestamp(record.added_at, now)
    local updated_at, updated_time_changed = normalize_timestamp(record.updated_at, now)
    local last_opened_at, opened_time_changed = normalize_timestamp(record.last_opened_at, 0)
    local title, title_changed = clean_text(source.title, "番茄书籍 " .. id, 300)
    local author, author_changed = clean_text(source.author, nil, 150)
    local cover_url, cover_changed = clean_cover_url(record.cover_url)
    if directory_time_changed or current_index_changed or added_time_changed
            or updated_time_changed or opened_time_changed or title_changed
            or author_changed or cover_changed then
        changed = true
    end
    local output = {
        id = id,
        title = title,
        author = author,
        chapters = chapters,
        current_index = current_index,
        added_at = added_at,
        updated_at = updated_at,
        directory_updated_at = directory_updated_at,
        last_opened_at = last_opened_at,
    }
    if cover_url then output.cover_url = cover_url end
    local imported_progress = record.imported_progress
    local imported_chapter_id = type(imported_progress) == "table"
        and valid_id(imported_progress.chapter_id) or nil
    if imported_progress ~= nil and not imported_chapter_id then changed = true end
    if imported_chapter_id then
        local chapter_title, chapter_title_changed =
            clean_text(imported_progress.chapter_title, nil, 300)
        local position, position_changed = normalize_position(imported_progress.position)
        output.imported_progress = {
            chapter_id = imported_chapter_id,
            chapter_title = chapter_title,
        }
        if position ~= nil then output.imported_progress.position = position end
        if chapter_title_changed or position_changed then changed = true end
    end
    return output, changed
end

function Library.new()
    return { version = Library.VERSION, sort = "recent", books = {} }
end

function Library.find(library, book_id)
    if type(library) ~= "table" or type(library.books) ~= "table" then return nil end
    book_id = tostring(book_id or "")
    for index, book in ipairs(library.books) do
        if book.id == book_id then return book, index end
    end
end

function Library.load(saved, legacy_book, legacy_chapters, legacy_index, now)
    now = current_time(now)
    local library = Library.new()
    local changed = type(saved) ~= "table" or saved.version ~= Library.VERSION
    if type(saved) == "table" then
        if saved.sort == "title" or saved.sort == "added" then
            library.sort = saved.sort
        elseif saved.sort ~= nil and saved.sort ~= "recent" then
            changed = true
        end
        if type(saved.books) == "table" then
            local seen = {}
            local keys, books_changed = ordered_numeric_keys(saved.books)
            if books_changed then changed = true end
            for _, key in ipairs(keys) do
                local book, book_changed = normalize_book(saved.books[key], now)
                if book and not seen[book.id] then
                    library.books[#library.books + 1] = book
                    seen[book.id] = true
                else
                    changed = true
                end
                if book_changed then changed = true end
            end
        elseif saved.books ~= nil then
            changed = true
        end
    end

    local legacy_id = type(legacy_book) == "table" and valid_id(legacy_book.id) or nil
    if legacy_id and not Library.find(library, legacy_id) then
        local migrated = normalize_book({
            book = legacy_book,
            chapters = legacy_chapters,
            current_index = legacy_index,
            added_at = now,
            updated_at = now,
            last_opened_at = now,
        }, now)
        if migrated then library.books[#library.books + 1] = migrated end
        changed = true
    end
    return library, changed
end

function Library.upsert(library, book, chapters, requested_index, now)
    now = current_time(now)
    local id = type(book) == "table" and valid_id(book.id) or nil
    if not id then return nil, "书籍 ID 无效" end
    local existing, existing_index = Library.find(library, id)
    local normalized_chapters = normalize_chapters(chapters)
    local current_index = tonumber(requested_index)
    if not current_index and existing then
        local current = existing.chapters[existing.current_index]
        if current then
            for index, chapter in ipairs(normalized_chapters) do
                if chapter.id == current.id then current_index = index; break end
            end
        end
        if not current_index and existing.imported_progress then
            for index, chapter in ipairs(normalized_chapters) do
                if chapter.id == existing.imported_progress.chapter_id then
                    current_index = index
                    break
                end
            end
        end
        current_index = current_index or existing.current_index
    end
    local record = normalize_book({
        book = book,
        chapters = normalized_chapters,
        current_index = current_index or 1,
        added_at = existing and existing.added_at or now,
        updated_at = now,
        directory_updated_at = now,
        last_opened_at = existing and existing.last_opened_at or 0,
        cover_url = existing and existing.cover_url or nil,
        imported_progress = existing and existing.imported_progress or nil,
    }, now)
    if existing then
        library.books[existing_index] = record
    else
        library.books[#library.books + 1] = record
    end
    return record
end

function Library.import_books(library, imported_books, now)
    now = current_time(now)
    local added, updated = 0, 0
    for _, imported in ipairs(imported_books or {}) do
        local existing = Library.find(library, imported.id)
        if existing then
            existing.title = clean_text(imported.title, existing.title, 300)
            existing.author = clean_text(imported.author, existing.author, 150)
            existing.cover_url = imported.cover_url ~= "" and imported.cover_url or existing.cover_url
            if #existing.chapters == 0 then
                existing.imported_progress = imported.imported_progress or existing.imported_progress
            end
            existing.updated_at = now
            updated = updated + 1
        else
            local record = normalize_book({
                book = imported,
                chapters = {},
                current_index = 1,
                added_at = now,
                updated_at = now,
                cover_url = imported.cover_url,
                imported_progress = imported.imported_progress,
            }, now)
            if record then library.books[#library.books + 1] = record; added = added + 1 end
        end
    end
    return added, updated
end

function Library.touch(library, book_id, chapter_index, now)
    local book = Library.find(library, book_id)
    if not book then return nil, "书籍不存在" end
    chapter_index = math.floor(tonumber(chapter_index) or 0)
    if chapter_index < 1 or not book.chapters[chapter_index] then return nil, "章节位置无效" end
    book.current_index = chapter_index
    book.last_opened_at = current_time(now)
    return book
end

function Library.take_imported_position(book, chapter_index, has_local_position)
    if type(book) ~= "table" or type(book.chapters) ~= "table"
            or type(book.imported_progress) ~= "table" then
        return nil, false
    end
    chapter_index = math.floor(tonumber(chapter_index) or 0)
    local chapter = book.chapters[chapter_index]
    local imported = book.imported_progress
    if type(chapter) ~= "table" or chapter.id ~= imported.chapter_id then
        return nil, false
    end
    local position = tonumber(imported.position)
    if not position or position ~= position or position < 0 or position > 1 then
        return nil, false
    end
    book.imported_progress = nil
    if has_local_position then return nil, true end
    return position, true
end

function Library.remove(library, book_id)
    local _, index = Library.find(library, book_id)
    if not index then return false end
    table.remove(library.books, index)
    return true
end

function Library.sorted(library)
    local output = {}
    for _, book in ipairs(library.books or {}) do output[#output + 1] = book end
    local mode = library.sort or "recent"
    table.sort(output, function(a, b)
        if mode == "title" then
            if a.title ~= b.title then return a.title < b.title end
        elseif mode == "added" then
            if a.added_at ~= b.added_at then return a.added_at > b.added_at end
        else
            if a.last_opened_at ~= b.last_opened_at then return a.last_opened_at > b.last_opened_at end
            if a.updated_at ~= b.updated_at then return a.updated_at > b.updated_at end
        end
        return a.id < b.id
    end)
    return output
end

return Library

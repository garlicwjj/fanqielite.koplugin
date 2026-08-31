local Library = {}

Library.VERSION = 1

local function valid_id(value)
    local id = tostring(value or "")
    if id:match("^%d%d%d%d%d%d%d%d%d%d+$") then return id end
end

local function clean_text(value, fallback, maximum)
    local text = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    if text == "" then return fallback or "" end
    if maximum and #text > maximum then return fallback or "" end
    return text
end

local function ordered_numeric_keys(value)
    local keys, changed = {}, false
    if type(value) ~= "table" then return keys, value ~= nil end
    for key in pairs(value) do
        if type(key) == "number" and key >= 1 and key == math.floor(key) then
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
            output[#output + 1] = {
                id = id,
                title = clean_text(chapter.title, "第 " .. tostring(#output + 1) .. " 章", 300),
                index = tonumber(chapter.index) or (#output + 1),
            }
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
    local directory_updated_at = tonumber(record.directory_updated_at) or 0
    if directory_updated_at ~= directory_updated_at or directory_updated_at < 0 then
        directory_updated_at = 0
    end
    local current_index = math.floor(tonumber(record.current_index) or 1)
    if current_index < 1 then current_index = 1 end
    if #chapters > 0 and current_index > #chapters then current_index = #chapters end
    local output = {
        id = id,
        title = clean_text(source.title, "番茄书籍 " .. id, 300),
        author = clean_text(source.author, nil, 150),
        chapters = chapters,
        current_index = current_index,
        added_at = tonumber(record.added_at) or now,
        updated_at = tonumber(record.updated_at) or now,
        directory_updated_at = directory_updated_at,
        last_opened_at = tonumber(record.last_opened_at) or 0,
    }
    if type(record.cover_url) == "string" and record.cover_url:match("^https://") then
        output.cover_url = record.cover_url
    end
    if type(record.imported_progress) == "table"
            and valid_id(record.imported_progress.chapter_id) then
        output.imported_progress = {
            chapter_id = tostring(record.imported_progress.chapter_id),
            chapter_title = clean_text(record.imported_progress.chapter_title, nil, 300),
        }
        local position = tonumber(record.imported_progress.position)
        if position and position == position and position >= 0 and position <= 1 then
            output.imported_progress.position = position
        end
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
    now = tonumber(now) or os.time()
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
    now = tonumber(now) or os.time()
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
    now = tonumber(now) or os.time()
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
    book.last_opened_at = tonumber(now) or os.time()
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

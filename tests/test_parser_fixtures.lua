package.path = "./?.lua;./?/init.lua;" .. package.path

local Parser = require("fanqielite.parser")
local fixtures = require("tests.fixtures.parser_variants")

local function fail(case, message)
    error(case.name .. ": " .. message)
end

for _, case in ipairs(fixtures.books) do
    local book, err = Parser.book_from_state(case.state, case.request_id)
    if case.error_contains then
        if book ~= nil then fail(case, "unsafe book variant was accepted") end
        if not tostring(err):find(case.error_contains, 1, true) then
            fail(case, "actionable rejection reason missing")
        end
    else
        if not book then fail(case, tostring(err)) end
        if book.id ~= case.expected_id then fail(case, "book id changed") end
        if case.expected_title and book.title ~= case.expected_title then fail(case, "book title changed") end
    end
end

for _, case in ipairs(fixtures.directories) do
    local chapters, err = Parser.directory_from_payload(case.payload)
    if case.error_contains then
        if chapters ~= nil then fail(case, "unsafe directory variant was accepted") end
        if not tostring(err):find(case.error_contains, 1, true) then
            fail(case, "actionable rejection reason missing")
        end
    else
        if not chapters then fail(case, tostring(err)) end
        if #chapters ~= #case.expected_ids then fail(case, "chapter count changed") end
        for index, expected_id in ipairs(case.expected_ids) do
            if chapters[index].id ~= expected_id then fail(case, "chapter order or id changed") end
        end
    end
end

for _, case in ipairs(fixtures.chapters) do
    local state = case.missing_reader and {} or { reader = { chapterData = case.chapter } }
    local chapter, err = Parser.chapter_from_state(state, case.item_id)
    if case.error_contains then
        if chapter ~= nil then fail(case, "unsafe chapter variant was accepted") end
        if not tostring(err):find(case.error_contains, 1, true) then
            fail(case, "actionable rejection reason missing")
        end
    else
        if not chapter then fail(case, tostring(err)) end
        if chapter.id ~= case.item_id then fail(case, "chapter id changed") end
        if case.expected_title and chapter.title ~= case.expected_title then fail(case, "chapter title changed") end
        if case.expected_contains
                and not table.concat(chapter.paragraphs, ""):find(case.expected_contains, 1, true) then
            fail(case, "decoded text missing")
        end
        if case.expected_pua and chapter.pua_count ~= case.expected_pua then
            fail(case, "encoded PUA count changed")
        end
    end
end

print("parser fixture tests passed")

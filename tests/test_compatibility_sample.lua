package.path = "./?.lua;./?/init.lua;" .. package.path
local Sample = require("tools.compatibility_sample")
local book_id = "1234567890123"
local function id(index) return string.format("%013d", index) end
local function payload(count)
    local chapters = {}
    for index = 1, count do
        chapters[index] = { itemId = id(index), title = "PRIVATE_TITLE", chapterIndex = 999 }
    end
    return { data = { chapterList = chapters } }
end

for _, count in ipairs({ 3, 4, 49, 50, 200, 201, 500, 501, 1000, 1001 }) do
    local input = payload(count)
    local plan = assert(Sample.plan(book_id, input))
    assert(plan.format == "fanqielite-sampling-plan")
    assert(plan.chapter_count == count and #plan.samples == 3)
    assert(plan.samples[1].id == id(1))
    assert(plan.samples[2].id == id(math.floor((count + 1) / 2)))
    assert(plan.samples[3].id == id(count))
    for _, sample in ipairs(plan.samples) do
        for key in pairs(sample) do
            assert(key == "id" or key == "position" or key == "ordinal")
        end
        assert(sample.id == id(sample.ordinal))
    end
    assert(input.data.chapterList[1].title == "PRIVATE_TITLE")
end
assert(not Sample.plan(book_id, payload(2)))
assert(not Sample.plan("not-an-id", payload(3)))
assert(not Sample.plan(book_id, { data = { chapterList = { [2] = { itemId = id(2) } } } }))
local duplicate = payload(3)
duplicate.data.chapterList[3].itemId = id(1)
assert(not Sample.plan(book_id, duplicate))
local volume = { data = { chapterListWithVolume = {
    { chapterList = { { itemId = id(1) } } },
    { chapterList = { { itemId = id(2) }, { itemId = id(3) } } },
} } }
assert(assert(Sample.plan(book_id, volume)).samples[2].id == id(2))
assert(assert(Sample.plan(book_id, { data = { allItemIds = { id(1), id(2), id(3) } } })).samples[3].id == id(3))
print("compatibility sample tests passed")

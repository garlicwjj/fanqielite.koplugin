-- Development-only sampling; never fetches chapters or generates test evidence.
local Parser = require("fanqielite.parser")
local Identifier = require("fanqielite.identifier")
local Sample = {}

function Sample.plan(book_id, payload)
    if not Identifier.valid(book_id) then return nil, "书籍 ID 无效" end
    local chapters, err = Parser.directory_from_payload(payload)
    if not chapters then return nil, err end
    local count = #chapters
    if count < 3 then return nil, "目录不足三个不同章节，不能纳入固定矩阵" end
    local positions = { "first", "middle", "latest" }
    local indices = { 1, math.floor((count + 1) / 2), count }
    local samples = {}
    for index, position in ipairs(positions) do
        local ordinal = indices[index]
        samples[index] = { position = position, ordinal = ordinal, id = chapters[ordinal].id }
    end
    return {
        format = "fanqielite-sampling-plan",
        version = 1,
        book_id = book_id,
        chapter_count = count,
        samples = samples,
    }
end

return Sample

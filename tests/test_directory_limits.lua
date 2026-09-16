package.path = "./?.lua;./?/init.lua;" .. package.path

local Parser = require("fanqielite.parser")

assert(Parser.MAX_DIRECTORY_CHAPTERS == 10000,
    "directory chapter safety limit changed without updating its contract")
assert(Parser.MAX_DIRECTORY_VOLUMES == 1000,
    "directory volume safety limit changed without updating its contract")

local function chapter_id(index)
    return string.format("8%010d", index)
end

local exact_ids = {}
for index = 1, Parser.MAX_DIRECTORY_CHAPTERS do
    exact_ids[index] = chapter_id(index)
end
local exact = assert(Parser.directory_from_payload({ data = { allItemIds = exact_ids } }))
assert(#exact == Parser.MAX_DIRECTORY_CHAPTERS,
    "directory rejected the documented chapter boundary")
assert(exact[1].id == chapter_id(1)
        and exact[#exact].id == chapter_id(Parser.MAX_DIRECTORY_CHAPTERS),
    "directory boundary changed chapter ordering")

local oversized_flat = {}
for index = 1, Parser.MAX_DIRECTORY_CHAPTERS + 1 do
    oversized_flat[index] = { itemId = chapter_id(index), title = "章" }
end
local flat_result, flat_err = Parser.directory_from_payload({ data = {
    chapterList = oversized_flat,
} })
assert(flat_result == nil, "oversized flat directory was accepted")
assert(type(flat_err) == "string" and flat_err:find("10000", 1, true)
        and flat_err:find("安全上限", 1, true),
    "oversized flat directory did not explain the fixed safety limit")

local first_volume, second_volume = {}, {}
for index = 1, 6000 do
    first_volume[index] = { itemId = chapter_id(index), title = "前卷" }
end
for index = 1, 4001 do
    second_volume[index] = { itemId = chapter_id(6000 + index), title = "后卷" }
end
local total_result, total_err = Parser.directory_from_payload({ data = {
    chapterListWithVolume = { first_volume, second_volume },
} })
assert(total_result == nil, "oversized multi-volume directory was accepted")
assert(type(total_err) == "string" and total_err:find("10000", 1, true)
        and total_err:find("安全上限", 1, true),
    "multi-volume total did not enforce the chapter safety limit")

local oversized_volumes = {}
for index = 1, Parser.MAX_DIRECTORY_VOLUMES + 1 do
    oversized_volumes[index] = {}
end
local volume_result, volume_err = Parser.directory_from_payload({ data = {
    chapterListWithVolume = oversized_volumes,
} })
assert(volume_result == nil, "oversized volume list was accepted")
assert(type(volume_err) == "string" and volume_err:find("1000", 1, true)
        and volume_err:find("安全上限", 1, true),
    "oversized volume list did not explain the fixed safety limit")

print("directory limit tests passed")

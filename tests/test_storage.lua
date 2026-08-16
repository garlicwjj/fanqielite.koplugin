package.path = "./?.lua;./?/init.lua;" .. package.path

local removed, rmdir_path = {}, nil
local names = { ".", "..", "10000000001.xhtml", "10000000002.xhtml.tmp", "notes.txt", "../escape.xhtml" }

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/safe-data" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            if path == "/safe-data/fanqielite/7633875868615461950" and attribute == "mode" then
                return "directory"
            end
        end,
        dir = function()
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        mkdir = function() return true end,
        rmdir = function(path) rmdir_path = path; return true end,
    }
end

local original_remove = os.remove
os.remove = function(path)
    removed[#removed + 1] = path
    return true
end

local Storage = require("fanqielite.storage")
local storage = setmetatable({ root = "/safe-data/fanqielite" }, { __index = Storage })

assert(Storage.is_cache_name("10000000001.xhtml"), "chapter cache name rejected")
assert(Storage.is_cache_name("10000000001.xhtml.tmp"), "temporary cache name rejected")
assert(not Storage.is_cache_name("notes.txt"), "unowned file accepted")
assert(not Storage.is_cache_name("../100.xhtml"), "path traversal accepted")
assert(storage:cached_count("7633875868615461950") == 1, "cached count must ignore temporary and unowned files")

local count = assert(storage:clear_book("7633875868615461950"))
os.remove = original_remove

assert(count == 2, "unexpected removed count")
assert(#removed == 2, "only owned cache files may be removed")
assert(removed[1] == "/safe-data/fanqielite/7633875868615461950/10000000001.xhtml")
assert(removed[2] == "/safe-data/fanqielite/7633875868615461950/10000000002.xhtml.tmp")
assert(rmdir_path == "/safe-data/fanqielite/7633875868615461950")

local invalid = storage:clear_book("../../outside")
assert(invalid == nil, "invalid book id accepted")

print("storage tests passed")

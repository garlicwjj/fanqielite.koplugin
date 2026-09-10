package.path = "./?.lua;./?/init.lua;" .. package.path

local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local mode = "throw"
local tostring_calls = 0
local raw_error = setmetatable({}, {
    __tostring = function()
        tostring_calls = tostring_calls + 1
        return "parser context contains " .. canary
    end,
})

package.preload["rapidjson"] = function()
    return {
        decode = function()
            if mode == "throw" then error(raw_error) end
            if mode == "nil" then return nil, "near secret " .. canary end
            return { safe = true }
        end,
    }
end

local Import = require("fanqielite.import")
local Parser = require("fanqielite.parser")

local function assert_fixed(label, decoder, expected)
    for _, next_mode in ipairs({ "throw", "nil" }) do
        mode = next_mode
        local value, err = decoder("malformed " .. canary)
        assert(value == nil, label .. " accepted malformed JSON")
        assert(type(err) == "string" and err:find(expected, 1, true),
            label .. " did not return the fixed category")
        assert(not err:find(canary, 1, true), label .. " leaked JSON or parser context")
    end
end

assert_fixed("bookshelf import", Import.decode, "书架 JSON 解析失败")
assert_fixed("official response", Parser.decode_json, "官方响应格式发生变化")
assert(tostring_calls == 0, "raw decoder exception was stringified")

mode = "success"
assert(Import.decode("{}").safe == true, "valid import JSON changed")
assert(Parser.decode_json("{}").safe == true, "valid official JSON changed")

print("JSON decode error tests passed")

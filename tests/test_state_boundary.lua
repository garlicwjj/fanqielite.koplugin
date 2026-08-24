package.path = "./?.lua;./?/init.lua;" .. package.path

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do output[copy(key, seen)] = copy(child, seen) end
    return output
end

local Library = {
    find = function(library, book_id)
        for _, book in ipairs(library.books or {}) do
            if book.id == book_id then return book end
        end
    end,
}

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    return setmetatable(definition, { __index = self })
end

local stubs = {
    ["ui/widget/confirmbox"] = {},
    datastorage = {},
    device = {},
    dispatcher = {},
    docsettings = {},
    ["ui/event"] = {},
    ["apps/filemanager/filemanager"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = {},
    logger = {},
    luasettings = {},
    ["ui/widget/menu"] = {},
    ["ui/network/manager"] = {},
    ["ui/widget/pathchooser"] = {},
    ["ui/trapper"] = {},
    ["ui/uimanager"] = {},
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    gettext = function(text) return text end,
    ["fanqielite.export"] = {},
    ["fanqielite.import"] = {},
    ["fanqielite.library"] = Library,
    ["fanqielite.networktask"] = {},
    ["fanqielite.parser"] = {},
    ["fanqielite.persistence"] = { copy = copy },
    ["fanqielite.search"] = {},
    ["fanqielite.storage"] = {},
}

for name, module in pairs(stubs) do
    package.preload[name] = function() return module end
end

local FanqieLite = assert(loadfile("main.lua"))()
local canary = "FANQIELITE_SYNTHETIC_CREDENTIAL_CANARY"
local plugin = setmetatable({
    settings = {
        readSetting = function(_, key)
            if key == "import_path" then return "/mnt/us" end
        end,
    },
    library = {
        version = 1,
        sort = "recent",
        books = {{
            id = "70000000001", title = "本地书籍", author = "测试作者",
            chapters = {{ id = "71000000001", title = "第一章" }}, current_index = 1,
        }},
    },
    active_book_id = "70000000001",
    ephemeral_session = {
        cookie = canary,
        sessionid = canary,
        csrf_token = canary,
        authorization = canary,
        qr_payload = canary,
    },
}, { __index = FanqieLite })

local state = plugin:state_table()
local allowed_top = {
    library = true, active_book_id = true, book = true,
    chapters = true, current_index = true, import_path = true,
}
for key in pairs(state) do assert(allowed_top[key], "unexpected persisted top-level field: " .. tostring(key)) end

local function inspect(value, seen)
    if value == canary then error("ephemeral credential value reached persisted state") end
    if type(value) ~= "table" then return end
    seen = seen or {}
    if seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
        local normalized = type(key) == "string" and key:lower():gsub("[^%a%d]", "") or ""
        assert(not normalized:find("cookie", 1, true), "cookie field reached persisted state")
        assert(not normalized:find("session", 1, true), "session field reached persisted state")
        assert(not normalized:find("csrf", 1, true), "csrf field reached persisted state")
        assert(not normalized:find("authorization", 1, true), "authorization field reached persisted state")
        assert(not normalized:find("token", 1, true), "token field reached persisted state")
        inspect(child, seen)
    end
end
inspect(state)
assert(plugin.ephemeral_session.cookie == canary, "state projection mutated the in-memory session")

print("state boundary tests passed")

local Pua = {}

-- Compatibility key independently verified against public Fanqie reader pages
-- on 2026-08-13. The site may change it; callers must reject unknown PUA.
local FIRST_CODEPOINT = 58344
local KEY = "D在主特家军然表场4要只v和?6别还g现儿岁??此象月3出战工相o男直失世F都平文什VO将真T那当?会立些u是十张学气大爱两命全后东性通被1它乐接而感车山公了常以何可话先pi叫轻M士w着变尔快l个说少色里安花远7难师放t报认面道S?克地度I好机U民写把万同水新没书电吃像斯5为y白几日教看但第加候作上拉住有法r事应位利你声身国问马女他Y比父xAHNsX边美对所金活回意到z从j知又内因点Q三定8Rb正或夫向德听更?得告并本q过记L让打f人就者去原满体做经K走如孩cG给使物?最笑部?员等受k行一条果动光门头见往自解成处天能于名其发总母的死手入路进心来h时力多开已许d至由很界n小与Z想代么分生口再妈望次西风种带J?实情才这?E我神格长觉间年眼无不亲关结0友信下却重己老2音字m呢明之前高PB目太e9起稜她也W用方子英每理便四数期中C外样a海们任"

local function next_codepoint(text, index)
    local b1 = text:byte(index)
    if not b1 then return nil end
    if b1 < 0x80 then return b1, index + 1 end
    local b2 = text:byte(index + 1)
    if b1 < 0xE0 and b2 then
        return (b1 - 0xC0) * 0x40 + b2 - 0x80, index + 2
    end
    local b3 = text:byte(index + 2)
    if b1 < 0xF0 and b2 and b3 then
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + b3 - 0x80, index + 3
    end
    local b4 = text:byte(index + 3)
    if b1 < 0xF8 and b2 and b3 and b4 then
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40 + b4 - 0x80, index + 4
    end
    return nil, index + 1
end

local function utf8_char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local key = {}
do
    local index = 1
    while index <= #KEY do
        local code, next_index = next_codepoint(KEY, index)
        key[#key + 1] = code and utf8_char(code) or "?"
        index = next_index
    end
end

function Pua.decode(text)
    text = tostring(text or "")
    local output = {}
    local stats = { pua = 0, unknown = 0 }
    local index = 1
    while index <= #text do
        local code, next_index = next_codepoint(text, index)
        if not code then
            output[#output + 1] = text:sub(index, index)
        elseif code >= 0xE000 and code <= 0xF8FF then
            stats.pua = stats.pua + 1
            local replacement = key[code - FIRST_CODEPOINT + 1]
            if not replacement or replacement == "?" then
                stats.unknown = stats.unknown + 1
                output[#output + 1] = "�"
            else
                output[#output + 1] = replacement
            end
        else
            output[#output + 1] = text:sub(index, next_index - 1)
        end
        index = next_index
    end
    return table.concat(output), stats
end

return Pua

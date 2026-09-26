local Identifier = {
    MIN_BYTES = 10,
    MAX_BYTES = 64,
}

function Identifier.valid(value)
    return type(value) == "string"
        and #value >= Identifier.MIN_BYTES
        and #value <= Identifier.MAX_BYTES
        and value:match("^%d+$") ~= nil
end

function Identifier.normalize(value)
    return Identifier.valid(value) and value or nil
end

return Identifier

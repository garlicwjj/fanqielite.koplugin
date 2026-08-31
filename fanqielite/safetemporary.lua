local lfs = require("libs/libkoreader-lfs")

local SafeTemporary = {}

function SafeTemporary.prepare(path, label)
    label = type(label) == "string" and label or "临时文件"
    local attributes_call, mode = pcall(lfs.symlinkattributes, path, "mode")
    if not attributes_call then return nil, "无法检查" .. label end
    if mode ~= nil then
        local remove_call, removed = pcall(os.remove, path)
        if not remove_call or not removed then return nil, "无法清理旧的" .. label end
    end
    local recheck_call, remaining = pcall(lfs.symlinkattributes, path, "mode")
    if not recheck_call then return nil, "无法复查" .. label end
    if remaining ~= nil then return nil, label .. "路径仍被占用" end
    return true
end

return SafeTemporary

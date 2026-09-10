local DataStorage = require("datastorage")
local https = require("ssl.https")

local VerifiedTLS = {}

local CA_FILE = DataStorage:getDataDir() .. "/data/ca-bundle.crt"

local function dns_name_matches(pattern, host)
    if type(pattern) ~= "string" or type(host) ~= "string"
            or pattern == "" or #pattern > 253
            or pattern:find("[%z\1-\31\127]") then
        return false
    end
    pattern = pattern:lower()
    host = host:lower()
    if pattern == host then return true end
    local suffix = pattern:match("^%*%.([%a%d][%a%d%.%-]+)$")
    if not suffix or not suffix:find("%.") then return false end
    local required_suffix = "." .. suffix
    if host:sub(-#required_suffix) ~= required_suffix then return false end
    local leftmost = host:sub(1, #host - #required_suffix)
    return leftmost ~= "" and not leftmost:find("%.", 1, true)
end

local function certificate_matches_host(certificate, host)
    if certificate == nil then return false end
    local ok, extensions = pcall(function() return certificate:extensions() end)
    if not ok or type(extensions) ~= "table" then return false end
    for _, extension in pairs(extensions) do
        if type(extension) == "table" and type(extension.dNSName) == "table" then
            for _, name in pairs(extension.dNSName) do
                if dns_name_matches(name, host) then return true end
            end
        end
    end
    return false
end

local base_create = https.tcp{
    protocol = "any",
    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
    verify = "peer",
    cafile = CA_FILE,
}

function VerifiedTLS.create()
    local connection = base_create()
    local connect = connection.connect
    function connection:connect(host, port)
        local connected, connect_err = connect(self, host, port)
        if not connected then return nil, connect_err end
        local cert_ok, certificate = pcall(self.getpeercertificate, self)
        if not cert_ok or not certificate_matches_host(certificate, host) then
            pcall(self.close, self)
            return nil, "certificate hostname mismatch"
        end
        return connected
    end
    return connection
end

return VerifiedTLS

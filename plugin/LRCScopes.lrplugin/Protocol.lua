--[[ Messages sent to the native helper over the LrSocket (see HelperLink.lua).

One JSON object per line, terminated by "\n". Must match
helper/Sources/ScopesCore/WireProtocol.swift:

  {"pluginVersion":"1.1.0","protocol":2,"type":"hello"}
  {"enabled":true,"module":"develop","photo":{"id":1,"name":"A.CR3"},"showSeq":0,"type":"state"}
  {"type":"frame","seq":7,"photoId":1,"renderMs":85,"sentAt":784249200.250,"jpeg":"<base64>"}
  {"photoId":1,"reason":"error loading thumb","type":"previewError"}
  {"type":"quit"}

renderMs (how long Lightroom took to render the preview) and sentAt
(LrDate.currentTime()) are diagnostics; the helper logs them. ]]

local LrStringUtils = import 'LrStringUtils'

local Protocol = { VERSION = 2 }

---------------------------------------------------------------------------------
-- Minimal JSON encoder (objects, arrays, strings, numbers, booleans).
---------------------------------------------------------------------------------

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

local encode

function encode(v)
    local t = type(v)
    if t == 'nil' then
        return 'null'
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v % 1 == 0 and math.abs(v) < 2^53 then return string.format('%d', v) end
        return string.format('%.6f', v)
    elseif t == 'string' then
        return encodeString(v)
    elseif t == 'table' then
        local parts = {}
        if next(v) ~= nil and isArray(v) then
            for i = 1, #v do parts[i] = encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys) -- deterministic output
        for _, k in ipairs(keys) do
            parts[#parts + 1] = encodeString(k) .. ':' .. encode(v[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    error('cannot JSON-encode a ' .. t)
end

Protocol.encodeJSON = encode

---------------------------------------------------------------------------------
-- Messages (each returned without the line terminator; HelperLink adds it)
---------------------------------------------------------------------------------

function Protocol.hello(pluginVersion)
    return encode({ type = 'hello', ['protocol'] = Protocol.VERSION, pluginVersion = pluginVersion })
end

--- showSeq counts Show Scopes choices; when it changes, the helper re-opens a panel
--- the user closed (closing only hides it; see HelperLink.lua for why).
function Protocol.state(enabled, module, photoId, photoName, showSeq)
    return encode({
        type = 'state',
        enabled = enabled,
        module = module,
        photo = photoId and { id = photoId, name = photoName } or nil,
        showSeq = showSeq,
    })
end

--- Frame message. Built by hand rather than through the JSON encoder: the payload
--- is large and base64 needs no escaping.
function Protocol.frame(seq, photoId, jpeg, renderMs, sentAt)
    -- Some base64 encoders wrap lines; a newline would end the message early.
    local b64 = LrStringUtils.encodeBase64(jpeg):gsub('[\r\n]', '')
    return string.format('{"type":"frame","seq":%d,"photoId":%d,"renderMs":%d,"sentAt":%.3f,"jpeg":"',
        seq, photoId, math.floor((renderMs or 0) + 0.5), sentAt or 0) .. b64 .. '"}'
end

--- Lightroom could not render a preview of the photo the helper is waiting for.
function Protocol.previewError(photoId, reason)
    return encode({ type = 'previewError', photoId = photoId, reason = reason })
end

function Protocol.quit()
    return '{"type":"quit"}'
end

return Protocol

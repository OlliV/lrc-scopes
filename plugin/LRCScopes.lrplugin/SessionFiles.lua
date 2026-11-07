--[[ The file-based protocol shared with the native helper.

Both sides use one session directory. Every file is written under a temporary name
and renamed into place, so the helper never reads a partially written file.

  plug-in -> state.json        Lightroom state + pointer to the newest frame
  plug-in -> frame-<seq>.jpg   rendered preview of the target photo
  helper  -> helper.json       refreshed every second; its mtime is the helper heartbeat

Times are LrDate.currentTime() (seconds since 2001-01-01 UTC), which equals
Date.timeIntervalSinceReferenceDate on the Swift side.
See helper/Sources/ScopesCore/SessionProtocol.swift for the reader. ]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Log = require 'Log'

local SessionFiles = {
    PROTOCOL = 1,
    STATE_FILE = 'state.json',
    HELPER_FILE = 'helper.json',
    FRAMES_TO_KEEP = 3,
}

-- Must match SessionProtocol.defaultSessionDirectory in Swift.
function SessionFiles.directory()
    local home = LrPathUtils.getStandardFilePath('home')
    return LrPathUtils.child(LrPathUtils.child(LrPathUtils.child(home, 'Library'), 'Caches'), 'com.lrcscopes.session')
end

function SessionFiles.path(name)
    return LrPathUtils.child(SessionFiles.directory(), name)
end

function SessionFiles.ensureDirectory()
    local dir = SessionFiles.directory()
    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end
    return LrFileUtils.exists(dir) == 'directory'
end

--- Writes `data` to `path` atomically (temp file + rename). Returns true on success.
function SessionFiles.atomicWrite(path, data)
    local tmp = path .. '.tmp'
    local f, openErr = io.open(tmp, 'wb')
    if not f then
        Log.error('Cannot open %s for writing: %s', tmp, tostring(openErr))
        return false
    end
    local ok, writeErr = f:write(data)
    f:close()
    if not ok then
        Log.error('Cannot write %s: %s', tmp, tostring(writeErr))
        LrFileUtils.delete(tmp)
        return false
    end
    -- Lightroom's sandbox has no os.rename/os.remove. LrFileUtils.move is a rename
    -- (complete file appears at once) but does not replace an existing destination,
    -- so replacing is delete + move: readers see the old file, briefly no file, or
    -- the complete new file — never a partial one. The helper tolerates the gap.
    if LrFileUtils.exists(path) then
        LrFileUtils.delete(path)
    end
    local moved, moveErr = LrFileUtils.move(tmp, path)
    if not moved and LrFileUtils.exists(path) ~= 'file' then
        Log.error('Cannot move %s -> %s: %s', tmp, path, tostring(moveErr))
        LrFileUtils.delete(tmp)
        return false
    end
    return true
end

function SessionFiles.frameName(seq)
    return string.format('frame-%d.jpg', seq)
end

--- Removes stale files from a previous session (frames, temp files, old state).
function SessionFiles.clean()
    local dir = SessionFiles.directory()
    if LrFileUtils.exists(dir) ~= 'directory' then return end
    for file in LrFileUtils.files(dir) do
        local name = LrPathUtils.leafName(file)
        if name:match('^frame%-%d+%.jpg$') or name:match('%.tmp$') then
            LrFileUtils.delete(file)
        end
    end
end

function SessionFiles.deleteFrame(seq)
    local path = SessionFiles.path(SessionFiles.frameName(seq))
    if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
end

--- Seconds since the helper last refreshed helper.json, or nil if it never did.
function SessionFiles.helperHeartbeatAge()
    local attrs = LrFileUtils.fileAttributes(SessionFiles.path(SessionFiles.HELPER_FILE))
    local modified = attrs and attrs.fileModificationDate
    if not modified then return nil end
    return LrDate.currentTime() - modified
end

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

SessionFiles.encodeJSON = encode

return SessionFiles

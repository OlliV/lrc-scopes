--[[ Offline tests for the plug-in logic.

Runs the real plug-in modules against a stubbed Lightroom SDK (including a fake
LrSocket) with a simulated clock and cooperative task scheduler. Usage (from the
repository root):

    lua plugin/tests/run_tests.lua
]]

local pluginDir = arg[0]:match('^(.*)/tests/[^/]+$') .. '/LRCScopes.lrplugin'
package.path = pluginDir .. '/?.lua;' .. package.path

local tmpRoot = (os.getenv('TMPDIR') or '/tmp'):gsub('/$', '')
local home = string.format('%s/lrcscopes-test-%d', tmpRoot, os.time())

---------------------------------------------------------------------------------
-- Simulated clock + scheduler
---------------------------------------------------------------------------------

local clock = 1000
local tasks = {} -- { co, wakeAt }

local function spawn(fn)
    tasks[#tasks + 1] = { co = coroutine.create(fn), wakeAt = clock }
end

local function runUntil(untilTime)
    while true do
        local nextTask, nextAt
        for _, t in ipairs(tasks) do
            if coroutine.status(t.co) ~= 'dead' and (not nextAt or t.wakeAt < nextAt) then
                nextTask, nextAt = t, t.wakeAt
            end
        end
        if not nextTask or nextAt > untilTime then clock = untilTime; return end
        clock = math.max(clock, nextAt)
        local ok, delay = coroutine.resume(nextTask.co)
        if not ok then error('task failed: ' .. tostring(delay)) end
        nextTask.wakeAt = clock + (delay or 0)
    end
end

local function advance(seconds) runUntil(clock + seconds) end

---------------------------------------------------------------------------------
-- Fake LrSocket: records binds and sends; the test plays the helper's part.
---------------------------------------------------------------------------------

local sockets = {}

local FakeSocket = {}
FakeSocket.__index = FakeSocket

function FakeSocket:send(message)
    assert(self.mode == 'send', 'send on a non-send socket')
    -- Like LrC: sending to a client that has gone away raises nothing.
    if not self.peer then self.dropped = (self.dropped or 0) + 1; return end
    self.sent[#self.sent + 1] = message
end
function FakeSocket:reconnect()
    -- LrC 15.6 deadlocks its main thread when a socket whose client has gone away is
    -- re-armed. Only a socket that never had a client may be (listen timeout).
    assert(not self.hadPeer, 'reconnect() on a socket that had a client (deadlocks Lightroom)')
    self.reconnects = self.reconnects + 1
    self.listening = true
end
function FakeSocket:callback(name, ...)
    self.params[name](self, ...)
end
function FakeSocket:close() self.closed = true; self.peer = false end

-- Test-side controls ("the helper").
function FakeSocket:startListening(port)
    self.listening = true
    self:callback('onConnecting', port)
end
function FakeSocket:helperConnects()
    assert(self.listening, 'helper connected to a socket that is not listening')
    self.listening = false
    self.peer = true
    self.hadPeer = true
    self:callback('onConnected', self.port)
end
function FakeSocket:helperDisconnects()
    self.peer = false
    self:callback('onClosed')
end
function FakeSocket:timeout() self.listening = false; self:callback('onError', 'timeout') end

local function newFakeSocket(params)
    assert(params.functionContext, 'bind needs a function context')
    assert(params.plugin, 'bind needs _PLUGIN')
    -- Re-arming a "receive" LrSocket deadlocks LrC 15.6; the plug-in must not use one.
    assert(params.mode == 'send', 'expected a send socket')
    assert(params.port == 0, 'expected a system-chosen port')
    local s = setmetatable({ params = params, mode = params.mode, sent = {}, reconnects = 0,
                             port = 54321 + #sockets, listening = false, peer = false, closed = false }, FakeSocket)
    sockets[#sockets + 1] = s
    -- Replacement sockets start listening on their own (the first one is driven by
    -- the startup test).
    if #sockets > 1 then spawn(function() s:startListening(s.port) end) end
    return s
end

---------------------------------------------------------------------------------
-- Other SDK stubs
---------------------------------------------------------------------------------

local executed = {}           -- helper launches
local executeStatus = 0
helperRunning = false         -- what the plug-in's pgrep check sees
processChecks = 0
local observers = {}
local currentModule = 'develop'
local prefs = {}

local Photo = {}
Photo.__index = Photo
local function newPhoto(id, name)
    return setmetatable({ localIdentifier = id, name = name, editCount = 1, lastEditTime = 0, requests = {} }, Photo)
end
function Photo:getFormattedMetadata(key) assert(key == 'fileName'); return self.name end
function Photo:getRawMetadata(key)
    if key == 'editCount' then return self.editCount end
    if key == 'lastEditTime' then return self.lastEditTime end
end
function Photo:requestJpegThumbnail(w, h, cb)
    local handle = { w = w, h = h, cb = cb }
    self.requests[#self.requests + 1] = handle
    return handle
end

local target = newPhoto(1, 'A.CR3')

-- Lightroom's Lua sandbox has no os.rename / os.remove; neither may the plug-in.
local realExecute = os.execute
os.rename, os.remove = nil, nil

local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local helperAppPath = home .. "/Plug ins/It's here/LRCScopes.lrplugin/bin/LRC Scopes.app"
realExecute('mkdir -p ' .. shq(helperAppPath))

local stubs = {
    LrApplication = { activeCatalog = function() return { getTargetPhoto = function() return target end } end },
    LrApplicationView = { getCurrentModuleName = function() return currentModule end },
    LrDate = { currentTime = function() return clock end },
    LrDevelopController = {
        addAdjustmentChangeObserver = function(ctx, obs, fn)
            assert(ctx, 'observer needs a function context')
            observers[#observers + 1] = { obs = obs, fn = fn }
        end,
    },
    LrFunctionContext = { callWithContext = function(_, fn) return fn({}) end },
    LrPrefs = { prefsForPlugin = function() return prefs end },
    LrSocket = { bind = newFakeSocket },
    LrStringUtils = {
        -- Real base64 is irrelevant here; wrap lines like some encoders do so the
        -- newline stripping is exercised.
        encodeBase64 = function(s)
            local hex = s:gsub('.', function(c) return string.format('%02x', c:byte()) end)
            return (hex:gsub(('.'):rep(8), '%0\r\n'))
        end,
    },
    LrTasks = {
        startAsyncTask = function(fn) spawn(fn) end,
        sleep = function(s) coroutine.yield(s) end,
        pcall = pcall,
        execute = function(cmd)
            if cmd:find('pgrep', 1, true) then
                processChecks = processChecks + 1
                return helperRunning and 0 or 1
            end
            executed[#executed + 1] = cmd
            return executeStatus
        end,
    },
    LrPathUtils = {
        child = function(a, b) return a .. '/' .. b end,
        leafName = function(p) return p:match('([^/]+)$') end,
    },
    LrFileUtils = {
        exists = function(p)
            if realExecute('test -d ' .. shq(p)) == true then return 'directory' end
            return false
        end,
    },
    LrLogger = function()
        local l = {}
        local function noop() end
        for _, m in ipairs({ 'enable', 'disable', 'infof', 'tracef', 'warnf' }) do l[m] = noop end
        l.errorf = function(_, fmt, ...) io.stderr:write('  [plug-in error] ', string.format(fmt, ...), '\n') end
        return l
    end,
}

_G.import = function(name) return assert(stubs[name], 'no stub for ' .. name) end
_G.LOC = function(s, ...)
    local text = s:gsub('^%$%$%$/[^=]*=', '')
    local args = { ... }
    return (text:gsub('%^(%d)', function(n) return tostring(args[tonumber(n)]) end))
end
_G.MAC_ENV = true
_G.WIN_ENV = false
_G._PLUGIN = { path = home .. "/Plug ins/It's here/LRCScopes.lrplugin" }

---------------------------------------------------------------------------------
-- Tiny test framework
---------------------------------------------------------------------------------

local failures, passes = 0, 0
local function check(cond, message)
    if cond then passes = passes + 1
    else
        failures = failures + 1
        io.stderr:write('FAIL: ', message, '\n', debug.traceback('', 2), '\n')
    end
end

local Protocol = require 'Protocol'
local MAX_IDLE = 1.6 -- > ScopesService MAX_RENDER_IDLE
-- Let pending settle requests run, answer them, and wait out the render throttle.
local function quiesce(jpeg)
    for _ = 1, 12 do
        advance(0.8)
        for _, r in ipairs(target.requests) do if not r.done then r.done = true; r.cb(jpeg) end end
    end
    advance(MAX_IDLE)
end
local Service = require 'ScopesService'

local function sock() return sockets[#sockets] end

-- The helper process. When it quits, the send-mode socket is NOT told (as in LrC).
local helper = {}
function helper.connect()
    helperRunning = true
    sock():helperConnects()
end
function helper.quit()
    helperRunning = false
    sock().peer = false
end
local function lastRequest() return target.requests[#target.requests] end
local function sentOfType(t)
    local out = {}
    for _, so in ipairs(sockets) do
        for _, m in ipairs(so.sent) do
            if m:find('"type":"' .. t .. '"', 1, true) then out[#out + 1] = m end
        end
    end
    return out
end
local function lastOfType(t) local l = sentOfType(t); return l[#l] end
local function countFrames() return #sentOfType('frame') end

---------------------------------------------------------------------------------
-- Protocol encoding (the exact lines the Swift tests decode)
---------------------------------------------------------------------------------

do
    local enc = Protocol.encodeJSON
    check(enc({ b = true, a = 1, c = 'x"y\n' }) == '{"a":1,"b":true,"c":"x\\"y\\n"}', 'object encoding')
    check(enc({ 1, 2, 3 }) == '[1,2,3]', 'array encoding')
    check(enc(0 / 0) == 'null', 'NaN encodes as null')
    check(enc('\1') == '"\\u0001"', 'control characters escaped')
    check(enc('Å.CR3') == '"Å.CR3"', 'UTF-8 passes through')

    check(Protocol.hello('1.1.0') == '{"pluginVersion":"1.1.0","protocol":2,"type":"hello"}', 'hello line: ' .. Protocol.hello('1.1.0'))
    check(Protocol.state(true, 'develop', 42, 'DSC_0001.NEF') ==
        '{"enabled":true,"module":"develop","photo":{"id":42,"name":"DSC_0001.NEF"},"type":"state"}', 'state line')
    check(Protocol.state(false, 'library', nil, nil) == '{"enabled":false,"module":"library","type":"state"}', 'state without photo')
    check(Protocol.state(true, 'develop', 1, 'A.CR3', true) ==
        '{"enabled":true,"module":"develop","photo":{"id":1,"name":"A.CR3"},"type":"state","updating":true}', 'state while updating')
    check(Protocol.quit() == '{"type":"quit"}', 'quit line')
    local frame = Protocol.frame(7, 42, 'JPEGDATA-THAT-IS-LONG-ENOUGH-TO-WRAP', 12.4, 1000.5)
    check(frame:match('^{"type":"frame","seq":7,"photoId":42,"renderMs":12,"sentAt":1000%.500,"jpeg":"[0-9a-f]+"}$') ~= nil,
        'frame line is one line with unwrapped payload: ' .. frame)
end

---------------------------------------------------------------------------------
-- Startup: bind, then launch the helper with the port
---------------------------------------------------------------------------------

Service.start()
advance(0.01)
check(#sockets == 1, 'one socket bound')
check(#executed == 0, 'no launch before the socket has a port')

sock():startListening(54321)
advance(0.3)
check(#executed == 1, 'helper launched once the port is known')
check(executed[1] and executed[1]:find("/Plug ins/It'\\''s here/LRCScopes.lrplugin/bin/LRC Scopes.app'", 1, true),
    'helper path shell-quoted: ' .. tostring(executed[1]))
check(executed[1] and executed[1]:find('--port 54321', 1, true), 'port passed to helper: ' .. tostring(executed[1]))
check(executed[1] and executed[1]:find('open -n -g', 1, true), 'fresh, background instance')

-- No helper yet: nothing rendered; a listen timeout re-arms the socket.
advance(1)
check(#target.requests == 0, 'no preview requests while the helper is not connected')
sock():timeout()
advance(0.3)
check(sock().reconnects == 1, 'listen timeout re-arms the socket')
check(processChecks == 0, 'no process checks while nothing is connected')

---------------------------------------------------------------------------------
-- Helper connects: hello, state, frame
---------------------------------------------------------------------------------

helper.connect()
advance(0.3)
check(sock().sent[1] == '{"pluginVersion":"1.1.0","protocol":2,"type":"hello"}\n', 'hello first, newline-terminated: ' .. tostring(sock().sent[1]))
check(lastOfType('state') and lastOfType('state'):find('"module":"develop"', 1, true), 'state sent')
check(lastOfType('state') and lastOfType('state'):find('"name":"A.CR3"', 1, true), 'photo name sent')
check(#observers == 1, 'adjustment observer registered in Develop')
check(#target.requests == 1, 'preview requested on connect, got ' .. #target.requests)
check(lastRequest() and lastRequest().w == 1024, 'default preview size is 1024')

lastRequest().cb('JPEG-1')
check(countFrames() == 1, 'frame sent')
check(lastOfType('frame') and lastOfType('frame'):find('"seq":1,"photoId":1', 1, true), 'frame header')
for _, m in ipairs(sock().sent) do
    check(m:sub(-1) == '\n' and not m:sub(1, -2):find('[\r\n]'), 'every message is exactly one line')
end

-- Keepalive.
local states = #sentOfType('state')
advance(3)
check(#sentOfType('state') >= states + 2, 'state re-sent as keepalive')

-- Identical pixels from a settle request are not re-sent.
for _, r in ipairs(target.requests) do if r ~= target.requests[1] then r.cb('JPEG-1') end end
check(countFrames() == 1, 'identical preview not re-sent')
check(#target.requests >= 2, 'settle re-request issued after change')

-- Slider drag: rate limited, one request in flight. (Wait out the render throttle
-- from the late answers above first.)
quiesce('JPEG-1')
local before = #target.requests
for _ = 1, 20 do observers[1].fn(observers[1].obs); advance(0.05) end
check(#target.requests - before == 1, 'only one request in flight while dragging, got ' .. (#target.requests - before))
lastRequest().cb('JPEG-2')
check(countFrames() == 2, 'new rendering sent')

-- Edits made outside the observer (e.g. sync) are found by the edit poll.
quiesce('JPEG-2')
local n = #target.requests
target.editCount = target.editCount + 1
advance(1)
check(#target.requests > n, 'editCount change triggers a request')

-- Late callback for a previous photo is ignored after switching photos.
local oldRequest = lastRequest()
target = newPhoto(2, 'B.NEF')
advance(0.5)
local framesBefore = countFrames()
oldRequest.cb('LATE-FROM-A')
check(countFrames() == framesBefore, 'stale photo callback ignored')
check(#target.requests == 1, 'new photo requested immediately')
target.requests[1].cb('JPEG-B')
check(lastOfType('frame'):find('"photoId":2', 1, true), 'frame for new photo sent')

-- A request whose callback never arrives does not block forever.
advance(6)
n = #target.requests
target.editCount = target.editCount + 1
advance(8)
check(#target.requests >= n + 2, 'requests resume after a lost callback')

-- Leaving Develop stops rendering but keeps state flowing.
currentModule = 'library'
advance(1)
n = #target.requests
target.editCount = target.editCount + 1
advance(3)
check(#target.requests == n, 'no requests outside Develop')
check(lastOfType('state'):find('"module":"library"', 1, true), 'module change sent')
currentModule = 'develop'
advance(1)

---------------------------------------------------------------------------------
-- Helper goes away: rendering stops, socket re-armed, relaunch on Show
---------------------------------------------------------------------------------

-- The helper dies (crash, force quit) and the send-mode socket never reports
-- onClosed. Nothing polls for that (a periodic shell command coincided with preview
-- requests failing); Show Scopes checks the process before deciding.
local checks = processChecks
helper.quit()
local oldSock, socketCount = sock(), #sockets
local oldReconnects = oldSock.reconnects
advance(10)
check(processChecks == checks, 'no periodic process checks')
spawn(function() Service.show() end)
advance(0.05)
check(processChecks == checks + 1, 'Show Scopes checks the helper process, got ' .. (processChecks - checks))
check(not Service.worker.link.connected, 'missing helper process drops the link')
check(#sockets == socketCount + 1, 'a fresh socket is bound for the next helper')
check(oldSock.reconnects == oldReconnects and not oldSock.closed, 'the old socket is not touched')
oldSock.params.onClosed(oldSock) -- a late callback from the abandoned socket
advance(0.3)
check(#sockets == socketCount + 1, 'callbacks from an abandoned socket are ignored')
advance(0.3)
check(#executed == 2, 'Show Scopes relaunches the helper')
n = #target.requests
target.editCount = target.editCount + 1
advance(3)
check(#target.requests == n, 'no requests while the helper is disconnected')
check(executed[2]:find('--port ' .. sock().port, 1, true), 'relaunched helper gets the new port: ' .. executed[2])
advance(20)
check(#executed == 3, 'one bounded retry when the helper never connects, got ' .. #executed)

-- Reconnect: a fresh hello and a full frame even if pixels are unchanged.
helper.connect()
advance(0.3)
check(#sentOfType('hello') == 2, 'hello on every connection')
lastRequest().cb('JPEG-B')
check(lastOfType('frame'):find('"photoId":2', 1, true) and countFrames() >= 4, 'reconnected helper gets a frame even if unchanged')

---------------------------------------------------------------------------------
-- Hide / show
---------------------------------------------------------------------------------

Service.hide()
check(lastOfType('state'):find('"enabled":false', 1, true), 'hide sends enabled=false immediately')
check(prefs.enabled == false, 'hide persisted')
advance(2)
n = #target.requests
target.editCount = target.editCount + 1
advance(2)
check(#target.requests == n, 'no requests while hidden')
spawn(function() Service.show() end)
advance(1)
check(prefs.enabled == true, 'show persisted')
check(lastOfType('state'):find('"enabled":true', 1, true), 'show sends enabled=true')
check(#target.requests > n, 'show resumes rendering')
check(#executed == 3, 'show does not relaunch a connected helper')

---------------------------------------------------------------------------------
-- Helper dies (crash, force quit) and Show Scopes comes before the periodic check
---------------------------------------------------------------------------------

advance(0.1)
socketCount = #sockets
helper.quit()
spawn(function() Service.show() end)
advance(0.05)
check(#sockets == socketCount + 1, 'Show Scopes checks the process and binds a fresh socket')
check(#executed == 4, 'and relaunches once the new port is known, got ' .. #executed)
helper.connect()
advance(0.3)
check(Service.worker.link.connected, 'relaunched helper connects')

-- An onClosed from the socket is also a disconnect.
sock():helperDisconnects()
helperRunning = false
advance(0.3)
check(not Service.worker.link.connected, 'socket close drops the link')
spawn(function() Service.show() end)
advance(0.3)
helper.connect()
advance(0.3)

---------------------------------------------------------------------------------
-- Preview errors: reported only while the helper has nothing for the photo
---------------------------------------------------------------------------------

target = newPhoto(3, 'C.3FR')
advance(0.5)
lastRequest().cb(nil, 'error loading thumb')
check(lastOfType('previewError') == '{"photoId":3,"reason":"error loading thumb","type":"previewError"}\n',
    'previewError sent: ' .. tostring(lastOfType('previewError')))
local errors = #sentOfType('previewError')
advance(1)
lastRequest().cb('JPEG-C')
advance(6)
target.editCount = target.editCount + 1
advance(0.5)
lastRequest().cb(nil, 'error loading thumb')
check(#sentOfType('previewError') == errors, 'no previewError once a frame was shown')

-- Large raws: after an edit Lightroom may have no preview for many seconds. Keep
-- retrying past the settle delays, then deliver the frame when it is back.
local function failPending()
    -- Fail every request issued since the last call (each fails exactly once).
    for _, r in ipairs(target.requests) do
        if not r.answered then r.answered = true; r.cb(nil, 'error loading thumb') end
    end
end
for _, r in ipairs(target.requests) do r.answered = true end
local framesBeforeStreak = countFrames()
local requestsBeforeStreak = #target.requests
target.editCount = target.editCount + 1
for _ = 1, 60 do advance(0.25); failPending() end -- 15 s of failures
local issued = #target.requests
check(issued - requestsBeforeStreak <= 14, 'backoff keeps retries modest, got ' .. (issued - requestsBeforeStreak))
advance(2.5)
check(#target.requests > issued, 'still retrying 15 s after the edit, beyond the settle delays')

-- Lightroom may report a failure more than once per request; that must not multiply
-- the retries.
local before = #target.requests
for _ = 1, 20 do
    advance(0.25)
    for _, q in ipairs(target.requests) do
        if not q.answered then q.answered = true; q.cb(nil, 'error loading thumb'); q.cb(nil, 'error loading thumb') end
    end
end
check(#target.requests - before <= 4, 'double failure callbacks do not multiply retries, got ' .. (#target.requests - before))
local r = lastRequest()
r.answered = true
r.cb('JPEG-C2')
check(countFrames() == framesBeforeStreak + 1, 'frame sent once Lightroom has a preview again')
advance(10)
check(#target.requests <= issued + 6, 'retries stop after a success')

-- A streak that never ends stops after the retry window, until the next edit.
for _, q in ipairs(target.requests) do q.answered = true end
target.editCount = target.editCount + 1
for _ = 1, 160 do advance(0.25); failPending() end -- 40 s
issued = #target.requests
advance(10); failPending()
check(#target.requests == issued, 'retries give up after the retry window')
target.editCount = target.editCount + 1
advance(1); failPending()
check(#target.requests > issued, 'the next edit starts requesting again')
for _ = 1, 8 do advance(0.25); failPending() end
lastRequest().cb('JPEG-C3')
for _, q in ipairs(target.requests) do q.answered = true end

---------------------------------------------------------------------------------
-- Smaller fallback sizes when Lightroom has no preview at the chosen size
---------------------------------------------------------------------------------

-- Model: after an edit only small thumbnails of the photo being developed are current.
local function answer(maxOk, jpeg)
    for _, q in ipairs(target.requests) do
        if not q.answered then
            q.answered = true
            if q.w <= maxOk then q.cb(jpeg) else q.cb(nil, 'error loading thumb') end
        end
    end
end
target = newPhoto(4, 'D.dng')
advance(0.3)
check(lastRequest().w == 1024, 'a new photo starts at the preferred size')
answer(1024, 'JPEG-D1')
for _ = 1, 4 do advance(0.3); answer(1024, 'JPEG-D1') end
local framesD = countFrames()
target.editCount = target.editCount + 1
for _ = 1, 10 do advance(0.3); answer(640, 'JPEG-D2') end
check(countFrames() == framesD + 1, 'edit shown via the 640 px fallback')
check(lastRequest().w == 640, 'the photo stays at the size that works')
target.editCount = target.editCount + 1
for _ = 1, 10 do advance(0.3); answer(320, 'JPEG-D3') end
check(countFrames() == framesD + 2, 'steps down to 320 px when 640 fails too')
target = newPhoto(5, 'E.dng')
advance(0.3)
check(lastRequest().w == 1024, 'the next photo starts at the preferred size again')
answer(1024, 'JPEG-E1')
for _, q in ipairs(target.requests) do q.answered = true end

---------------------------------------------------------------------------------
-- Slow renders throttle further requests (Lightroom must stay responsive)
---------------------------------------------------------------------------------

do
    for _ = 1, 30 do advance(0.3); answer(1024, 'JPEG-E1') end
    local first = #target.requests
    local completedAt
    -- Drag a slider continuously; each render takes 0.5 s.
    for i = 1, 40 do
        target.editCount = target.editCount + 1
        observers[1].fn(observers[1].obs)
        advance(0.05)
        local q = lastRequest()
        if not q.answered and clock - (q.at or clock) >= 0.5 then
            q.answered = true; q.cb('JPEG-E-' .. i); completedAt = completedAt or clock
        end
        q.at = q.at or clock
    end
    local issued = #target.requests - first
    -- 2 s of dragging with 0.5 s renders + 2x idle = one request per 1.5 s.
    check(issued <= 3, 'slow renders throttle requests while dragging, got ' .. issued)
    for _ = 1, 30 do advance(0.3); answer(1024, 'JPEG-E9') end
end

---------------------------------------------------------------------------------
-- "updating" tells the helper when the scopes lag behind the latest edit
---------------------------------------------------------------------------------

do
    local function updatingNow()
        advance(0.06) -- state goes out on the next tick
        return lastOfType('state'):find('"updating":true', 1, true) ~= nil
    end
    quiesce('JPEG-U0')
    check(not updatingNow(), 'not updating when the frame is current')
    target.editCount = target.editCount + 1
    observers[1].fn(observers[1].obs)
    check(updatingNow(), 'updating right after an edit')
    local stale = lastRequest()
    advance(0.2)
    target.editCount = target.editCount + 1
    observers[1].fn(observers[1].obs) -- another edit while the first request renders
    stale.done = true
    stale.cb('JPEG-U1')
    check(updatingNow(), 'a frame from before the latest edit keeps it updating')
    quiesce('JPEG-U2')
    check(not updatingNow(), 'cleared once a frame reflects the latest edit')
    target.editCount = target.editCount + 1
    for _ = 1, 160 do
        advance(0.25)
        for _, q in ipairs(target.requests) do if not q.done then q.done = true; q.cb(nil, 'error loading thumb') end end
    end
    check(not updatingNow(), 'cleared when the plug-in gives up waiting')
    quiesce('JPEG-U3')
end

---------------------------------------------------------------------------------
-- Launch failure is reported to the caller
---------------------------------------------------------------------------------

helper.quit()
advance(2.5)
executeStatus = 1
local showOk, showReason
spawn(function() showOk, showReason = Service.show() end)
advance(0.1)
check(showOk == false and showReason and showReason:find('could not be started', 1, true), 'launch failure surfaces to Show Scopes')
executeStatus = 0

---------------------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------------------

helper.connect()
advance(0.3)
Service.shutdown()
check(sock().sent[#sock().sent] == '{"type":"quit"}\n', 'shutdown sends quit')
check(sock().closed, 'socket closed on shutdown')
advance(2)
local alive = 0
for _, t in ipairs(tasks) do
    if coroutine.status(t.co) ~= 'dead' then alive = alive + 1 end
end
check(alive == 0, 'service task exits after shutdown')

realExecute('rm -rf ' .. shq(home))
print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)

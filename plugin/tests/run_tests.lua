--[[ Offline tests for the plug-in logic.

Runs the real plug-in modules against a stubbed Lightroom SDK with a simulated
clock and cooperative task scheduler. Usage (from the repository root):

    lua plugin/tests/run_tests.lua
]]

local pluginDir = arg[0]:match('^(.*)/tests/[^/]+$') .. '/LRCScopes.lrplugin'
package.path = pluginDir .. '/?.lua;' .. package.path

local tmpRoot = os.getenv('TMPDIR') or '/tmp'
local home = string.format('%s/lrcscopes-test-%d', tmpRoot:gsub('/$', ''), os.time())
os.execute('mkdir -p ' .. home)

---------------------------------------------------------------------------------
-- Simulated clock + scheduler
---------------------------------------------------------------------------------

local clock = 1000
local tasks = {} -- { co, wakeAt }

local function spawn(fn)
    local co = coroutine.create(fn)
    tasks[#tasks + 1] = { co = co, wakeAt = clock }
end

--- Runs tasks until the simulated clock reaches `untilTime`.
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
-- SDK stubs
---------------------------------------------------------------------------------

local executed = {}
local observers = {}
local helperTouchedAt = nil
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

local function fileExists(path)
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

local function isDir(path)
    return os.execute('test -d "' .. path .. '"') == true
end

local function readFile(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('a')
    f:close()
    return s
end

-- Lightroom's Lua sandbox has no os.rename / os.remove; neither may the plug-in.
local realRename, realRemove = os.rename, os.remove
os.rename, os.remove = nil, nil

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
    LrTasks = {
        startAsyncTask = function(fn) spawn(fn) end,
        sleep = function(s) coroutine.yield(s) end,
        pcall = pcall,
        execute = function(cmd) executed[#executed + 1] = cmd; return 0 end,
    },
    LrPathUtils = {
        child = function(a, b) return a .. '/' .. b end,
        getStandardFilePath = function(which) assert(which == 'home'); return home end,
        leafName = function(p) return p:match('([^/]+)$') end,
    },
    LrFileUtils = {
        exists = function(p)
            if isDir(p) then return 'directory' end
            return fileExists(p) and 'file' or false
        end,
        createAllDirectories = function(p) os.execute('mkdir -p "' .. p .. '"') end,
        delete = function(p) return realRemove(p) ~= nil end,
        -- Like Lightroom's: a rename that refuses to replace an existing file.
        move = function(from, to)
            if fileExists(to) then return false, 'destination exists' end
            return realRename(from, to) ~= nil
        end,
        files = function(dir)
            local pipe = io.popen('ls -1 "' .. dir .. '"')
            local list = {}
            for line in pipe:lines() do list[#list + 1] = dir .. '/' .. line end
            pipe:close()
            local i = 0
            return function() i = i + 1; return list[i] end
        end,
        fileAttributes = function(p)
            if p:match('helper%.json$') and helperTouchedAt then
                return { fileModificationDate = helperTouchedAt }
            end
            return {}
        end,
    },
    LrLogger = function()
        local l = {}
        local function noop() end
        for _, m in ipairs({ 'enable', 'disable', 'infof', 'tracef', 'warnf', 'errorf' }) do
            l[m] = noop
        end
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
os.execute("mkdir -p '" .. home .. "/Plug ins/It'\\''s here/LRCScopes.lrplugin/bin/LRC Scopes.app'")

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

local SessionFiles = require 'SessionFiles'
local Service = require 'ScopesService'

local function state()
    local s = readFile(SessionFiles.path('state.json'))
    return s
end

local function touchHelper() helperTouchedAt = clock end

local function lastRequest()
    return target.requests[#target.requests]
end

---------------------------------------------------------------------------------
-- JSON encoder
---------------------------------------------------------------------------------

do
    local enc = SessionFiles.encodeJSON
    check(enc({ b = true, a = 1, c = 'x"y\n' }) == '{"a":1,"b":true,"c":"x\\"y\\n"}', 'object encoding: ' .. enc({ b = true, a = 1, c = 'x"y\n' }))
    check(enc({ 1, 2, 3 }) == '[1,2,3]', 'array encoding')
    check(enc({}) == '{}', 'empty table encodes as object')
    check(enc(1.5) == '1.500000', 'float encoding')
    check(enc(0 / 0) == 'null', 'NaN encodes as null')
    check(enc('\1') == '"\\u0001"', 'control characters escaped')
    check(enc('Å.CR3') == '"Å.CR3"', 'UTF-8 passes through')
end

---------------------------------------------------------------------------------
-- Service lifecycle
---------------------------------------------------------------------------------

-- Leftovers from a "previous session" must be cleaned and must not make a new
-- helper quit.
os.execute('mkdir -p "' .. SessionFiles.directory() .. '"')
SessionFiles.atomicWrite(SessionFiles.path('frame-99.jpg'), 'old')
SessionFiles.atomicWrite(SessionFiles.path('state.json'), '{"protocol":1,"heartbeat":0,"enabled":true,"quit":true}')

Service.start()
advance(0.01)

check(not fileExists(SessionFiles.path('frame-99.jpg')), 'stale frames removed on start')
check(state():find('"quit":false', 1, true), 'fresh state written before helper launch')
check(#executed == 1, 'helper launched once on start')
check(executed[1] and executed[1]:find("/Plug ins/It'\\''s here/LRCScopes.lrplugin/bin/LRC Scopes.app'", 1, true),
    'helper path shell-quoted: ' .. tostring(executed[1]))
check(executed[1] and executed[1]:find('--session-dir', 1, true), 'session dir passed to helper')
check(#observers == 1, 'adjustment observer registered in Develop')

-- No helper yet: nothing rendered.
advance(1)
check(#target.requests == 0, 'no preview requests while helper is not running')

-- Helper comes up -> a frame is requested promptly.
touchHelper()
advance(1.2)
check(#target.requests == 1, 'preview requested once helper is alive, got ' .. #target.requests)
check(lastRequest().w == 1024, 'default preview size is 1024')

lastRequest().cb('JPEG-1')
check(fileExists(SessionFiles.path('frame-1.jpg')), 'frame-1 written')
check(readFile(SessionFiles.path('frame-1.jpg')) == 'JPEG-1', 'frame content intact')
check(state():find('"frame":{"file":"frame-1.jpg","photoId":1,"seq":1}', 1, true), 'state points to frame-1: ' .. state())
check(state():find('"module":"develop"', 1, true), 'module reported')
check(state():find('"name":"A.CR3"', 1, true), 'photo name reported')

-- A request repeated (settle) with identical pixels must not produce a frame.
local function keepHelperAlive(seconds)
    local stop = clock + seconds
    while clock < stop do touchHelper(); advance(0.5) end
end
keepHelperAlive(1)
for _, r in ipairs(target.requests) do if r ~= target.requests[1] then r.cb('JPEG-1') end end
check(not fileExists(SessionFiles.path('frame-2.jpg')), 'identical preview not re-sent')
check(#target.requests >= 2, 'settle re-request issued after change')

-- Slider drag: observer fires continuously; requests are rate limited, one in flight.
local before = #target.requests
for _ = 1, 20 do
    observers[1].fn(observers[1].obs)
    touchHelper()
    advance(0.05)
end
local during = #target.requests - before
check(during == 1, 'only one request in flight while dragging, got ' .. during)
lastRequest().cb('JPEG-2')
check(fileExists(SessionFiles.path('frame-2.jpg')), 'new rendering produces frame-2')
for _ = 1, 4 do observers[1].fn(observers[1].obs); lastRequest().cb('JPEG-x' .. clock); touchHelper(); advance(0.13) end
check(not fileExists(SessionFiles.path('frame-1.jpg')), 'old frames pruned')

-- Edits made outside the observer (e.g. sync) are found by the edit poll.
keepHelperAlive(6) -- let settles drain
local n = #target.requests
target.editCount = target.editCount + 1
keepHelperAlive(1)
check(#target.requests > n, 'editCount change triggers a request')

-- Late callback for a previous photo is ignored after switching photos.
local oldRequest = lastRequest()
target = newPhoto(2, 'B.NEF')
keepHelperAlive(0.5)
local frameBefore = state():match('"seq":(%d+)')
oldRequest.cb('LATE-FROM-A')
check(state():match('"seq":(%d+)') == frameBefore, 'stale photo callback ignored')
check(#target.requests == 1, 'new photo requested immediately')
target.requests[1].cb('JPEG-B')
check(state():find('"photoId":2', 1, true), 'frame for new photo published')

-- Timeout: a request whose callback never arrives does not block forever.
keepHelperAlive(6)
n = #target.requests
target.editCount = target.editCount + 1
keepHelperAlive(8)
check(#target.requests >= n + 2, 'requests resume after a lost callback')

-- Leaving Develop stops rendering.
currentModule = 'library'
keepHelperAlive(1)
n = #target.requests
target.editCount = target.editCount + 1
keepHelperAlive(3)
check(#target.requests == n, 'no requests outside Develop')
check(state():find('"module":"library"', 1, true), 'module change published')
currentModule = 'develop'

-- Helper gone -> rendering stops.
advance(6)
n = #target.requests
target.editCount = target.editCount + 1
advance(3)
check(#target.requests == n, 'no requests when helper heartbeat is stale')

-- Hide / show.
touchHelper()
Service.hide()
check(state():find('"enabled":false', 1, true), 'hide publishes enabled=false')
check(prefs.enabled == false, 'hide persisted')
keepHelperAlive(2)
n = #target.requests
target.editCount = target.editCount + 1
keepHelperAlive(2)
check(#target.requests == n, 'no requests while hidden')
spawn(function() Service.show() end)
keepHelperAlive(1)
check(prefs.enabled == true, 'show persisted')
check(#target.requests > n, 'show resumes rendering')

-- Show while helper is not running relaunches it.
local launches = #executed
advance(6) -- helper heartbeat goes stale
spawn(function() Service.show() end)
advance(0.1)
check(#executed == launches + 1, 'show relaunches a missing helper')
advance(20)
check(#executed == launches + 2, 'one bounded retry if the helper does not come up, got ' .. (#executed - launches))

-- Shutdown tells the helper to quit and stops the loop.
Service.shutdown()
check(state():find('"quit":true', 1, true), 'shutdown publishes quit=true')
advance(2)
local alive = 0
for _, t in ipairs(tasks) do if coroutine.status(t.co) ~= 'dead' then alive = alive + 1 end end
check(alive == 0, 'service task exits after shutdown')

os.execute('rm -rf "' .. home .. '"')
print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)

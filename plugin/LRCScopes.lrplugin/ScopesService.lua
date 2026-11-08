--[[----------------------------------------------------------------------------
ScopesService — the background task that feeds the helper with frames.

One long-lived task per plug-in instance. It owns the LrSocket link to the helper
(HelperLink.lua) and, each tick:
  * tracks the current module and target photo,
  * notices develop changes (LrDevelopController adjustment observer, plus an
    editCount/lastEditTime poll as a fallback for edits the observer misses, e.g.
    profile changes, masks, presets applied from elsewhere, sync, undo),
  * requests a fresh rendered preview (photo:requestJpegThumbnail) — rate limited,
    one request in flight, plus "settle" re-requests because Lightroom refines its
    previews shortly after an edit,
  * sends state (on change and as a keepalive) and frames to the helper.

Nothing is rendered while the helper isn't connected, scopes are hidden, or
Lightroom is outside the Develop module, so the plug-in costs ~nothing then.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDate = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local HelperLauncher = require 'HelperLauncher'
local HelperLink = require 'HelperLink'
local Log = require 'Log'
local Protocol = require 'Protocol'

local PLUGIN_VERSION = (function()
    local ok, info = pcall(require, 'Info')
    local v = ok and type(info) == 'table' and info.VERSION
    return v and string.format('%d.%d.%d', v.major, v.minor, v.revision) or 'unknown'
end)()

-- Timing (seconds).
local TICK_ACTIVE = 0.05          -- loop period while scopes are live
local TICK_IDLE = 0.25            -- loop period otherwise (still services the socket)
local MIN_REQUEST_INTERVAL = 0.12 -- caps preview requests at ~8/s while dragging sliders
local SETTLE_DELAYS = { 0.5, 1.5, 4.0 } -- re-requests after the last change
local REQUEST_TIMEOUT = 6         -- give up on a request whose callback never arrives
local HANDLE_RETENTION = 20       -- keep request objects alive for late repeat callbacks
local EDIT_POLL_INTERVAL = 0.4
local KEEPALIVE_INTERVAL = 1      -- must be < WireProtocol.staleAfter in the helper
-- (Helper liveness in the other direction: HelperLink.PROCESS_CHECK_INTERVAL.)
local HELPER_LAUNCH_GRACE = 8     -- wait this long for a launched helper to connect
local HELPER_LAUNCH_ATTEMPTS = 2

local DEFAULT_PREVIEW_SIZE = 1024

local Service = {
    running = false,
    generation = 0,
    worker = nil, -- the active Worker, for menu commands
}

---------------------------------------------------------------------------------
-- Worker: all mutable state of one running service instance.
---------------------------------------------------------------------------------

local Worker = {}
Worker.__index = Worker

local function newWorker(generation, context)
    local prefs = LrPrefs.prefsForPlugin()
    return setmetatable({
        generation = generation,
        context = context,
        catalog = LrApplication.activeCatalog(),
        enabled = prefs.enabled ~= false,
        link = nil,
        module = nil,
        photo = nil,
        photoId = nil,
        photoName = nil,
        editStamp = nil,
        observerAdded = false,

        dirty = false,
        settleAt = {},
        lastRequestAt = 0,
        inflight = nil,
        handles = {},

        seq = 0,
        lastJpeg = nil,

        launchWanted = false,   -- launch as soon as the socket has a port
        launchRequestedAt = nil,
        launchAttempts = 0,

        showSeq = 0,            -- incremented by Show Scopes (Protocol.state)
        lastStateSent = 0,
        nextEditPoll = 0,
        stateChanged = true,
    }, Worker)
end

function Worker:markDirty(now)
    self.dirty = true
    self.settleAt = {}
    for i, delay in ipairs(SETTLE_DELAYS) do self.settleAt[i] = now + delay end
end

function Worker:helperConnected()
    return self.link ~= nil and self.link.connected
end

function Worker:isActive()
    return self.enabled and self:helperConnected() and self.module == 'develop' and self.photo ~= nil
end

function Worker:sendState(now)
    if self.link:send(Protocol.state(self.enabled, self.module, self.photoId, self.photoName, self.showSeq)) then
        self.lastStateSent = now
        self.stateChanged = false
    end
end

function Worker:onHelperConnected()
    self.launchRequestedAt = nil
    self.launchAttempts = 0
    self.link:send(Protocol.hello(PLUGIN_VERSION))
    self.stateChanged = true
    -- A new helper has no frame yet; send one even if the pixels are unchanged.
    self.lastJpeg = nil
    self:markDirty(LrDate.currentTime())
end

function Worker:onHelperDisconnected()
    self.inflight = nil
end

-- Cheap fingerprint of the photo's edit history. editCount coalesces edits made
-- within a few seconds, so lastEditTime is included too.
local function editStampOf(photo)
    local ok, stamp = LrTasks.pcall(function()
        return tostring(photo:getRawMetadata('editCount')) .. ':' .. tostring(photo:getRawMetadata('lastEditTime'))
    end)
    return ok and stamp or nil
end

--- Launches (or relaunches) the helper once the socket knows its port.
function Worker:manageHelper(now)
    if not self.enabled or self:helperConnected() then
        self.launchWanted = false
        return
    end
    local port = self.link.port
    if self.launchWanted and port then
        self.launchWanted = false
        self.launchAttempts = self.launchAttempts + 1
        self.launchRequestedAt = now
        local ok, reason = HelperLauncher.launch(port)
        if not ok then
            Log.error('Helper not started: %s', tostring(reason))
            self.launchRequestedAt = nil
            self.launchError = reason
        end
        return
    end
    -- A launched helper that never connects (e.g. it raced with an exiting older
    -- instance) gets a bounded number of retries.
    if self.launchRequestedAt and now - self.launchRequestedAt > HELPER_LAUNCH_GRACE then
        if self.launchAttempts < HELPER_LAUNCH_ATTEMPTS then
            self.launchWanted = true
        else
            Log.warn('Helper did not connect after %d attempts', self.launchAttempts)
            self.launchRequestedAt = nil
        end
    end
end

function Worker:requestLaunch()
    self.launchAttempts = 0
    self.launchError = nil
    self.launchWanted = true
end

function Worker:trackTarget(now)
    local module = LrApplicationView.getCurrentModuleName()
    if module ~= self.module then
        Log.trace('Module: %s', tostring(module))
        self.module = module
        self.stateChanged = true
        if module == 'develop' then self:markDirty(now) end
    end

    -- The observer only registers while Develop is active; it lives as long as the
    -- service's function context.
    if module == 'develop' and not self.observerAdded then
        local ok, err = LrTasks.pcall(LrDevelopController.addAdjustmentChangeObserver,
            self.context, self, function(worker) worker:markDirty(LrDate.currentTime()) end)
        if ok then
            Log.trace('Adjustment observer registered')
        else
            Log.warn('Could not register adjustment observer: %s', tostring(err))
        end
        self.observerAdded = true -- don't retry every tick; the edit poll covers us
    end

    local photo = self.catalog:getTargetPhoto()
    local id = photo and photo.localIdentifier or nil
    if id ~= self.photoId then
        self.photo = photo
        self.photoId = id
        self.photoName = photo and photo:getFormattedMetadata('fileName') or nil
        self.editStamp = photo and editStampOf(photo) or nil
        self.lastJpeg = nil
        -- Don't wait for a request about the previous photo; its result is ignored.
        self.inflight = nil
        self.lastRequestAt = 0
        self.stateChanged = true
        Log.trace('Target photo: %s', tostring(self.photoName))
        if photo then self:markDirty(now) end
    end
end

function Worker:pollEdits(now)
    if not self.photo or now < self.nextEditPoll then return end
    self.nextEditPoll = now + EDIT_POLL_INTERVAL
    local stamp = editStampOf(self.photo)
    if stamp and stamp ~= self.editStamp then
        self.editStamp = stamp
        self:markDirty(now)
    end
end

function Worker:pruneHandles(now)
    for handle, created in pairs(self.handles) do
        if now - created > HANDLE_RETENTION then self.handles[handle] = nil end
    end
end

function Worker:onThumbnail(request, jpeg, err)
    if self.inflight == request then self.inflight = nil end
    if Service.worker ~= self then return end -- service restarted meanwhile
    if request.photoId ~= self.photoId then return end -- user moved on
    if not jpeg then
        Log.warn('Preview request failed for %s: %s', tostring(self.photoName), tostring(err))
        -- Only tell the helper if it has nothing for this photo yet; otherwise the last
        -- good frame stays up. Settle re-requests keep retrying meanwhile.
        if self.lastJpeg == nil then
            self.link:send(Protocol.previewError(request.photoId, tostring(err or 'unknown error')))
        end
        return
    end
    if jpeg == self.lastJpeg then return end         -- identical rendering, nothing new

    local seq = self.seq + 1
    local startedSend = LrDate.currentTime()
    local renderMs = (startedSend - request.startedAt) * 1000
    if self.link:send(Protocol.frame(seq, request.photoId, jpeg, renderMs, startedSend)) then
        self.seq = seq
        self.lastJpeg = jpeg
        Log.trace('Frame %d: %d bytes, rendered in %.0f ms, sent in %.0f ms', seq, #jpeg,
            renderMs, (LrDate.currentTime() - startedSend) * 1000)
    end
end

function Worker:requestFrame(now)
    local size = tonumber(LrPrefs.prefsForPlugin().previewSize) or DEFAULT_PREVIEW_SIZE
    local request = { photoId = self.photoId, startedAt = now }
    self.inflight = request
    self.lastRequestAt = now
    local worker = self
    -- Callbacks can arrive more than once (a cached preview first, a refined one
    -- later), so the request object is retained beyond the first callback.
    local handle = self.photo:requestJpegThumbnail(size, size, function(jpeg, err)
        worker:onThumbnail(request, jpeg, err)
    end)
    if handle then self.handles[handle] = now end
end

function Worker:scheduleRequests(now)
    if self.inflight and now - self.inflight.startedAt > REQUEST_TIMEOUT then
        Log.warn('Preview request timed out for %s', tostring(self.photoName))
        self.inflight = nil
    end
    if self.inflight or now - self.lastRequestAt < MIN_REQUEST_INTERVAL then return end

    if self.dirty then
        self.dirty = false
        self:requestFrame(now)
        return
    end
    local nextSettle = self.settleAt[1]
    if nextSettle and now >= nextSettle then
        table.remove(self.settleAt, 1)
        self:requestFrame(now)
    end
end

function Worker:tick()
    local now = LrDate.currentTime()
    self.link:tick() -- delivers connect/disconnect, re-arms the socket
    self:manageHelper(now)
    self:trackTarget(now)

    if self:isActive() then
        self:pollEdits(now)
        self:scheduleRequests(now)
    end
    self:pruneHandles(now)

    if self:helperConnected() and (self.stateChanged or now - self.lastStateSent >= KEEPALIVE_INTERVAL) then
        self:sendState(now)
    end
    return self:isActive() and TICK_ACTIVE or TICK_IDLE
end

---------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------

--- Starts the background service (idempotent).
function Service.start()
    if Service.running then return end
    if not MAC_ENV then
        Log.warn('LRC Scopes is macOS only; service not started')
        return
    end
    Service.running = true
    Service.generation = Service.generation + 1
    local generation = Service.generation

    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext('LRCScopes.service', function(context)
            local worker = newWorker(generation, context)
            local opened, openErr = LrTasks.pcall(function()
                worker.link = HelperLink.open(context, {
                    onConnected = function() worker:onHelperConnected() end,
                    onDisconnected = function() worker:onHelperDisconnected() end,
                })
            end)
            if not opened then
                Log.error('Cannot open the helper socket: %s', tostring(openErr))
                Service.running = false
                return
            end
            Service.worker = worker
            Log.info('Service started (generation %d)', generation)
            if worker.enabled then worker:requestLaunch() end

            local failures = 0
            while Service.running and Service.generation == generation do
                local ok, delay = LrTasks.pcall(Worker.tick, worker)
                if ok then
                    failures = 0
                else
                    failures = failures + 1
                    Log.error('Service tick failed: %s', tostring(delay))
                    delay = math.min(5, failures) -- back off, but keep going
                end
                LrTasks.sleep(delay)
            end

            worker.link:close()
            if Service.worker == worker then Service.worker = nil end
            Log.info('Service stopped (generation %d)', generation)
        end)
    end, 'LRCScopes.service')
end

--- Shows the scopes: persists the choice and launches the helper if it isn't
--- connected. Returns false plus a reason if the helper can't be started.
function Service.show()
    LrPrefs.prefsForPlugin().enabled = true
    if not Service.running then
        Service.start() -- launches the helper itself
        return true
    end
    local worker = Service.worker
    if not worker then return true end
    worker.enabled = true
    worker.showSeq = worker.showSeq + 1
    worker.stateChanged = true
    worker:markDirty(LrDate.currentTime())
    -- The user may have just closed the helper; don't wait for the periodic check.
    if worker:helperConnected() then worker.link:verify() end
    if not worker:helperConnected() then
        worker:requestLaunch()
        -- Launch happens on the service task; surface an immediate failure here.
        if worker.link.port then
            worker:manageHelper(LrDate.currentTime())
            if worker.launchError then return false, worker.launchError end
        end
    end
    return true
end

--- Hides the scopes until "Show Scopes" is chosen again (persists across restarts).
function Service.hide()
    LrPrefs.prefsForPlugin().enabled = false
    local worker = Service.worker
    if worker then
        worker.enabled = false
        worker.launchWanted = false
        worker.launchRequestedAt = nil
        if worker:helperConnected() then worker:sendState(LrDate.currentTime()) end
    end
end

--- Stops the service and tells the helper to exit. Safe to call from shutdown hooks.
function Service.shutdown()
    local worker = Service.worker
    Service.running = false
    Service.generation = Service.generation + 1
    if worker and worker.link then
        worker.link:send(Protocol.quit())
        worker.link:close()
    end
    -- If the socket is already gone the helper notices the closed connection, and
    -- it also exits when Lightroom quits.
    Service.worker = nil
end

return Service

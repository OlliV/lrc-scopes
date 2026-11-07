--[[----------------------------------------------------------------------------
ScopesService — the background task that feeds the helper with frames.

One long-lived task per plug-in instance. Each tick it:
  * tracks the current module and target photo,
  * notices develop changes (LrDevelopController adjustment observer, plus an
    editCount/lastEditTime poll as a fallback for edits the observer misses, e.g.
    profile changes, masks, presets applied from elsewhere, sync, undo),
  * requests a fresh rendered preview (photo:requestJpegThumbnail) — rate limited,
    one request in flight, plus "settle" re-requests because Lightroom refines its
    previews shortly after an edit,
  * writes frame-<seq>.jpg and state.json (see SessionFiles.lua) and a heartbeat.

Nothing is rendered while the helper is not running, scopes are hidden, or
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
local Log = require 'Log'
local SessionFiles = require 'SessionFiles'

local PLUGIN_VERSION = (function()
    local ok, info = pcall(require, 'Info')
    local v = ok and type(info) == 'table' and info.VERSION
    return v and string.format('%d.%d.%d', v.major, v.minor, v.revision) or 'unknown'
end)()

-- Timing (seconds).
local TICK_ACTIVE = 0.05        -- loop period while scopes are live
local TICK_IDLE = 0.5           -- loop period otherwise
local MIN_REQUEST_INTERVAL = 0.12 -- caps preview requests at ~8/s while dragging sliders
local SETTLE_DELAYS = { 0.5, 1.5, 4.0 } -- re-requests after the last change
local REQUEST_TIMEOUT = 6       -- give up on a request whose callback never arrives
local HANDLE_RETENTION = 20     -- keep request objects alive for late repeat callbacks
local EDIT_POLL_INTERVAL = 0.4
local HEARTBEAT_INTERVAL = 1
local HELPER_STALE_AFTER = 4
local HELPER_LAUNCH_GRACE = 8   -- wait this long for a launched helper before retrying
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

local function newWorker(generation)
    local prefs = LrPrefs.prefsForPlugin()
    return setmetatable({
        generation = generation,
        catalog = LrApplication.activeCatalog(),
        enabled = prefs.enabled ~= false,
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
        frame = nil,
        lastJpeg = nil,

        helperAlive = false,
        nextHelperCheck = 0,
        launchRequestedAt = nil,
        launchAttempts = 0,

        lastStateWrite = 0,
        nextEditPoll = 0,
        stateChanged = true,
    }, Worker)
end

function Worker:markDirty(now)
    self.dirty = true
    self.settleAt = {}
    for i, delay in ipairs(SETTLE_DELAYS) do self.settleAt[i] = now + delay end
end

function Worker:isActive()
    return self.enabled and self.helperAlive and self.module == 'develop' and self.photo ~= nil
end

function Worker:writeState(now, quit)
    local state = {
        ['protocol'] = SessionFiles.PROTOCOL,
        pluginVersion = PLUGIN_VERSION,
        heartbeat = now,
        enabled = self.enabled,
        quit = quit == true,
        module = self.module,
        photo = self.photoId and { id = self.photoId, name = self.photoName } or nil,
        frame = self.frame,
    }
    if SessionFiles.atomicWrite(SessionFiles.path(SessionFiles.STATE_FILE), SessionFiles.encodeJSON(state)) then
        self.lastStateWrite = now
        self.stateChanged = false
    end
end

-- Cheap fingerprint of the photo's edit history. editCount coalesces edits made
-- within a few seconds, so lastEditTime is included too.
local function editStampOf(photo)
    local ok, stamp = LrTasks.pcall(function()
        return tostring(photo:getRawMetadata('editCount')) .. ':' .. tostring(photo:getRawMetadata('lastEditTime'))
    end)
    return ok and stamp or nil
end

function Worker:updateHelperStatus(now)
    if now < self.nextHelperCheck then return end
    self.nextHelperCheck = now + 1
    local age = SessionFiles.helperHeartbeatAge()
    local alive = age ~= nil and age < HELPER_STALE_AFTER
    if alive ~= self.helperAlive then
        Log.info('Helper %s', alive and 'connected' or 'disconnected')
        self.helperAlive = alive
        if alive then
            self.launchRequestedAt = nil
            self.launchAttempts = 0
            -- A (re)started helper has no frame yet; send one even if unchanged.
            self.lastJpeg = nil
            self:markDirty(now)
        end
        self.stateChanged = true
    end
    -- A helper launch can race with a previous helper instance that is just exiting
    -- (e.g. plug-in reload). Retry a bounded number of times.
    if not alive and self.enabled and self.launchRequestedAt
        and now - self.launchRequestedAt > HELPER_LAUNCH_GRACE then
        if self.launchAttempts < HELPER_LAUNCH_ATTEMPTS then
            self:launchHelper(now)
        else
            Log.warn('Helper did not start after %d attempts', self.launchAttempts)
            self.launchRequestedAt = nil
        end
    end
end

function Worker:launchHelper(now)
    self.launchAttempts = self.launchAttempts + 1
    self.launchRequestedAt = now
    return HelperLauncher.launch()
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
            Service.context, self, function(worker) worker:markDirty(LrDate.currentTime()) end)
        if ok then
            self.observerAdded = true
            Log.trace('Adjustment observer registered')
        else
            Log.warn('Could not register adjustment observer: %s', tostring(err))
            self.observerAdded = true -- don't retry every tick; the edit poll covers us
        end
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
    if not jpeg then
        Log.warn('Preview request failed for %s: %s', tostring(self.photoName), tostring(err))
        return
    end
    if request.photoId ~= self.photoId then return end -- user moved on
    if jpeg == self.lastJpeg then return end         -- identical rendering, nothing new

    local seq = self.seq + 1
    local name = SessionFiles.frameName(seq)
    if not SessionFiles.atomicWrite(SessionFiles.path(name), jpeg) then return end
    self.seq = seq
    self.lastJpeg = jpeg
    self.frame = { seq = seq, file = name, photoId = request.photoId }
    self:writeState(LrDate.currentTime())
    SessionFiles.deleteFrame(seq - SessionFiles.FRAMES_TO_KEEP)
    Log.trace('Frame %d (%d bytes, %.0f ms)', seq, #jpeg, (LrDate.currentTime() - request.startedAt) * 1000)
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
    self:updateHelperStatus(now)
    self:trackTarget(now)

    if self:isActive() then
        self:pollEdits(now)
        self:scheduleRequests(now)
    end
    self:pruneHandles(now)

    if self.stateChanged or now - self.lastStateWrite >= HEARTBEAT_INTERVAL then
        self:writeState(now)
    end
    return self:isActive() and TICK_ACTIVE or TICK_IDLE
end

---------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------

--- Starts the background service (idempotent). Must not be called from a task-less
--- context that forbids starting tasks; all Lightroom entry points allow it.
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
            Service.context = context
            if not SessionFiles.ensureDirectory() then
                Log.error('Cannot create session directory %s', SessionFiles.directory())
                Service.running = false
                return
            end
            SessionFiles.clean()

            local worker = newWorker(generation)
            Service.worker = worker
            Log.info('Service started (generation %d)', generation)

            -- Replace any state left by a previous session (which may say quit=true)
            -- before the helper can read it.
            local started, startErr = LrTasks.pcall(function()
                local now = LrDate.currentTime()
                worker:trackTarget(now)
                worker:writeState(now)
                if worker.enabled then
                    local ok, reason = worker:launchHelper(now)
                    if not ok then Log.error('Helper not started: %s', tostring(reason)) end
                end
            end)
            if not started then
                -- Keep going: the loop retries everything each tick.
                Log.error('Service startup failed: %s', tostring(startErr))
            end

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

            if Service.worker == worker then Service.worker = nil end
            Log.info('Service stopped (generation %d)', generation)
        end)
    end, 'LRCScopes.service')
end

--- Shows the scopes: persists the choice and (re)launches the helper if needed.
function Service.show()
    LrPrefs.prefsForPlugin().enabled = true
    if not Service.running then
        Service.start() -- launches the helper itself
        return true
    end
    local worker = Service.worker
    if not worker then return true end
    worker.enabled = true
    worker.stateChanged = true
    worker.launchAttempts = 0
    local now = LrDate.currentTime()
    worker:markDirty(now)
    if not worker.helperAlive then
        return worker:launchHelper(now)
    end
    return true
end

--- Hides the scopes until "Show Scopes" is chosen again (persists across restarts).
function Service.hide()
    LrPrefs.prefsForPlugin().enabled = false
    local worker = Service.worker
    if worker then
        worker.enabled = false
        worker.launchRequestedAt = nil
        worker:writeState(LrDate.currentTime())
    end
end

--- Stops the service and tells the helper to exit. Safe to call from shutdown hooks.
function Service.shutdown()
    local worker = Service.worker
    Service.running = false
    Service.generation = Service.generation + 1
    if worker then
        worker:writeState(LrDate.currentTime(), true)
    else
        -- Still let a running helper know it should go away.
        SessionFiles.atomicWrite(SessionFiles.path(SessionFiles.STATE_FILE), SessionFiles.encodeJSON({
            ['protocol'] = SessionFiles.PROTOCOL, heartbeat = LrDate.currentTime(), enabled = false, quit = true,
        }))
    end
    Service.worker = nil
end

return Service

--[[ The plug-in's end of the connection to the helper: a "send" mode LrSocket on
127.0.0.1 at a system-chosen port. The helper is launched with the port and connects
to it as a TCP client; messages flow plug-in -> helper only.

LrSocket behaviour this is built around (LrC 15.6, observed):
  * reconnect() on a socket whose client has gone away deadlocks Lightroom's main
    thread, for both "send" and "receive" sockets, whether called from a task or
    from the socket's own onClosed. So a socket that has had a client is never
    re-armed: when the link is lost, it is abandoned untouched and a fresh socket is
    bound on a new port for the next helper.
  * Normally the helper never goes away while Lightroom runs: closing its window only
    hides it, and Show Scopes brings it back (see `showSeq` in Protocol.state). Losing
    the link is for crashes and force quits.
  * A send-mode socket does not reliably report its client leaving (the connection
    sits in CLOSE_WAIT with no onClosed), so while connected the link checks every
    PROCESS_CHECK_INTERVAL that the helper process exists.
  * A listening socket that nobody connects to reports onError "timeout" and is
    re-armed with reconnect(), the pattern the SDK documents; it never had a client.
  * Socket callbacks only record what happened; the service task calls tick() to act
    on it. Callbacks from abandoned sockets are ignored.

Must be used from a task (the process check uses LrTasks.execute). ]]

local LrDate = import 'LrDate'
local LrSocket = import 'LrSocket'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local HelperLink = {
    PROCESS_CHECK_INTERVAL = 2,
    -- The helper's executable name (CFBundleExecutable); pgrep -x matches it exactly.
    PROCESS_CHECK_COMMAND = '/usr/bin/pgrep -xq LRCScopes',
}
HelperLink.__index = HelperLink

--- Binds the socket. `context` must outlive the link (the service's function
--- context). `handlers.onConnected()` / `handlers.onDisconnected()` run from tick().
function HelperLink.open(context, handlers)
    local link = setmetatable({
        context = context,
        handlers = handlers or {},
        generation = 0,
        socket = nil,
        port = nil,               -- known once the current socket listens
        up = false,               -- the current socket has a client we believe exists
        connected = false,        -- last state reported to the handlers
        rearmTimeout = false,     -- listen timeout: re-arm (never had a client)
        rebind = false,           -- link lost: abandon the socket, bind a new one
        dropReason = nil,
        lastProcessCheck = nil,
        closed = false,
    }, HelperLink)
    link:bind()
    return link
end

function HelperLink:bind()
    self.generation = self.generation + 1
    local generation = self.generation
    local link = self
    local function current() return generation == link.generation and not link.closed end
    self.port = nil
    self.up = false
    self.hadClient = false
    self.socket = LrSocket.bind {
        functionContext = self.context,
        plugin = _PLUGIN,
        port = 0, -- let the system choose
        mode = 'send',
        onConnecting = function(_, port)
            if current() and port and port ~= link.port then
                Log.info('Listening for the helper on port %s', tostring(port))
                link.port = port
            end
        end,
        onConnected = function()
            if not current() then return end
            link.up = true
            link.hadClient = true
            link.lastProcessCheck = LrDate.currentTime() -- it just connected; it exists
        end,
        onClosed = function()
            if current() then link:lost('socket closed') end
        end,
        onError = function(_, err)
            if not current() then return end
            if err == 'timeout' and not link.up and not link.hadClient then
                link.rearmTimeout = true -- nobody connected yet; keep listening
            else
                Log.warn('Helper socket error: %s', tostring(err))
                link:lost(tostring(err))
            end
        end,
    }
end

--- Marks the link down (from a callback or tick); tick() replaces the socket.
function HelperLink:lost(reason)
    self.dropReason = self.dropReason or reason
    self.up = false
    self.rebind = true
end

--- True if a helper process is running. Yields (runs a short command).
function HelperLink.helperProcessExists()
    return LrTasks.execute(HelperLink.PROCESS_CHECK_COMMAND) == 0
end

--- Checks the helper process right now (e.g. before deciding not to relaunch it)
--- and drops the link if it is gone. Returns whether the link is still up.
function HelperLink:verify()
    if not self.up then return false end
    self.lastProcessCheck = LrDate.currentTime()
    if HelperLink.helperProcessExists() then return true end
    self:lost('helper process gone')
    self:tick()
    return false
end

function HelperLink:tick()
    local now = LrDate.currentTime()
    if self.up and self.connected and not self.closed
        and now - (self.lastProcessCheck or 0) >= HelperLink.PROCESS_CHECK_INTERVAL then
        self.lastProcessCheck = now
        if not HelperLink.helperProcessExists() then self:lost('helper process gone') end
    end

    if self.connected and not self.up then
        self.connected = false
        Log.info('Helper disconnected (%s)', tostring(self.dropReason))
        if self.handlers.onDisconnected then self.handlers.onDisconnected() end
    elseif not self.connected and self.up then
        self.connected = true
        Log.info('Helper connected')
        if self.handlers.onConnected then self.handlers.onConnected() end
    end
    if not self.connected then self.dropReason = nil end

    if self.closed then return end
    if self.rebind then
        -- Never touch the old socket again (see the header); it is released with the
        -- service's function context.
        self.rebind, self.rearmTimeout = false, false
        Log.info('Binding a new helper socket')
        local ok, err = pcall(self.bind, self)
        if not ok then Log.error('Could not bind a new helper socket: %s', tostring(err)) end
    elseif self.rearmTimeout then
        self.rearmTimeout = false
        local ok, err = pcall(self.socket.reconnect, self.socket)
        if not ok then Log.error('Could not re-arm the helper socket: %s', tostring(err)) end
    end
end

--- Sends one message (a single line, without terminator). Returns true if sent.
function HelperLink:send(message)
    if not self.connected or self.closed then return false end
    local ok, err = pcall(self.socket.send, self.socket, message .. '\n')
    if not ok then
        Log.warn('Send to helper failed: %s', tostring(err))
        self:lost(tostring(err))
        return false
    end
    return true
end

--- Closes the current socket if a live helper is on it (Lightroom quitting).
function HelperLink:close()
    if self.closed then return end
    local live = self.up
    self.closed = true
    self.connected = false
    if live then pcall(self.socket.close, self.socket) end
end

return HelperLink

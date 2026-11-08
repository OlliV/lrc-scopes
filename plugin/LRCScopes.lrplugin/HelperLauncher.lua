--[[ Launches the bundled native helper ("LRC Scopes.app"). Must be called from a task. ]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local HelperLauncher = {}

HelperLauncher.APP_NAME = 'LRC Scopes.app'

function HelperLauncher.appPath()
    return LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, 'bin'), HelperLauncher.APP_NAME)
end

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Launches the helper and tells it which port to connect to (see HelperLink.lua).
--- Returns true if `open` accepted the request, or false plus a user-facing reason.
function HelperLauncher.launch(port)
    if not MAC_ENV then
        return false, LOC '$$$/LRCScopes/Error/MacOnly=LRC Scopes currently supports macOS only.'
    end
    local app = HelperLauncher.appPath()
    if LrFileUtils.exists(app) ~= 'directory' then
        Log.error('Helper app missing at %s', app)
        return false, LOC('$$$/LRCScopes/Error/HelperMissing=The scopes helper app is missing from the plug-in folder:^n^1', app)
    end
    -- -g: don't bring the helper to the foreground (Lightroom keeps keyboard focus).
    -- -n: always a new instance, so it receives this port; the new instance tells
    --     any older one (connected to a socket that may no longer exist) to quit.
    -- -a with a path launches exactly this bundle, never another copy found by
    -- LaunchServices.
    local cmd = string.format('/usr/bin/open -n -g -a %s --args --port %d', shellQuote(app), port)
    local status = LrTasks.execute(cmd)
    if status ~= 0 then
        Log.error('Helper launch failed (status %s): %s', tostring(status), cmd)
        return false, LOC '$$$/LRCScopes/Error/LaunchFailed=The scopes helper app could not be started. See the plug-in log for details.'
    end
    Log.info('Helper launch requested')
    return true
end

return HelperLauncher

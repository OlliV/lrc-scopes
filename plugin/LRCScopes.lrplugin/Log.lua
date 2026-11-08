--[[ Shared logger.
Errors, warnings and info (rare lifecycle events: start/stop, helper launch,
connect/disconnect) always go to the log file; per-frame trace output only when
"Debug logging" is enabled in the Plug-in Manager. The file lives in Lightroom's plug-in log folder
(~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LRCScopes.log on current versions). ]]

local LrLogger = import 'LrLogger'
local LrPrefs = import 'LrPrefs'

local logger = LrLogger('LRCScopes')

local Log = {}

function Log.configure()
    local debug = LrPrefs.prefsForPlugin().debugLogging == true
    logger:disable()
    if debug then
        logger:enable('logfile')
    else
        logger:enable({ fatal = 'logfile', error = 'logfile', warn = 'logfile', info = 'logfile' })
    end
end

function Log.info(...) logger:infof(...) end
function Log.trace(...) logger:tracef(...) end
function Log.warn(...) logger:warnf(...) end
function Log.error(...) logger:errorf(...) end

Log.configure()

return Log

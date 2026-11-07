--[[ LrShutdownApp: Lightroom is quitting. Tell the helper to exit and return promptly. ]]

local ScopesService = require 'ScopesService'

return {
    LrShutdownFunction = function(doneFunction, progressFunction)
        local ok, err = pcall(ScopesService.shutdown)
        if not ok then
            -- Never block Lightroom's shutdown; the helper also exits on its own when
            -- Lightroom terminates.
            local Log = require 'Log'
            Log.error('Shutdown failed: %s', tostring(err))
        end
        doneFunction()
    end,
}

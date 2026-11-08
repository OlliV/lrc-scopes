--[[ Plug-in Manager section: preview resolution, logging, quick actions. ]]

local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Log = require 'Log'
local ScopesService = require 'ScopesService'

local function sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    local bind = LrView.bind

    propertyTable.previewSize = tonumber(prefs.previewSize) or 1024
    propertyTable.debugLogging = prefs.debugLogging == true
    propertyTable:addObserver('previewSize', function(_, _, value) prefs.previewSize = value end)
    propertyTable:addObserver('debugLogging', function(_, _, value)
        prefs.debugLogging = value
        Log.configure()
    end)

    return {
        {
            title = LOC '$$$/LRCScopes/Settings/Title=LRC Scopes',
            bind_to_object = propertyTable,

            f:static_text {
                title = LOC '$$$/LRCScopes/Settings/Intro=Shows an RGB waveform / parade and a vectorscope for the photo in the Develop module. Use File > Plug-in Extras > Show Scopes or Hide Scopes.',
                width_in_chars = 60,
                height_in_lines = 2,
            },
            f:row {
                f:static_text {
                    title = LOC '$$$/LRCScopes/Settings/PreviewSize=Analysis resolution:',
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:popup_menu {
                    value = bind 'previewSize',
                    items = {
                        { title = LOC '$$$/LRCScopes/Settings/Size/640=640 px (fastest)', value = 640 },
                        { title = LOC '$$$/LRCScopes/Settings/Size/1024=1024 px (recommended)', value = 1024 },
                        { title = LOC '$$$/LRCScopes/Settings/Size/1440=1440 px', value = 1440 },
                        { title = LOC '$$$/LRCScopes/Settings/Size/2048=2048 px (slowest)', value = 2048 },
                    },
                },
            },
            f:row {
                f:spacer { width = LrView.share 'label_width' },
                f:checkbox {
                    title = LOC '$$$/LRCScopes/Settings/Debug=Debug logging',
                    value = bind 'debugLogging',
                },
            },
            f:row {
                f:spacer { width = LrView.share 'label_width' },
                f:push_button {
                    title = LOC '$$$/LRCScopes/Settings/Show=Show Scopes',
                    action = function()
                        LrTasks.startAsyncTask(function()
                            local ok, reason = ScopesService.show()
                            if ok == false then
                                LrDialogs.message(LOC '$$$/LRCScopes/Error/Title=Scopes could not be shown', reason, 'critical')
                            end
                        end)
                    end,
                },
            },
        },
    }
end

return {
    sectionsForTopOfDialog = sectionsForTopOfDialog,
}

--[[----------------------------------------------------------------------------
LRC Scopes — RGB waveform / parade and vectorscope for the Develop module.

The plug-in watches the target photo and its develop settings, asks Lightroom for
a rendered preview whenever they change and hands it to the bundled native
"LRC Scopes" helper app, which draws the scopes in a floating panel.
------------------------------------------------------------------------------]]

return {
    LrSdkVersion = 14.0,
    LrSdkMinimumVersion = 10.0, -- requestJpegThumbnail (5.0), LrDevelopController observers

    LrToolkitIdentifier = 'com.lrcscopes.lightroom',
    LrPluginName = LOC '$$$/LRCScopes/PluginName=LRC Scopes',

    LrInitPlugin = 'Init.lua',
    LrForceInitPlugin = true, -- start with Lightroom, not on first menu use
    LrShutdownPlugin = 'Shutdown.lua',
    LrShutdownApp = 'ShutdownApp.lua',
    LrPluginInfoProvider = 'PluginInfoProvider.lua',

    -- File > Plug-in Extras (available in every module, including Develop).
    LrExportMenuItems = {
        { title = LOC '$$$/LRCScopes/Menu/Show=Show Scopes', file = 'ShowScopes.lua' },
        { title = LOC '$$$/LRCScopes/Menu/Hide=Hide Scopes', file = 'HideScopes.lua' },
    },

    VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}

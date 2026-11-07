--[[ LrInitPlugin: runs at Lightroom startup (LrForceInitPlugin) and on plug-in reload. ]]

local Log = require 'Log'
local ScopesService = require 'ScopesService'

Log.info('Plug-in initialising')
ScopesService.start()

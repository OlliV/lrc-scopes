--[[ File > Plug-in Extras > Hide Scopes ]]

local LrTasks = import 'LrTasks'

local ScopesService = require 'ScopesService'

LrTasks.startAsyncTask(function()
    ScopesService.hide()
end, 'LRCScopes.hide')

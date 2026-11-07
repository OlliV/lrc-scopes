--[[ File > Plug-in Extras > Show Scopes ]]

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local ScopesService = require 'ScopesService'

LrTasks.startAsyncTask(function()
    local ok, reason = ScopesService.show()
    if ok == false then
        LrDialogs.message(LOC '$$$/LRCScopes/Error/Title=Scopes could not be shown', reason, 'critical')
    end
end, 'LRCScopes.show')

local skynet = require "skynet"
local agent_boot = require "agent_components.agent_boot"

skynet.start(function()
    skynet.dispatch("lua", function(session, source, command, ...)
        local f = assert(agent_boot[command])
        skynet.ret(skynet.pack(f(source, ...)))
    end)
end)

local skynet = require "skynet"
local session = {}
local agent
local protocol
local rpc_handlers = {}

function session:init(a)
    agent = a
end

function session:bind_protocol(p)
    protocol = p
end

function session:use_rpc(rpc)
    rpc_handlers = rpc
end

function session:start()
    for name, system in pairs(agent.systems) do
        if system.rpc then
            for rpc_name, fn in pairs(system.rpc) do
                rpc_handlers[rpc_name] = fn
            end
        end
    end

    protocol:on_message(function(name, args)
        local handler = rpc_handlers[name]
        if handler then
            return handler(args)
        end
        return {}
    end)

    protocol:send("push", { channel = "system", content = "welcome " .. agent.uid })
    protocol:start_read_loop(function()
        skynet.error(string.format("[agent_layered] %s connection lost", agent.uid))
        self:shutdown()
        skynet.exit()
    end)
end

function session:shutdown()
    for name, system in pairs(agent.systems) do
        if system.save then
            local ok, err = agent.storage:save_component(name, system:save())
            if not ok then
                skynet.error(string.format("[agent_layered] failed to save system %s for %s: %s", name, agent.uid, tostring(err)))
            end
        end
    end
    for _, system in pairs(agent.systems) do
        if system.shutdown then
            system:shutdown()
        end
    end
    if agent.storage.shutdown then
        agent.storage:shutdown()
    end
end

return session

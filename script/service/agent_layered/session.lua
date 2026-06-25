local skynet = require "skynet"
local session = {}
local agent
local protocol

function session:init(a)
    agent = a
end

function session:bind_protocol(p)
    protocol = p
end

local function collect_rpc_methods(systems)
    local result = {}
    -- iterate each system (core, inventory, ...)
    for sys_name, sys in pairs(systems) do
        -- collect rpc_* methods from system itself
        for key, fn in pairs(sys) do
            if type(key) == "string" and key:sub(1, 4) == "rpc_" and type(fn) == "function" then
                local name = key:sub(5)   -- strip "rpc_" prefix
                result[name] = function(args)
                    return fn(sys, args)
                end
            end
        end
    end
    return result
end


function session:start()
    local rpc_handlers = collect_rpc_methods(agent.systems)

    protocol:on_message(function(name, args)
        -- sproto protocol names are "rpc_xxx" → strip prefix to match handler keys
        local handler_name = name
        if name:sub(1, 4) == "rpc_" then
            handler_name = name:sub(5)
        end
        local handler = rpc_handlers[handler_name]
        if handler then
            agent.log:debug("[agent_layered] rpc %s → %s", name, handler_name)
            return handler(args)
        end
        agent.log:warn("[agent_layered] unknown rpc: %s", name)
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

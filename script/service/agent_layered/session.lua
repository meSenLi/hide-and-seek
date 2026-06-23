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

function session:start()
    protocol:on_message(function(name, args)
        if name == "heartbeat" then
            return { time = os.time() }
        elseif name == "ping" then
            return { msg = args and args.msg or "" }
        elseif name == "echo" then
            return { content = args and args.content or "" }
        elseif name == "get_userinfo" then
            return { userid = agent.uid, subid = agent.subid, login_time = agent.login_time }
        else
            local system_result = nil
            if agent.systems.inventory and agent.systems.inventory.handle_request then
                system_result = agent.systems.inventory:handle_request(name, args)
            end
            return system_result or {}
        end
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

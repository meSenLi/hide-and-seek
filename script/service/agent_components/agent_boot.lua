local skynet = require "skynet"
local protocol = require "agent_components.protocol"
local component_manager = require "agent_components.component_manager"
local events = require "agent_components.events"
local storage = require "agent_components.storage"

local CMD = {}
local agent = {
    uid = nil,
    subid = nil,
    login_time = nil,
    protocol = protocol,
    events = events,
    storage = storage,
    components = component_manager,
}

local function init_components()
    local inventory = require "agent_components.components.inventory"
    component_manager:register("inventory", inventory, agent)
end

function CMD.start(source, conf)
    agent.uid = conf.uid
    agent.subid = tostring(conf.subid)
    agent.login_time = os.time()

    protocol:init({ client = conf.client, subid = agent.subid })
    events:init()
    storage:init(agent.uid)
    component_manager:init(agent)
    init_components()

    local function handle_request(name, args)
        if name == "ping" then
            return { msg = args and args.msg or "" }
        elseif name == "echo" then
            return { content = args and args.content or "" }
        elseif name == "get_userinfo" then
            return { userid = agent.uid, subid = agent.subid, login_time = agent.login_time }
        elseif name == "player.join" then
            events:publish("player.join", agent.uid)
            return { result = "joined" }
        else
            local result = component_manager:dispatch(name, args)
            if result ~= nil then
                return result
            end
        end
        return {}
    end

    protocol:on_message(function(name, args)
        return handle_request(name, args)
    end)

    protocol:send("push", { channel = "system", content = "welcome " .. agent.uid })
    events:publish("player.join", agent.uid)

    protocol:start_read_loop(function()
        skynet.error(string.format("[agent_components] %s connection lost", agent.uid))
        component_manager:shutdown_all()
        skynet.exit()
    end)
end

function CMD.disconnect(source)
    skynet.error(string.format("[agent_components] %s disconnected", agent.uid))
    component_manager:shutdown_all()
    skynet.exit()
end

function CMD.push(source, channel, content)
    protocol:send("push", { channel = channel, content = content })
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, command, ...)
        local f = assert(CMD[command])
        skynet.ret(skynet.pack(f(source, ...)))
    end)
end)

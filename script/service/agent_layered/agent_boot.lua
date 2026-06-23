local skynet = require "skynet"
local protocol = require "agent_layered.protocol"
local session = require "agent_layered.session"
local events = require "agent_layered.events"
local storage = require "agent_layered.storage"
local system_inventory = require "agent_layered.systems.inventory"

local CMD = {}
local agent = {
    uid = nil,
    subid = nil,
    login_time = nil,
    protocol = protocol,
    session = session,
    events = events,
    storage = storage,
    systems = {},
}

local rpc = {}

function rpc.heartbeat(args)
    return { time = os.time() }
end

function rpc.ping(args)
    return { msg = args and args.msg or "" }
end

function rpc.echo(args)
    return { content = args and args.content or "" }
end

function rpc.get_userinfo(args)
    return { userid = agent.uid, subid = agent.subid, login_time = agent.login_time }
end

local function init_systems()
    agent.systems.inventory = system_inventory
    system_inventory:init(agent)
    local inventory_state = storage:load_component("inventory")
    if inventory_state then
        system_inventory:load(inventory_state)
    end
end

function CMD.start(source, conf)
    agent.uid = conf.uid
    agent.subid = tostring(conf.subid)
    agent.login_time = os.time()

    protocol:init({ client = conf.client, subid = agent.subid })
    events:init()
    storage:init(agent.uid)
    session:init(agent)
    init_systems()

    session:bind_protocol(protocol)
    session:use_rpc(rpc)
    session:start()
end

function CMD.disconnect(source)
    skynet.error(string.format("[agent_layered] %s disconnected", agent.uid))
    session:shutdown()
    skynet.exit()
end

function CMD.push(source, channel, content)
    protocol:send("push", { channel = channel, content = content })
end

return CMD

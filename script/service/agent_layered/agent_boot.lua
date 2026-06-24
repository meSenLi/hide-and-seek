local skynet = require "skynet"
local logger = require "agent_layered.logger"
local protocol = require "agent_layered.protocol"
local session = require "agent_layered.session"
local events = require "agent_layered.events"
local storage = require "agent_layered.storage"
local system_core = require "agent_layered.systems.core"
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

local function init_systems()
    agent.systems.core = system_core
    agent.systems.inventory = system_inventory

    for name, system in pairs(agent.systems) do
        local state = storage:load_component(name)
        if system.init then
            system:init(agent, state)
        end
    end

    for _, system in pairs(agent.systems) do
        if system.init_finish then
            system:init_finish()
        end
    end
end

function CMD.start(source, conf)
    agent.uid = conf.uid
    agent.subid = tostring(conf.subid)
    agent.login_time = os.time()
    agent.log = logger.new(string.format("[agent:%s]", agent.uid), logger.LEVEL.DEBUG)

    protocol:init({ client = conf.client, subid = agent.subid })
    events:init()
    storage:init(agent.uid)
    session:init(agent)
    init_systems()

    session:bind_protocol(protocol)
    session:start()

    agent.systems.core:onLogin()
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

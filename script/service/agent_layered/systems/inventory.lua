local base = require "agent_layered.systems.base"
local event_const = require "agent_layered.systems.event_const"

local inventory = base.new {
    items = {},


    __fields__ = {
        items = { persist = true, sync = true },
    },
}

function inventory:rpc_add_item(args)
    if args and args.id then
        self.items[args.id] = { id = args.id, name = args.name }
        return { ok = 1 }
    end
    return { ok = 0 }
end

function inventory:rpc_get_inventory(args)
    return { count = #self.items }
end

function inventory:init(agent, state)
    self.super.init(self, agent, state)
end

function inventory:init_finish()
    self.agent.events:subscribe(event_const.EVENT_LOGIN, function(uid)
        self.log:info("user login, uid: %s", uid)
        print('user login, uid finish!!!!!!!!!!!!!!!!!!')
    end)
end

function inventory:shutdown()
    self.items = nil
    self.super.shutdown(self)
end

return inventory

local base = require "agent_layered.systems.base"

local inventory = base.new {
    items = {},         -- 公开 + 存盘
}

inventory.save_interval = 60000

inventory.rpc = {}

function inventory.rpc.add_item(args)
    if args and args.id then
        inventory.items[args.id] = { id = args.id, name = args.name }
        return { ok = 1 }
    end
    return { ok = 0 }
end

function inventory.rpc.get_inventory(args)
    return { count = #inventory.items }
end

function inventory:init(agent)
    self.super.init(self, agent)
    self.items = {}
    self._agent.events:subscribe("player.join", function(uid)
        if uid == self._agent.uid then
            self._agent.protocol:send("push", {
                channel = "inventory", content = "inventory ready"
            })
        end
    end)
end

function inventory:save()
    return { items = self.items }
end

function inventory:load(state)
    if state and state.items then self.items = state.items end
end

function inventory:shutdown()
    self.items = nil
    self.super.shutdown(self)
end

return inventory

local skynet = require "skynet"

local inventory = {
    items = {},
    agent = nil,
}

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

-- ====== lifecycle ======
function inventory:init(agent)
    self.agent = agent
    self.items = {}
    self.agent.events:subscribe("player.join", function(uid)
        if uid == self.agent.uid then
            self.agent.protocol:send("push", { channel = "inventory", content = "inventory ready" })
        end
    end)
end

function inventory:save()
    return { items = self.items }
end

function inventory:load(state)
    if state and state.items then
        self.items = state.items
    end
end

function inventory:shutdown()
    self.items = nil
    self.agent = nil
end

return inventory

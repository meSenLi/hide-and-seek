local inventory = {
    _module_name = "agent_components.components.inventory",
}

function inventory:init(agent)
    self.agent = agent
    self.items = self.items or {}
    agent.events:subscribe("player.join", function(uid)
        if uid == self.agent.uid then
            self.agent.protocol:send("push", { channel = "system", content = "inventory ready" })
        end
    end)
end

function inventory:handle_event(name, args)
    if name == "add_item" then
        local item = args.item
        self.items[item.id] = item
        self.agent.protocol:send("push", { channel = "inventory", content = "added " .. tostring(item.id) })
    end
end

function inventory:handle_request(name, args)
    if name == "add_item" then
        local item = args and args.item or {}
        if item.id then
            self.items[item.id] = item
            return { ok = true, added = item.id }
        end
        return { ok = false }
    elseif name == "get_inventory" then
        return { items = self.items }
    end
    return nil
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

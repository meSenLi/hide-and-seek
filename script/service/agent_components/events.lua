local events = {}
local subscribers = {}
local next_id = 0

function events:init()
    subscribers = {}
    next_id = 0
end

function events:subscribe(topic, fn)
    next_id = next_id + 1
    local id = next_id
    subscribers[id] = { topic = topic, fn = fn }
    return id
end

function events:unsubscribe(id)
    subscribers[id] = nil
end

function events:publish(topic, ...)
    for _, entry in pairs(subscribers) do
        if entry.topic == topic then
            local ok, err = pcall(entry.fn, ...)
            if not ok then
                print(string.format("[agent_components.events] handler error for topic %s: %s", topic, tostring(err)))
            end
        end
    end
end

return events

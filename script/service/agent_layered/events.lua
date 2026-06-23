local skynet = require "skynet"
local events = {}
local subscribers = {}
local dispatching = false
local dispatch_queue = {}
local dispatch_count = 0
local max_dispatch_count = 1000

function events:init()
    subscribers = {}
    dispatching = false
    dispatch_queue = {}
    dispatch_count = 0
end

function events:subscribe(topic, fn)
    if type(topic) ~= "string" then
        error("events:subscribe topic must be a string")
    end
    if type(fn) ~= "function" then
        error("events:subscribe callback must be a function")
    end
    local list = subscribers[topic]
    if not list then
        list = {}
        subscribers[topic] = list
    end
    table.insert(list, fn)
    return fn
end

function events:unsubscribe(topic, fn)
    if type(topic) ~= "string" then
        return
    end
    local list = subscribers[topic]
    if not list then
        return
    end
    if not fn then
        subscribers[topic] = nil
        return
    end
    for i = #list, 1, -1 do
        if list[i] == fn then
            table.remove(list, i)
        end
    end
    if #list == 0 then
        subscribers[topic] = nil
    end
end

local function dispatch_event(topic, args)
    local list = subscribers[topic]
    if not list then
        return
    end
    local handlers = { table.unpack(list) }
    for _, fn in ipairs(handlers) do
        dispatch_count = dispatch_count + 1
        if dispatch_count > max_dispatch_count then
            skynet.error(string.format("[agent_layered.events] dispatch overflow for topic %s, possible recursive loop", tostring(topic)))
            break
        end
        local ok, err = pcall(fn, table.unpack(args))
        if not ok then
            skynet.error(string.format("[agent_layered.events] handler error for topic %s: %s", tostring(topic), tostring(err)))
        end
    end
end

function events:publish(topic, ...)
    if type(topic) ~= "string" then
        error("events:publish topic must be a string")
    end
    if dispatching then
        table.insert(dispatch_queue, { topic = topic, args = { ... } })
        return
    end
    dispatching = true
    dispatch_event(topic, { ... })
    while #dispatch_queue > 0 do
        local item = table.remove(dispatch_queue, 1)
        dispatch_event(item.topic, item.args)
    end
    dispatching = false
    if dispatch_count > max_dispatch_count then
        dispatch_count = 0
    end
end

return events

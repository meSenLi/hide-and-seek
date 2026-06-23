local skynet = require "skynet"
local storage = {}
local uid

function storage:init(user_id)
    uid = tostring(user_id)
end

function storage:save_component(name, state)
    local ok, err = skynet.call("agentdb", "lua", "save_component", uid, name, state)
    if not ok then
        skynet.error(string.format("[agent_layered.storage] save_component failed for %s@%s: %s", name, uid, tostring(err)))
        return nil, err
    end
    return true
end

function storage:load_component(name)
    return skynet.call("agentdb", "lua", "load_component", uid, name)
end

return storage

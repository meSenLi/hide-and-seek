local component_manager = {}
local components = {}
local agent_ref

function component_manager:init(agent)
    agent_ref = agent
    components = {}
end

function component_manager:register(name, component, agent)
    local module = component
    local instance
    if type(component) == "table" and component.init then
        instance = {}
        for k, v in pairs(component) do
            instance[k] = v
        end
        instance._module_name = component._module_name or component._name
        instance.agent = agent or agent_ref
        if instance.init then
            instance:init(instance.agent)
        end
    else
        instance = component
    end
    components[name] = instance
    return instance
end

function component_manager:get(name)
    return components[name]
end

function component_manager:dispatch(name, args)
    for _, comp in pairs(components) do
        if comp.handle_request then
            local ok, result = pcall(comp.handle_request, comp, name, args)
            if ok and result ~= nil then
                return result
            elseif not ok then
                skynet.error(string.format("[agent_components.component_manager] component %s handle_request error: %s", tostring(comp._module_name), tostring(result)))
            end
        end
    end
    return nil
end

function component_manager:unregister(name)
    local comp = components[name]
    if comp and comp.shutdown then
        comp:shutdown()
    end
    components[name] = nil
end

function component_manager:reload(name)
    local comp = components[name]
    if not comp then
        return nil, "not found"
    end
    local state
    if comp.save then
        state = comp:save()
    end
    if comp.shutdown then
        comp:shutdown()
    end
    package.loaded[comp._module_name] = nil
    local new_comp = require(comp._module_name)
    new_comp._module_name = comp._module_name
    new_comp.agent = comp.agent
    if new_comp.load and state then
        new_comp:load(state)
    end
    if new_comp.init then
        new_comp:init(new_comp.agent)
    end
    components[name] = new_comp
    return new_comp
end

function component_manager:shutdown_all()
    for name, comp in pairs(components) do
        if comp.shutdown then
            comp:shutdown()
        end
        components[name] = nil
    end
end

return component_manager

local storage = {}
local root_path = "/tmp/agent_components"
local uid

local function ensure_dir(path)
    os.execute("mkdir -p " .. path)
end

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local parts = {"{\n"}
        for k, v in pairs(value) do
            local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            table.insert(parts, indent .. "  " .. key .. " = " .. serialize(v, indent .. "  ") .. ",\n")
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    else
        return string.format("%q", tostring(value))
    end
end

local function filename(name)
    return string.format("%s/%s_%s.lua", root_path, uid or "unknown", name)
end

function storage:init(user_id)
    uid = tostring(user_id)
    ensure_dir(root_path)
end

function storage:save_component(name, state)
    local fn = filename(name)
    local file, err = io.open(fn, "w")
    if not file then
        return nil, err
    end
    file:write("return " .. serialize(state))
    file:close()
    return true
end

function storage:load_component(name)
    local fn = filename(name)
    local ok, data = pcall(dofile, fn)
    if ok then
        return data
    end
    return nil
end

return storage

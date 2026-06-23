-- script/service/agentdb.lua
-- Agent 状态持久化服务 — 统一 MongoDB 访问

local skynet = require "skynet"
require "skynet.manager"
local mongo = require "skynet.db.mongo"
local bson = require "bson"
local config = require "config.mongo"

local db
local collection
local collection_name = "agent_state"

local function ensure_collection()
    if collection then
        return
    end
    local client = mongo.client({ host = config.host, port = config.port })
    db = client[config.db]
    collection = db[collection_name]
    collection:ensureIndex({ uid = 1 }, { component = 1 }, { unique = true, name = "agent_component_uid_idx" })
    skynet.error(string.format("[agentdb] connected to mongodb://%s:%d/%s, collection=%s", config.host, config.port, config.db, collection_name))
end

local function save_component(uid, component, state)
    if not collection then
        return nil, "storage_not_initialized"
    end
    local doc = {
        uid = uid,
        component = component,
        state = state or {},
        updated_at = os.time(),
    }
    local ok, err = collection:safe_update(
        { uid = uid, component = component },
        { ["$set"] = doc },
        true,
        false
    )
    if not ok then
        skynet.error(string.format("[agentdb] save_component failed for %s@%s: %s", uid, component, tostring(err)))
        return nil, err
    end
    return true
end

local function load_component(uid, component)
    if not collection then
        return nil, "storage_not_initialized"
    end
    local doc = collection:findOne({ uid = uid, component = component })
    if doc and doc.state then
        return doc.state
    end
    return nil
end

local CMD = {}

function CMD.save_component(uid, component, state)
    return save_component(uid, component, state)
end

function CMD.load_component(uid, component)
    return load_component(uid, component)
end

skynet.start(function()
    ensure_collection()

    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd], "Unknown command: " .. tostring(cmd))
        skynet.ret(skynet.pack(f(...)))
    end)

    skynet.register("agentdb")
    skynet.error("[agentdb] service started")
end)

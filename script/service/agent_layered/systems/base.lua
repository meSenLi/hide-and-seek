-- script/service/agent_layered/systems/base.lua
-- 系统基类 — 所有游戏系统（inventory/skill/mail 等）从此继承
--
-- 数据规则：
--   1. __fields__ 表定义哪些字段需要持久化/同步
--   2. save_interval → ms，自动存盘间隔；nil = 仅退出时存
--
-- 用法:
--   local base = require "agent_layered.systems.base"
--   local mysys = base.new {
--       data = {},        
--       gold = 0,         
--       agent = nil,      --（基类 init/shutdown 自动管理）
--       __fields__ = {
--           data = { persist = true, sync = true },
--           gold = { persist = true },
--       }
--   }
--   mysys.rpc = {}       -- 可选，默认已有空表
--   mysys.save_interval = 600
--   function mysys:load(state) ... end  -- 可选，默认实现会将 state 中持久字段赋值给 self

local skynet = require "skynet"

local base = {}

base.rpc = {}                -- 空 RPC 表，子类直接使用
base.save_interval = 60000   -- 子类覆盖为数值则自动存盘

local function normalize_field_meta(meta)
    if meta == nil then
        return { persist = false, sync = false }
    end
    if type(meta) == "boolean" then
        return { persist = meta, sync = meta }
    end
    if type(meta) == "table" then
        if meta.persist == nil then
            meta.persist = false
        end
        if meta.sync == nil then
            meta.sync = false
        end
        return meta
    end
    return { persist = false, sync = false }
end

local function collect_persist_fields(self)
    local result = {}
    if not self.__fields__ then
        return result
    end
    for key, meta in pairs(self.__fields__) do
        local field_meta = normalize_field_meta(meta)
        if field_meta.persist then
            result[key] = field_meta
        end
    end
    return result
end

local function collect_rpc_methods(self)
    local result = {}
    if self.rpc then
        for name, fn in pairs(self.rpc) do
            if type(fn) == "function" then
                result[name] = fn
            end
        end
    end
    for key, fn in pairs(self) do
        if type(key) == "string" and key:sub(1, 4) == "rpc_" and type(fn) == "function" then
            local name = key:sub(5)
            result[name] = function(...)
                return fn(self, ...)
            end
        end
    end
    return result
end

-- ====== lifecycle ======

function base:init(agent, state)
    self.agent = agent
    self.log = agent and agent.log or nil
    self._timers = {}
    self._timer_id = 0
    self.rpc = collect_rpc_methods(self)
    if state then
        self:load(state)
    end
end

function base:save()
    local data = {}
    local __fields__ = collect_persist_fields(self)
    for key in pairs(__fields__) do
        data[key] = self[key]
    end
    return data
end

function base:load(state)
    if not state then
        return
    end
    local __fields__ = collect_persist_fields(self)
    if not next(__fields__) then
        return
    end
    for key in pairs(__fields__) do
        if state[key] ~= nil then
            self[key] = state[key]
        end
    end
end

function base:init_finish()
    -- 子类覆盖
end

function base:shutdown()
    if self._timers then
        for id in pairs(self._timers) do
            self:cancel_timer(id)
        end
    end
    self.agent = nil
end

--- 添加定时器
-- @param delay_sec  number  延迟/间隔，单位秒
-- @param fn         func    回调(self, ...)
-- @param recurring  bool    是否循环（默认 false）
-- @param ...                传给回调的额外参数
-- @return integer   timer_id
function base:add_timer(delay_sec, fn, recurring, ...)
    if recurring == nil then recurring = false end
    self._timer_id = self._timer_id + 1
    local id = self._timer_id
    local t = { cancelled = false }
    self._timers[id] = t
    local args = { ... }
    local ms = delay_sec * 100
    skynet.fork(function()
        if recurring then
            while not t.cancelled do
                skynet.sleep(ms)
                if not t.cancelled then fn(self, table.unpack(args)) end
            end
        else
            skynet.sleep(ms)
            if not t.cancelled then fn(self, table.unpack(args)) end
        end
    end)
    return id
end

function base:cancel_timer(id)
    local t = self._timers[id]
    if t then
        t.cancelled = true
        self._timers[id] = nil
    end
end

-- ====== factory ======

function base.new(t)
    t = t or {}
    if not t.rpc then t.rpc = {} end
    t.super = base
    return setmetatable(t, { __index = base })
end

return base

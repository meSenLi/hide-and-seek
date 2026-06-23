-- script/service/agent_layered/systems/base.lua
-- 系统基类 — 所有游戏系统（inventory/skill/mail 等）从此继承
--
-- 数据规则：
--   1. `_` 前缀 → 私有字段，不下发客户端（decorator.public() 自动过滤）
--   2. 无 `_` 前缀 → 公开字段，可同步到客户端
--   3. save() 返回值 → 决定哪些数据存盘（公开私有都可以）
--   4. save_interval → ms，自动存盘间隔；nil = 仅退出时存
--
-- 用法:
--   local base = require "agent_layered.systems.base"
--   local mysys = base.new {
--       data = {},        -- 公开 + 存盘
--       gold = 0,         -- 公开 + 存盘
--       _agent = nil,     -- 私有引用（基类 init/shutdown 自动管理）
--   }
--   mysys.rpc = {}       -- 可选，默认已有空表
--   mysys.save_interval = 60000
--   function mysys:save() return { data = self.data, gold = self.gold } end
--   function mysys:load(state) ... end

local skynet = require "skynet"

local base = {}

base.rpc = {}                -- 空 RPC 表，子类直接使用
base.save_interval = 60000   -- 子类覆盖为数值则自动存盘

-- ====== lifecycle ======

function base:init(agent)
    self._agent = agent
    self._timers = {}
    self._timer_id = 0
end

function base:save()
    return {}
end

function base:load(state)
    -- 子类覆盖
end

function base:shutdown()
    if self._timers then
        for id in pairs(self._timers) do
            self:cancel_timer(id)
        end
    end
    self._agent = nil
end

--- 添加定时器
-- @param delay_sec  number  延迟/间隔，单位秒
-- @param fn         func    回调(self, ...)
-- @param repeat     bool    是否循环（默认 false）
-- @param ...                传给回调的额外参数
-- @return integer   timer_id
function base:add_timer(delay_sec, fn, repeat, ...)
    if repeat == nil then repeat = false end
    self._timer_id = self._timer_id + 1
    local id = self._timer_id
    local t = { cancelled = false }
    self._timers[id] = t
    local args = { ... }
    local ms = delay_sec * 100
    skynet.fork(function()
        if repeat then
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

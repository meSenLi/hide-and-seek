-- script/service/agent_layered/systems/core.lua
-- Agent 核心系统：承载框架级 RPC 和元信息查询

local skynet = require "skynet"
local base = require "agent_layered.systems.base"
local event_const = require "agent_layered.systems.event_const"


local AgentState = {
    INITIALIZING = 0,
    RELAYING = 1,
    NORMAL = 2,
    WAIT_RELAYING = 4,
    LOGOUT = 5,
}

local core = base.new {
    status = AgentState.INITIALIZING,
    nickname = "",


    __fields__ = {
        status = { persist = false, sync = true },
        nickname = { persist = true, sync = true },
    },
}

function core:init(agent, state)
    self.super.init(self, agent, state)
end

function core:on_login()
    self.status = AgentState.NORMAL
    self.agent.events:publish(event_const.EVENT_LOGIN, self.agent.uid)
    self.log:info("agent %s login", self.agent.uid)
    self:add_timer(5, self.rpc_heart_beat, true)
end



function core:rpc_change_nickname(nickname)
    if self.nickname ~= nickname then
        local old_nickname = self.nickname
        self.nickname = nickname
        self.log.info("change nickname: %s -> %s", old_nickname, self.nickname)
    end
end







function core:rpc_heart_beat(args)
    return { time = os.time() }
end

function core:rpc_ping(args)
    return { msg = args and args.msg or "" }
end

function core:rpc_echo(args)
    return { content = args and args.content or "" }
end

function core:rpc_get_user_info(args)
    return { userid = core.agent.uid, subid = core.agent.subid, login_time = core.agent.login_time }
end

return core

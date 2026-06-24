-- script/service/agent_layered/decorator.lua
-- 装饰器工具 — 限流等
-- RPC 直接用普通表 {} 即可，session 自动收集

local decorator = {}
local skynet = require "skynet"

function decorator.rate_limit(limit, window_ms)
	return function(fn)
		local count = 0
		local reset_at = 0
		return function(...)
			local now = skynet.now()
			if now >= reset_at then
				count = 0
				reset_at = now + math.ceil(window_ms / 10)
			end
			count = count + 1
			if count > limit then
				return { error = "rate_limit_exceeded" }
			end
			return fn(...)
		end
	end
end

return decorator

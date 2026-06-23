-- script/main.lua
-- 躲猫猫派对游戏 — 入口服务
-- 启动：./skynet

local skynet = require "skynet"
local config = require "config.config"

skynet.start(function()
	skynet.error("=" .. string.rep("=", 50))
	skynet.error("  躲猫猫派对游戏服务器启动中...")
	skynet.error("=" .. string.rep("=", 50))

	skynet.error("[main] starting accountdb...")
	local adb = skynet.newservice("accountdb")

	skynet.error("[main] starting agentdb...")
	skynet.newservice("agentdb")

	skynet.error("[main] starting protoloader...")
	skynet.newservice("protoloader")

	pcall(skynet.newservice, "debug_console", 8000)

	skynet.error(string.format("[main] starting gated (port %d)...", config.gate_port))
	local gated = skynet.newservice("gated")
	skynet.call(gated, "lua", "open", {
		port = config.gate_port,
		maxclient = config.gate_maxclient,
	}, adb)

	skynet.error("=" .. string.rep("=", 50))
	skynet.error(string.format("  服务器启动完成！端口: %d", config.gate_port))
	skynet.error("=" .. string.rep("=", 50))

	skynet.exit()
end)

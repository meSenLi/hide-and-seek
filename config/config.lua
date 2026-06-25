-- config/config.lua
-- 躲猫猫派对游戏 — 统一配置
-- 同时作为 skynet 启动配置 和 游戏业务配置模块
-- 启动: ./skynet

root = "./"
luaservice = root.."service/?.lua;"..root.."script/?.lua;"..root.."script/service/?.lua"
lualoader = root .. "lualib/loader.lua"
lua_path = root.."?.lua;"..root.."lualib/?.lua;"..root.."lualib/?/init.lua;"..root.."script/?.lua;"..root.."script/service/?.lua"
lua_cpath = root .. "bin/linux/luaclib/?.so"
snax = root.."service/?.lua;"..root.."script/service/?.lua"
cpath = root.."bin/linux/cservice/?.so"

thread = 8
harbor = 0

logger = "log/game.log"

start = "main"
bootstrap = "snlua bootstrap"
daemon = "./bin/linux/skynet.pid"
-- ======== 游戏业务配置 ========
local M = {}

M.mongo = {
	host = "127.0.0.1",
	port = 27017,
	db = "hideandseek",
}

M.login_port = 8001
M.gate_port = 8888
M.gate_maxclient = 512
M.gate_name = "hideandseek"

M.multilogin = false

-- 协议 slot 分配（protoloader 与各服务共用）
M.proto_slot = {
	common = 1,
	login  = 2,
	game   = 3,
	push   = 4,
}

return M

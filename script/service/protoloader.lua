-- script/service/protoloader.lua
-- 协议加载器：将 config/proto/*.sproto 文件加载到全局 slot
-- 其他服务通过 sprotoloader.load(slot) 获取协议对象

local skynet = require "skynet"
local sprotoparser = require "sprotoparser"
local sprotoloader = require "sprotoloader"

-- 协议文件列表 { 文件名, slot_id }
local proto_files = {
	{ "config/proto/common.sproto", 1 },
	{ "config/proto/login.sproto",  2 },
}

skynet.start(function()
	for _, entry in ipairs(proto_files) do
		local filename, slot = entry[1], entry[2]
		local f = assert(io.open(filename), "Can't open " .. filename)
		local data = f:read("a")
		f:close()
		local sp = sprotoparser.parse(data)
		sprotoloader.save(sp, slot)
		skynet.error("[protoloader] loaded " .. filename .. " -> slot " .. slot)
	end
	skynet.error("[protoloader] all protocols loaded, keeping service alive")
	-- 不调用 skynet.exit()，保持服务存活以维持全局 slot 有效
end)

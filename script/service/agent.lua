-- script/service/agent.lua
-- 玩家会话服务：接管已鉴权的连接，登录后走 sproto 二进制 RPC
-- 对外命令：start（由 gated 调用启动）、disconnect、push（主动推送）

local skynet = require "skynet"
local socket = require "skynet.socket"
local sprotoloader = require "sprotoloader"
local config = require "config.config"

local slot = config.proto_slot
local client_fd, userid, subid, login_time
local host    -- 解客户端请求（c2s）
local sender  -- 打包服务端推送（s2c）

local CMD = {}
local RPC = {}	-- ★协议白名单：只有这里定义的请求才被受理

-- ====== 帧收发：2 字节大端长度 + sproto 包体 ======
local function send_frame(body)
	socket.write(client_fd, string.pack(">s2", body))
end

local function read_packet(fd)
	local h = socket.read(fd, 2)
	if not h then return nil end
	local sz = string.unpack(">I2", h)
	return socket.read(fd, sz)
end

-- ====== RPC 处理函数 ======
function RPC.heartbeat()
	return { time = os.time() }
end

function RPC.ping(args)
	return { msg = args and args.msg or "" }
end

function RPC.echo(args)
	return { content = args and args.content or "" }
end

function RPC.get_userinfo()
	return { userid = userid, subid = subid, login_time = login_time }
end

-- ====== 主动推送 ======
local function push(channel, content)
	if not sender then return end
	send_frame(sender("push", { channel = channel, content = content }, nil))
end

-- 处理一条客户端消息
local function handle_message(body)
	local ok, t, name, args, response = pcall(host.dispatch, host, body)
	if not ok then
		skynet.error(string.format("[agent] %s reject undecodable packet: %s", userid, tostring(t)))
		return
	end
	if t == "REQUEST" then
		local f = RPC[name]
		if not f then
			skynet.error(string.format("[agent] %s reject unknown rpc: %s", userid, tostring(name)))
			return
		end
		local ret = f(args)
		if response then
			send_frame(response(ret))
		end
	end
	-- RESPONSE（针对服务端 push 的回复）：当前 push 无 response，忽略
end

function CMD.start(source, conf)
	client_fd = conf.client
	userid = conf.uid
	subid = tostring(conf.subid)
	login_time = os.time()

	local crypt = require "skynet.crypt"
	host = sprotoloader.load(slot.game):host "package"
	sender = host:attach(sprotoloader.load(slot.push))

	socket.start(client_fd)
	-- 鉴权分界：仍以文本行发送 200；之后切换为 sproto 帧
	socket.write(client_fd, "200 " .. crypt.base64encode(subid) .. "\n")
	skynet.error(string.format("[agent] %s started, fd=%d (sproto rpc)", userid, client_fd))

	skynet.fork(function()
		push("system", "welcome " .. userid)
		while true do
			local body = read_packet(client_fd)
			if not body then
				skynet.error("[agent] " .. userid .. " connection lost")
				skynet.exit()
				return
			end
			handle_message(body)
		end
	end)
end

function CMD.disconnect(source)
	skynet.error(string.format("[agent] %s disconnected", userid))
	skynet.exit()
end

-- 供其他服务主动推送：skynet.send(agent, "lua", "push", channel, content)
function CMD.push(source, channel, content)
	push(channel, content)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, command, ...)
		local f = assert(CMD[command])
		skynet.ret(skynet.pack(f(source, ...)))
	end)
end)

-- client/main.lua
-- 躲猫猫派对 — 交互式终端客户端
-- 鉴权阶段：文本 DH 握手；登录后：sproto 二进制 RPC（2 字节长度帧）
-- 命令：
--   login [账号 密码]   登录；省略则随机生成并注册
--   register 账号 密码  注册并登录
--   登录后：ping [msg] / echo <text> / info / heartbeat / help / quit

package.path = "lualib/?.lua;" .. package.path
package.cpath = "bin/luaclib/?.so"

local s = require "client.socket"
local c = require "client.crypt"
local sproto = require "sproto"

local HOST, PORT, SVR = "127.0.0.1", 8888, "hideandseek"

math.randomseed(os.time())

-- ====== sproto ======
local function readfile(path)
	local f = assert(io.open(path, "r"))
	local d = f:read("a"); f:close(); return d
end

local game_sp = sproto.parse(readfile("config/proto/game.sproto"))	-- c2s 请求
local push_sp = sproto.parse(readfile("config/proto/push.sproto"))	-- s2c 推送
local host = push_sp:host "package"		-- 解服务端响应/推送
local request = host:attach(game_sp)	-- 打包客户端请求

-- ====== network ======
local L = ""	-- 接收缓冲（鉴权文本 + 登录后二进制共用）

-- 文本：阻塞读一行（鉴权用）
local function readline(fd)
	while true do
		local n = L:find("\n", 1, true)
		if n then local l = L:sub(1, n-1); L = L:sub(n+1); return l end
		local d = s.recv(fd)
		if not d then s.usleep(100)
		elseif d == "" then error("closed")
		else L = L .. d end
	end
end

local function sendline(fd, t) s.send(fd, t .. "\n") end

-- 二进制：非阻塞解析一帧（2 字节大端长度 + sproto 包体）
-- 返回 包体 或 nil；连接关闭时第二返回值为 true
local function poll_frame(fd)
	local d = s.recv(fd)
	if d == "" then return nil, true end
	if d then L = L .. d end
	if #L < 2 then return nil end
	local sz = string.unpack(">I2", L:sub(1, 2))
	if #L < 2 + sz then return nil end
	local body = L:sub(3, 2 + sz)
	L = L:sub(3 + sz)
	return body
end

-- ====== DH auth ======
local function auth(fd, user, pass, reg)
	local ch = c.base64decode(readline(fd))
	local ck = c.randomkey(); sendline(fd, c.base64encode(c.dhexchange(ck)))
	local sec = c.dhsecret(c.base64decode(readline(fd)), ck)
	sendline(fd, c.base64encode(c.hmac64(ch, sec)))
	local tp
	if reg then tp = string.format("%s@%s:register:%s", c.base64encode(user), c.base64encode(SVR), c.base64encode(pass))
	else tp = string.format("%s@%s:%s", c.base64encode(user), c.base64encode(SVR), c.base64encode(pass)) end
	sendline(fd, c.base64encode(c.desencode(sec, tp)))
	local result = readline(fd)
	local code = tonumber(string.sub(result, 1, 3))
	local subid = code == 200 and c.base64decode(string.sub(result, 5)) or nil
	return code, subid
end

-- ====== helpers ======
local function split(str)
	local t = {}
	for w in str:gmatch("%S+") do t[#t+1] = w end
	return t
end

local function random_cred()
	return "guest" .. math.random(100000, 999999), tostring(math.random(100000, 999999))
end

local function dump(t)
	if type(t) ~= "table" then return tostring(t) end
	local p = {}
	for k, v in pairs(t) do p[#p+1] = string.format("%s=%s", k, tostring(v)) end
	return "{" .. table.concat(p, ", ") .. "}"
end

local function print_help()
	print("命令: login [账号 密码] | register 账号 密码 | help | quit")
	print("登录后: ping [msg] | echo <text> | info | heartbeat")
end

-- ====== 登录态 + RPC ======
local fd
local logged_user
local session = 0
local pending = {}    -- session -> 请求名
local client = {}
local client_rpc_handlers = {}
local client_rpc_discovered = false

local function discover_client_rpc_handlers()
    client_rpc_handlers = {}
    for name, fn in pairs(client) do
        if type(name) == "string" and name:sub(1, 8) == "on_rpc_" and type(fn) == "function" then
            client_rpc_handlers[name:sub(8)] = fn
        end
    end
    client_rpc_discovered = true
end

local function ensure_client_rpc_handlers()
    if not client_rpc_discovered then
        discover_client_rpc_handlers()
    end
end

function client.on_rpc_push(args)
    print(string.format("\n<<< [push:%s] %s", tostring(args and args.channel or "unknown"), tostring(args and args.content or "")))
end

local function send_request(name, args)
	session = session + 1
	pending[session] = name
	s.send(fd, string.pack(">s2", request(name, args or {}, session)))
end

-- 处理服务器发来的一帧
local function on_frame(body)
	local ok, typ, p2, p3 = pcall(host.dispatch, host, body)
	if not ok then
		print("\n[!] 无法解码服务器消息: " .. tostring(typ))
		return
	end
	if typ == "RESPONSE" then
		local name = pending[p2] or "?"
		pending[p2] = nil
		print(string.format("\n<<< [%s] %s", name, dump(p3)))
	elseif typ == "REQUEST" then
		ensure_client_rpc_handlers()
		local handler = client_rpc_handlers[p2]
		if handler then
			local ok, err = pcall(handler, p3)
			if not ok then
				print(string.format("\n[client on_rpc error] %s", tostring(err)))
			end
		else
			print(string.format("\n<<< [push] %s", dump(p3)))
		end
	end
	io.write("> "); io.flush()
end

local function do_login(user, pass, reg)
	print(string.format("连接 %s:%d ...", HOST, PORT))
	local nfd = s.connect(HOST, PORT)
	if not nfd then print("连接失败"); return end
	L = ""
	local ok, code, subid = pcall(auth, nfd, user, pass, reg)
	if not ok then print("认证异常: " .. tostring(code)); s.close(nfd); return end
	if code == 200 then
		fd = nfd; logged_user = user	-- 注意：保留 L（welcome push 可能已到达）
		print(string.format("登录成功! 账号=%s subid=%s", user, tostring(subid)))
		print("可用 RPC: ping / echo / info / heartbeat，quit 退出。")
	else
		print("登录失败 code=" .. tostring(code)); s.close(nfd)
	end
end

local function str2table(str)
    local f = load("return " .. str)
    if not f then return nil, "parse error" end
    local ok, ret = pcall(f)
    if not ok then return {} end
    return ret
end

-- 登录后命令 → RPC
local function handle_rpc(cmd)
	local t = split(cmd)
	local op = t[1]
	if op == "ping" then
		send_request("ping", { msg = t[2] or "ping" })
	elseif op == "echo" then
		send_request("echo", { content = cmd:match("^%s*echo%s+(.*)") or "" })
	elseif op == "info" then
		send_request("get_userinfo", {})
	elseif op == "heartbeat" or op == "hb" then
		send_request("heartbeat", {})
	elseif op == "help" then
		print_help()
	elseif op == nil then
		-- 空行
	else
		send_request(op, str2table(t[2]))
	end
end

-- 未登录命令
local function handle_pre_login(cmd)
	local t = split(cmd)
	local op = t[1]
	if op == "login" then
		if t[2] and t[3] then do_login(t[2], t[3], false)
		elseif not t[2] and not t[3] then
			local u, p = random_cred()
			print(string.format("随机生成账号: %s / 密码: %s", u, p))
			do_login(u, p, true)
		else print("用法: login [账号 密码]  (不填则随机生成)") end
	elseif op == "register" then
		if t[2] and t[3] then do_login(t[2], t[3], true)
		else print("用法: register 账号 密码") end
	elseif op == "help" then print_help()
	elseif op == nil then
	else print("未登录。请先 login，或输入 help 查看命令") end
end

-- ====== main loop ======
print("===== 躲猫猫派对 交互客户端 =====")
print(string.format("服务器: %s:%d", HOST, PORT))
print_help()
io.write("> "); io.flush()

while true do
	-- 1. 已登录：解析并处理服务器帧
	if fd then
		while true do
			local body, closed = poll_frame(fd)
			if closed then
				print("\n[连接已关闭]")
				s.close(fd); fd = nil; logged_user = nil
				io.write("> "); io.flush()
				break
			elseif body then
				on_frame(body)
			else
				break
			end
		end
	end

	-- 2. 终端输入（非阻塞）
	local cmd = s.readstdin()
	if cmd then
		if cmd == "quit" or cmd == "exit" then
			if fd then s.close(fd) end
			break
		elseif fd then
			handle_rpc(cmd)
		else
			handle_pre_login(cmd)
		end
		io.write("> "); io.flush()
	else
		s.usleep(10000)
	end
end

print("Bye!")

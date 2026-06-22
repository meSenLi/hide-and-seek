-- client/main.lua
-- 躲猫猫派对 — 测试客户端
-- 流程: 连接 Gate → DH 认证 → 收 200 → echo 消息

package.cpath = "bin/luaclib/?.so"
local s = require "client.socket"
local c = require "client.crypt"

local HOST, PORT, SVR = "127.0.0.1", 8888, "hideandseek"
local TEST_USER, TEST_PASS = "testplayer", "123456"

-- ====== network ======
local L = ""
local function readline(fd)
	while true do
		local n = L:find("\n", 1, true)
		if n then local l = L:sub(1, n-1); L = L:sub(n+1); return l end
		local d = s.recv(fd)
		if not d then s.usleep(100) elseif d == "" then error("closed") else L = L .. d end
	end
end
local function sendline(fd, t) s.send(fd, t .. "\n") end

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
	return code, subid, fd
end

-- ====== test ======
print("===== 躲猫猫派对 =====")
print(string.format("服务器: %s:%d", HOST, PORT))

-- register
print("\n--- Register ---")
local fd = assert(s.connect(HOST, PORT))
local code, subid = auth(fd, TEST_USER, TEST_PASS, true)
print(string.format("code=%s, subid=%s", tostring(code), tostring(subid)))

-- login
print("\n--- Login ---")
fd = assert(s.connect(HOST, PORT))
code, subid = auth(fd, TEST_USER, TEST_PASS, false)
print(string.format("code=%s, subid=%s", tostring(code), tostring(subid)))

if code == 200 then
	-- echo
	print("\n--- Echo ---")
	sendline(fd, "hello server")
	local reply = readline(fd)
	print("reply: " .. reply)
end

s.close(fd)
print("\nDone!")

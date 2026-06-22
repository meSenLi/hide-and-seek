local skynet = require "skynet"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, fd, addr, gate, adb)
		assert(cmd == "auth")
		skynet.error(string.format("[account] auth fd=%d", fd))
		local ok, err = pcall(function()
			socket.start(fd)
			local ch = crypt.randomkey(); socket.write(fd, crypt.base64encode(ch).."\n")
			local hs = socket.readline(fd); assert(hs, "hs")
			local ck = crypt.base64decode(hs)
			local sk = crypt.randomkey(); socket.write(fd, crypt.base64encode(crypt.dhexchange(sk)).."\n")
			local sec = crypt.dhsecret(ck, sk)
			local r = socket.readline(fd); assert(r, "r"); assert(crypt.hmac64(ch,sec)==crypt.base64decode(r), "hmac")
			local et = socket.readline(fd); assert(et, "et")
			local token = crypt.desdecode(sec, crypt.base64decode(et))
			local user = token:match("([^@]+)"); user = crypt.base64decode(user)
			local pass = token:match(":([^:]+)$"); pass = crypt.base64decode(pass:match("^register:(.*)") or pass)
			local reg = token:find(":register:") ~= nil
			if reg then local c = skynet.call(adb, "lua", "create_user", user, pass); assert(c == 200 or c == 409, "code="..c) end
			local a = skynet.call(adb, "lua", "find_user", user); assert(a, "nouser")
			if not reg then assert(skynet.call(adb, "lua", "verify_password", pass, a._salt, a._password_hash), "badpw") end
			skynet.call(adb, "lua", "set_online", user, true)
			skynet.call(adb, "lua", "update_login", user)
			socket.abandon(fd)
			skynet.call(gate, "lua", "forward", fd, user, tostring(os.time()))
			skynet.error("[account] OK " .. user)
		end)
		if not ok then skynet.error("[account] FAIL: "..tostring(err)); pcall(socket.close, fd) end
		skynet.exit()
	end)
end)

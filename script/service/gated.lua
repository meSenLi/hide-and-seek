local skynet = require "skynet"
local socket = require "skynet.socket"
local connections, gate, adb = {}, nil, nil
local CMD = {}
function CMD.open(source, conf, accountdb_addr)
	adb = accountdb_addr
	skynet.error(string.format("[gated] listening on 0.0.0.0:%d", conf.port))
	local id = socket.listen("0.0.0.0", conf.port)
	socket.start(id, function(fd, addr)
		skynet.error(string.format("[gated] connect from %s (fd=%d)", addr, fd))
		local account = skynet.newservice("account")
		connections[fd] = { account = account, ip = addr }
		skynet.send(account, "lua", "auth", fd, addr, skynet.self(), adb)
	end)
	gate = skynet.self()
end
function CMD.forward(source, fd, uid, subid)
	local c = connections[fd]; if not c then return end
	local agent = skynet.newservice("agent_layered")
	skynet.call(agent, "lua", "start", {gate=gate, client=fd, uid=uid, subid=subid})
	c.agent = agent; c.account = nil
	skynet.error(string.format("[gated] %s -> agent=%s", uid, skynet.address(agent)))
end
skynet.start(function()
	skynet.dispatch("lua", function(s, src, cmd, ...)
		local f = assert(CMD[cmd]); skynet.ret(skynet.pack(f(src, ...)))
	end)
end)

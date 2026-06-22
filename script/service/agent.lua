local skynet = require "skynet"
local socket = require "skynet.socket"
local client_fd, userid

local CMD = {}

function CMD.start(source, conf)
	client_fd = conf.client
	userid = conf.uid
	local crypt = require "skynet.crypt"
	socket.start(client_fd)
	socket.write(client_fd, "200 " .. crypt.base64encode(tostring(conf.subid)) .. "\n")
	skynet.error(string.format("[agent] %s started, fd=%d", userid, client_fd))
	-- read loop
	skynet.fork(function()
		while true do
			local msg = socket.readline(client_fd, "\n")
			if not msg then
				skynet.error("[agent] " .. userid .. " connection lost")
				skynet.exit()
				return
			end
			skynet.error(string.format("[agent] %s recv: %s", userid, msg))
			socket.write(client_fd, "echo: " .. msg .. "\n")
		end
	end)
end

function CMD.disconnect(source)
	skynet.error(string.format("[agent] %s disconnected", userid))
	skynet.exit()
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, command, ...)
		local f = assert(CMD[command])
		skynet.ret(skynet.pack(f(source, ...)))
	end)
end)

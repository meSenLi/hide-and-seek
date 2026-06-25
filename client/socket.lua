-- client/socket.lua
-- 客户端 TCP Socket 封装（基于 lua-clientsocket C 模块）

package.cpath = "bin/luaclib/?.so"
local c = require "client_socket"

local M = {}

function M.connect(host, port)
	local fd = c.connect(host, port)
	if not fd then return nil end
	return fd
end

function M.recv(fd)
	return c.recv(fd)
end

function M.send(fd, data)
	return c.send(fd, data)
end

function M.close(fd)
	c.close(fd)
end

function M.usleep(us)
	c.usleep(us)
end

function M.readstdin()
	return c.readstdin()
end

return M

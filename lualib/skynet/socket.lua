-- lualib/skynet/socket.lua
-- Skynet socket 高层封装：把底层 socketdriver 的异步事件，
-- 包装成基于协程的“同步阻塞”读写 API（open/read/readline/listen 等）。
-- 核心机制：每个 fd 对应一个 socket 对象(s)，读写时挂起当前协程(suspend)，
-- 待 socket 线程投递事件(socket_message[type]) 后 wakeup 恢复协程。

local driver = require "skynet.socketdriver"
local skynet = require "skynet"
local skynet_core = require "skynet.core"
local assert = assert

-- 单个 socket 缓冲超过此阈值(128K)时暂停接收(pause)，防止内存膨胀
local BUFFER_LIMIT = 128 * 1024
local socket = {}	-- api
-- 所有 socket 对象表：id(fd) -> socket 对象 s
-- 设置 __gc：服务退出/GC 时自动关闭残留连接
local socket_pool = setmetatable( -- store all socket object
	{},
	{ __gc = function(p)
		for id,v in pairs(p) do
			driver.close(id)
			p[id] = nil
		end
	end
	}
)

local socket_onclose = {}	-- id -> 关闭回调
local socket_message = {}	-- socket 事件类型 -> 处理函数(见下方 1~7)

-- 唤醒挂在该 socket 上等待的协程（读/连接完成时调用）
local function wakeup(s)
	local co = s.co
	if co then
		s.co = nil
		skynet.wakeup(co)
	end
end

-- 暂停接收：缓冲过大时通知底层停止读，避免内存无限增长
local function pause_socket(s, size)
	if s.pause ~= nil then
		return
	end
	if size then
		skynet.error(string.format("Pause socket (%d) size : %d" , s.id, size))
	else
		skynet.error(string.format("Pause socket (%d)" , s.id))
	end
	driver.pause(s.id)
	s.pause = true
	skynet.yield()	-- there are subsequent socket messages in mqueue, maybe.
end

-- ★核心：挂起当前协程，等待 socket 事件唤醒
-- 记录协程到 s.co；若处于 pause 状态则先恢复接收(driver.start)再等待
local function suspend(s)
	assert(not s.co)
	s.co = coroutine.running()
	if s.pause then
		skynet.error(string.format("Resume socket (%d)", s.id))
		driver.start(s.id)
		skynet.wait(s.co)
		s.pause = nil
	else
		skynet.wait(s.co)
	end
	-- wakeup closing corouting every time suspend,
	-- because socket.close() will wait last socket buffer operation before clear the buffer.
	if s.closing then
		skynet.wakeup(s.closing)
	end
end

-- ======== socket 事件处理表：对应底层 SKYNET_SOCKET_TYPE_* ========
-- read skynet_socket.h for these macro
-- SKYNET_SOCKET_TYPE_DATA = 1
-- 收到数据：push 进缓冲，按 read_required(数字=按长度/字符串=按分隔符) 判断是否满足读请求并唤醒
socket_message[1] = function(id, size, data)
	local s = socket_pool[id]
	if s == nil then
		skynet.error("socket: drop package from " .. id)
		driver.drop(data, size)
		return
	end

	local sz = driver.push(s.buffer, s.pool, data, size)
	local rr = s.read_required
	local rrt = type(rr)
	if rrt == "number" then
		-- read size
		if sz >= rr then
			s.read_required = nil
			if sz > BUFFER_LIMIT then
				pause_socket(s, sz)
			end
			wakeup(s)
		end
	else
		if s.buffer_limit and sz > s.buffer_limit then
			skynet.error(string.format("socket buffer overflow: fd=%d size=%d", id , sz))
			driver.close(id)
			return
		end
		if rrt == "string" then
			-- read line
			if driver.readline(s.buffer,nil,rr) then
				s.read_required = nil
				if sz > BUFFER_LIMIT then
					pause_socket(s, sz)
				end
				wakeup(s)
			end
		elseif sz > BUFFER_LIMIT and not s.pause then
			pause_socket(s, sz)
		end
	end
end

-- SKYNET_SOCKET_TYPE_CONNECT = 2
-- 连接成功：标记 connected 并唤醒等待 connect 的协程；listen socket 则记录实际 addr/port
socket_message[2] = function(id, ud , addr)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	-- log remote addr
	if not s.connected then	-- resume may also post connect message
		if s.listen then
			s.addr = addr
			s.port = ud
		end
		s.connected = true
		wakeup(s)
	end
end

-- SKYNET_SOCKET_TYPE_CLOSE = 3
-- 连接关闭：置 connected=false 唤醒读协程；触发 onclose 回调
socket_message[3] = function(id)
	local s = socket_pool[id]
	if s then
		s.connected = false
		wakeup(s)
	else
		driver.close(id)
	end
	local cb = socket_onclose[id]
	if cb then
		cb(id)
		socket_onclose[id] = nil
	end
end

-- SKYNET_SOCKET_TYPE_ACCEPT = 4
-- listen socket 接到新连接：回调 s.callback(newid, addr) 交业务处理
socket_message[4] = function(id, newid, addr)
	local s = socket_pool[id]
	if s == nil then
		driver.close(newid)
		return
	end
	s.callback(newid, addr)
end

-- SKYNET_SOCKET_TYPE_ERROR = 5
-- 出错：区分 accept 错误/连接中错误/已连接错误，置 connected=false 并唤醒
socket_message[5] = function(id, _, err)
	local s = socket_pool[id]
	if s == nil then
		driver.shutdown(id)
		skynet.error("socket: error on unknown", id, err)
		return
	end
	if s.callback then
		skynet.error("socket: accept error:", err)
		return
	end
	if s.connected then
		skynet.error("socket: error on", id, err)
	elseif s.connecting then
		s.connecting = err
	end
	s.connected = false
	driver.shutdown(id)

	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_UDP = 6
-- 收到 UDP 包：拷为字符串后回调 s.callback(str, address)
socket_message[6] = function(id, size, data, address)
	local s = socket_pool[id]
	if s == nil or s.callback == nil then
		skynet.error("socket: drop udp package from " .. id)
		driver.drop(data, size)
		return
	end
	local str = skynet.tostring(data, size)
	skynet_core.trash(data, size)
	s.callback(str, address)
end

-- 默认发送缓冲告警：待发数据堆积时打印 WARNING
local function default_warning(id, size)
	local s = socket_pool[id]
	if not s then
		return
	end
	skynet.error(string.format("WARNING: %d K bytes need to send out (fd = %d)", size, id))
end

-- SKYNET_SOCKET_TYPE_WARNING
-- 发送缓冲堆积告警：调用 s.on_warning 或默认处理
socket_message[7] = function(id, size)
	local s = socket_pool[id]
	if s then
		local warning = s.on_warning or default_warning
		warning(id, size)
	end
end

-- 注册 socket 协议：底层投递的 PTYPE_SOCKET 消息经 unpack 解出事件类型 t，
-- 再分发到上面的 socket_message[t]
skynet.register_protocol {
	name = "socket",
	id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
	unpack = driver.unpack,
	dispatch = function (_, _, t, ...)
		socket_message[t](...)
	end
}

-- 内部通用建链：创建 socket 对象入池，挂起等待 connect 结果
-- func 非 nil 表示 listen 模式(accept 回调)，此时不分配读缓冲
local function connect(id, func)
	local newbuffer
	if func == nil then
		newbuffer = driver.buffer()
	end
	local s = {
		id = id,
		buffer = newbuffer,
		pool = newbuffer and {},
		connected = false,
		connecting = true,
		read_required = false,
		co = false,
		callback = func,
		protocol = "TCP",
	}
	assert(not socket_onclose[id], "socket has onclose callback")
	local s2 = socket_pool[id]
	if s2 and not s2.listen then
		error("socket is not closed")
	end
	socket_pool[id] = s
	suspend(s)
	local err = s.connecting
	s.connecting = nil
	if s.connected then
		return id
	else
		socket_pool[id] = nil
		return nil, err
	end
end

-- 主动连接远端 addr:port，返回 fd（失败返回 nil, err）
function socket.open(addr, port)
	local id = driver.connect(addr,port)
	return connect(id)
end

-- 绑定一个已有的系统 fd
function socket.bind(os_fd)
	local id = driver.bind(os_fd)
	return connect(id)
end

-- 绑定标准输入(fd=0)
function socket.stdin()
	return socket.bind(0)
end

-- 启动一个 fd 的收发：func 为 accept 回调则作为 listen 服务端使用
function socket.start(id, func)
	driver.start(id)
	return connect(id, func)
end

-- 主动暂停接收
function socket.pause(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	pause_socket(s)
end

-- 半关闭：通知底层 shutdown，后续会收到 CLOSE 事件
function socket.shutdown(id)
	local s = socket_pool[id]
	if s then
		-- the framework would send SKYNET_SOCKET_TYPE_CLOSE , need close(id) later
		driver.shutdown(id)
	end
end

-- 关闭一个不在池中的裸 fd（池中的请用 socket.close）
function socket.close_fd(id)
	assert(socket_pool[id] == nil,"Use socket.close instead")
	driver.close(id)
end

-- 关闭连接：若另有协程正在读，需等其读完缓冲后再清理，避免丢数据
function socket.close(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	driver.close(id)
	if s.connected then
		s.pause = false -- Do not resume this fd if it paused.
		if s.co then
			-- reading this socket on another coroutine, so don't shutdown (clear the buffer) immediately
			-- wait reading coroutine read the buffer.
			assert(not s.closing)
			s.closing = coroutine.running()
			skynet.wait(s.closing)
		else
			suspend(s)
		end
		s.connected = false
	end
	socket_pool[id] = nil
end

-- 读取：sz 为 nil 读当前可用数据；否则读满 sz 字节。不足则挂起等待
-- 返回数据；连接断开返回 false, 剩余数据
function socket.read(id, sz)
	local s = socket_pool[id]
	assert(s)
	if sz == nil then
		-- read some bytes
		local ret = driver.readall(s.buffer, s.pool)
		if ret ~= "" then
			return ret
		end

		if not s.connected then
			return false, ret
		end
		assert(not s.read_required)
		s.read_required = 0
		suspend(s)
		ret = driver.readall(s.buffer, s.pool)
		if ret ~= "" then
			return ret
		else
			return false, ret
		end
	end

	local ret = driver.pop(s.buffer, s.pool, sz)
	if ret then
		return ret
	end
	if s.closing or not s.connected then
		return false, driver.readall(s.buffer, s.pool)
	end

	assert(not s.read_required)
	s.read_required = sz
	suspend(s)
	ret = driver.pop(s.buffer, s.pool, sz)
	if ret then
		return ret
	else
		return false, driver.readall(s.buffer, s.pool)
	end
end

-- 读到连接关闭为止，返回全部数据
function socket.readall(id)
	local s = socket_pool[id]
	assert(s)
	if not s.connected then
		local r = driver.readall(s.buffer, s.pool)
		return r ~= "" and r
	end
	assert(not s.read_required)
	s.read_required = true
	suspend(s)
	assert(s.connected == false)
	return driver.readall(s.buffer, s.pool)
end

-- 按分隔符 sep(默认 "\n") 读一行；不足则挂起等待
function socket.readline(id, sep)
	sep = sep or "\n"
	local s = socket_pool[id]
	assert(s)
	local ret = driver.readline(s.buffer, s.pool, sep)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, s.pool)
	end
	assert(not s.read_required)
	s.read_required = sep
	suspend(s)
	if s.connected then
		return driver.readline(s.buffer, s.pool, sep)
	else
		return false, driver.readall(s.buffer, s.pool)
	end
end

-- 阻塞直到有数据可读（read_required=0），用于探测连接是否仍可用
function socket.block(id)
	local s = socket_pool[id]
	if not s or not s.connected then
		return false
	end
	assert(not s.read_required)
	s.read_required = 0
	suspend(s)
	return s.connected
end

-- 发送相关 API 直接映射底层 driver（无需挂起协程）
socket.write = assert(driver.send)
socket.lwrite = assert(driver.lsend)
socket.header = assert(driver.header)

-- fd 是否已不在池中（无效）
function socket.invalid(id)
	return socket_pool[id] == nil
end

-- 是否已断开（既未连接也未在连接中）
function socket.disconnected(id)
	local s = socket_pool[id]
	if s then
		return not(s.connected or s.connecting)
	end
end

-- 监听端口：挂起等待底层返回实际 addr/port，返回 id, addr, port
function socket.listen(host, port, backlog)
	local id = driver.listen(host, port, backlog)
	local s = {
		id = id,
		connected = false,
		listen = true,
	}
	assert(socket_pool[id] == nil)
	socket_pool[id] = s
	suspend(s)
	return id, s.addr, s.port
end

-- abandon use to forward socket id to other service
-- you must call socket.start(id) later in other service
-- 放弃本服务对 fd 的管理（用于把连接转交给另一个服务，如 gate->agent）
function socket.abandon(id)
	local s = socket_pool[id]
	if s then
		s.connected = false
		wakeup(s)
		socket_onclose[id] = nil
		socket_pool[id] = nil
	end
end

-- 设置该 fd 的接收缓冲上限
function socket.limit(id, limit)
	local s = assert(socket_pool[id])
	s.buffer_limit = limit
end

---------------------- UDP

-- 创建 UDP socket 对象（UDP 无连接，直接 connected=true）
local function create_udp_object(id, cb)
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = {
		id = id,
		connected = true,
		protocol = "UDP",
		callback = cb,
	}
end

-- 创建 UDP socket，callback 处理收到的包
function socket.udp(callback, host, port)
	local id = driver.udp(host, port)
	create_udp_object(id, callback)
	return id
end

-- 为 UDP socket 设置默认目标地址
function socket.udp_connect(id, addr, port, callback)
	local obj = socket_pool[id]
	if obj then
		assert(obj.protocol == "UDP")
		if callback then
			obj.callback = callback
		end
	else
		create_udp_object(id, callback)
	end
	driver.udp_connect(id, addr, port)
end

-- 监听 UDP 端口
function socket.udp_listen(addr, port, callback)
	local id = driver.udp_listen(addr, port)
	create_udp_object(id, callback)
	return id
end

-- 连接 UDP 远端
function socket.udp_dial(addr, port, callback)
	local id = driver.udp_dial(addr, port)
	create_udp_object(id, callback)
	return id
end

socket.sendto = assert(driver.udp_send)
socket.udp_address = assert(driver.udp_address)
socket.netstat = assert(driver.info)
socket.resolve = assert(driver.resolve)

-- 注册发送缓冲堆积告警回调
function socket.warning(id, callback)
	local obj = socket_pool[id]
	assert(obj)
	obj.on_warning = callback
end

-- 注册连接关闭回调
function socket.onclose(id, callback)
	socket_onclose[id] = callback
end

return socket

package.path = "./lualib/?.lua;./client/?.lua;./script/?.lua;./script/service/?.lua;./?.lua;" .. package.path
package.cpath = "./bin/luaclib/?.so;./luaclib/?.so;" .. package.cpath

local sproto = require "sproto"
local socket = require "client.socket"

local function readfile(path)
    local f = assert(io.open(path, "r"))
    local data = f:read("a")
    f:close()
    return data
end

local game_sp = sproto.parse(readfile("config/proto/game.sproto"))
local push_sp = sproto.parse(readfile("config/proto/push.sproto"))
local host = push_sp:host "package"
local request = host:attach(game_sp)

local function pack_request(name, args, session)
    local body = request(name, args or {}, session)
    return string.pack(">s2", body)
end

local function unpack_frame(body)
    local ok, typ, p2, p3 = pcall(host.dispatch, host, body)
    return ok, typ, p2, p3
end

local function run()
    local sock = assert(socket.connect("127.0.0.1", 8888))
    local line = assert(sock:receive("*l"))
    print("login response:", line)
    local frame = pack_request("ping", { msg = "hello" }, 1)
    assert(sock:send(frame))
    local header = assert(sock:receive(2))
    local sz = string.unpack(">I2", header)
    local body = assert(sock:receive(sz))
    local ok, typ, p2, p3 = unpack_frame(body)
    print("frame result:", ok, typ, p2, p3)
    sock:close()
end

run()

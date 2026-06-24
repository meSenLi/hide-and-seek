local skynet = require "skynet"
local socket = require "skynet.socket"
local sprotoloader = require "sprotoloader"
local config = require "config.config"

local slot = config.proto_slot
local protocol = {}
local client_fd
local host
local sender
local message_callback

local function send_frame(body)
    socket.write(client_fd, string.pack(">s2", body))
end

local function read_packet()
    local h = socket.read(client_fd, 2)
    if not h then
        return nil
    end
    local sz = string.unpack(">I2", h)
    return socket.read(client_fd, sz)
end

local function dispatch_message(body)
    local ok, t, name, args, response = pcall(host.dispatch, host, body)
    if not ok then
        skynet.error(string.format("[agent_layered.protocol] reject undecodable packet: %s", tostring(t)))
        return
    end
    if t == "REQUEST" and message_callback then
        print("runing request: ", name, args)
        local status, result = pcall(message_callback, name, args)
        if status and response then
            send_frame(response(result or {}))
        elseif not status then
            skynet.error(string.format("[agent_layered.protocol] message handler error: %s", tostring(result)))
        end
    end
end

function protocol:init(conf)
    client_fd = conf.client
    host = sprotoloader.load(slot.game):host "package"
    sender = host:attach(sprotoloader.load(slot.push))
    socket.start(client_fd)
    local crypt = require "skynet.crypt"
    socket.write(client_fd, "200 " .. crypt.base64encode(tostring(conf.subid)) .. "\n")
end

function protocol:on_message(cb)
    message_callback = cb
end

function protocol:send(name, msg)
    if not sender then
        return
    end
    send_frame(sender(name, msg or {}, nil))
end

function protocol:start_read_loop(on_disconnect)
    skynet.fork(function()
        while true do
            local body = read_packet()
            if not body then
                if on_disconnect then on_disconnect() end
                return
            end
            dispatch_message(body)
        end
    end)
end

return protocol

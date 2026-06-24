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
function print_r ( t )  
    local print_r_cache={}
    local function sub_print_r(t,indent)
        if (print_r_cache[tostring(t)]) then
            print(indent.."*"..tostring(t))
        else
            print_r_cache[tostring(t)]=true
            if (type(t)=="table") then
                for pos,val in pairs(t) do
                    if (type(val)=="table") then
                        print(indent.."["..pos.."] => "..tostring(t).." {")
                        sub_print_r(val,indent..string.rep(" ",string.len(pos)+8))
                        print(indent..string.rep(" ",string.len(pos)+6).."}")
                    elseif (type(val)=="string") then
                        print(indent.."["..pos..'] => "'..val..'"')
                    else
                        print(indent.."["..pos.."] => "..tostring(val))
                    end
                end
            else
                print(indent..tostring(t))
            end
        end
    end
    if (type(t)=="table") then
        print(tostring(t).." {")
        sub_print_r(t,"  ")
        print("}")
    else
        sub_print_r(t,"  ")
    end
    print()
end
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
        skynet.error(string.format("[agent_layered.protocol] reject undecodable packet: %s", print_r(t)))
        return
    end
    skynet.error(string.format("[agent_layered.protocol] receive: %s, %s, %s", print_r(t), print_r(name), print_r(args)))
    if t == "REQUEST" and message_callback then
        
        local status, result = pcall(message_callback, name, args)
        skynet.error(string.format("[agent_layered.protocol] message handler result: %s", print_r(result)))
        if status and response then
            send_frame(response(result or {}))
        elseif not status then
            skynet.error(string.format("[agent_layered.protocol] message handler error: %s", print_r(result)))
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
            skynet.error(string.format("[agent_layered.protocol] receive: %s", tostring(body)))
            dispatch_message(body)
        end
    end)
end

return protocol

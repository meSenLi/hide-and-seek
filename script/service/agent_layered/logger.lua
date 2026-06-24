-- script/service/agent_layered/logger.lua
-- AgentLayered logging helper for Lua systems.

local skynet = require "skynet"
local logger = {}

logger.LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
}

local function format_level(level)
    if level == logger.LEVEL.DEBUG then
        return "DEBUG"
    elseif level == logger.LEVEL.INFO then
        return "INFO"
    elseif level == logger.LEVEL.WARN then
        return "WARN"
    else
        return "ERROR"
    end
end

local function format_message(prefix, level, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then
        msg = tostring(fmt)
    end
    if prefix then
        return string.format("%s [%s] %s", prefix, format_level(level), msg)
    end
    return string.format("[%s] %s", format_level(level), msg)
end

local function new(prefix, min_level)
    local self = {
        prefix = prefix or "[agent_layered]",
        min_level = min_level or logger.LEVEL.INFO,
    }

    function self:log(level, fmt, ...)
        if level < self.min_level then
            return
        end
        skynet.error(format_message(self.prefix, level, fmt, ...))
    end

    function self:debug(fmt, ...)
        self:log(logger.LEVEL.DEBUG, fmt, ...)
    end
    function self:info(fmt, ...)
        self:log(logger.LEVEL.INFO, fmt, ...)
    end
    function self:warn(fmt, ...)
        self:log(logger.LEVEL.WARN, fmt, ...)
    end
    function self:error(fmt, ...)
        self:log(logger.LEVEL.ERROR, fmt, ...)
    end

    return self
end

logger.new = new
return logger

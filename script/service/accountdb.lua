-- game/service/accountdb.lua
-- 账号数据库服务 — MongoDB 账号 CRUD
-- 提供：create_user, find_user, verify_password, set_online, update_login
-- 密码哈希：HMAC-MD5 + 8 字节随机盐

local skynet = require "skynet"
require "skynet.manager"  -- skynet.register
local mongo = require "skynet.db.mongo"
local bson = require "bson"
local md5 = require "md5"
local crypt = require "skynet.crypt"

-- ====== 配置 ======
local db
local accounts_col = "accounts"

-- ====== 密码工具 ======

--- 生成随机盐（8 字节，hex 编码后 16 字符）
local function make_salt()
	return crypt.hexencode(crypt.randomkey())
end

--- 哈希密码：HMAC-MD5(password, salt) 返回 hex 字符串
--- @param password string 明文密码
--- @param salt string hex 编码的盐
local function hash_password(password, salt)
	local raw_salt = crypt.hexdecode(salt)
	return md5.hmacmd5(password, raw_salt)
end

--- 验证密码
local function verify_password(password, salt, stored_hash)
	return hash_password(password, salt) == stored_hash
end

-- ====== MongoDB 操作 ======

local function ensure_indexes()
	-- 用户名唯一索引
	db[accounts_col]:ensureIndex(
		{ username = 1 },
		{ unique = true, name = "username_idx" }
	)
	skynet.error("[accountdb] indexes ensured on " .. accounts_col)
end

--- 创建用户
--- @return ok, err_code
local function create_user(username, password)
	if not username or #username < 2 or #username > 32 then
		return false, "invalid_username"
	end
	if not password or #password < 4 or #password > 64 then
		return false, "invalid_password"
	end

	local salt = make_salt()
	local hash = hash_password(password, salt)
	local now = os.time()

	local ok, err, ret = db[accounts_col]:safe_insert({
		username = username,
		password_hash = hash,
		salt = salt,
		created_at = now,
		last_login = 0,
		online = false,
	})

	if not ok then
		if err and string.find(err, "duplicate key") then
			return false, "user_exists"
		end
		skynet.error("[accountdb] create_user failed: " .. tostring(err))
		return false, "db_error"
	end

	skynet.error("[accountdb] user created: " .. username)
	return true
end

--- 查找用户
--- @return user_table or nil
local function find_user(username)
	return db[accounts_col]:findOne({ username = username })
end

--- 更新登录时间
local function update_login(username)
	local now = os.time()
	db[accounts_col]:update(
		{ username = username },
		{ ["$set"] = { last_login = now } }
	)
end

--- 设置在线状态
local function set_online(username, online)
	db[accounts_col]:update(
		{ username = username },
		{ ["$set"] = { online = online } }
	)
end

-- ====== 服务入口 ======

local CMD = {}

function CMD.create_user(username, password)
	local ok, err = create_user(username, password)
	if ok then
		return 200
	elseif err == "user_exists" then
		return 409
	elseif err == "invalid_username" or err == "invalid_password" then
		return 400
	else
		return 500
	end
end

function CMD.find_user(username)
	local user = find_user(username)
	if user then
		-- 不要把敏感信息暴露出去
		return {
			username = user.username,
			created_at = user.created_at,
			last_login = user.last_login,
			online = user.online,
			-- 内部使用
			_password_hash = user.password_hash,
			_salt = user.salt,
		}
	end
	return nil
end

function CMD.verify_password(password, salt, stored_hash)
	return verify_password(password, salt, stored_hash)
end

function CMD.set_online(username, online)
	set_online(username, online)
end

function CMD.update_login(username)
	update_login(username)
end

skynet.start(function()
	-- 从 config/mongo 读取 MongoDB 配置
	local cfg = require "config.mongo"

	skynet.error(string.format("[accountdb] connecting to mongodb://%s:%d/%s",
		cfg.host, cfg.port, cfg.db))

	-- 创建 MongoDB 客户端（如需认证，在 config/mongo.lua 添加 user/pass 字段）
	local client = mongo.client({ host = cfg.host, port = cfg.port })

	db = client[cfg.db]

	-- 创建索引
	ensure_indexes()

	-- 注册协议
	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f = assert(CMD[cmd], "Unknown command: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	-- 注册为具名服务，方便其他服务查找
	skynet.register("accountdb")

	skynet.error("[accountdb] service started")
end)

-- client/crypt.lua
-- 客户端加密模块（基于 lua-crypt C 模块）

package.cpath = (os.getenv("CLIENT_CPATH") or "bin/linux/luaclib/?.so")
return require "client_crypt"

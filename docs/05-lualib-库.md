# lualib Lua 库详解

> Skynet 的 Lua API 和工具库，是业务开发者最常接触的层面。源文件位于 `lualib/` 目录下。

## 文件清单

| 文件 | 职责 |
|------|------|
| `skynet.lua` | ★核心 Lua API（send/call/fork/wait/sleep 等） |
| `loader.lua` | Lua 模块加载器 |
| `sproto.lua` | Sproto 协议库 |
| `sprotoloader.lua` | Sproto 加载器 |
| `sprotoparser.lua` | Sproto 解析器 |
| `md5.lua` | MD5 哈希 |

### lualib/skynet/ 子模块

| 文件 | 职责 |
|------|------|
| `manager.lua` | 服务管理 API（launch/kill/newservice/uniqueservice 等） |
| `service.lua` | `service.new()` 独特服务创建 |
| `socket.lua` | Socket 操作封装 |
| `socketchannel.lua` | Socket 通道（异步 IO） |
| `cluster.lua` | 集群 RPC 调用 |
| `queue.lua` | 消息队列（串行化执行） |
| `coroutine.lua` | 协程工具 |
| `debug.lua` | 调试支持 |
| `datacenter.lua` | 数据中心客户端 |
| `sharedata.lua` | 共享数据客户端 |
| `sharemap.lua` | 共享 Map |
| `sharetable.lua` | 共享 Table |
| `harbor.lua` | Harbor 通信 |
| `snax.lua` | Snax 框架接口 |
| `require.lua` | 自定义 require |
| `inject.lua` | 热更新注入 |
| `injectcode.lua` | 代码注入 |
| `dns.lua` | DNS 解析 |
| `multicast.lua` | 多播客户端 |
| `remotedebug.lua` | 远程调试 |
| `datasheet/` | 数据表 |
| `db/` | 数据库支持（Redis/MongoDB/MySQL） |
| `sharedata/` | 共享数据核心 |
| `codecache.lua` | 代码缓存 |

### lualib/snax/ 子模块

| 文件 | 职责 |
|------|------|
| `gateserver.lua` | ★Gate 服务器框架 |
| `hotfix.lua` | 热更新支持 |
| `interface.lua` | 接口定义 |
| `loginserver.lua` | 登录服务器模板 |
| `msgserver.lua` | 消息服务器模板 |

### lualib/http/ 子模块

| 文件 | 职责 |
|------|------|
| `httpd.lua` | HTTP 服务器 |
| `httpc.lua` | HTTP 客户端 |
| `internal.lua` | HTTP 内部实现 |
| `sockethelper.lua` | Socket 辅助 |
| `tlshelper.lua` | TLS 辅助 |
| `url.lua` | URL 解析 |
| `websocket.lua` | WebSocket 支持 |

---

## 一、`skynet.lua` — 核心 Lua API ★

### 1.1 消息类型常量

```lua
skynet.PTYPE_TEXT      = 0   -- 文本/Lua 消息
skynet.PTYPE_RESPONSE  = 1   -- 响应（超时回调等）
skynet.PTYPE_MULTICAST = 2   -- 多播
skynet.PTYPE_CLIENT    = 3   -- 客户端
skynet.PTYPE_SYSTEM    = 4   -- 系统
skynet.PTYPE_HARBOR    = 5   -- 集群
skynet.PTYPE_SOCKET    = 6   -- Socket 事件
skynet.PTYPE_ERROR     = 7   -- 错误
skynet.PTYPE_LUA       = 10  -- Lua 协议分发
skynet.PTYPE_SNAX      = 11  -- Snax 协议
skynet.PTYPE_TRACE     = 12  -- 追踪
```

### 1.2 Session 管理系统

Skynet 使用 **session** 来实现 RPC 请求-响应匹配：

```lua
-- 全局映射表
session_id_coroutine = {}       -- session → 协程
session_coroutine_id = {}       -- 协程 → session
session_coroutine_address = {}  -- 协程 → 目标地址
watching_session = {}           -- session → 等待地址
unresponse = {}                 -- 未响应的 session
```

### 1.3 Session 回绕安全（Danger Zone）

当 session ID 接近 32 位整数上限时（0x7FFFFFFF），会回绕到 1。此时存在新旧 session 冲突的风险：

```lua
-- 安全区：正常分配 session
local function auxsend_checkrewind(addr, proto, msg, sz)
    local session = csend(addr, proto, nil, msg, sz)
    if session > dangerzone_low and session <= dangerzone_up then
        set_checkconflict(session)  -- 进入危险区
    end
    return session
end

-- 危险区：检查每个 session 是否冲突
local function auxsend_checkconflict(addr, proto, msg, sz)
    local session = csend(addr, proto, nil, msg, sz)
    checkconflict(session)  -- 跳过已存在的 session
    return session
end
```

### 1.4 核心 API

#### 消息发送

| API | 说明 |
|-----|------|
| `skynet.send(addr, type, ...)` | 单向发送（不等待响应） |
| `skynet.call(addr, type, ...)` | RPC 调用（阻塞等待响应） |
| `skynet.ret(pack(...))` | 返回响应 |
| `skynet.redirect(addr, source, type, ...)` | 转发消息 |
| `skynet.rawsend(addr, type, msg, sz)` | 原始发送 |

#### 协程控制

| API | 说明 |
|-----|------|
| `skynet.fork(func, ...)` | 启动新协程 |
| `skynet.wait(co)` | 等待协程 |
| `skynet.wakeup(co)` | 唤醒协程 |
| `skynet.sleep(ti)` | 睡眠（ti × 0.01 秒） |
| `skynet.yield()` | 让出执行权 |
| `skynet.timeout(ti, func)` | 超时回调 |

#### 服务管理

| API | 说明 |
|-----|------|
| `skynet.start(func)` | 启动服务（注册回调） |
| `skynet.exit()` | 退出当前服务 |
| `skynet.dispatch(type, func)` | 注册消息处理器 |
| `skynet.register_protocol(class)` | 注册协议 |
| `skynet.self()` | 获取当前服务 handle |
| `skynet.address(handle)` | handle → 地址字符串 |

#### 其他

| API | 说明 |
|-----|------|
| `skynet.pack(...)` | 序列化数据 |
| `skynet.unpack(msg, sz)` | 反序列化 |
| `skynet.tostring(msg, sz)` | 消息转字符串 |
| `skynet.trash(msg, sz)` | 释放消息内存 |
| `skynet.now()` | 获取当前时间 |
| `skynet.name(name, handle)` | 注册服务名称 |
| `skynet.error(...)` | 输出错误日志 |
| `skynet.trace()` | 开启调用追踪 |

### 1.5 `skynet.call` 实现

```lua
function skynet.call(addr, typename, ...)
    local p = proto[typename]
    local session = auxsend(addr, p.id, p.pack(...))
    if session == nil then
        error("call to invalid address")
    end
    return yield_call(addr, session)  -- 挂起等待响应
end

local function yield_call(addr, session)
    watching_session[session] = addr
    session_id_coroutine[session] = running_thread
    -- 挂起当前协程
    local succ, msg, sz = coroutine_yield("SUSPEND", running_thread)
    watching_session[session] = nil
    if not succ then error("call failed") end
    return p.unpack(msg, sz)
end
```

### 1.6 消息分发主循环

```lua
skynet.start = function(start_func)
    -- 注册 C 回调
    c.callback(skynet.dispatch_message)
    
    -- 启动主协程
    skynet.fork(start_func)
end
```

Dispatch 回调处理所有消息类型：
- `PTYPE_RESPONSE`：超时/RPC 响应
- `PTYPE_SOCKET`：网络事件
- `PTYPE_ERROR`：错误处理
- `PTYPE_LUA`：Lua 协议分发（最常用）
- 其他：自定义处理

---

## 二、`skynet/manager.lua` — 服务管理

```lua
-- 核心函数
skynet.launch(name, ...)           -- 底层启动服务
skynet.kill(handle)                -- 杀死服务
skynet.newservice(name, ...)       -- 通过 launcher 启动并等待初始化完成
skynet.uniqueservice(name, ...)   -- 启动全局唯一服务
skynet.queryservice(name)          -- 查询全局唯一服务
skynet.localname(name)             -- 查询本地名称服务

-- 名称管理
skynet.name(name, handle)          -- 注册本地名称
skynet.handle()                    -- 获取当前 handle（十六进制字符串）
```

### `newservice` 流程

```
skynet.newservice("myservice", arg1, arg2)
    ↓
向 launcher 发送 LAUNCH 命令
    ↓
launcher 通过 skynet.launch() 创建 context
    ↓
新服务初始化完成后向 launcher 发送 LAUNCHOK
    ↓
launcher 通知调用者（返回 handle）
```

---

## 三、`skynet/socket.lua` — Socket 操作

```lua
socket.listen(host, port)         -- 监听 TCP
socket.connect(host, port)        -- TCP 连接
socket.start(id)                  -- 开始接收
socket.close(id)                  -- 关闭
socket.read(id, sz)               -- 读取指定大小
socket.readline(id, sep)          -- 读取一行
socket.readall(id)                -- 读取所有数据
socket.write(id, str)             -- 发送
socket.shutdown(id)               -- 半关闭
socket.block(id)                  -- 阻塞模式
socket.header(id)                 -- 读取协议头
socket.abandon(id)                -- 放弃连接
```

---

## 四、`skynet/queue.lua` — 消息队列化

用于在单个服务内串行化执行消息处理：

```lua
local queue = require("skynet.queue")
local cs = queue()

cs(function()
    -- 串行执行的代码块
end)
```

---

## 五、`skynet/cluster.lua` — 集群 RPC

```lua
cluster.open(port)                   -- 开启集群监听
cluster.reload(cfg)                  -- 重新加载配置
cluster.proxy(name, addr)            -- 获取远程服务代理
cluster.call(name, addr, ...)       -- 跨节点 RPC
cluster.send(name, addr, ...)       -- 跨节点发送
cluster.register(name, handle)       -- 注册全局名称
cluster.query(name)                  -- 查询全局名称
```

---

## 六、`snax/gateserver.lua` — Gate 服务器框架

Snax 是一个基于接口约定的服务框架，gateserver 是其核心组件。

```lua
local gateserver = require("snax.gateserver")

local handler = {}
function handler.open(source, conf) end       -- 开启监听
function handler.message(fd, msg, sz) end     -- 收到消息
function handler.connect(fd, addr) end        -- 新连接
function handler.disconnect(fd) end           -- 断开连接
function handler.error(fd, msg) end           -- 错误
function handler.warning(fd, size) end        -- 发送缓冲警告
function handler.command(cmd, source, ...) end -- 控制命令

gateserver.start(handler)
```

---

## 七、`http/httpd.lua` — HTTP 服务器

```lua
local httpd = require("http.httpd")
local sockethelper = require("http.sockethelper")

httpd.start(addr, port, function(id)
    sockethelper.readfunc(id, 8192)
end)
```

---

## 八、`loader.lua` — 模块加载器

Skynet 的 `require` 加载器，处理文件路径解析和多 Lua state 环境下的模块隔离（通过 `package.loaded` 和代码缓存）。

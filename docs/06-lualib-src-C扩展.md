# lualib-src C 扩展详解

> 供 Lua 调用的 C 扩展库，编译为 `.so` 动态库（放在 `luaclib/` 目录下），源文件位于 `lualib-src/` 目录下。

## 目录

- [文件清单](#文件清单)
- [一、`lua-skynet.c` — skynet.core ★](#一lua-skynetc--skynetcore)
  - [提供的 Lua 函数](#提供的-lua-函数)
  - [消息回调桥接](#消息回调桥接)
  - [回调安全机制](#回调安全机制)
  - [时间函数](#时间函数)
- [二、`lua-socket.c` — Socket 底层](#二lua-socketc--socket-底层)
- [三、`lua-netpack.c` — 网络封包](#三lua-netpackc--网络封包)
- [四、`lua-cluster.c` — 集群协议](#四lua-clusterc--集群协议)
- [五、`lua-sharedata.c` — 共享数据](#五lua-sharedatac--共享数据)
- [六、`lua-sharetable.c` — 共享表](#六lua-sharetablec--共享表)
- [七、其他模块](#七其他模块)
  - [`lua-mongo.c` + `lua-bson.c` — MongoDB 驱动](#lua-mongoc--lua-bsonc--mongodb-驱动)
  - [`lua-memory.c` — 内存统计](#lua-memoryc--内存统计)
  - [`lua-crypt.c` — 加密工具](#lua-cryptc--加密工具)
  - [`lua-stm.c` — 软件事务内存](#lua-stmc--软件事务内存)
  - [`lua-debugchannel.c` — 调试通道](#lua-debugchannelc--调试通道)
  - [`lua-datasheet.c` — 数据表](#lua-datasheetc--数据表)
  - [`lua-multicast.c` — 多播](#lua-multicastc--多播)

---

## 文件清单

| 文件 | 提供的 Lua 模块 | 职责 |
|------|----------------|------|
| `lua-skynet.c` | `skynet.core` | ★Lua ↔ Skynet C API 桥梁 |
| `lua-socket.c` | `skynet.socketdriver` | Socket 底层操作 |
| `lua-netpack.c` | `skynet.netpack` | 网络封包/解包 |
| `lua-cluster.c` | `skynet.cluster.core` | 集群协议支持 |
| `lua-sharedata.c` | `skynet.sharedata.core` | 共享数据核心 |
| `lua-sharetable.c` | `skynet.sharetable.core` | 共享表核心 |
| `lua-clientsocket.c` | `client.socketdriver` | 客户端 Socket |
| `lua-mongo.c` | `mongo.driver` | MongoDB 驱动 |
| `lua-bson.c` | `bson` | BSON 编解码 |
| `lua-seri.c` | `skynet.seri` | 序列化（内部） |
| `lua-stm.c` | `skynet.stm` | 软件事务内存 |
| `lua-memory.c` | `skynet.memory` | 内存信息 |
| `lua-crypt.c` | `skynet.crypt` | 加密（base64/hex/hmac） |
| `lua-datasheet.c` | `skynet.datasheet.core` | 数据表核心 |
| `lua-debugchannel.c` | `skynet.debugchannel` | 调试通道 |
| `lua-multicast.c` | `skynet.multicast.core` | 多播核心 |
| `lua-spdy.c` | `skynet.spdy` | SPDY 协议 |
| `lua-tls.c` | `skynet.tls.core` | TLS/SSL |
| `lsha1.c` | `sha1` | SHA1 哈希 |
| `ltls.c` | `ltls` | TLS 初始化 |

---

## 一、`lua-skynet.c` — skynet.core ★

这是 **Lua 与 Skynet C 核心之间的桥梁**，是最重要的 C 扩展模块。

### 提供的 Lua 函数

| Lua 函数 | 对应 C API | 说明 |
|----------|-----------|------|
| `skynet.core.send(addr, type, session, msg, sz)` | `skynet_send()` | 发送消息 |
| `skynet.core.genid()` | `skynet_context_newsession()` | 生成 session ID |
| `skynet.core.error(msg)` | `skynet_error()` | 输出错误 |
| `skynet.core.command(cmd, param)` | `skynet_command()` | 执行命令 |
| `skynet.core.intcommand(cmd, param)` | `skynet_command()` | 执行命令并返回整数 |
| `skynet.core.address(handle)` | 格式化 | handle → 十六进制字符串 |
| `skynet.core.now()` | `skynet_now()` | 获取当前时间 |
| `skynet.core.callback(callback_func)` | `skynet_callback()` | 注册消息回调 |
| `skynet.core.forward(func)` | `skynet_callback()` | 注册转发回调 |
| `skynet.core.timeout(ti, session)` | `skynet_timeout()` | 设置超时 |
| `skynet.core.trace(tag, name)` | 追踪 | 输出追踪日志 |

### 消息回调桥接

```c
static int
_cb(struct skynet_context *context, void *ud, 
    int type, int session, uint32_t source, 
    const void *msg, size_t sz) {
    
    struct callback_context *cb_ctx = ud;
    lua_State *L = cb_ctx->L;
    
    // 将 C 回调转为 Lua 函数调用
    lua_pushvalue(L, 2);                          // Lua 回调函数
    lua_pushinteger(L, type);                      // 消息类型
    lua_pushlightuserdata(L, (void *)msg);         // 消息指针
    lua_pushinteger(L, sz);                        // 消息大小
    lua_pushinteger(L, session);                   // session
    lua_pushinteger(L, source);                    // 来源
    
    r = lua_pcall(L, 5, 0, 1);  // 调用 Lua 回调
    
    if (r == LUA_OK) return 0;
    // 错误处理...
}
```

### 回调安全机制

```c
// 首次回调使用 _cb_pre，防止上一个 context 的残余数据被误用
static int
_cb_pre(struct skynet_context *context, void *ud, ...) {
    clear_last_context(L);  // 清理上一个 context 的用户数据
    skynet_callback(context, ud, _cb);  // 后续用 _cb
    return _cb(context, ud, ...);
}
```

### 时间函数

```c
static int64_t get_time() {
    // Linux: clock_gettime(CLOCK_MONOTONIC)
    // macOS: gettimeofday
    return nanoseconds;
}

// skynet.core.now() → 返回纳秒精度时间
```

---

## 二、`lua-socket.c` — Socket 底层

提供 `skynet.socketdriver` 模块，封装 `skynet_socket_*` C API：

```lua
local driver = require("skynet.socketdriver")

driver.listen(host, port, backlog)    -- TCP 监听
driver.connect(host, port)            -- TCP 连接
driver.bind(fd)                       -- 绑定已有 fd
driver.close(id)                      -- 关闭 socket
driver.shutdown(id)                   -- 半关闭
driver.start(id)                      -- 开始接收
driver.pause(id)                      -- 暂停接收
driver.nodelay(id)                    -- TCP_NODELAY
driver.send(id, buffer)              -- 发送数据
driver.lsend(lowpriority)            -- 低优先级发送
driver.block_connect(host, port)     -- 阻塞连接（客户端用）
driver.udp(addr, port)               -- UDP socket
driver.udp_connect(id, addr, port)   -- UDP connect
driver.header(id)                     -- 读取数据大小
driver.read(id, sz)                   -- 读取数据
driver.readall(id)                    -- 读取所有
driver.readline(id, sep)             -- 按行读取
driver.halfclose(id)                  -- 半关闭确认
```

---

## 三、`lua-netpack.c` — 网络封包

提供 `skynet.netpack` 模块：

```lua
local netpack = require("skynet.netpack")

-- 封包
netpack.pack(str)              -- 2字节长度 + 数据
netpack.tostring(msg, sz)     -- 解包为 Lua 字符串

-- 过滤器链
netpack.filter(queue, func)   -- 注册过滤器
netpack.clear(queue)          -- 清空队列
netpack.pop(queue, sz)        -- 从队列取包
```

---

## 四、`lua-cluster.c` — 集群协议

提供 `skynet.cluster.core` 模块，负责跨节点的消息序列化：

```lua
local cluster_core = require("skynet.cluster.core")

cluster_core.pack(...)       -- 序列化跨节点消息
cluster_core.unpack(msg)     -- 反序列化
cluster_core.open(port)      -- 开启集群端口
cluster_core.close(port)     -- 关闭
cluster_core.register(name, addr) -- 注册全局名称
cluster_core.query(name)    -- 查询全局名称
```

---

## 五、`lua-sharedata.c` — 共享数据

提供 `skynet.sharedata.core`，支持多个服务共享只读数据，节省内存：

- 使用内存映射和引用计数
- 支持嵌套结构
- 读取时无需锁（只读数据）
- 更新时采用 COW（Copy-on-Write）策略

---

## 六、`lua-sharetable.c` — 共享表

提供 `skynet.sharetable.core`，支持服务间共享 table：

- 比 sharedata 更灵活
- 支持远程查询
- 内存高效

---

## 七、其他模块

### `lua-mongo.c` + `lua-bson.c` — MongoDB 驱动

```lua
local mongo = require("mongo")
local db = mongo.client({ host = "127.0.0.1", port = 27017 })
db:findOne("db.collection", { _id = 1 })
```

### `lua-memory.c` — 内存统计

```lua
local memory = require("skynet.memory")
memory.total()     -- 总内存
memory.block()     -- 大块内存
memory.info()      -- 详细信息
```

### `lua-crypt.c` — 加密工具

```lua
local crypt = require("skynet.crypt")
crypt.base64encode(str)
crypt.base64decode(str)
crypt.hexencode(str)
crypt.hmac64(challenge, secret)
crypt.hmac_md5(text, key)
crypt.desdecode(key, text)
crypt.dhexchange(key)
crypt.dhsecret(key, pubkey)
crypt.randomkey()
crypt.scrypt(secret, salt, ...)
```

### `lua-stm.c` — 软件事务内存

```lua
local stm = require("skynet.stm")
stm.new(init_value)
stm.copy(obj)
stm.update(obj, func)
stm.read(obj, func)
```

### `lua-debugchannel.c` — 调试通道

用于远程调试时注入代码到运行中的服务。

### `lua-datasheet.c` — 数据表

高效的二维数据表，用于游戏配置数据。

### `lua-multicast.c` — 多播

多播底层实现，支持频道订阅和消息广播。

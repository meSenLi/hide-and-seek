# service-src C 服务层详解

> C 语言实现的服务模块，编译为 `.so` 动态库，由 `skynet_module.c` 通过 `dlopen` 加载。源文件位于 `service-src/` 目录下。

## 文件清单

| 文件 | 职责 |
|------|------|
| `service_snlua.c` | ★Lua 服务宿主（最重要的 C 服务） |
| `service_gate.c` | TCP 网关服务 |
| `service_harbor.c` | 集群/节点间通信服务 |
| `service_logger.c` | 日志服务 |
| `databuffer.h` | 数据缓冲区（gate 使用） |
| `hashid.h` | ID 哈希表（gate 使用） |

---

## 一、`service_snlua.c` — Lua 服务宿主 ★

`snlua` 是 Skynet 最重要的 C 服务，它为每个 Lua 服务创建独立的 Lua state（lua_State），在其中加载并执行 Lua 业务逻辑。

### 核心数据结构

```c
struct snlua {
    lua_State *L;          // 主 Lua state
    struct skynet_context *ctx;  // 关联的 skynet context
    size_t mem;            // 当前内存使用
    size_t mem_report;     // 内存报告阈值
    size_t mem_limit;      // 内存限制
    lua_State *activeL;    // 当前活跃的协程
    ATOM_INT trap;         // 信号陷阱标志
};
```

### 生命周期函数

```c
// 创建
struct snlua * snlua_create(void) {
    struct snlua *l = skynet_malloc(sizeof(*l));
    memset(l, 0, sizeof(*l));
    l->mem_report = MEMORY_WARNING_REPORT;   // 32MB
    l->mem_limit = 0;                        // 无限制
    l->L = lua_newstate(lalloc, l);          // 创建 Lua state
    l->activeL = l->L;
    return l;
}

// 初始化
int snlua_init(struct snlua *l, struct skynet_context *ctx, const char *args) {
    // 1. 注册 skynet.core 模块到 Lua
    luaopen_skynet_core(l->L);
    
    // 2. 设置 Lua 搜索路径
    //    lualib/?.lua, lualib/?/init.lua, luaclib/?.so
    set_lua_path(l->L, skynet_getenv("lua_path"));
    set_lua_cpath(l->L, skynet_getenv("lua_cpath"));
    
    // 3. 加载 loader.lua 启动脚本
    //    从 service/bootstrap.lua 或自定义脚本开始
    const char *path = skynet_getenv("lua_loader");
    // loader.lua 会调用 skynet.start() 注册回调
    
    // 4. 初始化内存限制
    l->mem_limit = ...;
    
    // 5. 设置信号钩子
    if (l->mem_limit) {
        lua_sethook(l->L, memory_hook, LUA_MASKCOUNT, ...);
    }
    
    return 0;
}

// 释放
void snlua_release(struct snlua *l) {
    lua_close(l->L);
    skynet_free(l);
}

// 信号处理
void snlua_signal(struct snlua *l, int signal) {
    // 设置 trap 标志，触发 Lua hook 中的错误
    ATOM_STORE(&l->trap, signal);
}
```

### Lua 内存管理

自定义 `lalloc` 分配器，跟踪每个 Lua state 的内存使用：

```c
static void * lalloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    struct snlua *l = ud;
    // 跟踪内存使用
    l->mem += nsize;
    if (osize) l->mem -= osize;
    
    // 超出 report 阈值则报告
    if (l->mem > l->mem_report) {
        l->mem_report *= 2;
        skynet_error(ctx, "Memory warning %.2f M", (float)l->mem/(1024*1024));
    }
    
    // 超出 limit 则拒绝分配
    if (l->mem_limit && l->mem > l->mem_limit) {
        return NULL;
    }
    
    // 实际分配
    return skynet_lalloc(ptr, osize, nsize);
}
```

### snlua 消息回调

```c
static int launch_cb(struct skynet_context *context, void *ud, 
                     int type, int session, uint32_t source, 
                     const void *msg, size_t sz) {
    struct snlua *l = ud;
    // 将 C 消息转为 Lua 调用
    // 调用 skynet.dispatch 注册的回调函数
    
    // 特殊处理 PTYPE_SYSTEM（信号）和 PTYPE_TEXT（启动参数）
    // 其他类型由 Lua 层的 _cb 函数处理
}
```

### Lua Code Cache

如果 Lua 编译时定义了 `LUA_CACHELIB`，支持 Lua 编译后的字节码共享：

```c
#ifdef LUA_CACHELIB
#define codecache luaopen_cache  // 使用 patch 版 lua 的 cache 库
#else
// 提供空的 cache 实现
static int cleardummy(lua_State *L) { return 0; }
static int codecache(lua_State *L) {
    // 注册空的 cache.clear / cache.mode / cache.loadfile
}
#endif
```

---

## 二、`service_gate.c` — TCP 网关服务

### 功能概述

Gate 服务是 Skynet 的网络入口，管理 TCP 连接的生命周期：

1. 监听端口，接受客户端连接
2. 为每个连接分配编号
3. 支持将连接转发给 Agent 服务（旁路模式）
4. 提供连接管理命令（kick/close/forward）

### 核心数据结构

```c
struct connection {
    int id;                     // skynet_socket id
    uint32_t agent;             // 代理服务的 handle
    uint32_t client;            // 客户端标识
    char remote_name[32];       // 远程地址
    struct databuffer buffer;   // 数据缓冲区
};

struct gate {
    struct skynet_context *ctx;
    int listen_id;              // 监听 socket id
    uint32_t watchdog;          // 看门狗服务 handle
    uint32_t broker;            // 消息代理 handle
    int client_tag;             // 客户端标记
    int header_size;            // 包头大小
    int max_connection;         // 最大连接数
    struct hashid hash;         // fd → connection 索引映射
    struct connection *conn;    // 连接数组
    struct messagepool mp;      // 消息内存池
};
```

### 生命周期

```c
struct gate * gate_create(void);          // 分配 gate 结构
void gate_release(struct gate *g);        // 关闭所有连接，释放资源
int gate_init(struct gate *, ctx, parm);  // 初始化（解析参数，启动监听）
```

`gate_init` 参数格式：`<max_connection> <client_tag> <header_size>`

### 连接管理

```c
// 接受新连接
// 在 SOCKET_ACCEPT 事件中：
//   1. hashid_insert 分配连接索引
//   2. skynet_socket_start 开始接收
//   3. 通知 watchdog

// 关闭连接
// 在 SOCKET_CLOSE / SOCKET_ERR 中：
//   1. hashid_remove
//   2. 清理缓冲区
//   3. 通知 agent/watchdog

// 数据到达
// 在 SOCKET_DATA 中：
//   1. databuffer_push 追加数据
//   2. databuffer_readheader 尝试读包头
//   3. databuffer_read 读取完整包
//   4. 转发给 agent 或 watchdog
```

### 控制命令

| 命令 | 说明 |
|------|------|
| `kick <fd>` | 踢掉指定连接 |
| `forward <fd> <agent> <client>` | 将连接转发给 agent |
| `broker <handle>` | 设置消息代理 |
| `start <fd>` | 开始接收数据 |
| `close` | 关闭监听端口 |

---

## 三、`service_harbor.c` — 集群通信服务

### 功能概述

Harbor 服务负责节点间通信，实现跨机器的服务消息转发。

### 协议

```
远程消息格式：
┌────────────┬─────────────┬─────────┬──────────┐
│  source    │ destination │ session │  data    │
│  (4bytes)  │  (4bytes)   │(4bytes) │(variable)│
└────────────┴─────────────┴─────────┴──────────┘
```

### 核心数据结构

```c
struct harbor_msg {
    struct remote_message_header header;  // source, destination, session
    void *buffer;
    size_t size;
};

struct harbor_msg_queue {
    int size, head, tail;
    struct harbor_msg *data;     // 环形缓冲
};

struct slave {
    int fd;
    struct harbor_msg_queue *queue;  // 待发送队列
    int status;                      // WAIT/HANDSHAKE/HEADER/CONTENT/DOWN
    int length, read;
    char *recv_buffer;
};

struct harbor {
    struct skynet_context *ctx;
    int id;
    uint32_t slave;                // slave 服务 handle
    struct hashmap *map;           // 全局名称 → harbor 映射
    struct slave s[REMOTE_MAX];    // 最多 256 个远程连接
};
```

### 状态机

```
STATUS_WAIT → STATUS_HANDSHAKE → STATUS_HEADER → STATUS_CONTENT
                                                ↑          ↓
                                                └──────────┘
```

### 消息类型

| 消息 | 格式 | 说明 |
|------|------|------|
| `N <name> <handle>` | 文本 | 注册全局名称 |
| `S <fd> <id>` | 文本 | 连接到远程 harbor |
| `A <fd> <id>` | 文本 | 接受远程连接 |
| `D <id>` | 文本 | 远端断开 |

---

## 四、`service_logger.c` — 日志服务

### 功能

将接收到的文本消息写入日志文件或 stdout。

### 核心结构

```c
struct logger {
    FILE *handle;          // 文件句柄
    char *filename;        // 日志文件路径
    uint32_t starttime;    // 启动时间戳
    int close;             // 是否需要在 release 时关闭
};
```

### 消息处理

```c
static int logger_cb(struct skynet_context *context, void *ud, 
                     int type, int session, uint32_t source, 
                     const void *msg, size_t sz) {
    struct logger *inst = ud;
    switch (type) {
    case PTYPE_SYSTEM:
        // SIGHUP → freopen 重新打开日志文件（用于 logrotate）
        if (inst->filename) {
            inst->handle = freopen(inst->filename, "a", inst->handle);
        }
        break;
    case PTYPE_TEXT:
        // 格式化输出：时间戳 + 来源 + 消息内容
        fprintf(inst->handle, "%s.%02d [:%08x] %s\n", 
                timestring, csec, source, msg);
        fflush(inst->handle);
        break;
    }
    return 0;
}
```

logger 在启动时被赋予名称 `"logger"`，SIGHUP 信号处理中通过 `skynet_handle_findname("logger")` 找到它并发送系统消息来重新打开日志文件。

---

## 五、`databuffer.h` — 数据缓冲区

用于 Gate 服务的 TCP 流式数据缓冲和解包：

```c
struct databuffer {
    struct messagepool *pool;  // 内存池
    int size;                  // 总数据量
    int head, tail;            // 多段缓冲区
    struct datasheet **queue;
};

void databuffer_push(databuffer, pool, void *data, int sz);  // 追加数据
int  databuffer_read(databuffer, pool, void *buffer, int sz); // 读取数据
int  databuffer_readheader(databuffer, pool, int headersize); // 检查包头
```

## 六、`hashid.h` — ID 哈希表

用于 Gate 服务的 fd → 连接索引映射：

```c
struct hashid {
    int hashmod;       // 哈希表大小
    int cap;           // 容量
    int *hash;         // 哈希槽
    int *id;           // 空闲 ID 链表
};

void hashid_init(hashid, max);   // 初始化
int  hashid_lookup(hashid, id);  // 查找
int  hashid_insert(hashid, id);  // 插入
void hashid_remove(hashid, id);  // 删除
void hashid_clear(hashid);       // 清空
```

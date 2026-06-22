# skynet-src 核心层详解

> 这是 Skynet 框架的 C 语言核心引擎层，所有源文件位于 `skynet-src/` 目录下。

## 目录

- [文件清单与职责](#文件清单与职责)
- [一、`skynet.h` — 公共 API](#一skyneth--公共-api)
- [二、`skynet_main.c` — 程序入口](#二skynet_mainc--程序入口)
  - [配置加载流程](#配置加载流程)
  - [配置读取函数](#配置读取函数)
- [三、`skynet_start.c` — 启动与线程](#三skynet_startc--启动与线程)
  - [`skynet_start()` 启动序列](#skynet_start-启动序列)
  - [`start()` — 线程创建](#start--线程创建)
  - [`bootstrap()` — 引导服务](#bootstrap--引导服务)
  - [`wakeup()` — Worker 唤醒机制](#wakeup--worker-唤醒机制)
  - [`CHECK_ABORT` 宏](#check_abort-宏)
- [四、`skynet_server.c` — Context 管理与消息分发](#四skynet_serverc--context-管理与消息分发)
  - [Context 生命周期](#context-生命周期)
  - [`delete_context()` 清理](#delete_context-清理)
  - [消息发送：`skynet_context_push()`](#消息发送skynet_context_push)
  - [名称查询：`skynet_queryname()`](#名称查询skynet_queryname)
  - [服务退出：`handle_exit()`](#服务退出handle_exit)
  - [内置命令](#内置命令)
- [五、`skynet_handle.c` — Handle 管理系统](#五skynet_handlec--handle-管理系统)
  - [核心数据结构](#核心数据结构)
  - [Handle 编码](#handle-编码)
  - [注册流程](#注册流程)
  - [★无锁读优化（percpu reader slot）](#无锁读优化percpu-reader-slot)
  - [Handle 回收](#handle-回收)
  - [名称服务](#名称服务)
- [六、`skynet_mq.c` — 消息队列系统](#六skynet_mqc--消息队列系统)
  - [双层队列架构](#双层队列架构)
  - [全局队列操作](#全局队列操作)
  - [服务队列操作](#服务队列操作)
  - [过载检测](#过载检测)
  - [队列扩容](#队列扩容)
  - [队列释放](#队列释放)
- [七、`skynet_module.c` — 模块动态加载](#七skynet_modulec--模块动态加载)
  - [模块生命周期](#模块生命周期)
  - [模块查询与加载](#模块查询与加载)
  - [动态库搜索路径](#动态库搜索路径)
  - [模块接口约定](#模块接口约定)
- [八、`skynet_timer.c` — 多级时间轮定时器](#八skynet_timerc--多级时间轮定时器)
  - [关键 API](#关键-api)
  - [时间精度](#时间精度)
- [九、`skynet_socket.c` — 网络层封装](#九skynet_socketc--网络层封装)
  - [架构](#架构)
  - [消息转发](#消息转发)
  - [Socket API](#socket-api)
- [十、`skynet_harbor.c` — 集群通信](#十skynet_harborc--集群通信)
- [十一、`skynet_monitor.c` — 死循环检测](#十一skynet_monitorc--死循环检测)
- [十二、`skynet_log.c` — 日志系统](#十二skynet_logc--日志系统)
  - [日志文件管理](#日志文件管理)
- [十三、`skynet_env.c` — 环境变量](#十三skynet_envc--环境变量)
- [十四、辅助文件](#十四辅助文件)
  - [`atomic.h` — 原子操作](#atomich--原子操作)
  - [`spinlock.h` — 自旋锁](#spinlockh--自旋锁)
  - [`rwlock.h` — 读写锁](#rwlockh--读写锁)
  - [`skynet_malloc.h` — 内存分配](#skynet_malloch--内存分配)
  - [`skynet_daemon.c` — 守护进程](#skynet_daemonc--守护进程)

---

## 文件清单与职责

| 文件 | 行数(约) | 职责 |
|------|----------|------|
| `skynet.h` | 46 | 公共 API 头文件、消息类型定义 |
| `skynet_imp.h` | 39 | 内部配置结构体、线程类型枚举、工具函数 |
| `skynet_main.c` | 200 | 程序入口 `main()`，加载配置，启动框架 |
| `skynet_start.c` | 330 | ★启动逻辑、4 类线程实现 |
| `skynet_server.c` | 420 | ★Context 生命周期、消息分发核心 |
| `skynet_server.h` | 27 | Context 操作 API 声明 |
| `skynet_handle.c` | 300 | Handle 注册/查找/回收，名称服务 |
| `skynet_handle.h` | 23 | Handle 操作 API 声明 |
| `skynet_mq.c` | 280 | 消息队列（全局队列 + 服务队列）|
| `skynet_mq.h` | 40 | 消息队列 API 声明，消息结构体定义 |
| `skynet_module.c` | 170 | C 模块动态加载（dlopen）|
| `skynet_module.h` | 17 | 模块操作 API 声明 |
| `skynet_timer.c` | 220 | 多级时间轮定时器 |
| `skynet_timer.h` | 12 | 定时器 API 声明 |
| `skynet_socket.c` | 220 | 网络层封装 |
| `skynet_socket.h` | 55 | 网络操作 API 声明 |
| `socket_server.c` | ~1800 | 底层 epoll/kqueue 事件驱动 |
| `socket_server.h` | 135 | Socket Server API 声明 |
| `skynet_harbor.c` | 60 | 集群通信管理 |
| `skynet_harbor.h` | 22 | Harbor API 声明 |
| `skynet_monitor.c` | 45 | 死循环检测 |
| `skynet_monitor.h` | 10 | Monitor API 声明 |
| `skynet_log.c` | 85 | 日志输出 |
| `skynet_log.h` | 12 | 日志 API 声明 |
| `skynet_env.c` | 65 | 环境变量存储（基于 Lua state）|
| `skynet_env.h` | 10 | Env API 声明 |
| `skynet_malloc.h` | ~30 | 内存分配封装（jemalloc 集成）|
| `skynet_daemon.c` | ~80 | 守护进程化 |
| `atomic.h` | ~80 | 原子操作封装 |
| `spinlock.h` | ~40 | 自旋锁封装 |
| `rwlock.h` | ~60 | 读写锁（供 handle 使用）|
| `socket_poll.h` | ~30 | IO 多路复用抽象层 |
| `socket_epoll.h` | ~120 | Linux epoll 实现 |
| `socket_kqueue.h` | ~120 | BSD/macOS kqueue 实现 |
| `socket_buffer.h` | ~80 | Socket 缓冲区管理 |
| `socket_info.h` | ~60 | Socket 信息结构体 |

---

## 一、`skynet.h` — 公共 API

```c
// 消息类型定义
#define PTYPE_TEXT      0   // 文本（Lua 默认）
#define PTYPE_RESPONSE  1   // 响应消息（定时器/RPC 回包）
#define PTYPE_MULTICAST 2   // 多播
#define PTYPE_CLIENT    3   // 客户端
#define PTYPE_SYSTEM     4   // 系统
#define PTYPE_HARBOR    5   // 集群通信
#define PTYPE_SOCKET    6   // Socket 事件
#define PTYPE_ERROR     7   // 错误

// 消息标记
#define PTYPE_TAG_DONTCOPY     0x10000  // 不要拷贝消息
#define PTYPE_TAG_ALLOCSESSION 0x20000  // 自动分配 session

// 公开的 C API
void skynet_error(struct skynet_context *context, const char *msg, ...);
const char * skynet_command(struct skynet_context *context, const char *cmd, const char *parm);
uint32_t skynet_queryname(struct skynet_context *context, const char *name);
int skynet_send(struct skynet_context *context, uint32_t source, uint32_t destination, 
                int type, int session, void *msg, size_t sz);
int skynet_sendname(struct skynet_context *context, uint32_t source, const char *destination, 
                    int type, int session, void *msg, size_t sz);
int skynet_isremote(struct skynet_context *, uint32_t handle, int *harbor);

typedef int (*skynet_cb)(struct skynet_context *context, void *ud, 
                          int type, int session, uint32_t source, 
                          const void *msg, size_t sz);
void skynet_callback(struct skynet_context *context, void *ud, skynet_cb cb);

uint32_t skynet_current_handle(void);
uint64_t skynet_now(void);
```

## 二、`skynet_main.c` — 程序入口

### 配置加载流程

```
main(argc, argv)
    ├── skynet_globalinit()     ← 全局 TLS key 创建
    ├── skynet_env_init()       ← 创建 Lua state 作为环境变量存储
    ├── sigign()                ← 忽略 SIGPIPE
    ├── 加载 config 文件 (Lua)
    │   └── _init_env(L)        ← 将 Lua 配置导入 C env
    ├── optint/optstring/optboolean   ← 读取各项配置（带默认值）
    │   ├── thread (默认 8)
    │   ├── harbor (默认 1)
    │   ├── profile (默认 1)
    │   ├── cpath (默认 "./cservice/?.so")
    │   ├── bootstrap (默认 "snlua bootstrap")
    │   ├── daemon/logservice/logger
    ├── skynet_start(&config)   ← 启动框架
    └── skynet_globalexit()     ← 清理
```

### 配置读取函数

```c
static int optint(const char *key, int opt);        // 整数配置
static int optboolean(const char *key, int opt);     // 布尔配置
static const char * optstring(const char *key, const char *opt);  // 字符串配置
```

每个函数先从 `skynet_getenv()` 读取，如果不存在则设置默认值。

## 三、`skynet_start.c` — 启动与线程

### `skynet_start()` 启动序列

```c
void skynet_start(struct skynet_config *config) {
    // 1. SIGHUP 信号处理（用于日志文件重开）
    // 2. daemon_init() — 可选守护进程化
    // 3. 初始化各子系统
    skynet_harbor_init(config->harbor);
    skynet_handle_init(config->harbor, config->thread);
    skynet_mq_init();
    skynet_module_init(config->module_path);
    skynet_timer_init();
    skynet_socket_init();
    skynet_profile_enable(config->profile);
    
    // 4. 启动 logger 服务
    uint32_t logger_handle = skynet_context_new(config->logservice, config->logger);
    skynet_handle_namehandle(logger_handle, "logger");
    
    // 5. 启动 bootstrap 服务（通常是 snlua bootstrap）
    bootstrap(logger_handle, config->bootstrap);
    
    // 6. 启动线程组（阻塞直到所有线程退出）
    start(config->thread);
    
    // 7. 清理
    skynet_harbor_exit();
    skynet_socket_free();
    daemon_exit(config->daemon);
}
```

### `start()` — 线程创建

```c
static void start(int thread) {
    pthread_t pid[thread + 3];  // N个worker + monitor + timer + socket
    
    struct monitor *m = ...     // 共享的 monitor 结构
    
    // 创建 3 个固定线程
    create_thread(&pid[0], thread_monitor, m);   // Monitor
    create_thread(&pid[1], thread_timer, m);     // Timer
    create_thread(&pid[2], thread_socket, m);    // Socket
    
    // 创建 N 个 worker 线程（带权重）
    struct worker_parm wp[thread];
    for (i = 0; i < thread; i++) {
        wp[i].m = m;
        wp[i].id = i;
        wp[i].weight = weight[i];  // -1, -1, -1, -1, 0, 0, 0, 0, 1, 1, ...
        create_thread(&pid[i+3], thread_worker, &wp[i]);
    }
    
    // 等待所有线程结束
    for (i = 0; i < thread + 3; i++) {
        pthread_join(pid[i], NULL);
    }
    free_monitor(m);
}
```

### `bootstrap()` — 引导服务

```c
static void bootstrap(uint32_t logger_handle, const char *cmdline) {
    // 解析 cmdline：第一个空格前为 name，之后为 args
    // 例如 "snlua bootstrap" → name="snlua", args="bootstrap"
    
    const uint32_t handle = skynet_context_new(name, args);
    if (handle == 0) {
        // 启动失败，输出错误并退出
        skynet_error(logger, "Bootstrap error : %s\n", cmdline);
        exit(1);
    }
}
```

### `wakeup()` — Worker 唤醒机制

```c
static void wakeup(struct monitor *m, int busy) {
    if (m->sleep >= m->count - busy) {
        // 只有睡眠的 worker >= (总数 - 忙碌数) 时才唤醒
        // 这个条件确保至少有一个空闲 worker 来接收新消息
        pthread_cond_signal(&m->cond);
    }
}
```

### `CHECK_ABORT` 宏

```c
#define CHECK_ABORT if (skynet_context_total() == 0) break;
```

当所有 context 都退出后（total == 0），各线程退出循环。

## 四、`skynet_server.c` — Context 管理与消息分发

### Context 生命周期

```c
// 创建
uint32_t skynet_context_new(const char *name, const char *param) {
    // 1. 查询模块 (skynet_module_query)
    // 2. 创建模块实例 (skynet_module_instance_create)
    // 3. 分配 skynet_context 内存
    // 4. 初始化字段 (ref=2, session_id=0, ...)
    // 5. 注册 handle (skynet_handle_register)
    // 6. 创建消息队列 (skynet_mq_create)
    // 7. 调用模块 init 函数
    // 8. 成功后 push 到全局队列，返回 handle
    // 9. 失败则 release context, retire handle, 释放消息队列
}

// 引用计数
void skynet_context_grab(ctx)     → ATOM_FINC(&ctx->ref)
void skynet_context_release(ctx)  → ATOM_FDEC, 归零则 delete_context

// 保留（不参与 CHECK_ABORT 计数）
void skynet_context_reserve(ctx)  → grab + context_dec()
```

### `delete_context()` 清理

```c
static void delete_context(struct skynet_context *ctx) {
    fclose(logfile);                              // 关闭日志文件
    skynet_module_instance_release(mod, inst);    // 调用模块 release
    skynet_mq_mark_release(queue);               // 标记队列释放
    skynet_free(ctx);                             // 释放 context
    context_dec();                                // total--
}
```

### 消息发送：`skynet_context_push()`

```c
int skynet_context_push(uint32_t handle, struct skynet_message *message) {
    struct skynet_context *ctx = skynet_handle_grab(handle);
    if (ctx == NULL) return -1;            // 目标不存在
    skynet_mq_push(ctx->queue, message);   // push 到队列
    skynet_context_release(ctx);
    return 0;
}
```

### 名称查询：`skynet_queryname()`

```c
uint32_t skynet_queryname(struct skynet_context *context, const char *name) {
    switch (name[0]) {
    case ':': return strtoul(name+1, NULL, 16);   // ":01000001" → handle
    case '.': return skynet_handle_findname(name+1); // ".launcher" → handle
    }
    return 0;  // 不支持全局名称
}
```

### 服务退出：`handle_exit()`

```c
static void handle_exit(struct skynet_context *context, uint32_t handle) {
    if (handle == 0) handle = context->handle;  // 0 表示自杀
    // 通知 monitor_exit（如果设置了）
    if (G_NODE.monitor_exit) {
        skynet_send(context, handle, G_NODE.monitor_exit, PTYPE_CLIENT, 0, NULL, 0);
    }
    skynet_handle_retire(handle);
}
```

### 内置命令

| 命令 | 函数 | 说明 |
|------|------|------|
| `TIMEOUT` | `cmd_timeout` | 设置超时定时器，返回 session |
| `REG` | `cmd_reg` | 注册/查询名称 |
| `QUERY` | `cmd_query` | 查询名称对应的 handle |
| `NAME` | `cmd_name` | 按 handle 查名称 |
| `EXIT` | `cmd_exit` | 退出服务 |
| `KILL` | `cmd_kill` | 杀死指定 handle 的服务 |
| `LAUNCH` | `cmd_launch` | 启动新服务 |
| `GETENV` | `cmd_getenv` | 获取环境变量 |
| `SETENV` | `cmd_setenv` | 设置环境变量 |
| `STARTTIME` | `cmd_starttime` | 获取启动时间 |
| `ABORT` | `cmd_abort` | 强制退出进程 |
| `NOW` | `cmd_now` | 获取当前时间（10ms 精度）|
| `TRACELOG` | `cmd_tracelog` | 开启/关闭追踪日志 |
| `MEMSTAT` | `cmd_memstat` | 内存统计 |
| `CPUCOST` | `cmd_cpucost` | CPU 耗时查询 |

## 五、`skynet_handle.c` — Handle 管理系统

### 核心数据结构

```c
struct handle_storage {
    struct rwlock lock;                    // 读写锁
    uint32_t harbor;                       // 本节点 harbor id
    uint32_t handle_index;                 // 下一个 handle 序号
    int slot_size;                         // 槽位数量（2 的幂）
    struct skynet_context **slot;          // 哈希槽数组
    int name_cap, name_count;              // 名称容量/数量
    struct handle_name *name;              // 名称表（有序）
    
    // ★分布式 reader slot（无锁读优化）
    ATOM_INT thread_idx;
    int rslot_count;
    struct handle_reader_slot *rslots;
};
```

### Handle 编码

```
 31        24 23                     0
┌───────────┬─────────────────────────┐
│  harbor   │     handle_index        │
│  (8bits)  │      (24bits)           │
└───────────┴─────────────────────────┘
MAX: 每个 harbor 最多 16,777,216 个服务
```

```c
#define HANDLE_MASK         0xffffff
#define HANDLE_REMOTE_SHIFT 24
```

### 注册流程

```c
uint32_t skynet_handle_register(struct skynet_context *ctx) {
    handle_wlock(s);
    for (;;) {
        // 从 handle_index 开始线性探测
        for (i = 0; i < slot_size; i++, handle++) {
            if (handle > HANDLE_MASK) handle = 1;  // 回绕
            int hash = handle & (slot_size - 1);
            if (slot[hash] == NULL) {
                slot[hash] = ctx;
                handle_index = handle + 1;
                handle_wunlock(s);
                return handle | harbor;  // 编码 harbor
            }
        }
        // 槽位满，扩容 2 倍，重新哈希
        new_slot = realloc ×2;
        rehash all entries;
    }
}
```

### ★无锁读优化（percpu reader slot）

```c
struct handle_reader_slot {
    ATOM_INT active;  // 读者在此槽活跃
    char _pad[60];    // 缓存行对齐避免 false sharing
};

// 读锁获取（TLS）
static inline void handle_rlock(struct handle_storage *s) {
    if (TLS_SLOT_IDX >= 0 && TLS_SLOT_IDX < s->rslot_count) {
        for (;;) {
            ATOM_STORE(&s->rslots[TLS_SLOT_IDX].active, 1);
            if (!ATOM_LOAD(&s->lock.write)) break;  // 无写者
            ATOM_STORE(&s->rslots[TLS_SLOT_IDX].active, 0);  // 回退
            while (ATOM_LOAD(&s->lock.write)) atomic_pause_();
        }
    } else {
        rwlock_rlock(&s->lock);  // 回退到传统读写锁
    }
}

// 写锁获取
static inline void handle_wlock(struct handle_storage *s) {
    rwlock_wlock(&s->lock);
    // 等待所有 reader slot 的 active 清 0
    for (int i = 0; i < s->rslot_count; i++) {
        while (ATOM_LOAD(&s->rslots[i].active)) atomic_pause_();
    }
}
```

**设计思想**：Handle 查找是高频只读操作，通过 per-thread slot 让读者只需原子写一个标志位即可，无需竞争全局锁。

### Handle 回收

```c
int skynet_handle_retire(uint32_t handle) {
    handle_wlock(s);
    hash = handle & (slot_size - 1);
    if (slot[hash] != NULL && ctx->handle == handle) {
        slot[hash] = NULL;           // 清空槽位
        // 同步清理名称表中的条目
        compact name array;
    }
    handle_wunlock(s);
    if (ctx) skynet_context_release(ctx);  // 释放引用
}
```

### 名称服务

名称表是**有序数组**，支持二分查找：

```c
uint32_t skynet_handle_findname(const char *name) {
    // 二分查找
    while (begin <= end) {
        int mid = (begin + end) / 2;
        int c = strcmp(name[mid].name, name);
        if (c == 0) return name[mid].handle;
        // ...
    }
}

const char * skynet_handle_namehandle(uint32_t handle, const char *name) {
    // 按序插入名称表（保持有序）
    insert_name_before(s, name, handle, insert_position);
}
```

## 六、`skynet_mq.c` — 消息队列系统

### 双层队列架构

```
┌──────────────────────────────────────────────┐
│            Global Queue (链表)                │
│  head → [Queue A] → [Queue B] → [Queue C]   │
└──────────────────────────────────────────────┘
                    │
                    ▼
    ┌──────────────────────────────┐
    │    Service Queue (环形缓冲)   │
    │  ┌───┬───┬───┬───┬───┬───┐  │
    │  │ M │ M │ M │   │   │   │  │
    │  └───┴───┴───┴───┴───┴───┘  │
    │    head↑           tail↑     │
    └──────────────────────────────┘
```

### 全局队列操作

```c
// 入队（尾部）
void skynet_globalmq_push(struct message_queue *queue) {
    SPIN_LOCK(q)
    if (q->tail) { q->tail->next = queue; q->tail = queue; }
    else { q->head = q->tail = queue; }
    SPIN_UNLOCK(q)
}

// 出队（头部）
struct message_queue * skynet_globalmq_pop() {
    SPIN_LOCK(q)
    mq = q->head;
    if (mq) { q->head = mq->next; mq->next = NULL; }
    SPIN_UNLOCK(q)
    return mq;
}
```

### 服务队列操作

```c
// push 消息（尾部写入）
void skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
    SPIN_LOCK(q)
    q->queue[q->tail] = *message;
    if (++q->tail >= q->cap) q->tail = 0;   // 环形
    if (q->head == q->tail) expand_queue(q); // 满则扩容
    
    // 如果队列不在全局队列中，加入
    if (q->in_global == 0) {
        q->in_global = MQ_IN_GLOBAL;
        skynet_globalmq_push(q);
    }
    SPIN_UNLOCK(q)
}

// pop 消息（头部读取）
int skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
    SPIN_LOCK(q)
    if (q->head != q->tail) {
        *message = q->queue[q->head++];      // 环形
        if (q->head >= q->cap) q->head = 0;
        
        // 过载检测
        int length = tail - head;
        if (length < 0) length += cap;
        while (length > q->overload_threshold) {
            q->overload = length;
            q->overload_threshold *= 2;      // 阈值翻倍，避免频繁报告
        }
    } else {
        q->overload_threshold = MQ_OVERLOAD;  // 队列空则重置阈值
    }
    if (ret) q->in_global = 0;  // 队列空时从全局队列移除
    SPIN_UNLOCK(q)
    return ret;
}
```

### 过载检测

- 初始阈值 `MQ_OVERLOAD = 1024`
- 超过阈值时记录 overload 值
- 阈值自动翻倍，防止频繁报告
- 队列清空后重置为 1024

### 队列扩容

环形缓冲区容量不够时，扩容为 2 倍，并将消息重新排列到连续内存：

```c
static void expand_queue(struct message_queue *q) {
    new_queue = malloc(cap * 2);
    for (i = 0; i < cap; i++)
        new_queue[i] = q->queue[(head + i) % cap];
    head = 0; tail = cap; cap *= 2;
}
```

### 队列释放

```c
void skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud) {
    if (q->release) {
        _drop_queue(q, drop_func, ud);  // 丢弃所有消息并释放
    } else {
        skynet_globalmq_push(q);        // 重新入全局队列等待释放
    }
}
```

## 七、`skynet_module.c` — 模块动态加载

### 模块生命周期

```c
struct skynet_module {
    const char *name;       // 模块名称（如 "snlua", "logger"）
    void *module;           // dlopen 返回的句柄
    void *(*create)(void);  // snlua_create, logger_create 等
    int (*init)(void *inst, struct skynet_context *ctx, const char *parm);
    void (*release)(void *inst);
    void (*signal)(void *inst, int signal);
};
```

### 模块查询与加载

```c
struct skynet_module * skynet_module_query(const char *name) {
    // 1. 从已加载模块中查找
    result = _query(name);
    if (result) return result;
    
    SPIN_LOCK(M)
    // 2. Double-check
    result = _query(name);
    
    // 3. 尝试 dlopen 加载
    if (result == NULL && M->count < MAX_MODULE_TYPE) {
        void *dl = _try_open(M, name);   // dlopen
        if (dl) {
            // 4. 查找 create/init/release/signal 符号
            if (open_sym(&M->m[index]) == 0) {
                M->m[index].name = strdup(name);
                M->count++;
                result = &M->m[index];
            }
        }
    }
    SPIN_UNLOCK(M)
    return result;
}
```

### 动态库搜索路径

从配置 `cpath` 读取（默认 `"./cservice/?.so"`），支持 `;` 分隔的多个路径，`?` 会被替换为模块名。

### 模块接口约定

每个 C 模块必须导出以下函数（命名规则：`<modname>_<func>`）：

```c
// 例：snlua 模块
void * snlua_create(void);                              // 创建实例
int    snlua_init(void *inst, struct skynet_context *ctx, const char *parm);  // 初始化
void   snlua_release(void *inst);                       // 释放
void   snlua_signal(void *inst, int signal);            // 信号处理
```

`open_sym()` 函数通过 `dlsym` 查找这些符号。

## 八、`skynet_timer.c` — 多级时间轮定时器

详见 [01-核心循环详解.md](./01-核心循环详解.md) 第四节。

### 关键 API

| API | 说明 |
|-----|------|
| `skynet_timer_init()` | 创建时间轮，记录启动时间 |
| `skynet_timeout(handle, time, session)` | 添加一个超时事件 |
| `skynet_updatetime()` | 推进时间（timer_update） |
| `skynet_now()` | 获取当前时间（10ms 精度） |
| `skynet_starttime()` | 获取启动时间戳 |
| `skynet_thread_time()` | 获取当前线程 CPU 时间（微秒） |

### 时间精度

- 1 tick = 10ms（100 ticks/秒）
- `skynet_now()` 返回的是 centiseconds（百分之一秒）

```c
uint64_t skynet_now(void) {
    return TI->current;  // 由 skynet_updatetime 递增
}
```

## 九、`skynet_socket.c` — 网络层封装

### 架构

```
skynet_socket.c (消息转发层)
    │
    ▼
socket_server.c (事件驱动层)
    │
    ▼
socket_epoll.h / socket_kqueue.h (IO 多路复用)
```

### 消息转发

Socket 事件通过 `forward_message()` 转为 `PTYPE_SOCKET` 消息：

```c
static void forward_message(int type, bool padding, struct socket_message *result) {
    struct skynet_socket_message *sm = malloc(sz);
    sm->type = type;   // DATA/CLOSE/CONNECT/ERROR/ACCEPT/UDP/WARNING
    sm->id = result->id;
    sm->ud = result->ud;
    
    struct skynet_message message;
    message.source = 0;
    message.session = 0;
    message.data = sm;
    message.sz = sz | ((size_t)PTYPE_SOCKET << MESSAGE_TYPE_SHIFT);
    
    skynet_context_push(result->opaque, &message);
}
```

### Socket API

| API | 说明 |
|-----|------|
| `skynet_socket_listen(ctx, host, port, backlog)` | 监听 TCP 端口 |
| `skynet_socket_connect(ctx, host, port)` | TCP 连接 |
| `skynet_socket_bind(ctx, fd)` | 绑定已有 fd |
| `skynet_socket_close(ctx, id)` | 关闭 socket |
| `skynet_socket_shutdown(ctx, id)` | 半关闭 |
| `skynet_socket_start(ctx, id)` | 开始接收数据 |
| `skynet_socket_pause(ctx, id)` | 暂停接收 |
| `skynet_socket_nodelay(ctx, id)` | 设置 TCP_NODELAY |
| `skynet_socket_udp(ctx, addr, port)` | 创建 UDP socket |
| `skynet_socket_udp_connect(ctx, id, addr, port)` | UDP connect |
| `skynet_socket_sendbuffer(ctx, buffer)` | 普通优先级发送 |
| `skynet_socket_sendbuffer_lowpriority(ctx, buffer)` | 低优先级发送 |

## 十、`skynet_harbor.c` — 集群通信

```c
void skynet_harbor_init(int harbor) {
    HARBOR = (unsigned int)harbor << HANDLE_REMOTE_SHIFT;
}

void skynet_harbor_start(void *ctx) {
    skynet_context_reserve(ctx);  // 保留（不参与退出计数）
    REMOTE = ctx;                 // 设置远程通信 context
}

int skynet_harbor_message_isremote(uint32_t handle) {
    int h = (handle & ~HANDLE_MASK);
    return h != HARBOR && h != 0;  // harbor 不同 → 远程消息
}

void skynet_harbor_send(struct remote_message *rmsg, uint32_t source, int session) {
    skynet_context_send(REMOTE, rmsg, sizeof(*rmsg), source, PTYPE_SYSTEM, session);
}
```

## 十一、`skynet_monitor.c` — 死循环检测

每个 Worker 线程有一个 monitor 实例。详见 [01-核心循环详解.md](./01-核心循环详解.md) 第六节。

## 十二、`skynet_log.c` — 日志系统

### 日志文件管理

```c
FILE * skynet_log_open(ctx, handle) {
    // 从 env 读取 logpath
    // 打开 "{logpath}/{handle:08x}.log"
    // 每个服务可以有独立的日志文件
}

void skynet_log_output(FILE *f, source, type, session, buffer, sz) {
    if (type == PTYPE_SOCKET) {
        log_socket(f, buffer, sz);  // Socket 消息特殊格式
    } else {
        // ":%08x %d %d %u <hex>" 格式输出
    }
}
```

## 十三、`skynet_env.c` — 环境变量

使用一个独立的 Lua state 存储配置：

```c
void skynet_env_init() {
    E = malloc(sizeof(*E));
    E->L = luaL_newstate();  // 纯 Lua state，只用于存储变量
}

const char * skynet_getenv(const char *key) {
    SPIN_LOCK(E)
    lua_getglobal(L, key);
    result = lua_tostring(L, -1);
    SPIN_UNLOCK(E)
    return result;
}

void skynet_setenv(const char *key, const char *value) {
    SPIN_LOCK(E)
    lua_pushstring(L, value);
    lua_setglobal(L, key);
    SPIN_UNLOCK(E)
}
```

## 十四、辅助文件

### `atomic.h` — 原子操作

封装 GCC/Clang 的 `__atomic_*` 内置函数：

```c
#define ATOM_INT       int
#define ATOM_POINTER   uintptr_t
#define ATOM_ULONG     unsigned long long

#define ATOM_INIT(ptr, v)      __atomic_store_n(&(ptr), v, __ATOMIC_RELAXED)
#define ATOM_LOAD(ptr)         __atomic_load_n(&(ptr), __ATOMIC_RELAXED)
#define ATOM_STORE(ptr, v)    __atomic_store_n(&(ptr), v, __ATOMIC_RELAXED)
#define ATOM_FINC(ptr)         __atomic_fetch_add(&(ptr), 1, __ATOMIC_RELAXED)
#define ATOM_FDEC(ptr)         __atomic_fetch_sub(&(ptr), 1, __ATOMIC_RELAXED)
```

### `spinlock.h` — 自旋锁

```c
struct spinlock { int lock; };

#define SPIN_INIT(q)     (q)->lock = 0
#define SPIN_LOCK(q)     while (__sync_lock_test_and_set(&(q)->lock, 1)) {}
#define SPIN_UNLOCK(q)   __sync_lock_release(&(q)->lock)
#define SPIN_DESTROY(q)
```

### `rwlock.h` — 读写锁

```c
struct rwlock {
    int write;    // 写标志
    int read;     // 读者数量
};

void rwlock_rlock(rwlock);  // 读锁
void rwlock_wlock(rwlock);  // 写锁
void rwlock_runlock(rwlock);
void rwlock_wunlock(rwlock);
```

### `skynet_malloc.h` — 内存分配

```c
#define skynet_malloc(size)     je_malloc(size)  // 使用 jemalloc
#define skynet_free(ptr)        je_free(ptr)
```

### `skynet_daemon.c` — 守护进程

```c
int daemon_init(const char *pidfile);  // fork + setsid + 写 pid 文件
int daemon_exit(const char *pidfile);  // 删除 pid 文件
```

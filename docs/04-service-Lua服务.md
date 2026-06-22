# service Lua 服务层详解

> Lua 编写的内置服务，由 `snlua` 加载执行。源文件位于 `service/` 目录下。

## 目录

- [文件清单](#文件清单)
- [一、`bootstrap.lua` — 启动引导 ★](#一bootstraplua--启动引导)
  - [启动流程](#启动流程)
  - [关键设计](#关键设计)
- [二、`launcher.lua` — 服务管理器 ★](#二launcherlua--服务管理器)
  - [核心数据结构](#核心数据结构)
  - [命令集](#命令集)
  - [LAUNCH 流程](#launch-流程)
  - [服务退出](#服务退出)
- [三、`gate.lua` — Lua 层网关](#三gatelua--lua-层网关)
- [四、`snaxd.lua` — Snax 框架宿主](#四snaxdlua--snax-框架宿主)
- [五、集群相关服务](#五集群相关服务)
  - [`cmaster.lua` — 集群主节点](#cmasterlua--集群主节点)
  - [`cslave.lua` — 集群从节点](#cslavelua--集群从节点)
  - [`clusterd.lua` — 集群守护](#clusterdlua--集群守护)
  - [`clusteragent.lua` / `clusterproxy.lua` / `clustersender.lua`](#clusteragentlua--clusterproxylua--clustersenderlua)
- [六、`console.lua` — 调试控制台](#六consolelua--调试控制台)
- [七、`debug_console.lua` — Web 调试控制台](#七debug_consolelua--web-调试控制台)
- [八、`datacenterd.lua` — 数据中心](#八datacenterdlua--数据中心)
- [九、`sharedatad.lua` — 共享数据服务](#九sharedatadlua--共享数据服务)
- [十、`multicastd.lua` — 多播服务](#十multicastdlua--多播服务)
- [十一、其他服务](#十一其他服务)

---

## 文件清单

| 文件 | 职责 |
|------|------|
| `bootstrap.lua` | ★启动引导服务（第一个 Lua 服务，初始化整个系统） |
| `launcher.lua` | 服务启动器/管理器（管理所有服务的生命周期） |
| `gate.lua` | Lua 层网关（基于 snax.gateserver 框架） |
| `snaxd.lua` | Snax 框架宿主 |
| `clusterd.lua` | 集群守护进程 |
| `clusteragent.lua` | 集群代理 |
| `clusterproxy.lua` | 集群代理 |
| `clustersender.lua` | 集群发送器 |
| `cmaster.lua` | 集群 master |
| `cslave.lua` | 集群 slave |
| `console.lua` | 调试控制台 |
| `debug_agent.lua` | 调试代理 |
| `debug_console.lua` | Web 调试控制台 |
| `dbg.lua` | 调试支持 |
| `datacenterd.lua` | 数据中心（全局共享数据） |
| `multicastd.lua` | 多播服务 |
| `sharedatad.lua` | 共享数据服务 |
| `service_cell.lua` | 服务单元 |
| `service_mgr.lua` | 服务管理器 |
| `service_provider.lua` | 服务提供者 |
| `cmemory.lua` | 内存统计 |
| `cdummy.lua` | 占位服务 |

---

## 一、`bootstrap.lua` — 启动引导 ★

Bootstrap 是 Skynet 启动的**第一个 Lua 服务**，负责初始化整个系统。

### 启动流程

```lua
skynet.start(function()
    local standalone = skynet.getenv("standalone")
    
    -- 1. 启动 launcher（服务管理器）
    local launcher = assert(skynet.launch("snlua", "launcher"))
    skynet.name(".launcher", launcher)
    
    local harbor_id = tonumber(skynet.getenv("harbor") or 0)
    
    if harbor_id == 0 then
        -- ★单节点模式
        standalone = true
        local ok, slave = pcall(skynet.newservice, "cdummy")
        skynet.name(".cslave", slave)
    else
        -- ★集群模式
        if standalone then
            -- master 节点：启动 cmaster
            pcall(skynet.newservice, "cmaster")
        end
        local ok, slave = pcall(skynet.newservice, "cslave")
        skynet.name(".cslave", slave)
    end
    
    if standalone then
        local datacenter = skynet.newservice("datacenterd")
        skynet.name("DATACENTER", datacenter)
    end
    
    -- 2. 启动 service_mgr
    skynet.newservice("service_mgr")
    
    -- 3. 可选：SSL 支持
    if skynet.getenv("enablessl") == "true" then
        service.new("ltls_holder", function()
            local c = require("ltls.init.c")
            c.constructor()
        end)
    end
    
    -- 4. ★启动用户主服务（config 中的 start 或 "main"）
    pcall(skynet.newservice, skynet.getenv("start") or "main")
    
    -- 5. bootstrap 自身退出
    skynet.exit()
end)
```

### 关键设计

- **bootstrap 在启动完毕后立即退出**，不占用系统资源
- `.launcher` 注册为全局名称，所有后续服务由 launcher 管理
- 单节点和集群模式通过 `harbor` 和 `standalone` 配置区分

---

## 二、`launcher.lua` — 服务管理器 ★

Launcher 是 Skynet 的**服务生命周期管理器**，所有通过 `skynet.newservice()` 创建的服务都由它管理。

### 核心数据结构

```lua
local services = {}          -- handle → 服务名
local instance = {}          -- handle → response 回调（等待初始化确认）
local launch_session = {}    -- 服务地址 → session
```

### 命令集

| 命令 | 说明 |
|------|------|
| `LAUNCH` | 启动新服务，返回 handle |
| `LIST` | 列出所有服务 |
| `STAT` | 查询服务状态 |
| `KILL` | 杀死服务 |
| `MEM` | 查询内存使用 |
| `GC` | 强制执行 GC 并查询内存 |
| `REMOVE` | 服务退出通知 |
| `LAUNCHOK` | 服务初始化完成确认 |
| `ERROR` | 服务初始化失败 |
| `QUERY` | 查询服务启动状态 |

### LAUNCH 流程

```lua
local function launch_service(service, ...)
    local param = table.concat({...}, " ")
    local inst = skynet.launch(service, param)  -- C 层创建 context
    local session = skynet.context()
    local response = skynet.response()
    
    if inst then
        -- 记录服务信息
        services[inst] = service .. " " .. param
        instance[inst] = response        -- 保存回调
        launch_session[inst] = session
        
        -- 给新服务发送初始化参数
        skynet.send(inst, "lua", "LAUNCH", ...)
    else
        -- 启动失败
        response(false)
    end
end
```

### 服务退出

当服务调用 `skynet.exit()` 时，会向 launcher 发送 `REMOVE` 命令：

```lua
function command.REMOVE(_, handle, kill)
    services[handle] = nil
    local response = instance[handle]
    if response then
        response(not kill)  -- 通知 newservice 的调用者
        instance[handle] = nil
    end
    return NORET  -- 不返回（handle 即将销毁）
end
```

---

## 三、`gate.lua` — Lua 层网关

基于 `snax.gateserver` 框架实现的 TCP 网关：

```lua
local gateserver = require("snax.gateserver")

local handler = {}

function handler.open(source, conf)
    -- 返回监听的地址和端口
    return conf.address, conf.port
end

function handler.message(fd, msg, sz)
    -- 收到客户端消息，转发给 agent
    local c = connection[fd]
    if c.agent then
        skynet.redirect(agent, c.client, "client", fd, msg, sz)
    else
        skynet.send(watchdog, "lua", "socket", "data", fd, ...)
    end
end

function handler.connect(fd, addr)
    -- 新连接，通知 watchdog
    connection[fd] = { fd = fd, ip = addr }
    skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

function handler.disconnect(fd)
    -- 连接断开
    close_fd(fd)
    skynet.send(watchdog, "lua", "socket", "close", fd)
end

function handler.command(cmd, source, ...)
    -- 控制命令：forward/accept/kick
end

gateserver.start(handler)
```

---

## 四、`snaxd.lua` — Snax 框架宿主

Snax 是 Skynet 的一个简单服务框架，提供热更新和接口定义：

```lua
skynet.start(function()
    local snax = require("snax")
    -- 加载 Snax 服务
    -- 支持热更新（hotfix）
    -- 提供 interface 定义和检查
end)
```

---

## 五、集群相关服务

### `cmaster.lua` — 集群主节点

管理集群中的 harbor 分配和全局名称注册。

### `cslave.lua` — 集群从节点

连接到 master，接收 harbor 分配，同步全局名称表。

### `clusterd.lua` — 集群守护

管理与其他节点的 TCP 连接（通过 `service_harbor.c`）。

### `clusteragent.lua` / `clusterproxy.lua` / `clustersender.lua`

提供跨节点的服务调用接口：
- `clusteragent`：本地代理，接收远程请求
- `clusterproxy`：远程代理，转发本地请求
- `clustersender`：负责实际的消息序列化和发送

---

## 六、`console.lua` — 调试控制台

提供运行时调试命令：

```lua
-- 常用命令
list        -- 列出所有服务
stat        -- 查看状态
mem         -- 查看内存
gc          -- 强制执行 GC
kill <handle>  -- 杀死服务
info <handle>  -- 查看服务信息
```

---

## 七、`debug_console.lua` — Web 调试控制台

启动一个 HTTP 服务器（默认端口 8000），提供 Web 界面调试。

---

## 八、`datacenterd.lua` — 数据中心

提供一个全局的 key-value 存储，所有服务可以访问：

```lua
-- 在单节点模式下由 bootstrap 启动
local datacenter = skynet.newservice("datacenterd")
skynet.name("DATACENTER", datacenter)
```

---

## 九、`sharedatad.lua` — 共享数据服务

管理跨服务的共享数据结构，支持读写锁。

## 十、`multicastd.lua` — 多播服务

支持向多个服务发送同一消息，基于频道订阅模式。

## 十一、其他服务

| 服务 | 说明 |
|------|------|
| `service_mgr.lua` | 服务管理器辅助 |
| `service_provider.lua` | 服务提供者模式 |
| `service_cell.lua` | 服务单元 |
| `cmemory.lua` | 内存使用统计 |
| `cdummy.lua` | 占位服务（用于单节点模拟 cslave） |
| `dbg.lua` | 调试辅助 |
| `debug_agent.lua` | 调试代理 |

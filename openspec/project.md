# 项目说明（Project Spec）

## 目的（Purpose）

「躲猫猫派对游戏」服务端。基于 Skynet（Actor 模型 + Lua 协程框架）构建的多人在线游戏后端，负责账号注册/登录鉴权、客户端连接管理、玩家会话（agent）与游戏业务逻辑。

- 框架层：Skynet（C 核心 + Lua 业务），位于 `skynet-src/`、`service-src/`、`lualib/` 等，源自 cloudwu/skynet（MIT）。
- 业务层：本项目自有代码，位于 `script/`、`config/`、`client/`。

## 技术栈（Tech Stack）

| 类别 | 选型 |
|------|------|
| 框架 | Skynet（Actor 模型，每服务独立消息队列与协程） |
| 核心语言 | C（框架引擎、C 服务模块 `.so`） |
| 业务语言 | Lua（修改版 Lua 5.5，多 lua_State） |
| 数据库 | MongoDB（账号存储，库名 `hideandseek`，集合 `accounts`） |
| 网络 | Skynet socket（gate 监听，TCP 文本协议 `\n` 分行） |
| 加密鉴权 | `skynet.crypt`（DH 密钥交换 + HMAC + DES），密码哈希 HMAC-MD5 + 8 字节随机盐 |
| 构建 | GNU Make（`make linux` 等） |
| 运行 | `./skynet config/config.lua` |

## 架构与服务（Architecture）

启动入口 `script/main.lua`（`start = "main"`），依次拉起业务服务：

```
main
 ├─ accountdb   具名服务，MongoDB 账号 CRUD（create/find/verify/set_online/update_login）
 ├─ protoloader 协议加载
 ├─ debug_console (:8000，pcall 容错)
 └─ gated       监听 :8888，接受连接
        ├─ account  每连接临时鉴权服务（DH 握手 + 校验/注册），成功后 forward
        └─ agent     每玩家会话服务，收发客户端消息
```

关键约定：
- 服务间通信走 `skynet.call`（同步 RPC）/ `skynet.send`（异步），协议类型 `"lua"`。
- 每个 Lua 服务用 `skynet.start(func)` 注册启动函数；消息处理用 `skynet.dispatch("lua", ...)`，命令分发到 `CMD` 表，`skynet.ret(skynet.pack(...))` 回复。
- 临时服务（account、agent）处理完用 `skynet.exit()` 退出。
- 具名服务（accountdb）用 `skynet.register(name)` 注册供查找。

## 目录约定（Layout）

| 路径 | 用途 |
|------|------|
| `skynet-src/` | Skynet C 核心（一般不改） |
| `service-src/` | C 服务模块源码（编译为 `.so`） |
| `lualib/` `lualib-src/` | Skynet Lua 库与 C 扩展（一般不改） |
| `service/` | Skynet 内置 Lua 服务（bootstrap、launcher 等） |
| `script/` | ★本项目业务入口与服务（`main.lua`、`service/*.lua`） |
| `config/` | 启动配置 + 业务配置（`config.lua` 双重职责） |
| `client/` | 客户端代码 |
| `docs/` | 项目中文文档（编号 00~10 + 专题） |
| `test/` | Skynet 自带测试用例 |

## 项目规范（Conventions）

### 代码风格
- Lua：缩进用 Tab，与现有 `script/` 文件一致。
- 服务文件顶部用 `-- 文件路径 + 中文职责说明` 注释（见 `accountdb.lua`、`main.lua`）。
- 日志统一 `skynet.error(string.format("[服务名] ...", ...))`，前缀方括号标服务名。
- 命令表统一命名 `CMD`，函数签名 `function CMD.xxx(source, ...)`。

### 安全
- 密码绝不明文存储：HMAC-MD5 + 随机盐。
- `find_user` 对外只返回非敏感字段，敏感字段用 `_` 前缀且仅内部使用。
- 鉴权全程 DH 交换 + HMAC 校验，禁止跳过握手。

### 配置
- 所有端口/数据库等参数集中在 `config/config.lua`，不要硬编码到服务里。
- MongoDB 连接信息走 `config.mongo`。

## 重要约束（Constraints）

- 框架代码（`skynet-src/`、`lualib/`）默认不修改；业务改动集中在 `script/`、`config/`、`client/`。
- `start_func` 内可安全用阻塞 API（`skynet.call`），因其由 `timeout(0)` 延迟执行（详见 `docs/08`）。
- MongoDB 必须先启动（`127.0.0.1:27017`），否则 `accountdb` 起服失败。

## 外部依赖（External Dependencies）

- MongoDB 27017。
- 第三方库在 `3rd/`（lua、jemalloc 等），由 Makefile 构建。

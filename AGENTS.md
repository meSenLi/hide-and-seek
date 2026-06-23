# AGENTS 规范说明

本文件为 AI 编码助手（agents）在本仓库工作时的规范。「躲猫猫派对游戏」服务端基于 Skynet（C 核心 + Lua 业务）。完整项目说明见 `openspec/project.md`。

## 工作边界

- **改业务，不改框架**：默认只改 `script/`、`config/`、`client/`。`skynet-src/`、`service-src/`、`lualib/`、`lualib-src/`、`service/`、`3rd/` 属框架/第三方，除非用户明确要求，否则不动。
- 修改前先读相关服务文件与 `docs/` 对应章节，理解 Actor/消息模型再动手。
- 不引入新依赖库前先确认仓库已使用（查 `lualib/`、`config/`）。

## OpenSpec 工作流

本仓库采用 OpenSpec 规范驱动开发。变更存于 `openspec/changes/<name>/`，归档于 `openspec/changes/archive/`，主规范与项目上下文存于 `openspec/`。

- 新功能/改动：先提案（proposal）→ 规格（specs）→ 设计（design）→ 任务（tasks）→ 实现（apply）→ 归档（archive）。
- 意图不明时倾向先 explore（思考），勿直接写码。
- 规划/提案阶段务必用提问澄清需求，不臆测。

> 注意：本机当前未安装 OpenSpec CLI 与 Node。如需 `openspec` 命令，先安装 Node 与 `openspec`，否则按规范手动维护 `openspec/` 下文件。

## 代码规范

- **语言**：Lua（修改版 5.5）。缩进用 **Tab**，与现有文件一致。
- **文件头注释**：业务服务顶部写 `-- 路径 + 中文职责`，列出对外命令。
- **服务结构**：`skynet.start(func)` 注册启动；`skynet.dispatch("lua", ...)` 分发到 `CMD` 表；`skynet.ret(skynet.pack(...))` 回复。
- **命令表**：统一命名 `CMD`，函数 `function CMD.xxx(source, ...)`。
- **日志**：`skynet.error(string.format("[服务名] ...", ...))`，方括号标服务名。
- **临时服务**：处理完调 `skynet.exit()`；具名服务用 `skynet.register(name)`。
- **注释**：默认不写解释性注释，代码自解释；现有中文注释勿随意删。

## 服务通信约定

- 同步 RPC 用 `skynet.call(addr, "lua", cmd, ...)`；异步用 `skynet.send`。
- 跨服务只传可序列化数据；连接 fd 转交用 `socket.abandon` + `forward`。
- `start_func` 内可用阻塞 API（由 `timeout(0)` 延迟执行）。

## 安全红线

- 密码必须 HMAC-MD5 + 随机盐，**禁止明文存储或日志输出**。
- 对外返回用户数据时过滤敏感字段（`_password_hash`、`_salt` 等仅内部用）。
- 鉴权握手（DH + HMAC 校验）流程不得跳过或简化。
- 不得硬编码密钥/口令；端口、数据库等配置集中在 `config/config.lua`。

## 配置与运行

- 启动：`./skynet config/config.lua`；入口服务 `main`。
- 依赖 MongoDB（`127.0.0.1:27017`，库 `hideandseek`）先行启动。
- 改端口/库等只动 `config/config.lua`，勿散落到各服务。

## 验证

- 改动后尽量端到端验证：能起服、能连接、鉴权与登录流程通（参考 `docs/登录流程.md`）。
- C 层改动需 `make` 重新编译；Lua 改动热改即可。

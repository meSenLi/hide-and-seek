# 提案：登录后改用 sproto RPC 交互

## Why（为什么）

玩家登录后，客户端与 `agent` 当前是**纯文本按行 echo**：客户端可发送任意字符串，服务端原样回显。这没有协议约束，客户端"什么都能发"，无法表达结构化游戏指令，也不利于安全与扩展。

项目已搭好 sproto 设施（`protoloader` + `config/proto/*.sproto` + `lualib/sproto*`），但 `agent` 完全没用上。本变更让**登录后的交互全部走 sproto 二进制 RPC**：只有协议中定义的请求才被受理，未定义内容一律拒绝。

## What Changes（改动内容）

- **传输**：登录后从"文本按行"切换为"2 字节大端长度前缀 + sproto 包体"的二进制帧。鉴权握手阶段（DH + `200 subid`）保持文本不变。
- **协议**：
  - 新增 `config/proto/game.sproto`（c2s 请求/响应）：`heartbeat`、`ping`、`echo`、`get_userinfo`。
  - 新增 `config/proto/push.sproto`（s2c 服务端主动推送）：`push`。
  - `protoloader` 注册这两个新 slot。
- **服务端 `agent`**：用 `sproto:host "package"` 解包，按协议名分发到 `RPC` 处理表；未定义协议或解码失败一律拒绝（记录并断开）。支持向客户端 `push`。
- **客户端**：登录成功后切换为 sproto 帧；终端命令映射为 RPC 请求（`ping`/`echo`/`info`/`heartbeat`），按 session 匹配响应；异步接收并打印服务端 push；未知命令本地拒绝。

## Capabilities（能力）

### New Capabilities
- `game-rpc`：登录后客户端与 agent 之间基于 sproto 的请求/响应 + 服务端推送的 RPC 通道，含协议白名单约束。

## Impact（影响）

- `config/proto/game.sproto`：新增 c2s 协议定义。
- `config/proto/push.sproto`：新增 s2c 推送协议定义。
- `script/service/protoloader.lua`：注册 game/push 两个 slot。
- `script/service/agent.lua`：替换 echo 循环为 sproto 帧读取 + host 分发 + RPC 处理表 + push。
- `client/main.lua`：登录后切换 sproto 帧；命令→RPC 映射；响应/推送处理。
- `config/config.lua`（可选）：集中 slot 常量。

## 非目标（Non-Goals）

- 不改鉴权握手（DH/HMAC）流程，仍为文本。
- 不引入心跳超时踢人、不做断线重连。
- 不实现真实游戏玩法指令（躲/找等），仅打通 RPC 框架与示例命令。

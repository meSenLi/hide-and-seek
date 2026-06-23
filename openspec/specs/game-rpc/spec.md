# Spec: game-rpc

登录后客户端与 `agent` 之间基于 sproto 的 RPC 通道（请求/响应 + 服务端推送），含协议白名单约束。

## Requirements

### Requirement: 登录后仅受理 sproto 协议白名单内的 RPC

玩家通过鉴权（收到 `200 <subid>`）后，客户端与 `agent` 之间的所有交互 MUST 使用 sproto 二进制 RPC，且服务端 MUST 仅受理协议中已定义的请求；未定义协议名或无法解码的数据 MUST 被拒绝，不得当作有效消息处理。

#### Scenario: 客户端发送已定义的 RPC 请求

- **WHEN** 已登录客户端发送一个 `game.sproto` 中定义的请求（如 `ping`）
- **THEN** `agent` 解包后路由到对应处理函数
- **AND** 若该请求声明了 response，`agent` 以相同 session 打包响应回客户端

#### Scenario: 客户端发送未定义/非法内容

- **WHEN** 客户端发送协议中未定义的请求名，或发送无法被 sproto 解码的字节
- **THEN** `agent` 记录一条拒绝日志且不执行任何业务处理
- **AND** 该消息不产生正常响应，且不影响该连接的后续正常通信

### Requirement: 二进制帧格式

登录后双方 MUST 以"2 字节大端长度前缀 + sproto 包体"为帧边界收发消息。

#### Scenario: 收发一条消息

- **WHEN** 任一方发送一条 RPC 消息
- **THEN** 先写入 2 字节大端长度（包体字节数），再写入 sproto 包体
- **AND** 接收方先读 2 字节得到长度，再精确读取该长度的包体后解码

### Requirement: 首批 RPC 命令

`game.sproto`（c2s）MUST 定义 `heartbeat`、`ping`、`echo`、`get_userinfo`；`push.sproto`（s2c）MUST 定义服务端主动推送 `push`。

#### Scenario: echo 请求

- **WHEN** 客户端发送 `echo{content="hi"}`
- **THEN** `agent` 返回 `echo` 响应，`content` 等于原内容

#### Scenario: get_userinfo 请求

- **WHEN** 已登录客户端发送 `get_userinfo{}`
- **THEN** `agent` 返回该玩家的 `userid`、`subid`、`login_time`

#### Scenario: 服务端主动推送

- **WHEN** 服务端需要主动通知客户端
- **THEN** `agent` 用 `push.sproto` 的 `push` 协议打包成帧发送
- **AND** 客户端无需先发请求即可收到并展示该 push

### Requirement: 鉴权阶段不受影响

DH 鉴权握手与 `200 <subid>` 响应 MUST 保持原有文本按行协议，不得改为二进制。

#### Scenario: 鉴权仍为文本

- **WHEN** 客户端连接并进行 DH 握手
- **THEN** 握手与 `200`/错误码响应仍以文本行收发
- **AND** 仅在收到 `200` 之后双方才切换为 sproto 帧

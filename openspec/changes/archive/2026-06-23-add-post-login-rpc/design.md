# 设计：登录后 sproto RPC 交互

## Context（背景）

- 现有连接生命周期：`gated`（自定义网关，监听 8888）接受连接 → 创建临时 `account` 做 DH 鉴权 → 成功后 `socket.abandon` 把 fd `forward` 给 `gated` → 创建 `agent` 并 `socket.start(fd)` 接管该连接。
- `agent` 当前直接持有 socket，用 `socket.readline(fd, "\n")` 按行读，回显 `"echo: "..msg`。
- sproto 设施已就绪：`protoloader` 把 `.sproto` 解析后 `sprotoloader.save(sp, slot)`，其他服务用 `sprotoloader.load(slot)` 取回；`lualib/sproto.lua` 提供 `host`/`attach`/`dispatch`。

关键边界：**鉴权（文本）与 RPC（二进制）在同一条 TCP 连接上前后衔接**。`200 <subid>\n` 文本行是分界，之后双方都切换为 sproto 帧。

## Goals / Non-Goals

**Goals**
- 登录后所有交互走 sproto 二进制 RPC，协议白名单约束输入。
- 复用现有 sproto/protoloader 设施与现有 `agent` 连接接管方式。
- 提供请求/响应与服务端主动 push 两种语义。

**Non-Goals**
- 不改 DH 鉴权；不做心跳超时、重连、真实玩法指令。

## Decisions（关键决策）

### 决策 1：帧格式 = 2 字节大端长度 + sproto 包体

与 skynet `netpack`/`client` 协议一致：每个消息前置 `string.pack(">I2", #body)`（大端 uint16），body 为 sproto 打包结果。

- 发送：`socket.write(fd, string.pack(">s2", body))`（`>s2` = 2 字节长度前缀 + 内容）。
- 接收：先 `socket.read(fd, 2)` 取长度，再 `socket.read(fd, sz)` 取整包。
- 上限 65535 字节，初期足够。

理由：与框架既有客户端协议一致，`socket.read(fd, n)` 精确读 n 字节天然支持定长帧；避免引入 netpack/gateserver 的更大改造。

### 决策 2：双 sproto 定义（c2s / s2c），各占一个 slot

- `game.sproto`（c2s，slot 3）：客户端→服务端的请求及其响应。
- `push.sproto`（s2c，slot 4）：服务端→客户端的主动推送（request，无 response）。

服务端：
```lua
local host   = sprotoloader.load(GAME_SLOT):host "package"   -- 解客户端请求
local sender = host:attach(sprotoloader.load(PUSH_SLOT))     -- 打包 push 给客户端
```
客户端（镜像）：
```lua
local host    = sproto.new(s2c_text):host "package"          -- 解服务端响应/推送
local request = host:attach(sproto.new(c2s_text))            -- 打包请求给服务端
```

理由：这是 skynet 官方 examples 的标准 RPC 模式，`.package{type,session}` 头驱动请求/响应配对，职责清晰。

### 决策 3：服务端按协议名分发 + 白名单拒绝

`agent` 读到整包后 `host:dispatch(msg)`：
```lua
local t, name, args, response = host:dispatch(msg)
if t == "REQUEST" then
    local f = RPC[name]
    if not f then
        skynet.error("[agent] reject unknown rpc: "..tostring(name))
        return  -- 或断开
    end
    local ret = f(args)
    if response then send_frame(fd, response(ret)) end
elseif t == "RESPONSE" then
    -- 服务端 push 暂不要求响应，忽略
end
```
- 未定义协议名 / 解码失败（`pcall(host.dispatch, ...)` 抛错）→ 记录并丢弃或断开。这满足"客户端不能乱发"。
- `RPC` 处理表即权威白名单：`heartbeat`、`ping`、`echo`、`get_userinfo`。

### 决策 4：协议内容（首批）

`game.sproto`：
```
.package { type 0 : integer  session 1 : integer }
heartbeat 1 { response { time 0 : integer } }
ping 2 { request { msg 0 : string } response { msg 0 : string } }
echo 3 { request { content 0 : string } response { content 0 : string } }
get_userinfo 4 { response { userid 0 : string  subid 1 : string  login_time 2 : integer } }
```
`push.sproto`：
```
.package { type 0 : integer  session 1 : integer }
push 1 { request { channel 0 : string  content 1 : string } }
```

### 决策 5：客户端命令 → RPC 映射

登录成功后：
- `ping [msg]` → `ping{msg}`，打印响应。
- `echo <text>` → `echo{content}`。
- `info` → `get_userinfo{}`。
- `heartbeat` → `heartbeat{}`。
- `quit`/`exit` → 关闭。
- 其它 → 本地提示"未知命令"，不发送。

客户端维护自增 `session`，发送请求时记录，收到响应按 `host:dispatch` 的 RESPONSE 分支回调匹配；服务端 push 走 REQUEST 分支直接打印。

### 决策 6：slot 常量集中

在 `config/config.lua` 增加（或新建小模块）：
```lua
M.proto_slot = { common = 1, login = 2, game = 3, push = 4 }
```
`protoloader` 与 `agent` 引用同一常量，避免魔数散落。

## Risks / 注意

- **客户端需要 sproto 库**：`client/main.lua` 须把 `package.path` 指向 `lualib/?.lua` 以 require `sproto`/`sprotoparser`，并直接读取 `.sproto` 文本解析（客户端无 sprotoloader slot）。
- **文本→二进制切换时序**：客户端读完 `200` 文本行后，接收缓冲 `L` 应已清空再进入帧模式；服务端写完 `200\n` 后下一次读即按帧处理。
- **粘包/半包**：用 `socket.read(fd, n)` 精确读规避；注意 `socket.read` 在连接断开时返回 `false`，需判断退出。

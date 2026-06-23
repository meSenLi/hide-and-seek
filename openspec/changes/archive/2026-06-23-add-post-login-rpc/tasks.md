# Tasks: 登录后 sproto RPC 交互

## 1. 协议定义

- [x] 1.1 新建 `config/proto/game.sproto`（c2s）：`.package{type,session}` + `heartbeat`/`ping`/`echo`/`get_userinfo`
- [x] 1.2 新建 `config/proto/push.sproto`（s2c）：`.package{type,session}` + `push`
- [x] 1.3 在 `config/config.lua` 增加 `M.proto_slot = {common=1, login=2, game=3, push=4}`

## 2. 协议加载

- [x] 2.1 `script/service/protoloader.lua` 注册 `game.sproto`→slot 3、`push.sproto`→slot 4

## 3. 服务端 agent

- [x] 3.1 引入 `sproto`/`sprotoloader`，构建 `host = load(game):host"package"` 与 `sender = host:attach(load(push))`
- [x] 3.2 增加帧收发：`read_packet`（读 2 字节长度 + 包体）、`send_frame`（`>s2` 前缀）
- [x] 3.3 用 `host:dispatch` + `RPC` 处理表替换原 echo 循环；未知/解码失败记录并拒绝
- [x] 3.4 实现处理函数：`heartbeat`、`ping`、`echo`、`get_userinfo`（返回 userid/subid/login_time）
- [x] 3.5 提供 `push(channel, content)` 用 `sender` 打包成帧发送（start 后发 welcome push；并暴露 `CMD.push`）
- [x] 3.6 连接断开（`socket.read` 返回 false）时 `skynet.exit()`

## 4. 客户端

- [x] 4.1 `client/main.lua` 设置 `package.path` 指向 `lualib/?.lua`，require `sproto`/`sprotoparser`
- [x] 4.2 读取 `game.sproto`/`push.sproto` 文本，构建 `host`（s2c）+ `request`（c2s attach）
- [x] 4.3 登录成功后**保留**接收缓冲（welcome push 可能已到达），切换为帧模式收发
- [x] 4.4 命令映射：`ping`/`echo`/`info`/`heartbeat` → RPC 请求（自增 session）
- [x] 4.5 主循环用 `host:dispatch` 区分 RESPONSE（匹配 session 打印）与 REQUEST（push，直接打印）
- [x] 4.6 未知命令本地提示，不发送

## 5. 验证

- [x] 5.1 `3rd/lua/lua -e "assert(loadfile('client/main.lua'))"` 语法校验 + sproto 端到端往返自测（echo/get_userinfo/push）通过
- [x] 5.2 起服（需 MongoDB）+ 跑客户端：`login` → `ping/echo/info/heartbeat` 收到正确响应
- [x] 5.3 发送未定义内容（构造非法帧）验证被拒绝、连接行为符合预期
- [x] 5.4 验证服务端 push 能被客户端收到并展示

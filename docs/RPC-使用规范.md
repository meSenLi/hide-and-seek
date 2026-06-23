# RPC 使用规范

## 添加 RPC 的步骤

### 1. 在 `game.sproto` 中定义协议

```sproto
-- config/proto/game.sproto
mypackage 7 {
    request {
        name 0 : string      -- 必填字段
        count 1 : integer    -- 必填字段
    }
    response {
        ok 0 : integer
    }
}
```

sproto 自动校验类型，非法请求在解码阶段被拒绝。

### 2. 在 handler 中实现

**agent_boot.lua（核心 RPC）：**

```lua
local rpc = {}

function rpc.mypackage(args)
    -- args.name 必然是 string, args.count 必然是 integer
    return { ok = 1 }
end

session:use_rpc(rpc)
```

**系统模块（如 inventory）：**

```lua
-- systems/inventory.lua
inventory.rpc = {}

function inventory.rpc.add_item(args)
    return { ok = 1 }
end
```

无需任何注册代码，session 自动收集所有 `system.rpc` 表。

## 可选：限流

```lua
local decorator = require "agent_layered.decorator"

rpc.echo = decorator.ratelimit(5, 1000)(function(args)
    -- 1000ms 内最多 5 次，超出返回 { error = "rate_limit_exceeded" }
    return { content = args.content }
end)
```

## 规则

1. 新增 RPC **必须先** 在 `game.sproto` 定义协议（类型声明 = 安全校验）
2. 核心 RPC 写在 `agent_boot.lua` 的 `rpc` 表上
3. 系统专用 RPC 写在 `system.rpc` 表上（`rpc = {}` 即可）
4. 不要手动调 `session:use_rpc` — session 自动合并
5. 参数类型只用 `string` / `integer`

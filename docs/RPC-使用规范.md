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
    return { ok = 1 }
end

session:use_rpc(rpc)
```

**系统模块（如 inventory）：**

```lua
local base = require "agent_layered.systems.base"
local mysys = base.new { data = {} }
mysys.rpc = {}

function mysys.rpc.my_rpc(args) ... end
```

无需注册，session 自动合并所有 `system.rpc`。

## 数据规则

| 规则 | 说明 |
|------|------|
| `_` 前缀 | 私有字段，`decorator.public()` 自动过滤，不下发客户端 |
| 无 `_` 前缀 | 公开字段 |
| `save()` 返回值 | 决定存盘内容（公开+私有都能存） |
| `save_interval` | ms，自动存盘间隔；nil = 仅退出时存 |

## 系统基类 (systems/base.lua)

```
base.new(t)              -- 创建子系统（原型继承）
init(agent)              -- 设置 _agent，初始化 _timers
save()     → table       -- 存盘数据
load(state)              -- 恢复
shutdown()               -- 清理 _timers + _agent
add_timer(sec, fn, repeat)→id -- 定时器
cancel_timer(id)              -- 取消
```

新建系统模板：

```lua
local base = require "agent_layered.systems.base"
local sys = base.new { items = {}, gold = 0 }

sys.rpc = {}
sys.save_interval = 60000

function sys.rpc.add(args) ... end
function sys:init(agent)    base.init(self, agent); ... end
function sys:save()         return { gold = self.gold } end
function sys:load(state)    ... end
function sys:shutdown()     base.shutdown(self) end

return sys
```

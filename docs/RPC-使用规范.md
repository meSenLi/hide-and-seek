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

## 新增系统说明

### 1. 系统文件位置

- 新系统一般放在 `script/service/agent_layered/systems/` 下
- 文件名应与模块名一致，例如 `script/service/agent_layered/systems/achievement.lua`
- 需要在 `agent_boot.lua` 的 `agent.systems` 中注册

### 2. 基础结构

```lua
local base = require "agent_layered.systems.base"
local sys = base.new {
    unlocked = {},
    points = 0,

    __fields__ = {
        unlocked = { persist = true, sync = true },
        points = { persist = true, sync = false },
    },
}

sys.rpc = {}
```

- `base.new(t)` 会把 `sys` 继承自系统基类
- `sys.rpc` 是显式 RPC 映射表，可放置函数
- `__fields__` 控制哪些字段需要持久化和同步

### 3. 数据声明说明

- `__fields__` 是显式字段元信息表，只有在这里声明的字段才会持久化
- 支持两种形式：
  - 布尔值：`true` 相当于 `{ persist = true, sync = true }`
  - 表：`{ persist = bool, sync = bool }`
- 默认值为 `{ persist = false, sync = false }`
- `persist = true` 表示字段会被存盘
- `sync = true` 表示字段可对外同步

示例：

```lua
__fields__ = {
    items = { persist = true, sync = true },
    gold = { persist = true, sync = false },
    cache = { persist = false, sync = false },
}
```

### 4. 公有/私有字段约定

- 公开字段：不以下划线 `_` 开头
- 私有字段：以下划线 `_` 开头，表示内部实现细节
- `save()` 返回值决定存盘内容，私有字段也可以存盘

### 5. RPC 新增说明

系统 RPC 有两种写法：

1. 显式注册 `sys.rpc`

```lua
sys.rpc.add_item = function(args)
    ...
end
```

2. 使用 `rpc_*` 方法自动收集

```lua
function sys:rpc_add_item(args)
    ...
end
```

- `rpc_*` 方法会被自动映射为 RPC 名称去掉前缀后的部分
- `sys.rpc` 表中的函数会直接作为 RPC 处理器
- RPC 函数签名为 `function(args)` 或 `function(self, args)`
- 返回值应为一个结果表，如 `{ ok = 1 }`

### 6. 生命周期方法

建议实现以下方法：

- `function sys:init(agent, state)`
  - 调用 `self.super.init(self, agent, state)` 或 `base.init(self, agent, state)`
  - 绑定 `self.agent`、`self.log`、计时器等基础功能
  - 让基类帮你自动恢复 `__fields__`

- `function sys:load(state)`
  - 读取 `state` 并赋值给系统字段
  - 基类默认实现会自动恢复 `__fields__`

- `function sys:save()`
  - 返回一个表用于持久化
  - 基类默认实现会保存 `__fields__` 中声明的字段

- `function sys:init_finish()`
  - 可选，所有系统初始化完成后调用

- `function sys:shutdown()`
  - 清理定时器与引用
  - 最后调用 `self.super.shutdown(self)` 或 `base.shutdown(self)`

### 7. 示例系统

```lua
local base = require "agent_layered.systems.base"
local achievement = base.new {
    unlocked = {},
    points = 0,

    __fields__ = {
        unlocked = { persist = true, sync = true },
        points = { persist = true, sync = true },
    },
}

function achievement:rpc_add_point(args)
    self.points = self.points + (args.amount or 1)
    return { points = self.points }
end

function achievement:rpc_get_status(args)
    return { unlocked = self.unlocked, points = self.points }
end

function achievement:init(agent, state)
    self.super.init(self, agent, state)
end

function achievement:shutdown()
    self.super.shutdown(self)
end

return achievement
```

### 8. 其它注意点

- 新系统添加后，确保 `agent_boot.lua` 的 `agent.systems` 已注册该模块
- 如需订阅事件，可使用 `self.agent.events:subscribe(...)`
- 如需日志输出，可使用 `self.log:info(...)`、`self.log:error(...)`
- 推荐 RPC 名称保持小写、简洁和语义明确
```

# 躲猫猫派对游戏 - Unity 客户端

## 技术选型

| 维度 | 选型 | 说明 |
|------|------|------|
| 引擎 | Unity 2022.3 LTS | 稳定长期支持版本 |
| 渲染 | URP | 通用渲染管线，跨平台 |
| 网络协议 | **Sproto 原生二进制** over TCP | 与后端完全一致，无需改后端 |
| 鉴权 | DH(P=0xffffffffffffffc5, G=5) + HMAC-MD5-64 + DES-ECB | 严格对齐 lua-crypt.c |
| 异步 | UniTask | 零 GC async/await |
| UI | UGUI + DOTween | 内置 UI 系统 |

## DH 加密参数（关键）

```
P = 0xffffffffffffffc5  （最大 64 位素数）
G = 5
密钥长度 = 8 字节（uint64 小端）
DH-Exchange = G^priv mod P
DH-Secret = peerPub^priv mod P
HMAC-MD5-64 = HMAC-MD5(data, key) 取前 8 字节
DES = ECB 模式, 8 字节密钥, ISO 7816-4 填充
```

以上参数已完整实现在 `CryptoUtil.cs` 中，与 `lualib-src/lua-crypt.c` 完全一致。
| 业务通信 | Sproto RPC (2字节长度前缀帧) | request/response + push |
| 异步 | UniTask | 零 GC async/await |
| UI | UGUI + DOTween | 内置 UI 系统 |
| 序列化 | Sproto (C# port) | 与后端 .sproto 文件共享 |

## 架构概览

```
GameManager (入口/生命周期)
  ├── RpcClient (RPC 层: send_rpc / on_push)
  │     ├── TcpConnection (传输层: TCP Socket 帧收发)
  │     │     └── SprotoCodec (编解码: .sproto → C# 对象)
  │     └── DhAuthHandler (鉴权: DH 握手)
  ├── Systems (业务系统)
  │     ├── LoginSystem
  │     ├── PlayerSystem
  │     ├── InventorySystem
  │     └── ChatSystem
  ├── EventBus (事件总线)
  └── UIManager (界面管理)
```

## 通信协议

### 阶段 A: 鉴权（文本行协议 `\n` 分隔）

```
S → C: base64(8字节 challenge)
C → S: base64(8字节 client DH key)
S → C: base64(DH-Exchange(server key))
双方各自计算 secret = DH-Secret(...)
C → S: base64(HMAC(challenge, secret))
C → S: DES(token), token = base64(user)@base64(server):base64(password)
S → C: 200 base64(subid)
```

### 阶段 B: 业务通信（二进制帧）

```
帧格式: [2字节大端长度][sproto包体]

Sproto 包体结构:
  .package { type:0=REQUEST/1=RESPONSE, session }

RPC 请求: type=REQUEST, session=N  →  响应: type=RESPONSE, session=N
Push 推送: type=REQUEST, session=0 (直接分发)
```

## 快速开始

1. 用 Unity Hub 创建 Unity 2022.3 URP 项目
2. 将 `Assets/` 下所有文件复制到 Unity 项目的 `Assets/` 目录
3. 将 `config/proto/game.sproto` 和 `config/proto/push.sproto` 复制到 `Assets/Config/`
4. 安装依赖包（UniTask 等）
5. 打开 `Assets/Scenes/Boot.unity`，点击 Play
6. 确保后端已启动: `bash shell/run.sh`

```
创建 Unity 2022.3 URP 项目
将 Scripts 复制到项目 Assets/Scripts/
安装 UniTask（Package Manager → https://github.com/Cysharp/UniTask.git?path=src/UniTask/Assets/Plugins/UniTask）
创建 Boot 场景，挂 GameManager + UIManager
创建 Login/Lobby Canvas 绑定 UI 组件
确保后端运行 → Play 测试
```

## 目录结构

```
Assets/
├── Scripts/
│   ├── Core/           # 核心框架层
│   │   ├── Network/    # TCP 连接 + Sproto 编解码
│   │   ├── Auth/       # DH 鉴权握手
│   │   ├── Rpc/        # RPC 客户端
│   │   ├── Event/      # 事件总线
│   │   └── Util/       # 工具类
│   ├── Systems/        # 业务系统（对应后端 systems/）
│   ├── Game/           # 游戏模式/实体
│   └── UI/             # UI 面板
├── Config/             # 协议文件
├── Scenes/             # 场景
├── Prefabs/            # 预制体
└── Resources/          # 动态资源
```

## 与后端对应关系

| Unity | 后端 |
|-------|------|
| `BaseSystem.cs` | `systems/base.lua` |
| `LoginSystem.cs` | `account.lua`（鉴权）+ `systems/core.lua` |
| `InventorySystem.cs` | `systems/inventory.lua` |
| `RpcClient.cs` | `session.lua` |
| `TcpConnection.cs` | Gate TCP 层 |
| `SprotoCodec.cs` | `sproto.lua` / `sprotoloader.lua` |

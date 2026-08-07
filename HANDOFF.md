# IBKR_Float（OpenIBKR）macOS 技术方案与开发交接

## 1. 文档目的

本文档用于把 `IBKR_Float` 项目及其 macOS 产品 OpenIBKR 交接给一个新的开发 session。新 session 应以本文档为主要技术约束，从零创建一个独立 Git 仓库并分阶段实现。

本项目不是现有 `wealth` Web 项目的新页面，也不应依赖其 FastAPI、PostgreSQL、Next.js、部署环境或 Git 历史。现有 `wealth` 项目继续负责历史资产管理、Flex 日报同步和 Web Dashboard；OpenIBKR 是一个独立的、本地优先的 macOS 实时悬浮应用，其代码仓库名为 `IBKR_Float`。

本文档所在的当前仓库仅作为方案交接位置。正式代码应创建在新的仓库中，例如：

```text
/Users/<user>/Projects/IBKR_Float
```

推荐仓库名：`IBKR_Float`。推荐产品名：`OpenIBKR`。

---

## 2. 最终选型摘要

### 2.1 已确定的技术选型

| 领域 | 最终选择 | 说明 |
| --- | --- | --- |
| 运行环境 | Apple Silicon Mac | IB Gateway、Python Helper 和原生 App 都运行在本机 |
| 原生 UI | SwiftUI + 少量 AppKit | SwiftUI 构建内容，AppKit `NSPanel` 实现始终置顶及 Spaces 行为 |
| 本地后端 | Python | 使用 IBKR 官方支持的 TWS API Python 实现 |
| 本地通信 | HTTP + WebSocket，仅监听 `127.0.0.1` | CRUD/快照走 HTTP，实时账户及报价走 WebSocket |
| 本地数据库 | SQLite | 保存设置、自选、合约映射、最新快照及可选分钟历史 |
| IBKR 数据入口 | IB Gateway + TWS API | 账户 P&L 使用 `reqPnL`，行情使用 `reqMktData` |
| 版本控制 | 新建独立 GitHub 仓库 | 不 fork、不使用 submodule、不长期依赖原 `wealth` 仓库 |
| 发布方式 | 站外签名与 Notarization | MVP 不考虑 Mac App Store |

### 2.2 明确不采用的方案

- 不在第一版使用 Go 或 Rust。IBKR 没有官方 Go/Rust TWS API SDK，协议维护风险大于性能收益。
- 不使用 MCP 作为实时数据主链路。MCP 可在未来作为查询或 AI 控制面，但不承担 1 秒级持续订阅。
- 不使用 Client Portal Gateway 作为 MVP 数据源。它的浏览器认证、2FA、每日会话和保活要求更复杂。
- 不让 SwiftUI 直接连接 IB Gateway。
- 不让 SwiftUI 直接读写 SQLite。
- 不连接现有 `wealth` PostgreSQL，也不复用其数据库迁移。
- 不把 IB Gateway、TWS 或用户登录凭据打包进应用。
- 不实现下单、改单、撤单或任何交易功能。
- 不永久保存每一个行情 tick。

### 2.3 核心产品目标

实现一个 Apple Silicon 原生 macOS 应用，以可折叠、可拖动、始终置顶的悬浮窗显示：

1. IBKR 账户当日盈亏 `dailyPnL`。
2. IBKR 账户未实现盈亏 `unrealizedPnL`。
3. 可选显示已实现盈亏 `realizedPnL` 和净值等补充字段，但不能阻塞 MVP。
4. 少量自选标的的最新价格、当日涨跌额、当日涨跌幅。
5. IB Gateway、账户数据和市场数据的实时连接状态。
6. 所有数据的来源时间与过期状态。

目标是“收到 IBKR 更新后，界面最多约 1 秒内反映”，而不是伪造每秒都有新市场数据。

---

## 3. 范围与非目标

### 3.1 MVP 范围

- 单个本机用户。
- 单个 IBKR 登录会话。
- 默认支持一个账户；如果登录名可见多个账户，提供账户选择设置。
- 股票类自选优先；数据库模型必须能够扩展到期权、期货和其他 `secType`。
- 自选数量默认上限 30，可配置。
- 账户 P&L 推送。
- 自选报价动态订阅和取消订阅。
- 本地 SQLite 持久化。
- IB Gateway 断线检测、指数退避重连和重新订阅。
- SwiftUI/AppKit 悬浮窗、菜单栏入口、折叠与窗口位置恢复。
- Apple Silicon 开发构建和可签名的发布构建。

### 3.2 MVP 非目标

- 任何交易或订单管理能力。
- 多用户、团队共享或云端账户体系。
- 跨 Mac 同步。
- 与现有 `wealth` 项目双向实时同步。
- 图表、K 线、技术指标和历史回测。
- 高并发行情、Level 2、市深或逐笔成交。
- 完全无头登录或自动填写 IBKR 密码/2FA。
- Mac App Store 发布。
- iOS/iPadOS 版本。

### 3.3 后续可选能力

- 通过 HTTP API 将分钟级 P&L 快照同步到现有 `wealth` 服务。
- 自选分组、排序和颜色标记。
- 多账户聚合。
- 系统通知与盈亏阈值提醒。
- 历史分钟曲线。
- MCP 查询接口。

这些能力必须放在 MVP 完成之后，不得提前扩大第一版范围。

---

## 4. 总体架构

```text
┌───────────────────────────────────────────────────────────┐
│                         macOS                             │
│                                                           │
│  ┌──────────────┐       TWS Socket API                    │
│  │  IB Gateway  │◀──────────────────────┐                 │
│  └──────────────┘                       │                 │
│                                         │                 │
│                              ┌──────────▼──────────┐      │
│                              │ Python Local Helper │      │
│                              │                     │      │
│                              │ IBKR connection     │      │
│                              │ subscription mgr    │      │
│                              │ in-memory snapshot  │      │
│                              │ SQLite owner        │      │
│                              │ local HTTP/WS       │      │
│                              └───────┬───────┬─────┘      │
│                                      │       │             │
│                                  HTTP│       │WebSocket    │
│                                      │       │             │
│                              ┌───────▼───────▼─────┐      │
│                              │ SwiftUI + AppKit App │      │
│                              │ NSPanel / Menu Bar   │      │
│                              └──────────────────────┘      │
│                                                           │
│  SQLite: ~/Library/Application Support/OpenIBKR/       │
└───────────────────────────────────────────────────────────┘
```

### 4.1 进程职责

#### IB Gateway

- 由用户单独安装和登录。
- 只接受本机 API 连接。
- 开启 Read-Only API。
- 开发期默认使用 Paper Trading。
- 开启 Auto Restart，但不自动化密码或 2FA。

#### Python Local Helper

- 作为本地数据平面和唯一数据库写入者。
- 管理 IBKR Socket 连接和状态机。
- 订阅账户 P&L、合约详情和自选行情。
- 在内存中维护最新状态。
- 对 Swift App 提供本地 HTTP 和 WebSocket。
- 管理 SQLite schema 和迁移。
- 负责日志、数据过期和错误归一化。
- 不调用任何订单相关 API。

#### SwiftUI/AppKit App

- 负责所有用户界面。
- 启动、监控并在退出时终止 Helper。
- 通过本地协议获取数据，不了解 IBKR 回调细节。
- 保存非敏感 UI 偏好；业务数据仍由 Helper 管理。
- 使用 `NSPanel` 实现悬浮窗口。

### 4.2 Helper 生命周期

MVP 使用“App 与 Helper 同生命周期”模式：

1. Swift App 启动。
2. App 生成一次性随机会话令牌。
3. App 启动已签名并内嵌于 `.app` 的 Python Helper 可执行文件。
4. Helper 只绑定 `127.0.0.1` 的随机空闲端口。
5. Helper 在 stdout 输出一行启动握手 JSON，包含端口、进程 ID 和协议版本。
6. Swift App 使用令牌调用 Helper。
7. App 退出时通知 Helper 优雅关闭；若超时，再终止子进程。

推荐握手示例：

```json
{
  "type": "ready",
  "protocol_version": 1,
  "port": 49321,
  "pid": 12345
}
```

会话令牌应通过子进程环境变量或受控 stdin 传入，仅在本次运行有效，不写入磁盘。

第一阶段开发允许手动启动 Helper；正式打包阶段再完成子进程托管。

---

## 5. 仓库设计

推荐新仓库结构：

```text
IBKR_Float/
├── app/
│   ├── OpenIBKR.xcodeproj
│   ├── OpenIBKR/
│   │   ├── App/
│   │   ├── Models/
│   │   ├── Networking/
│   │   ├── Views/
│   │   ├── ViewModels/
│   │   ├── Windowing/
│   │   └── Resources/
│   ├── OpenIBKRTests/
│   └── OpenIBKRUITests/
├── helper/
│   ├── pyproject.toml
│   ├── src/
│   │   └── wealth_helper/
│   │       ├── api/
│   │       ├── db/
│   │       ├── ibkr/
│   │       ├── models/
│   │       ├── services/
│   │       └── main.py
│   └── tests/
├── protocol/
│   ├── README.md
│   ├── messages.schema.json
│   └── examples/
├── packaging/
│   ├── build-helper.sh
│   ├── sign-app.sh
│   └── create-dmg.sh
├── docs/
│   ├── DEVELOPMENT.md
│   ├── IBKR_SETUP.md
│   └── RELEASE.md
├── .github/workflows/
├── .gitignore
├── HANDOFF.md
├── LICENSE
└── README.md
```

### 5.1 Git 规则

- `main` 始终保持可构建。
- 使用短期功能分支，例如：
  - `feat/ibkr-spike`
  - `feat/local-helper`
  - `feat/floating-panel`
  - `feat/watchlist`
  - `feat/app-packaging`
- 每个阶段通过 PR 合并回 `main`。
- 不把 SQLite、日志、IBKR 下载包、API 凭据、签名证书或 Notarization 密钥提交到 Git。
- 不复制现有 `wealth/.env`。
- 不使用 Git submodule 引用原项目。

### 5.2 版本固定

首次技术验证时记录并固定：

- macOS 版本。
- Xcode 和 Swift 版本。
- Python 版本。
- IB Gateway Stable/Latest 版本。
- TWS API 版本。
- Helper Python 依赖版本。

IBKR 官方 Python API 应优先从官方 TWS API 分发包安装。不要默认依赖未经确认版本的 PyPI `ibapi`。是否可以把 SDK 源码或 wheel 纳入仓库，必须先确认 IBKR 分发许可；默认做法是记录官方安装步骤并在构建机安装指定版本。

---

## 6. Python Helper 详细设计

### 6.1 推荐技术栈

- Python：选择本机与当前 TWS API 兼容的稳定版本，首次验证后锁定。
- IBKR：官方 TWS API Python Client。
- 本地 API：FastAPI。
- ASGI Server：Uvicorn。
- SQLite：Python 标准库 `sqlite3`，减少 ORM 和打包复杂度。
- 数据模型：Pydantic。
- 测试：pytest。
- 打包：优先验证 PyInstaller 的 arm64 构建；若失败，再评估嵌入式 Python 运行时方案。

### 6.2 并发模型

IBKR TWS API 的网络循环与 FastAPI asyncio 循环必须隔离：

1. `EClient.run()` 在专用线程运行。
2. 所有 `EWrapper` 回调只做轻量解析，不直接访问 SQLite 或执行 HTTP 广播。
3. 回调通过 `asyncio_loop.call_soon_threadsafe()` 把规范化事件放入 asyncio 队列。
4. asyncio 消费者更新内存快照、广播 WebSocket，并按策略持久化。
5. 所有 IBKR 请求由一个 Subscription Manager 序列化，避免重复请求 ID 和竞态。

禁止在 IBKR 回调线程执行耗时数据库事务。

### 6.3 IBKR 连接配置

所有参数可配置，开发默认值：

| 参数 | 开发默认值 | 说明 |
| --- | --- | --- |
| Host | `127.0.0.1` | 只连接本机 Gateway |
| Paper Gateway Port | `4002` | Paper Trading 默认端口 |
| Live Gateway Port | `4001` | Live 默认端口 |
| Client ID | `71` | 可配置且必须避免与其他客户端冲突 |
| Read-only | Gateway 中开启 | 应用代码也不得暴露订单接口 |
| Reconnect Backoff | 1–30 秒 | 指数退避并加入少量 jitter |

实际端口以用户在 IB Gateway 中的配置为准，不能硬编码为不可修改。

### 6.4 账户发现与 P&L

建议流程：

1. 连接成功并收到有效会话信号。
2. 使用 managed accounts 回调获取可见账户。
3. 如果只有一个账户，自动选中。
4. 如果有多个账户，等待用户从设置中选中并持久化选择。
5. 调用 `reqPnL(reqId, account, "")`。
6. 把回调规范化为：
   - `daily_pnl`
   - `unrealized_pnl`
   - `realized_pnl`
   - `account_id_masked`
   - `currency`，若 API 数据源能可靠获得
   - `source_timestamp`
   - `received_at`
7. 账户切换时先取消旧订阅，再订阅新账户。

注意：IBKR P&L 的每日重置时点受 TWS/IB Gateway 设置和产品规则影响，不应把它解释成北京时间零点。界面应标注为“IBKR Daily P&L”。

### 6.5 合约与自选订阅

不能把股票代码 `symbol` 当作全局唯一标识。核心标识使用 IBKR `conId`。

每个 instrument 至少保存：

- `conid`
- `symbol`
- `local_symbol`
- `sec_type`
- `exchange`
- `primary_exchange`
- `currency`
- `display_name`
- `contract_details_json`，可选

添加自选流程：

1. 用户输入 symbol 或搜索词。
2. Helper 请求合约匹配/合约详情。
3. 若有多个匹配，返回候选列表给 Swift App。
4. 用户选择明确合约。
5. 按 `conId` 保存并发起 `reqMktData`。
6. 收到报价后更新内存快照。
7. 删除自选时调用 `cancelMktData`，再删除自选关系。

首版可优化美国股票的快捷添加，但底层模型不得只保存 symbol。

### 6.6 行情字段

MVP 需要规范化：

- `last_price`
- `bid_price`
- `ask_price`
- `close_price` 或 previous close
- `change_amount`
- `change_percent`
- `market_data_type`：real-time、delayed、frozen、delayed-frozen、not-subscribed
- `source_timestamp`
- `received_at`

计算规则：

```text
change_amount = last_price - close_price
change_percent = change_amount / close_price
```

当 `last_price` 或 `close_price` 缺失/无效时，涨跌额和涨跌幅必须为 `null`，不能显示 0。

### 6.7 动态订阅管理

Subscription Manager 应维护：

```text
conId -> requestId -> subscription state
```

必须支持：

- 启动时恢复 SQLite 自选并订阅。
- 运行中新增订阅，无需重启 Helper。
- 运行中取消订阅。
- 防止同一 `conId` 重复订阅。
- 重连后重新提交全部活跃订阅。
- 达到自选上限时返回明确错误。
- 记录 market data permission 和 pacing 错误，但不导致整个进程退出。

### 6.8 连接状态机

推荐状态：

```text
starting
gateway_unavailable
connecting
connected
subscribing
live
degraded
reconnecting
authentication_required
stopped
```

至少处理：

- Gateway 未启动或端口错误。
- 连接被拒绝。
- IBKR 网络中断。
- 1100：连接丢失。
- 1101：恢复但数据丢失，需要重新提交订阅。
- 1102：恢复且数据保留。
- 1300：Socket 端口被重置。
- 行情权限不足。
- competing session。
- Helper 收到退出信号。

状态变化必须发送到 Swift App，并写入有限长度的本地日志。

### 6.9 数据过期策略

每个数据对象保存两个时间：

- `source_timestamp`：IBKR 提供的源时间；如果没有，允许为空。
- `received_at`：Helper 收到回调的 UTC 时间。

基础规则：

- Gateway 断线后，所有数据立即标为 stale，但仍保留最后值。
- 账户 P&L 在已连接状态下超过约 10 秒未更新，标为 stale/degraded。
- 行情长时间不更新不一定代表断线，可能是停牌或休市。第一版以连接状态和最后更新时间为主，不做复杂交易日历推断。
- UI 必须同时显示最后更新时间和连接状态。

### 6.10 限流与持久化

- IBKR 回调可以高于 UI 刷新频率。
- Helper 在内存中接收所有需要的回调。
- 对 Swift App 的 quote 广播按合约合并，最大约每秒一次。
- 账户 P&L 收到后可立即广播，但 UI 仍可做 1 Hz 合并。
- 最新值可以覆盖写入 SQLite。
- 历史 P&L 默认按分钟保存，而不是每秒保存。
- 不保存每个报价 tick；如需恢复界面，只保存每个自选的最新报价。

---

## 7. 本地 API 与 WebSocket 协议

### 7.1 安全约束

- 只监听 `127.0.0.1`。
- 使用随机端口。
- 所有请求必须带本次进程的 Bearer token。
- 不启用局域网访问。
- 不提供订单 API。
- 日志不得记录 token、完整账户号、密码或 2FA 信息。

### 7.2 HTTP API 建议

```text
GET    /v1/health
GET    /v1/snapshot
GET    /v1/settings
PATCH  /v1/settings
GET    /v1/accounts
PUT    /v1/accounts/selected
GET    /v1/watchlist
POST   /v1/instruments/search
POST   /v1/watchlist
DELETE /v1/watchlist/{conid}
POST   /v1/connection/reconnect
POST   /v1/shutdown
```

HTTP API 使用明确的错误代码和机器可读 error code，例如：

```json
{
  "error": {
    "code": "GATEWAY_UNAVAILABLE",
    "message": "IB Gateway is not reachable on 127.0.0.1:4002",
    "retryable": true
  }
}
```

### 7.3 WebSocket

```text
GET /v1/stream
```

统一 envelope：

```json
{
  "protocol_version": 1,
  "sequence": 123,
  "type": "account_pnl",
  "source_timestamp": "2026-08-06T02:30:00Z",
  "received_at": "2026-08-06T02:30:00.200Z",
  "payload": {}
}
```

MVP 消息类型：

- `hello`
- `connection_state`
- `account_pnl`
- `quote`
- `watchlist_changed`
- `settings_changed`
- `error`
- `heartbeat`

WebSocket 建立后先发送当前完整 snapshot，再发送增量事件，防止 UI 必须等待下一条市场数据。

### 7.4 协议版本

- 第一版固定 `protocol_version = 1`。
- Swift 必须拒绝无法识别的主版本。
- `protocol/messages.schema.json` 作为 Python 和 Swift 的共同契约。
- 为每种消息保留 JSON fixture，用于跨语言兼容测试。

---

## 8. SQLite 设计

### 8.1 存储位置

```text
~/Library/Application Support/OpenIBKR/openibkr.sqlite3
```

日志建议放在：

```text
~/Library/Logs/OpenIBKR/
```

### 8.2 SQLite 设置

- `PRAGMA journal_mode=WAL`
- `PRAGMA foreign_keys=ON`
- 合理设置 `busy_timeout`
- 所有业务写入由 Helper 单进程负责
- 批量写入使用事务
- schema migration 在 Helper 启动时串行执行

### 8.3 推荐表

#### `schema_migrations`

```text
version INTEGER PRIMARY KEY
applied_at TEXT NOT NULL
```

#### `settings`

```text
key TEXT PRIMARY KEY
value_json TEXT NOT NULL
updated_at TEXT NOT NULL
```

#### `accounts`

```text
account_id TEXT PRIMARY KEY
display_name TEXT
base_currency TEXT
is_selected INTEGER NOT NULL DEFAULT 0
updated_at TEXT NOT NULL
```

完整账户号属于敏感信息。日志和 UI 默认只显示掩码；数据库文件权限应限制为当前用户。

#### `instruments`

```text
conid INTEGER PRIMARY KEY
symbol TEXT NOT NULL
local_symbol TEXT
sec_type TEXT NOT NULL
exchange TEXT
primary_exchange TEXT
currency TEXT NOT NULL
display_name TEXT
contract_details_json TEXT
created_at TEXT NOT NULL
updated_at TEXT NOT NULL
```

#### `watchlist`

```text
conid INTEGER PRIMARY KEY REFERENCES instruments(conid) ON DELETE CASCADE
sort_order INTEGER NOT NULL
is_enabled INTEGER NOT NULL DEFAULT 1
created_at TEXT NOT NULL
updated_at TEXT NOT NULL
```

#### `latest_account_pnl`

```text
account_id TEXT PRIMARY KEY REFERENCES accounts(account_id)
daily_pnl TEXT
unrealized_pnl TEXT
realized_pnl TEXT
currency TEXT
source_timestamp TEXT
received_at TEXT NOT NULL
is_stale INTEGER NOT NULL DEFAULT 0
```

金额建议以字符串形式序列化 Decimal，避免不必要的二进制浮点误差扩散。

#### `pnl_minute_snapshots`

```text
account_id TEXT NOT NULL
bucket_timestamp TEXT NOT NULL
daily_pnl TEXT
unrealized_pnl TEXT
realized_pnl TEXT
currency TEXT
PRIMARY KEY (account_id, bucket_timestamp)
```

#### `latest_quotes`

```text
conid INTEGER PRIMARY KEY REFERENCES instruments(conid) ON DELETE CASCADE
last_price TEXT
bid_price TEXT
ask_price TEXT
close_price TEXT
change_amount TEXT
change_percent TEXT
market_data_type TEXT
source_timestamp TEXT
received_at TEXT NOT NULL
is_stale INTEGER NOT NULL DEFAULT 0
```

#### `connection_events`，可选

只保存有限数量或有限天数，用于诊断。必须定期清理。

### 8.4 数据保留

- 最新 P&L：覆盖更新。
- 最新报价：覆盖更新。
- P&L 分钟快照：默认保留 90 天，可配置。
- 连接事件：默认保留 14 天。
- 不保存原始逐 tick 行情。

---

## 9. SwiftUI/AppKit 详细设计

### 9.1 最低系统与构建环境

- 仅支持 Apple Silicon。
- 最低 macOS 版本建议从 macOS 14 开始；新 session 应根据实际目标设备确认。
- 使用当前稳定版 Xcode 创建项目，记录确切版本。
- SwiftUI 负责视图，AppKit 负责特殊窗口行为。

### 9.2 窗口实现

创建自定义 `NSPanel` 或 `NSPanel` 控制器，并托管 SwiftUI `NSHostingView`。

推荐行为：

- `level = .floating`
- `hidesOnDeactivate = false`
- 支持 `.canJoinAllSpaces`
- 支持 `.fullScreenAuxiliary`，但提供用户开关
- 无传统标题栏或使用隐藏标题栏
- 可拖动
- 可折叠为紧凑模式
- 保存窗口位置、尺寸和屏幕信息
- 外接显示器断开时把窗口恢复到可见区域
- 默认允许鼠标交互，不做 click-through

不能只依赖 SwiftUI `WindowGroup` 实现始终置顶。

### 9.3 UI 信息架构

#### 紧凑模式

- 当日盈亏
- 未实现盈亏
- 连接状态点
- 展开按钮

#### 展开模式

- 账户 P&L 区域
- 自选列表
- 最后更新时间
- IB Gateway 状态
- 添加自选按钮
- 设置入口

#### 自选行

- Symbol / display name
- 最新价
- 涨跌额
- 涨跌幅
- real-time/delayed/frozen 状态
- stale 指示

### 9.4 菜单栏

提供状态栏图标：

- 显示/隐藏悬浮窗
- 连接状态摘要
- 打开设置
- 重新连接
- 打开 IB Gateway 设置说明
- 退出

### 9.5 ViewModel

Swift 侧维护单一应用状态：

- `HelperProcessState`
- `GatewayConnectionState`
- `AccountPnLState`
- `[WatchlistQuoteState]`
- `UserPreferences`
- `LastError`

WebSocket 事件在后台解码，所有 UI 更新切换到 `MainActor`。对高频 quote 更新进行每秒合并，避免 SwiftUI 过度重绘。

### 9.6 数值显示

- 不使用原始 `Double` 做金额格式化的业务真值。
- JSON 金额按字符串传输，Swift 使用 `Decimal` 解码。
- 使用账户/标的币种格式化。
- 正数、负数和零必须有一致视觉语义。
- `null` 显示 `—`，不能显示 `$0.00`。
- 默认掩码账户号。

### 9.7 登录启动

发布阶段使用 `SMAppService` 支持“登录时启动”。

登录启动只启动 OpenIBKR App 和其 Helper，不负责自动登录 IB Gateway。如果 Gateway 未登录，UI 显示可恢复状态和操作说明。

---

## 10. 安全设计

### 10.1 IBKR 安全边界

- 应用不收集、不保存 IBKR 用户名、密码或 2FA。
- 用户在官方 IB Gateway UI 中完成登录。
- Gateway 开启 Read-Only API。
- 仅允许 localhost Socket Client。
- 不实现、导入或暴露订单相关请求。
- 如果未来添加交易功能，必须重新做独立安全评审，不能在当前结构上悄悄扩展。

### 10.2 本地 API

- 随机 loopback 端口。
- 一次性 Bearer token。
- token 不落盘。
- Helper stdout 握手不得输出 token。
- 对请求体设置合理大小限制。
- WebSocket 客户端只允许一个受信 App 实例，或限制很小的连接数。

### 10.3 本地数据

- Application Support 目录权限只允许当前用户。
- 账户号在日志中掩码。
- 日志不得写入原始 IBKR 回调全集。
- 崩溃报告必须避免包含 token、完整账户号和合约原始响应。
- 签名和 Notarization 凭据只存在本地 Keychain 或 CI Secret。

### 10.4 发布安全

- Helper 必须先单独 code sign，再作为 nested executable 签入 App。
- 开启 Hardened Runtime。
- 对最终 `.app` 和 `.dmg` 做签名验证。
- 提交 Apple Notarization 并 staple。
- MVP 先做 Developer ID 站外分发，不做 Mac App Store Sandbox。

---

## 11. 日志与可观测性

Helper 使用结构化日志，至少包括：

- 启动版本和协议版本。
- Gateway host/port，但不包含密码。
- 连接状态转换。
- 订阅/取消订阅的 `conId` 和 request ID。
- IBKR error code 及清理后的 message。
- WebSocket 客户端连接状态。
- SQLite migration 版本。
- Helper 退出原因。

建议：

- 日志文件滚动。
- 单文件上限 5–10 MB。
- 最多保留 5 个文件。
- UI 提供“打开日志目录”，但不自动上传。
- Debug 模式可提高日志级别；Release 默认 INFO。

健康接口至少返回：

```json
{
  "status": "ok",
  "helper_version": "0.1.0",
  "protocol_version": 1,
  "gateway_state": "live",
  "database_schema_version": 1,
  "uptime_seconds": 3600
}
```

---

## 12. 测试策略

### 12.1 Python 单元测试

- IBKR P&L 回调规范化。
- quote/bid/ask/close 回调合并。
- Decimal 字符串序列化。
- 合约候选与 `conId` 唯一性。
- request ID 分配。
- 重复订阅防护。
- 重连后的重订阅计划。
- stale 状态计算。
- SQLite migration 幂等性。
- watchlist CRUD。
- WebSocket envelope 和 schema validation。

所有常规 CI 测试使用 Fake IBKR Adapter，不连接真实 Gateway。

### 12.2 Python 集成测试

- FastAPI HTTP API。
- WebSocket 建连后完整 snapshot。
- 事件增量顺序和 sequence。
- SQLite 重启恢复。
- Helper 优雅关闭。
- 模拟 IBKR 1100/1101/1102/1300。

### 12.3 Swift 测试

- JSON fixture 解码。
- 协议版本不兼容处理。
- Decimal 与币种格式化。
- ViewModel 状态转换。
- quote 合并节流。
- Helper 启动握手解析。
- Helper 崩溃后的 UI 状态。
- 窗口位置恢复和不可见屏幕修正逻辑。

### 12.4 手工 Paper Trading 验证

- 首次连接。
- 获取账户 P&L。
- 添加 1、5、30 个自选。
- 动态删除和重新添加。
- 关闭 IB Gateway。
- 重启 IB Gateway。
- 断网再恢复。
- 从 Paper 切换到 Live 配置但不实际启用交易。
- 无实时行情权限时显示 delayed/not-subscribed。
- 市场关闭时不误报断线。
- Mac 睡眠/唤醒。
- 外接屏幕接入/拔出。

### 12.5 发布验证

- 在干净的 Apple Silicon Mac 用户环境安装。
- Gatekeeper 验证通过。
- Helper 可被 App 正常启动。
- 未安装 Python 开发环境也能运行。
- 未启动 IB Gateway 时不崩溃。
- App 更新或数据库迁移后旧数据仍可读取。

---

## 13. CI/CD 与发布

### 13.1 Pull Request CI

GitHub Actions 建议包含：

- Python lint/type check/test。
- SQLite migration test。
- JSON Schema test。
- Swift build/test，使用 macOS runner。
- 禁止提交大文件、SQLite、日志和潜在 secrets 的检查。

不在普通 CI 中登录真实 IBKR 或运行 Paper Trading 集成测试。

### 13.2 发布流程

第一阶段可采用本地签名发布：

1. 构建 arm64 Python Helper。
2. 在干净临时目录验证 Helper。
3. 把 Helper 放入 App bundle 的受控位置。
4. 签名 nested Helper。
5. 签名主 App，开启 Hardened Runtime。
6. 运行 Swift 和 Helper smoke tests。
7. 创建 DMG。
8. Notarize。
9. Staple。
10. 验证 Gatekeeper。
11. 创建 GitHub Release 和 checksum。

正式自动发布前，先证明本地流程可重复。

### 13.3 版本策略

- App、Helper 和 protocol 分别有版本。
- App release 使用 SemVer。
- Helper 与 App 通常一起发布。
- 协议主版本不兼容时，App 应拒绝连接并提示重新安装完整版本。

---

## 14. 分阶段开发计划

## 阶段 0：新仓库与开发环境初始化

### 目标

创建独立仓库并验证本机工具链，不编写产品功能。

### 任务

- 创建 `IBKR_Float` Git 仓库。
- 将本文档复制为新仓库根目录 `HANDOFF.md`。
- 创建基础目录结构。
- 记录 `sw_vers`、`uname -m`、`xcodebuild -version`、Python 版本。
- 安装 Apple Silicon 版 IB Gateway Stable。
- 下载与 Gateway 匹配的官方 TWS API。
- 配置 Paper Trading：Socket API、localhost、Read-Only、端口。
- 创建 `docs/IBKR_SETUP.md`，记录不含凭据的配置步骤。
- 创建 `.gitignore` 和基础 README。
- 初始化 Python `pyproject.toml` 和最小 SwiftUI 项目。
- 添加最小 CI 骨架。

### 验收标准

- 仓库 `main` 干净且可在 Apple Silicon 上构建空 Swift App。
- Python 测试命令可以运行。
- Paper IB Gateway 能正常登录。
- 没有任何凭据或数据库进入 Git。

---

## 阶段 1：IBKR 技术验证 Spike

### 目标

先证明最关键的外部依赖可用，再进入正式架构开发。

### 任务

- 编写最小 Python 脚本连接 Paper IB Gateway。
- 打印已连接状态和可见账户掩码。
- 调用账户 `reqPnL`，观察 daily/unrealized/realized P&L 回调。
- 解析一个明确的美国股票合约并取得 `conId`。
- 调用 `reqMktData`，接收 last/bid/ask/close 与 market data type。
- 测量回调频率和延迟，只记录统计，不记录敏感完整数据。
- 人工关闭 Gateway，验证错误回调。
- 重启 Gateway，验证自动重连和重新订阅。
- 验证无实时行情权限时的 delayed/frozen 行为。
- 写出 `docs/SPIKE_RESULTS.md`。

### 必须记录的结果

- Gateway/TWS API/Python 的确切版本。
- Paper/Live 端口。
- `reqPnL` 实测更新节奏。
- `reqMktData` 实测字段。
- 重连时收到的错误代码。
- 当前账户市场数据权限表现。
- Apple Silicon 上是否存在依赖或打包问题。

### 验收标准

- 能稳定收到 Paper 账户 P&L。
- 能稳定收到至少一个标的报价或明确的 delayed/not-subscribed 状态。
- Gateway 重启后无需重启 Python 进程即可恢复。
- 若以上任一项失败，停止 UI 开发，先解决或调整架构。

---

## 阶段 2：Python Local Helper MVP

### 目标

把 Spike 重构为可测试、可持久化、可被 Swift 使用的本地服务。

### 任务

- 建立正式 Python package。
- 抽象 `IBKRAdapter` 接口和 Fake Adapter。
- 实现 IBKR 专用线程与 asyncio event bridge。
- 实现连接状态机和重连 backoff。
- 实现账户发现、账户选择和 P&L Subscription。
- 实现合约搜索、合约详情和 `conId` 缓存。
- 实现动态行情 Subscription Manager。
- 实现内存 snapshot store。
- 实现 SQLite migrations 和 repository。
- 实现 watchlist CRUD。
- 实现 FastAPI HTTP API。
- 实现 WebSocket snapshot + incremental events。
- 实现一次性 Bearer token 校验。
- 实现结构化日志和日志滚动。
- 补齐 Python 单元与集成测试。

### 验收标准

- 不依赖 Swift App，可单独启动和测试。
- 重启 Helper 后恢复自选和最新本地状态。
- 运行中新增/删除自选立即订阅/取消，无需重启。
- 连接中断时状态正确，旧数据标为 stale。
- WebSocket 新客户端立即收到完整 snapshot。
- Fake Adapter 测试不需要真实 IBKR。
- 没有任何订单 API。

---

## 阶段 3：SwiftUI/AppKit 悬浮窗 MVP

### 目标

实现可日常使用的原生悬浮界面，开发期可连接手动启动的 Helper。

### 任务

- 建立 Swift 网络层和协议模型。
- 使用 protocol fixtures 做跨语言解码测试。
- 实现 Helper HTTP Client。
- 实现 WebSocket Client、断线重连和 snapshot 恢复。
- 建立 `MainActor` AppState/ViewModel。
- 实现账户 P&L 卡片。
- 实现自选列表和 quote 行。
- 实现添加合约候选选择界面。
- 实现删除自选。
- 实现连接状态、stale 和错误展示。
- 实现 `NSPanel` 悬浮窗。
- 实现折叠/展开。
- 实现窗口位置和尺寸恢复。
- 实现菜单栏入口。
- 添加基础可访问性标签和键盘操作。

### 验收标准

- App 可以在 Apple Silicon 上原生启动。
- 能显示真实 Paper 账户 P&L。
- 能显示自选报价、涨跌额和涨跌幅。
- 新增/删除自选无需重启。
- 窗口在切换应用后保持置顶。
- 用户能隐藏、恢复和折叠窗口。
- Gateway 不可用时 UI 不崩溃且给出明确状态。

---

## 阶段 4：进程托管与可靠性加固

### 目标

让 App 能自行启动和管理 Helper，并覆盖长期运行中的常见故障。

### 任务

- 把 Helper 构建为 Apple Silicon 可执行文件。
- Swift App 使用 `Process` 启动 Helper。
- 实现随机端口、一次性令牌和 stdout 握手。
- 实现 Helper 启动超时和失败诊断。
- 实现 Helper 崩溃检测和有限次数自动重启。
- 实现 App 退出时 Helper 优雅关闭。
- 处理重复 App 实例或端口冲突。
- 处理 Mac 睡眠/唤醒。
- 处理 IB Gateway 每日重启和周末重新认证状态。
- 完成 1100/1101/1102/1300 的测试。
- 完成外接显示器窗口恢复。
- 加入 P&L 分钟快照和数据清理。
- 加入设置页：Gateway 端口、Paper/Live、自选上限、登录启动等。

### 验收标准

- 用户不需要手动启动 Python。
- 未安装系统 Python 也能运行。
- Helper 崩溃后 App 能恢复或明确提示。
- Gateway 重启后自动恢复订阅。
- Mac 睡眠唤醒后能恢复连接。
- SQLite 无并发锁异常和损坏。

---

## 阶段 5：签名、Notarization 与发布

### 目标

产出可在另一台 Apple Silicon Mac 安装的正式构建。

### 任务

- 固定最低 macOS 版本和 bundle identifier。
- 配置 Developer ID Application 证书。
- 配置 Hardened Runtime 和必要 entitlements。
- 签名 nested Helper。
- 签名主 App。
- 创建 DMG。
- 完成 Notarization 和 staple。
- 使用 `codesign`、`spctl` 验证。
- 在干净用户环境做安装测试。
- 编写 `docs/RELEASE.md`。
- 编写用户版 `docs/IBKR_SETUP.md`。
- 创建首个 GitHub prerelease。

### 验收标准

- 干净 Apple Silicon Mac 上无需安装 Python 即可运行。
- Gatekeeper 不阻止启动。
- App 能检测未运行/未登录的 IB Gateway。
- 用户按文档配置后能连接 Paper 账户。
- Release 包不包含凭据、开发数据库或调试日志。

---

## 阶段 6：可选的现有 Wealth 服务同步

本阶段不属于 MVP，只有本地产品稳定后才评估。

### 原则

- 通过版本化 HTTPS API 同步。
- 不直连远程 PostgreSQL。
- 不共享 Alembic migration。
- 不 import 原 `wealth` 仓库 Python package。
- 同步失败不能影响本地实时悬浮窗。
- 只同步分钟级聚合，不上传逐 tick 数据。
- 用户可以完全关闭云同步。

---

## 15. 里程碑与粗略工作量

| 阶段 | 预计工作量 | 风险 |
| --- | --- | --- |
| 阶段 0：初始化 | 0.5–1 天 | 低 |
| 阶段 1：IBKR Spike | 1–2 天 | 高，决定架构是否成立 |
| 阶段 2：Helper MVP | 3–5 天 | 中 |
| 阶段 3：原生 UI MVP | 3–5 天 | 中 |
| 阶段 4：可靠性与托管 | 3–5 天 | 中高 |
| 阶段 5：发布 | 2–4 天 | 中高，签名与 Python 打包 |

一个可开发自用的 MVP 预计约 2 周；达到稳定、可分发的质量预计约 3–4 周。实际时间取决于 IBKR 认证、行情权限、官方 Python API 与打包工具在目标 macOS 上的兼容性。

---

## 16. 关键风险与缓解措施

### 风险 1：IB Gateway 不是完全无头

**影响：** 用户仍需通过官方 UI 登录，周期性重新认证。

**缓解：** 本地部署、Auto Restart、清晰状态提示；绝不保存密码或自动操作 2FA。

### 风险 2：行情权限和 delayed 数据

**影响：** 部分标的可能没有实时行情。

**缓解：** 显示 `market_data_type`，区分 real-time、delayed、frozen、not-subscribed；不把 delayed 数据标成实时。

### 风险 3：Python Helper 打包

**影响：** 开发环境可运行，但 `.app` 在干净机器失败。

**缓解：** 阶段 1 后尽早做最小 arm64 Helper 打包实验，不要把打包推迟到全部功能完成后。

### 风险 4：TWS API 回调线程与 asyncio 竞态

**影响：** 丢事件、死锁或 SQLite 跨线程错误。

**缓解：** 回调线程只投递事件，所有状态和 SQLite 写入集中到 asyncio/单写者路径。

### 风险 5：symbol 不是唯一键

**影响：** 跨市场、期权、期货和同名证券订阅错误。

**缓解：** 从第一天开始以 `conId` 为唯一 instrument ID。

### 风险 6：把 1 秒刷新误解为每秒必有新数据

**影响：** UI 显示伪实时状态。

**缓解：** 基于事件更新、最多 1 Hz 重绘；始终显示 `received_at`、连接状态和 stale。

### 风险 7：账户会话冲突

**影响：** 同一用户名在其他 IBKR 产品中的 brokerage session 可能与 Gateway 竞争。

**缓解：** Spike 阶段实际验证使用习惯；必要时研究额外用户名，但注意市场数据权限通常与用户名相关，可能产生额外订阅成本。

### 风险 8：P&L 口径误解

**影响：** 用户把 IBKR Daily P&L 误认为本地午夜重置或 Flex 日报口径。

**缓解：** 明确标注数据来自 IBKR P&L subscription，并在文档中说明重置由 IBKR/TWS 配置和产品规则决定。

---

## 17. 开放决策及默认值

以下事项允许在阶段 0/1 根据本机环境确认，但没有新信息时使用默认值：

| 决策 | 默认值 |
| --- | --- |
| 产品名 | OpenIBKR |
| 仓库名 | IBKR_Float |
| Bundle ID | 使用开发者自有反向域名，例如 `com.example.OpenIBKR`，创建前确认 |
| 最低 macOS | macOS 14 |
| CPU | arm64 only |
| 自选上限 | 30 |
| 开发账户 | Paper Trading |
| 开发 Gateway 端口 | 4002，可配置 |
| Live Gateway 端口 | 4001，可配置 |
| UI 合并频率 | 最多 1 Hz |
| P&L stale 阈值 | 已连接时约 10 秒 |
| P&L 历史粒度 | 1 分钟 |
| P&L 历史保留 | 90 天 |
| Helper 生命周期 | 与 App 同生命周期 |
| 发布渠道 | Developer ID + DMG + GitHub Release |

需要用户确认但不阻塞 Spike 的项目：

- 最终 App 名称和图标。
- Bundle ID 和 Apple Developer Team。
- 是否需要多账户聚合。
- 是否希望全屏 App 上仍显示悬浮窗。
- 是否需要开机/登录启动默认开启。
- 是否保存分钟级 P&L 历史，还是完全只保留最新值。

---

## 18. MVP 完成定义

只有同时满足以下条件，MVP 才算完成：

1. 在 Apple Silicon Mac 上原生运行。
2. 用户通过官方 IB Gateway Paper UI 登录后，App 能自动连接。
3. App 显示账户当日盈亏和未实现盈亏。
4. 收到新的 IBKR P&L 回调后，界面约 1 秒内反映。
5. 用户能搜索、确认并添加明确的 IBKR 合约。
6. 用户能删除自选，订阅立即取消。
7. 自选显示最新价、涨跌额、涨跌幅和数据类型。
8. Gateway 关闭、断网和重启时 App 不崩溃。
9. 数据过期时保留最后值但明确标记 stale。
10. App 重启后恢复自选、设置和窗口位置。
11. SQLite 只有 Helper 写入。
12. 代码中不存在订单 API 或交易入口。
13. 正常 CI 不依赖真实 IBKR。
14. 发布包不要求用户预装 Python。
15. 发布包通过 Apple 签名和 Notarization 验证。

---

## 19. 新 session 的首轮执行指令

新 session 开始后应按以下顺序执行：

1. 完整阅读本 `HANDOFF.md`。
2. 确认当前工作区是新的 `IBKR_Float` 仓库，而不是原 `wealth` 仓库。
3. 检查本机 macOS、Apple Silicon、Xcode、Python 和 Git 环境。
4. 检查是否已安装 IB Gateway；若没有，给出官方安装和 Paper 配置步骤，不要下载非官方组件。
5. 建立阶段 0 的仓库结构和文档。
6. 创建短期分支 `feat/ibkr-spike`。
7. 只实施阶段 1 Spike，先验证 `reqPnL`、`reqMktData` 和重连。
8. 把实测结果写入 `docs/SPIKE_RESULTS.md`。
9. Spike 通过后再提出阶段 2 的具体实现计划。

新 session 不应在没有真实 Spike 证据前同时构建完整 Swift UI、SQLite schema 和发布流水线。

可直接交给新 session 的简短提示词：

```text
请完整阅读仓库根目录 HANDOFF.md，并严格按照其中的阶段顺序工作。先检查当前仓库与本机环境，然后完成阶段 0 和阶段 1 IBKR Paper Trading 技术验证。不要实现交易能力，不要保存 IBKR 凭据，不要提前进入完整 UI 或发布阶段。完成后把版本、P&L/行情回调、重连行为和所有阻塞项写入 docs/SPIKE_RESULTS.md。
```

---

## 20. 官方参考资料

- IBKR TWS API 文档：<https://www.interactivebrokers.com/docs/tws-api/doc/introduction>
- IB Gateway 架构与登录限制：<https://www.interactivebrokers.com/docs/tws-api/doc/architecture/the-trader-workstation/the-ib-gateway>
- 账户 P&L 订阅：<https://www.interactivebrokers.com/docs/tws-api/doc/account-portfolio-data/profit-loss-pn-l/request-p-l-for-accounts>
- 单持仓 P&L：<https://www.interactivebrokers.com/docs/tws-api/doc/account-portfolio-data/profit-loss-pn-l/request-p-l-for-individual-positions>
- 市场数据更新频率：<https://www.interactivebrokers.com/docs/tws-api/doc/market-data-live/top-of-book-l-1/market-data-update-frequency>
- IBKR 市场数据订阅要求：<https://www.interactivebrokers.com/docs/general/market-data-subscriptions/introduction>
- Apple `NSWindow`：<https://developer.apple.com/documentation/appkit/nswindow>
- Apple `NSWindow.Level.floating`：<https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/floating>
- Apple `SMAppService`：<https://developer.apple.com/documentation/servicemanagement/smappservice>

---

## 21. 最终架构结论

OpenIBKR 应作为独立、本地优先、只读的 macOS 产品开发，代码托管在 `IBKR_Float` 仓库。SwiftUI/AppKit 负责原生悬浮体验；Python Helper 使用官方 TWS API 与本机 IB Gateway 通信；SQLite 只由 Helper 管理；Swift 与 Python 之间使用受认证的 localhost HTTP/WebSocket 协议。

第一优先级不是 UI，而是使用 Paper Trading 实证以下三点：

1. 账户 P&L 回调满足实际刷新需求。
2. 少量自选行情能够正确订阅并识别实时/延迟状态。
3. IB Gateway 中断与恢复后能够可靠重连和重新订阅。

这三个条件通过后，后续开发风险才是可控的。

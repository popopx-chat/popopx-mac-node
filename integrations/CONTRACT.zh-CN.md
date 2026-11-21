# 生态桥接契约 · Ecosystem bridge contract

[English](CONTRACT.md) · [简体中文](CONTRACT.zh-CN.md)

本文件是 `integrations/shared`、`integrations/linger-skill`、`integrations/openclaw-skill`
的**唯一**规格。它描述的是一座*复用节点已有设施*的桥：不新增端口、不新增传输层、不新增授权主体。

下面每一条断言都标注了它所测量到的 Swift 源文件位置。Swift 代码是生产者：本文件与 `Sources/`
冲突时，以 `Sources/` 为准，本文件即为缺陷。

---

## 1 · 传输通道，以及唯一的端口

| 方向 | 机制 | 真实端点 | 出处 |
| --- | --- | --- | --- |
| 桥 → 节点 | HTTP `POST`，JSON，identity 编码 | `http://127.0.0.1:18920/api/engine/invoke` | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3638-3645` |
| 桥 → 节点 | HTTP `POST`（仅诊断，见 §6） | `http://127.0.0.1:18920/api/command` | `LocalWebConsoleServer.swift:3647-3654` |
| 节点 → 桥 | Server-Sent Events，单条长连接响应 | `GET /api/events?t=<token>` | `LocalWebConsoleServer.swift:3686-3700` |
| 节点 → 任意方 | 带 HMAC 签名的出站 webhook，**默认关闭** | 取决于 `sentinel.webhookURL` 的配置值 | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5795-5831` |

监听器只绑回环，否则拒绝服务（`LocalWebConsoleServer.swift:3244,3267-3276,3410-3418,3428-3435`；
`NodeWire.consoleHost`、`NodeWire.consolePort` 见 `Sources/PopopxMacNode/Models/MacNodeModels.swift:58,89`）。
端口固定且无回退：绑定失败就是错误，绝不会换成另一个端口（`LocalWebConsoleServer.swift:3256,3292-3298`）。

**`18920` 上没有 WebSocket 端点。** 本系统里唯一的 `ws://` 是聊天守护进程的控制套接字
`127.0.0.1:5225`，它按设计不做鉴权，而且节点自己是它的客户端（`MacNodeModels.swift:60-67`；
`Sources/PopopxMacNode/Core/MacNodePopopxBridge.swift:323,940,1712-1741`）。桥接插件不得去连它：
那等于插入一个无鉴权的第二会话，且拿不到已配对的会话。本契约采用的是一对组合：请求/响应 + SSE。

## 2 · 鉴权

控制台 token 是 24 字节 `SecRandomCopyBytes`，base64url 无填充，每次启动生成一次，
并且**刻意永不落盘**——见 `LocalWebConsoleServer.swift:3224-3226,3249` 与
`MacNodeModels.swift:3064-3071`。它可放在 `X-PPX-Token` 请求头或 `t` 查询参数里，比较方式为
时序安全比较（`LocalWebConsoleServer.swift:3704-3711`；`MacNodeModels.swift:92,95,3098-3103`），
缺失或错误一律 `401` 并附带一句人话说明（`LocalWebConsoleServer.swift:83`）。

本套插件使用的交接方式（方案甲）：操作者粘贴带 token 的控制台 URL，或设置
`PPX_CONSOLE_TOKEN`。该 URL 由 `--headless` 打印，也可由菜单栏"复制配对地址"写入剪贴板
（`Sources/PopopxMacNodeApp/PopopxMacNodeApp.swift:486-493,537-541`）。
由于 token 随进程消亡，**节点每次重启都会让所有插件配置失效**；`consoleClient` 把这件事表达成
一个明确的类型化错误（`tokenRejected`），而不是无声重试循环。

## 3 · 指令语法

规范形式为一行，不含包裹：

```text
::popopx_sys::NODE_CMD::<serviceId>::<action>::<payload>
```

* 前缀 `::popopx_sys::NODE_CMD::`（`MacNodeModels.swift:40`，段数常量 `:44`）
* 切分时恰好消耗 **两个** `::` 分隔符，第二个之后的内容原样保留，因此 payload 内可以含 `::`
  （`MacNodeModels.swift:113-139`）
* `serviceId` 与 `action` 必须非空；**`payload` 也必须非空**
* payload 预算：`payload.count <= NodeWire.maxSignalPayloadCharacters - (serviceId.count + action.count + 2)`，
  上限常量为 `1_024`，前两段也计入（`MacNodeModels.swift:52,129-131`）
* payload 是原始 JSON 文本。不做 base64，不做百分号编码。JSON 解析失败不算错误：节点把它当字符串保留
  （`MacNodePopopxBridge.swift:375-380`、`MacNodeModels.swift:1136`）

节点里存在**两个**解析器，而且它们不一致，所以本契约只认定其中一个：

| 解析器 | 运行位置 | marker 位置 | 空 payload | 未知 serviceId |
| --- | --- | --- | --- | --- |
| `NodeWire.parseCommand` — "the one and only parser"（`MacNodeModels.swift:106`） | 本地控制台注入 | 必须是前缀 | 拒绝 | 拒绝 |
| `SBCommandCodec.parse` | 入站 SMP 聊天 | 行内任意位置（`MacNodePopopxBridge.swift:656-658`） | 允许（`:667`） | 放行，下游再拒（`TenBusinessEngines.swift:2077-2091`） |

桥接实现"严格"那一列。`engine(for:)`（`TenBusinessEngines.swift:2151-2170`）里的别名在**校验之前**
先规范名化，因此 `warroom` 会归到 `zero_trust_warroom`，但作为原始 wire id 仍然非法。动作匹配
不区分大小写，空格折叠为 `_`（`TenBusinessEngines.swift:2172-2175`）。

机器可读的向量放在 `shared/test/fixtures/wire-vectors.json`，同时被 TypeScript 测试与
`Tests/PopopxMacNodeTests/MacNodeContractTests.swift` 消费，让两个运行时用同一批语料判分。
不要把向量复制进正文。

## 4 · 十大服务

`serviceId` 即 `EngineKind.rawValue`（`MacNodeModels.swift:1207-1217`）。可接受的别名
（`TenBusinessEngines.swift:2151-2170`）：

| serviceId | 别名 | 名称 |
| --- | --- | --- |
| `shadow_cos` | `cos`、`chief_of_staff` | 幕僚长简报 |
| `zero_trust_warroom` | `warroom`、`zero_trust`、`gop_watermark` | 战情室归因 |
| `zerotrace_studio` | `studio`、`zero_trace` | 元数据净化工作室 |
| `solo_autopilot` | `solo`、`autopilot` | 单人视频流水线 |
| `edge_compute_mesh` | `mesh`、`edge_mesh`、`compute_mesh` | 边缘算力共享 |
| `morning_tv` | `tv`、`morning` | 晨间播报 |
| `phantom_sentinel` | `sentinel`、`lockdown` | 确定性物理锁定 |
| `chrono_ark` | `ark`、`time_lock` | 时间锁保险库 |
| `health_sentinel` | `health` | 健康解读与音频 |
| `creator_paywall_hub` | `paywall`、`creator` | 权益校验 |

## 5 · 动作表

由 `execute` 与 `invoke` 共用的那张唯一路由表逐条转录（`TenBusinessEngines.swift:2199-2328`）。
`∅` 表示空动作串；桥接应发送规范名，表中列出的别名是节点同样接受的写法。

| serviceId | 规范动作 | 同时接受 |
| --- | --- | --- |
| `shadow_cos` | `briefing` · `negotiation_prompt` | `∅`,`brief`,`run`,`daily`,`daily_brief`,`generate` / `negotiation`,`tactics`,`prompt` |
| `zero_trust_warroom` | `assign` · `embed` · `trace` · `registry` | `register`,`queue_assign` / `mark`,`distribute` / `extract`,`identify`,`decode` / `status` |
| `zerotrace_studio` | `process` · `strip` · `anchor` · `shred` | `∅`,`run`,`ingest`,`sanitize`,`sanitise` / `clean`,`metadata` / `briefing_clip`,`broadcast` / `destroy` |
| `solo_autopilot` | `run` · `script` | `∅`,`generate`,`video`,`clip` / `copy` |
| `edge_compute_mesh` | `status` · `offer` · `poll` · `enable` · `settle` | `∅`,`summary` / `accept`,`execute`,`run` / `drain` / `sharing` |
| `morning_tv` | `broadcast` · `digest` · `scheduled` · `schedule` | `∅`,`run`,`tv` / `headlines`,`feeds` / `fire`,`on_time` / `next` |
| `phantom_sentinel` | `status`（只读报告） | `probe`。**`lockdown` 及其别名由桥接拒绝——见 §7** |
| `chrono_ark` | `seal` · `list` · `unseal` · `heartbeat` · `check` · `reveal` | `lock`,`store` / `∅`,`vaults`,`status` / `open`,`recover` / `ping`,`alive` / `watch`,`release_check` / `dir`,`folder` |
| `health_sentinel` | `read` · `binaural` | `∅`,`report`,`parse`,`interpret` / `tone`,`sleep`,`wav` |
| `creator_paywall_hub` | `verify` · `grant` · `claim` · `status` | `∅`,`ticket`,`admit` / `deliver`,`drop`,`distribute` / `red_packet`,`redpacket` / `ledger` |

每个引擎的 `default:` 分支返回 `unsupported(kind, action, allowed)`，标题为
`未知动作 · unknown action “…” for …`，并置 `metrics.unknownAction = true`
（`TenBusinessEngines.swift:2188-2196`）。

## 6 · 控制台做不到什么——以及拒绝时的原文

`POST /api/command` 会把裸文本自动补上规范前缀（`LocalWebConsoleServer.swift:3653-3654`），
再以**本地**命令提交，`senderPublicKey: "local-console"`、`authenticated: false`
（`MacNodeModels.swift:115-116`；`PopopxMacNodeApp.swift:361-375,402-404`）。`execute` 随后在
第二道门禁处拒绝它（`TenBusinessEngines.swift:2097-2108`）：

```text
Refused: the sender key is not on the paired-device whitelist.
```

也就是说，尽管语法是真的，字面的 `NODE_CMD` 串**并不是一条可由 HTTP 触发的执行路径**。
桥接的执行走 `POST /api/engine/invoke`，请求体为 `{ kind, action, payload }`
（`LocalWebConsoleServer.swift:3878-3882`），是同步 JSON 而非流。桥接先按 §3 解析规范行，
再映射到 `invoke`；`/api/command` 仅保留用于读取节点自己的解析判定，默认关闭。

其他值得在插件里对齐的拒绝：

| 条件 | 原文 | 出处 |
| --- | --- | --- |
| 未知引擎 id | `Unknown service identifier “…”. Known ids: …` | `TenBusinessEngines.swift:2086-2090` |
| 引擎已关闭 | `引擎已关闭 · … is switched off.` / `Nothing was executed.` | `:2177-2186` |
| 语法非法（SMP 路径） | `NODE_CMD 段数不足或 serviceId/action 为空` — 只记本地日志，**线上不回复任何东西** | `MacNodePopopxBridge.swift:2165-2174` |
| token 错误 | `401` + `Missing or wrong console token. …` | `LocalWebConsoleServer.swift:83` |
| 方法不对 | `405` + `Allow` | `:3661-3671,3742-3744` |
| 请求体 > 8 MiB | `413`；缺 `Content-Length` → `411` | `:3163,4083-4088` |

## 7 · `phantom_sentinel`，以及桥接为何要拒绝它

锁定是真的动手。`lockdown` 用 `NSPasteboard.general.clearContents()` 清空剪贴板
（`TenBusinessEngines.swift:5568-5576`），用 `diskutil info -all -plist` 探测卷后再
`diskutil unmount` / `diskutil unmountDisk` 卸载（拒绝启动卷、绝不使用 `--force`，`:5741-5780`），
用 `/usr/bin/pmset displaysleepnow` 熄屏（`:5605-5607`），用 `CGSession -suspend` 锁屏
（`:5610-5615`）。全程用户态：无 `sudo`、无 `pkexec`、无守护进程（`:5600-5615`）。默认值为
清剪贴板/锁屏/熄屏开启，`unmountPaths = []`，webhook 为空（`MacNodeModels.swift:1494-1501`）。
这里**没有**确认步骤、冷却、干跑或撤销——`lastLockAt` 只被写入和展示，从不作为节流依据
（`TenBusinessEngines.swift:5636-5638,5692`）。

节点里有两处顺序让这件事在 HTTP 侧变得危险，桥接的处理是补偿，而不是悄悄改节点：

1. `execute()` 把确定性锁定分支（`:2059-2075`）放在配对白名单门禁（`:2097`）**之前**。这个顺序是
   刻意的且有注释——机主的手机发出 🔒 时必须能插进渲染中间——但它同时意味着本地控制台注入可以
   在引擎开关为开时锁定整机。
2. `invoke()` 把锁定触发词（`:2118-2122`）放在 `document.isEnabled(kind)`（`:2123`）**之前**，
   且完全没有 `authenticated` 概念。于是对 `/api/engine/invoke` 发送
   `{"kind":"phantom_sentinel","action":"lock_all"}`，即便该引擎已被关闭，机器照样被锁。
   触发词为 `["🔒","LOCK_ALL","lock_all"]`（`MacNodeModels.swift:98`），按小写比较。

空动作在 HTTP 侧不是缺口：路由在 `invoke` 看到它之前就把空动作拒了
（`LocalWebConsoleServer.swift:3644`），尽管 `invoke` 自己把 `""` 当作锁定。

桥接侧策略，落地在 `shared/src/wireCommand.ts` 与两个插件中：

* 任何规范名落到 `lockdown`/`lock`/`lock_all`/`sentinel`/`🔒` 的动作，在发起网络请求之前即被拒绝，
  除非同时满足 `allowLockdown: true` **且**出示插件侧共享密钥；
* 默认唯一放行的 `phantom_sentinel` 动作是 `status`/`probe`，它们是只读的
  （`TenBusinessEngines.swift:5678-5710`）；
* 每一次拒绝都写进插件自己的日志，让操作者看得见它发生过；
* 本契约把节点侧的顺序问题如实写成未闭合风险，而不是宣称桥接已经加固。

## 8 · 串行化

不要再造一把锁。单个 actor 持有全部十个引擎，使 SMP 入口与控制台按钮入口共用同一个调度器
（`TenBusinessEngines.swift:7-9,1917`），App 用一个任务串行路由命令
（`PopopxMacNodeApp.swift:165-171`）。命令通过
`AsyncStream(bufferingPolicy: .bufferingNewest(64))` 分发给订阅者
（`MacNodePopopxBridge.swift:1309-1324`）。因此插件对同一节点最多保持一个 in-flight
`engine/invoke`，只重试一次，其余交给 actor。重量/轻量渲染闸门
（`TenBusinessEngines.swift:63-69`）从不出现在锁定路径上，所以桥接不得拿渲染队列深度当作
锁定被延迟的理由。

## 9 · 回执，以及已知的 iOS 缺口

没有专门的 ack 消息类型。节点对远端命令的回复就是一张普通聊天卡片：`✅`/`⚠️` + 引擎名 + 标题，
正文截断到 1 800 字符（`MacNodeModels.swift:1196-1200`；`MacNodePopopxBridge.swift:2476-2512`），
失败时以 at-least-once 语义重新入队（`:2471-2475,2518-2541`）。`NodeWire.signalMarker` 有声明但
从未用于出站。`NODE_CMD` 尚不是 iOS 的 `PopopxCommerceSignalKind`，所以节点指令会渲染成可见气泡；
节点把这件事作为**控制台事件**字段 `iosSignalGap` 记录（`MacNodePopopxBridge.swift:2200-2214`，
提示文本在 `:982-985`）——它不在 `POST /api/engine/invoke` 的响应里，且事件携带的是 `payloadHash`
而不是 payload 本身（`:2205`）。桥接不得声称静默送达。

## 10 · 刻意不做的事

* 不新增监听端口，不用 `18925`，不在急停开关前面套一个 localhost webhook；
* 不复用 `ws://5225`（§1），也不引入任何 `ws` 依赖——插件只跑 Node 内置能力
  （`fetch`、`http`、`test`），`typescript` 仅是 devDependency；
* 不写凭证文件，不把 token 落盘，不产生任何全局可读文件；
* 不模拟物理动作：节点没执行的事，插件就不提供；
* 不声称曾用真实 Linger 或 OpenClaw 宿主验证。这两个宿主都不在这三个仓库里，因此验收标准是：
  同一批语料在两个运行时都通过，`tsc` strict 构建通过，以及按各插件 README 对手一个活节点跑通。

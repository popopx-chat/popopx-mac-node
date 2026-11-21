---
name: popopx-mac-node
description: Run one of the ten POPOPX Mac Node business engines through the node's own loopback console, and refuse the ones that would physically lock the machine without the operator opting in. / 通过节点自身的回环控制台调用十个业务引擎之一；未开启时拒绝任何会真实锁定整机的调用。
whenToUse: The host has a service id, an action and a JSON payload, and wants the node's answer as one card. Do not use it for pairing, for the chat queue, or for anything the node does not execute. / 宿主已经有 service、action、payload，只想要节点返回的那张结果卡。配对、聊天队列、以及节点本身不执行的事情，都不要用它。
inputs:
  service: "EngineKind raw value or alias, e.g. `shadow_cos`, `warroom`, `paywall`."
  action: "Any spelling the node routes, e.g. `daily`. The canonical name is what goes on the wire."
  payload: "A JSON object, or the raw JSON text of one. Omitted means `{}`."
  handoff: "The tokenised console URL the node printed, or a bare token. Empty means read `PPX_CONSOLE_TOKEN`."
services:
  - id: shadow_cos
    actions: [briefing, negotiation_prompt]
    accepts: [brief, run, daily, daily_brief, generate, negotiation, tactics, prompt]
    also: [cos, chief_of_staff]
  - id: zero_trust_warroom
    actions: [assign, embed, trace, registry]
    accepts: [register, queue_assign, mark, distribute, extract, identify, decode, status]
    also: [warroom, zero_trust, gop_watermark]
  - id: zerotrace_studio
    actions: [process, strip, anchor, shred]
    accepts: [run, ingest, sanitize, sanitise, clean, metadata, briefing_clip, broadcast, destroy]
    also: [studio, zero_trace]
  - id: solo_autopilot
    actions: [run, script]
    accepts: [generate, video, clip, copy]
    also: [solo, autopilot]
  - id: edge_compute_mesh
    actions: [status, offer, poll, enable, settle]
    accepts: [summary, accept, execute, run, drain, sharing]
    also: [mesh, edge_mesh, compute_mesh]
  - id: morning_tv
    actions: [broadcast, digest, scheduled, schedule]
    accepts: [run, tv, headlines, feeds, fire, on_time, next]
    also: [tv, morning]
  - id: phantom_sentinel
    actions: [status]
    accepts: [probe]
    also: [sentinel, lockdown]
    denied: [lockdown, lock, lock_all, sentinel, 🔒]
  - id: chrono_ark
    actions: [seal, list, unseal, heartbeat, check, reveal]
    accepts: [lock, store, vaults, status, open, recover, ping, alive, watch, release_check, dir, folder]
    also: [ark, time_lock]
  - id: health_sentinel
    actions: [read, binaural]
    accepts: [report, parse, interpret, tone, sleep, wav]
    also: [health]
  - id: creator_paywall_hub
    actions: [verify, grant, claim, status]
    accepts: [ticket, admit, deliver, drop, distribute, red_packet, redpacket, ledger]
    also: [paywall, creator]
examples:
  - { service: shadow_cos, action: daily, payload: { tone: terse } }
  - { service: warroom, action: embed, payload: { file: report.pdf } }
  - { service: edge_compute_mesh, action: status }
  - { service: phantom_sentinel, action: status }
  - { service: creator_paywall_hub, action: verify, payload: { ticket: t-42 } }
---

# POPOPX Mac Node · Linger skill card

`@popopx/linger-skill` is the adapter between a skill host named Linger and a POPOPX Mac Node running
on the same machine. The host passes three arguments; the adapter builds one canonical wire line,
validates it with the shared bridge kernel, and posts it to the node's own console. Nothing is
invented here: every id, action, route and refusal below is transcribed from the Swift source and from
`integrations/CONTRACT.md`, which is the only specification for this package.

`@popopx/linger-skill` 是名为 Linger 的技能宿主与同一台机器上运行的 POPOPX Mac Node 之间的适配器。
宿主传入三个参数；适配器构造一条规范的 wire 行，用共享桥接内核校验它，然后 POST 到节点自己的控制台。
本文件没有发明任何内容：下面每一个 id、动作、路由与拒绝措辞都逐字抄自 Swift 源码与
`integrations/CONTRACT.md`（本包唯一规格）。

> Honesty note · 诚实说明: neither Linger nor the node's skill host exists in these repositories. This
> card is forward-looking. What has been verified is the strict build, the unit suite against a fake
> transport, and the manual run against a live node described in `README.md`.
> Linger 与技能宿主都不在这三个仓库里，这张卡是面向未来的。已验证的是：strict 构建、对着假传输层的单元测试、
> 以及 `README.md` 里对着活节点的手工流程。

## Invocation rules · 调用规则

One call is one line, and the line is built for you from `service` + `action` + `payload`:

```text
::popopx_sys::NODE_CMD::<serviceId>::<action>::<payload>
```

* The prefix is mandatory and must sit at position 0; exactly two `::` separators are consumed, so a
  payload may contain `::` / 前缀必须位于 0 号位；切分只消耗 **两个** `::`，因此 payload 内可以含 `::`
* `serviceId` must be a raw `EngineKind` value or one of the aliases listed in `also:` above
  / `serviceId` 必须是 `EngineKind` 原值，或上文 `also:` 里列出的别名
* `action` may be any spelling the node routes; the **canonical** name is what reaches the node
  (`daily` becomes `briefing`) / `action` 可用节点路由的任意写法；真正发给节点的是**规范名**
  （`daily` 会变成 `briefing`）
* `payload` must be a JSON **object**: `/api/engine/invoke` decodes it as a dictionary. Non-empty is
  required by the grammar, so an omitted payload becomes `{}` / `payload` 必须是 JSON **对象**：
  `/api/engine/invoke` 按字典解码。语法要求非空，因此省略时按 `{}` 处理
* Budget: `payload` may use `1024 - (serviceId + action + 2)` grapheme clusters, counted as Swift counts
  them, so CJK and emoji cost one each / 预算：`payload` 可用 `1024 - (serviceId + action + 2)`
  个字素簇，计数方式与 Swift 一致，中日韩文字和 emoji 每个都算 1
* One command in flight per node. A second concurrent call is answered `inFlightLimit`, never queued
  / 同一节点同时只允许一条在途指令。第二条并发调用会直接返回 `inFlightLimit`，不会被排队
* One retry only, and only when the node demonstrably never received the request (a refused connection).
  Anything with an unknown outcome is reported, not resent / 只重试一次，且仅在节点确实没收到请求时
  （连接被拒）。结果未知的失败一律如实上报，绝不重发
* The answer carries `headline`, `body`, `artifacts`, `durationMs` and `nodeOk`. `body` is not
  re-truncated: the node already cuts it at 1 800 characters
  / 回答携带 `headline`、`body`、`artifacts`、`durationMs`、`nodeOk`。`body` 不再二次截断：
  节点已经把它切到 1 800 字符
* Delivery is not silent and this card does not claim it is: `NODE_CMD` is not yet a signal kind on
  iOS, so a node command renders as a visible bubble (`iosSignalGap` on the console event)
  / 送达并非静默，本卡也不这样宣称：`NODE_CMD` 在 iOS 上还不是 signal kind，
  节点指令会渲染成可见气泡（控制台事件上的 `iosSignalGap`）

## Auth handoff · 鉴权交接

The console listens on one loopback port with no fallback: `http://127.0.0.1:18920`. A target that is
not loopback is refused as `nonLoopbackTarget`, because the token is a bearer secret and the transport
is clear HTTP. / 控制台只监听一个回环端口且无回退：`http://127.0.0.1:18920`。非回环目标会以
`nonLoopbackTarget` 拒绝——token 是持有即生效的秘密，而传输是明文 HTTP。

The token is 24 random bytes, minted once per launch and never persisted. Two consequences a host must
expect: / token 是 24 字节随机值，每次启动生成一次，永不落盘。宿主必须接受两个推论：

1. a node restart invalidates every saved plugin configuration, and the failure is one typed
   `tokenRejected` rather than a retry loop / 节点重启会让所有已保存的插件配置失效，
   失败会表达成一个类型化的 `tokenRejected`，而不是重试循环
2. the skill never writes the token to disk and never puts it in a log line. Logs carry
   `tokenFingerprint` (length plus last four characters) only / 技能不把 token 写盘、不出现在日志行里，
   日志只带 `tokenFingerprint`（长度加末四位）

Give the token to the skill in either of two ways / 两种交接方式任选其一：

```sh
# 1 · the tokenised URL, copied from --headless or the menu bar
export PPX_CONSOLE_URL="http://127.0.0.1:18920/?t=REPLACE_WITH_COPIED_VALUE"

# 2 · the bare token, when the host cannot carry a URL
export PPX_CONSOLE_TOKEN="REPLACE_WITH_COPIED_VALUE"
node --input-type=module -e 'import { run } from "@popopx/linger-skill"; console.log(await run({ service: "shadow_cos", action: "briefing", payload: { tone: "terse" } }))'
```

Precedence is: the `handoff` argument, then `handoff` in the config file named by `PPX_SKILL_CONFIG`,
then the environment, then the safe default. / 优先级：`handoff` 参数，其次
`PPX_SKILL_CONFIG` 所指配置文件里的 `handoff`，再次环境变量，最后是安全默认值。

## Lockdown disclosure · 锁定披露

`phantom_sentinel` is the one service this adapter refuses by default, and the refusal happens before
any socket is opened. It is not a polite suggestion: the node really acts. `lockdown` clears the
general pasteboard, unmounts volumes with `diskutil unmount` / `diskutil unmountDisk` (refusing the
boot volume, never `--force`), sleeps the displays with `/usr/bin/pmset displaysleepnow` and locks the
screen with `CGSession -suspend`. All of it is user-space, with no confirmation, no cooldown, no
dry-run and no undo. / `phantom_sentinel` 是本适配器默认拒绝的那个服务，而且拒绝发生在任何 socket
打开之前。这不是客气的建议：节点是真的动手。`lockdown` 会清空通用剪贴板、用
`diskutil unmount` / `diskutil unmountDisk` 卸载卷（拒绝启动卷、绝不使用 `--force`）、用
`/usr/bin/pmset displaysleepnow` 熄屏、用 `CGSession -suspend` 锁屏。全程用户态，
没有确认、没有冷却、没有干跑、也没有撤销。

The trigger words the node acts on, and the only reason any of them appear in this card, are:
`lockdown`, `lock`, `lock_all`, `sentinel`, `🔒`. / 节点会真的执行的触发词——它们出现在这张卡里
也只是为了被拒绝——是：`lockdown`、`lock`、`lock_all`、`sentinel`、`🔒`。

Two orderings inside the node are why a plugin must not rely on the node to protect itself:
/ 节点内部有两处顺序，正是插件不能指望节点自我保护的原因：

1. `invoke()` evaluates the lock trigger **before** it checks whether the engine is switched off, so an
   HTTP call with `{"kind":"phantom_sentinel","action":"lock_all"}` locks the machine even with
   `phantom_sentinel` disabled / `invoke()` 在检查引擎是否关闭**之前**就处理锁定触发词，
   因此即使 `phantom_sentinel` 已关闭，一次 HTTP 调用照样锁整机
2. `execute()` reaches the deterministic-lock branch before the paired-device whitelist gate
   / `execute()` 在配对设备白名单门禁之前就进入确定性锁定分支

To run a lockdown on purpose you must satisfy both conditions, and this package adds no third way:
/ 若确有必要执行锁定，必须同时满足两个条件，本包不提供第三条路：

* `allowLockdown: true` in the call or in the config file / 调用或配置文件里的 `allowLockdown: true`
* a plugin shared secret of at least 16 characters, from `PPX_BRIDGE_SECRET` or the `secret` argument
  / 至少 16 字符的插件共享密钥，来自 `PPX_BRIDGE_SECRET` 或 `secret` 参数

Otherwise the result is `lockdownDenied` (opt-in missing) or `secretRequired` (opt-in without a usable
secret), with zero network calls, and the refusal is written to the log.
/ 否则结果为 `lockdownDenied`（未开启）或 `secretRequired`（开启但没有可用密钥），
且零次网络调用，拒绝会写入日志。

`phantom_sentinel status` (alias `probe`) stays available: it is report-only.
/ `phantom_sentinel status`（别名 `probe`）始终可用：它只出报告。

## Refusal codes · 拒绝码

| code | meaning | retried |
| --- | --- | --- |
| `malformedCommand` | bad prefix, missing segment, empty payload, payload not a JSON object, unknown action | no |
| `unknownService` | the id resolves to no engine | no |
| `emptyAction` | the node's `""` default action, which this bridge rejects | no |
| `payloadBudget` | payload over the grapheme budget for that line | no |
| `lockdownDenied` | a blocked action with `allowLockdown` off | no |
| `secretRequired` | `allowLockdown: true` without a 16-character secret | no |
| `nonLoopbackTarget` | the handoff points away from `127.0.0.1` | no |
| `tokenRejected` | HTTP 401, usually a node restart | no |
| `methodNotAllowed` `405`, `lengthRequired` `411`, `payloadTooLarge` `413` | the console rejected the request shape | no |
| `nodeUnreachable` | nothing listening, or the read timed out | once, and only when the connection was refused |
| `nodeBusy` | HTTP 5xx | no: the node may already have started the work |
| `inFlightLimit` | another command holds the node's single slot | no |
| `badResponse` | redirect, non-JSON, no such route, or an untyped internal fault | no |
| `badConfig` | the file named by `PPX_SKILL_CONFIG` is unreadable or carries a key this package does not know | no |

A refusal never looks like a transport failure, and a transport failure never hides a refusal: the code
is on the output and the log line. / 拒绝不会被误读成传输失败，传输失败也不会掩盖拒绝：
code 同时出现在返回值和日志行里。

## Measured from · 实测出处

| Claim | Source |
| --- | --- |
| wire grammar, two separators, non-empty parts, grapheme budget | `Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139` |
| the ten `EngineKind` raw values | `Sources/PopopxMacNode/Models/MacNodeModels.swift:1207-1217` |
| the single routing table both paths share | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2199-2328` |
| service aliases, canonicalised before validation | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2151-2170` |
| `invoke()` locks before the engine switch | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2118-2123` |
| real side effects: pasteboard, unmount, display sleep, screen lock | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5568-5576,5600-5615,5741-5780` |
| executable route and its `{ kind, action, payload }` body | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3638-3645,3878-3882` |
| diagnostic-only `/api/command` | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3647-3654` |
| loopback bind, fixed port, no WebSocket | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3244,3256,3292-3298` |
| token: 24 random bytes, never persisted, `X-PPX-Token` or `?t=` | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3224-3226,3704-3711` |
| body truncated at 1 800 characters | `Sources/PopopxMacNode/Models/MacNodeModels.swift:1196-1200` |
| lock triggers compared lowercased | `Sources/PopopxMacNode/Models/MacNodeModels.swift:98` |
| the paired-device refusal wording | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2097-2108` |

The kernel this card assumes: `@popopx/node-bridge` at `integrations/shared`. The policy gate is
`assertSendable`, reached only through the barrel, so no call path can bypass it.
/ 本卡所依赖的内核：`integrations/shared` 里的 `@popopx/node-bridge`。策略闸门是 `assertSendable`，
只能通过 barrel 触达，因此没有任何调用路径能绕过它。

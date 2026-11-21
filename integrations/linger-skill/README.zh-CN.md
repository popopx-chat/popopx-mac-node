# Linger 技能卡 · `@popopx/linger-skill`

语言：[English](README.md) · [简体中文](README.zh-CN.md) · 契约：[English](../CONTRACT.md) · [简体中文](../CONTRACT.zh-CN.md)

这是一个适配器：让名为 Linger 的技能宿主调用 POPOPX Mac Node 的十个业务引擎，走的是节点自己已经在跑的那个
控制台。它接收三个参数——`service`、`action`、`payload`——构造一条规范的 `NODE_CMD` 行，用
`@popopx/node-bridge` 校验，然后 POST 到 `http://127.0.0.1:18920/api/engine/invoke`。它不开别的端口、
不说别的协议，并且在任何 socket 建立之前就拒绝物理锁定。

Linger 和技能宿主都不在这三个仓库里。这个包是面向未来的设计，它也不会声称已经用真宿主验证过。已验证的是：
`tsc --strict` 干净构建、单元测试对着假传输层跑通（不需要节点）、以及文末那串对着活节点的手工步骤。

---

## 这是什么

一个函数、一种带类型的回答形态、不向宿主抛异常。

```js
import { run } from "@popopx/linger-skill";

const answer = await run({
  service: "shadow_cos",
  action: "daily",
  payload: { tone: "terse" },
  handoff: "http://127.0.0.1:18920/?t=paste-the-value-the-node-printed"
});

if (answer.ok) {
  console.log(answer.headline, answer.body, answer.artifacts, answer.durationMs, answer.nodeOk);
} else {
  console.log(answer.code, answer.message, answer.detail);
}
```

`answer` 是一个带类型的联合。成功时携带节点自己的 `CommandResult` 字段：`headline`、`body`、`artifacts`、
`durationMs`、`at`、`engine`、`deterministic`、`metrics`，以及 `nodeOk`——那是引擎自身的判定，所以
`ok: true` 配 `nodeOk: false` 可以诚实地表示"节点回答了，并拒绝执行"。`body` 不做二次截断：节点已经把它
切到 1 800 字符（`Sources/PopopxMacNode/Models/MacNodeModels.swift:1196-1200`）。失败时返回
`{ ok: false, code, message, detail? }`，其中 `code` 取自共享的错误词汇表，另加 `badConfig`。

`run()` 内部的顺序就是它的安全属性：

1. **语法**——构造规范行，交给共享解析器判定
2. **配置**——解析设置；配置文件读不到时退回安全默认值
3. **策略**——`assertSendable`，在目标解析之前、在 socket 存在之前
4. **目标**——只允许回环的交接解析
5. **执行**——`ConsoleClient.invokeWithRetry`，绝不手写 `fetch`

因此语法与策略判定都是零网络调用；配置文件读坏也不会让第 3 步变宽松：`PPX_SKILL_CONFIG` 读不到时
`allowLockdown` 取 `false`。

---

## 安装

需要 Node 20.10 或更新版本。运行时依赖只有一个 `@popopx/node-bridge`，即本仓库的 `integrations/shared`，
以路径方式链接。没有 `ws`、没有 `eventsource`、没有测试框架：测试跑在 `node:test` 上，唯一的传输就是 Node
内置的 `fetch`。

```sh
cd integrations/linger-skill
npm install --no-audit --fund=false
npm run build
npm test
```

`npm test` 先构建，再对 `dist` 跑 `node --test`。`npm run typecheck` 只检查不产出。

---

## 配置交接

控制台 token 是 24 字节随机值，每次启动生成一次，并且刻意永不落盘
（`Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3224-3226`）。它可以放在 `X-PPX-Token`
请求头或 `t` 查询参数里（`:3701-3708`）。请从 `--headless` 打印的内容或菜单栏"复制配对地址"取它；技能不把
token 写盘、不出现在日志行里，只记录 `tokenFingerprint`（长度加末四位）。

有两个推论，而它们都是节点的性质而非这个适配器的毛病：

* 节点重启会让所有已保存配置失效，并被表达成一个明确的 `tokenRejected`，而不是重试循环（`../CONTRACT.zh-CN.md` §2）
* 指向非回环地址的交接一律以 `nonLoopbackTarget` 拒绝，因为传输是明文 HTTP，而 token 是持有即生效的秘密

```sh
cp config/popopx-bridge.example.json popopx-bridge.json
export PPX_SKILL_CONFIG="$PWD/popopx-bridge.json"
export PPX_CONSOLE_TOKEN="paste-the-value-the-node-printed"
```

示例配置只有四个键：`handoff`、`timeoutMs`、`allowLockdown`、`logRefusals`。出现未知键就是 `badConfig`
失败——一个悄悄什么都不做的拼写错误，比一次明确的拒绝更糟。`handoff: ""` 表示"去读 `PPX_CONSOLE_TOKEN`"。

优先级：`handoff` 参数，其次 `PPX_SKILL_CONFIG` 所指文件里的 `handoff`，再次环境变量
（`PPX_CONSOLE_TOKEN`、`PPX_CONSOLE_HOST`、`PPX_CONSOLE_PORT`），最后是安全默认值。插件共享密钥来自
`secret` 参数或 `PPX_BRIDGE_SECRET`。把 `PPX_SKILL_LOG` 设成 `silent` 可以只丢掉 `info` 行：拒绝仍然会写，
因为契约 §7 没给它退路。

---

## 线上传输的是什么

只有一行，而且由你传入的参数构造。宿主的别名与写法先被解析，所以 `daily` 到节点时是 `briefing`：

```text
::popopx_sys::NODE_CMD::shadow_cos::briefing::{"tone":"terse"}
```

语法即 `NodeWire.parseCommand`（`Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`）：前缀必须位于
0 号位，切分恰好消耗两个 `::`，因此 payload 内可以含 `::`，`serviceId`、`action`、`payload` 都必须非空，
并且 `payload` 可用 `1024 - (serviceId + action + 2)` 个字素簇——按 Swift 的计数方式，一个中日韩汉字或一个
emoji 都算 1，而不是 JavaScript 会报出的 2 或 4 个 UTF-16 单元（`MacNodeModels.swift:52,129-131`）。
`serviceId` 必须是精确的小写 `EngineKind` 原值：别名与大小写折叠都上不了线，这就是适配器要先规范名化再校验
的原因（`TenBusinessEngines.swift:2151-2170`）。

这一行只是内部表示。真正执行只走那条确实能驱动引擎的路由：`POST /api/engine/invoke`，请求体
`{ kind, action, payload }`，其中 `payload` 必须是 JSON 对象，因为节点按字典解码
（`LocalWebConsoleServer.swift:3638-3645,3878-3882`）。`POST /api/command` 只用于诊断，本包从不用它：
它的引擎调用会被节点的配对白名单门禁拒绝（`TenBusinessEngines.swift:2097-2108`），原文是
`Refused: the sender key is not on the paired-device whitelist.`

并发与重试沿用节点的节奏，而不是再造一个调度器（`../CONTRACT.zh-CN.md` §8）：每个节点缓存一个客户端，因此
同一节点只有一条在途指令，第二条并发调用直接返回 `inFlightLimit` 而不是排队。重试只有一次，而且只在失败
确实证明请求从未到达时（连接被拒）；超时或回答丢失会带着 `outcomeUnknown` 如实上报而不重发，因为
`chrono_ark seal` 与 `creator_paywall_hub grant` 不是幂等的。

---

## 服务与动作

下面是本包能发送的全部 id 与全部动作写法。规范名才是真正到达节点的名字；`also` 列出节点同样路由的别名；
`as service` 列出可接受的服务 id 别名。空动作 `""`（节点当作默认动作）由本桥接拒绝。

| service | canonical actions | also | as service |
| --- | --- | --- | --- |
| `shadow_cos` | `briefing` `negotiation_prompt` | `brief` `run` `daily` `daily_brief` `generate` `negotiation` `tactics` `prompt` | `cos` `chief_of_staff` |
| `zero_trust_warroom` | `assign` `embed` `trace` `registry` | `register` `queue_assign` `mark` `distribute` `extract` `identify` `decode` `status` | `warroom` `zero_trust` `gop_watermark` |
| `zerotrace_studio` | `process` `strip` `anchor` `shred` | `run` `ingest` `sanitize` `sanitise` `clean` `metadata` `briefing_clip` `broadcast` `destroy` | `studio` `zero_trace` |
| `solo_autopilot` | `run` `script` | `generate` `video` `clip` `copy` | `solo` `autopilot` |
| `edge_compute_mesh` | `status` `offer` `poll` `enable` `settle` | `summary` `accept` `execute` `run` `drain` `sharing` | `mesh` `edge_mesh` `compute_mesh` |
| `morning_tv` | `broadcast` `digest` `scheduled` `schedule` | `run` `tv` `headlines` `feeds` `fire` `on_time` `next` | `tv` `morning` |
| `phantom_sentinel` | `status` | `probe` | `sentinel` `lockdown` |
| `chrono_ark` | `seal` `list` `unseal` `heartbeat` `check` `reveal` | `lock` `store` `vaults` `status` `open` `recover` `ping` `alive` `watch` `release_check` `dir` `folder` | `ark` `time_lock` |
| `health_sentinel` | `read` `binaural` | `report` `parse` `interpret` `tone` `sleep` `wav` | `health` |
| `creator_paywall_hub` | `verify` `grant` `claim` `status` | `ticket` `admit` `deliver` `drop` `distribute` `red_packet` `redpacket` `ledger` | `paywall` `creator` |

`chrono_ark lock` 是给时间锁保险库加封，不是锁屏。除了这个词，两者没有任何共同点。

---

## 拒绝，以及锁定

`phantom_sentinel` 是本适配器默认拒绝的那个服务。节点是真的要动手：`lockdown` 会清空通用剪贴板、用
`diskutil unmount` / `diskutil unmountDisk` 卸载卷（拒绝启动卷、绝不使用 `--force`）、用
`/usr/bin/pmset displaysleepnow` 熄屏、用 `CGSession -suspend` 锁屏
（`TenBusinessEngines.swift:5568-5576,5600-5615,5741-5780`）。全程用户态，而且没有确认、没有冷却、没有
干跑、没有撤销：`lastLockAt` 只被写入和展示，从不作为节流依据（`:5636-5638,5692`）。

节点内部有两处顺序，正是"必须由插件来说不"的原因：

* `invoke()` 在检查该引擎是否被关闭**之前**就处理锁定触发词，因此即使引擎已关闭，对
  `/api/engine/invoke` 发送 `{"kind":"phantom_sentinel","action":"lock_all"}` 照样锁整机
  （`TenBusinessEngines.swift:2118-2123`，触发词见 `MacNodeModels.swift:98`）
* `execute()` 在配对设备白名单门禁之前就进入确定性锁定分支（`:2059-2075`、`:2097`）

所以，凡规范名是 `lockdown`、`lock`、`lock_all`、`sentinel`、`🔒` 的动作，都在任何 socket 打开之前被拒绝，
除非操作者把 `allowLockdown: true` **并且**出示至少 16 字符的插件共享密钥（`PPX_BRIDGE_SECRET`）。对应的
code 是 `lockdownDenied` 与 `secretRequired`；每一次拒绝都带规范行与开关状态写进日志；`status`（别名
`probe`）保持可用，因为它只出报告（`:5678-5710`）。

请注意这处不对称，因为它是宿主最容易读错的地方：`sentinel` 与 `lockdown` 是合法的**服务**别名，而
`lockdown`、`lock`、`lock_all`、`sentinel`、`🔒` 是该服务被屏蔽的**动作**。`phantom_sentinel status` 能跑；
`lockdown lockdown` 不能。

| code | 含义 | 是否重试 |
| --- | --- | --- |
| `malformedCommand` | 前缀错误、段数不足、payload 为空、payload 不是 JSON 对象、动作未知 | 否 |
| `unknownService` | 该 id 解析不到任何引擎 | 否 |
| `emptyAction` | 节点的 `""` 默认动作，本桥接拒绝它 | 否 |
| `payloadBudget` | payload 超出这一行的字素簇预算 | 否 |
| `lockdownDenied` | 被屏蔽动作，且 `allowLockdown` 未开启 | 否 |
| `secretRequired` | `allowLockdown: true` 但没有 16 字符密钥 | 否 |
| `nonLoopbackTarget` | 交接指向非 `127.0.0.1` 的目标 | 否 |
| `tokenRejected` | HTTP 401，通常是节点重启了 | 否 |
| `methodNotAllowed` `405`、`lengthRequired` `411`、`payloadTooLarge` `413` | 控制台认为请求形态不合法 | 否 |
| `nodeUnreachable` | 没有监听者，或读取超时 | 仅一次，且只在连接被拒时 |
| `nodeBusy` | HTTP 5xx | 否：节点可能已经开始执行 |
| `inFlightLimit` | 另一条指令正占着节点唯一的槽位 | 否 |
| `badResponse` | 重定向、非 JSON、路由不存在，或未被类型化的内部故障 | 否 |
| `badConfig` | `PPX_SKILL_CONFIG` 所指文件读不到，或带有本包不认识的键 | 否 |

---

## 对着活节点的手工验收

先启动节点，复制它打印的控制台 URL，然后在本包目录下逐条执行。每一步都写明正确答案长什么样，因此失败是
关于节点的一个事实，而不是一个谜。

```sh
# 0 · the handoff you copied, kept in the environment rather than in a file
export PPX_CONSOLE_URL="http://127.0.0.1:18920/?t=paste-the-value-the-node-printed"

# 1 · read the console directly, with the token in the header
node --input-type=module -e 'const u=new URL(process.env.PPX_CONSOLE_URL);const r=await fetch(u.origin+"/api/health",{headers:{"X-PPX-Token":u.searchParams.get("t")}});console.log(r.status,await r.text())'

# 2 · run one engine through the skill: canonical action, canonical service id
node --input-type=module -e 'const {run}=await import("./dist/src/index.js");console.log(await run({service:"edge_compute_mesh",action:"summary",handoff:process.env.PPX_CONSOLE_URL}))'

# 3 · prove the refusal needs no socket: the console stays untouched
node --input-type=module -e 'const {run}=await import("./dist/src/index.js");console.log(await run({service:"phantom_sentinel",action:"lockdown",handoff:process.env.PPX_CONSOLE_URL}))'

# 4 · an alias service and a non-canonical action, canonicalised before validation
node --input-type=module -e 'const {run}=await import("./dist/src/index.js");console.log(await run({service:"warroom",action:"register",handoff:process.env.PPX_CONSOLE_URL}))'

# 5 · watch the node answer on the one push channel it has, then stop it with Ctrl-C
node --input-type=module -e 'const {NodeBridge}=await import("@popopx/node-bridge");const b=new NodeBridge({handoff:process.env.PPX_CONSOLE_URL});for await(const e of b.events())console.log(e.channel,e.level,e.message)'
```

第 2 步必须返回 `ok: true` 且 `action: "status"`，也就是规范写法。第 3 步必须返回 `lockdownDenied`，附带
`blocked canonical actions` 说明，并且全程没有 HTTP 请求；节点自己的日志里什么都不会出现。第 4 步必须以
`zero_trust_warroom` 的 `assign` 作答。如果第 2 步返回 `tokenRejected`，那是节点重启并换了 token：粘贴新的
交接即可，这是设计而不是故障。

---

## 这个包不做什么

* 不开端口、不加传输层、不创设授权主体；唯一的端点是 `127.0.0.1:18920`，而且它上面没有 WebSocket。聊天守护
  进程在 `127.0.0.1:5225` 上的控制套接字按设计不做鉴权，并且节点自己是它的客户端，所以本包从不去连它
  （`../CONTRACT.zh-CN.md` §1）
* 不把 token 写盘、不记进日志、也不会出现在提交进版本库的文件里
* 不模拟物理动作：节点不会执行的事，本适配器就不提供
* 不排队。同一节点一条在途，因为已经有一个 actor 在串行化这些引擎
* 不声称静默送达：`NODE_CMD` 在 iOS 上还不是 signal kind，所以节点指令会渲染成可见气泡，节点会在控制台事件上
  记录 `iosSignalGap`（`MacNodePopopxBridge.swift:2200-2214`）
* 不拿渲染队列当"锁定被延迟"的借口：那道闸门从不出现在锁定路径上（`TenBusinessEngines.swift:63-69`）

---

## 目录结构

| 路径 | 职责 |
| --- | --- |
| `src/index.ts` | `run()`、带类型的输出联合、按节点缓存的客户端 |
| `src/handlers.ts` | 宿主参数到规范行的构造、配置解析、策略调用 |
| `src/log.ts` | 单行 JSON 记录、token 抹除、拒绝写入 |
| `SKILL.md` | 宿主看的技能卡：输入、服务、动作、锁定披露 |
| `config/popopx-bridge.example.json` | 复制即用的模板，四个键，不含机密 |
| `test/skill.test.ts` | 测试套件，对着假 `fetch` 跑，不需要节点 |

---

## 排障

| 现象 | 结论 |
| --- | --- |
| 每次调用都是 `tokenRejected` | 节点重启了；token 随进程消亡，粘贴新的交接 |
| `nonLoopbackTarget` | 交接不是回环控制台 URL；`https` 同样被拒，控制台是回环上的明文 HTTP |
| invoke 返回带 404 的 `badResponse` | 那个端口上是别的东西在应答；本桥接只跟节点的控制台说话 |
| 看着不长的 payload 却报 `payloadBudget` | 预算按字素簇算，而且 `serviceId` 与 `action` 也计入；请用规范 id 与规范动作 |
| 指名 payload 的 `malformedCommand` | 路由把 `payload` 解码成字典，所以它必须是 JSON 对象，不能是数组、裸字符串或数字 |
| `inFlightLimit` | 该节点上上一条调用还在跑；先 await 它 |
| 出现了你没预期的拒绝 | 在日志里 grep `"event":"refusal"`；每次拒绝都记录 code、规范行与开关状态 |
| 日志里没有东西 | `PPX_SKILL_LOG=silent` 只丢掉 `info` 行；拒绝始终会写 |

---

## 本包实测出处

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

---

## 许可

AGPL-3.0-only，与节点一致。商用条款见 `../../LICENSE-COMMERCIAL.md`。

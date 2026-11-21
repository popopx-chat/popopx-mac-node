# 共享桥接内核 · `@popopx/node-bridge`

语言：[English](README.md) · [简体中文](README.zh-CN.md) · 契约：[English](../CONTRACT.md) · [简体中文](../CONTRACT.zh-CN.md) · 节点：[../../README.md](../../README.md)

这是两个插件共同导入的内核：线格式文法解析器、控制台客户端、SSE 读取器。`integrations/CONTRACT.zh-CN.md`
里的规则只在这一个地方以代码形式存在，所以插件只从 barrel 入口导入，别处都没有出口——它想绕过
`assertSendable` 也找不到可以伸手进去的模块。

零运行时依赖，只用 `node:` 内置模块，只走回环，只有 18920 这一个端口。

---

## 这个包是什么

四个模块，一个入口：

| 模块 | 导出 | 职责 |
| --- | --- | --- |
| `wireCommand.ts` | `parseWireLine`、`renderWireLine`、`assertSendable`、`ROUTES`、`SERVICE_IDS` | 文法、规范化、策略 |
| `consoleClient.ts` | `resolveTarget`、`ConsoleClient`、`ROUTE` | 对着控制台的唯一 HTTP 客户端 |
| `eventStream.ts` | `EventStream`、`splitFrames`、`decodeFrame`、`EVENT_CHANNELS` | SSE 读取器 |
| `errors.ts` | `BridgeError`、`BridgeErrorCode`、`isRetryable` | 三者共用的错误形状 |

`NodeBridge` 用一次构造把它们接好，这样插件既不会各自重写目标解析，也不可能在未显式给出
`allowLockdown` 和一个密钥的情况下放宽锁定策略。

```ts
import { NodeBridge } from "@popopx/node-bridge";

const bridge = new NodeBridge({ handoff: process.argv[2] ?? "" });
const outcome = await bridge.run("::popopx_sys::NODE_CMD::shadow_cos::briefing::{}");
console.log(outcome.line, outcome.result?.ok);
```

## 交接串

`resolveTarget` 只接受两种形状，其余一律拒绝：

| 输入 | 结果 |
| --- | --- |
| `http://127.0.0.1:18920/?t=<token>` | 直接从节点打印的那个 URL 里取主机、端口和 Token |
| `<token>` | 裸 Token，主机与端口取自 `PPX_CONSOLE_HOST` / `PPX_CONSOLE_PORT` |

环境变量那条支路是为 systemd 和 launchd 单元准备的：它们不能把 Token 写进命令行。输入为空且
`PPX_CONSOLE_TOKEN` 也为空时，在建立任何 socket 之前就返回 `tokenRejected`。

在这一步、第一个请求之前就完成的拒绝：

- 非回环主机，或 `https://` 的控制台 → `nonLoopbackTarget`；
- `PPX_CONSOLE_HOST` 不在回环范围内，或 `PPX_CONSOLE_PORT` 不是一个合法端口 → 同一个错误码；
- URL 里没有 `?t=`，`PPX_CONSOLE_TOKEN` 也没设 → `tokenRejected`。

理由不是洁癖：Token 是 bearer 密钥，而它走的是明文 HTTP，一个指向可路由地址的拼写错误就会把它送出这台机器。

## 线格式文法

一条命令行由前缀、service id、action、payload 用 `::` 连接而成——恰好四段，不多不少：

```
::popopx_sys::NODE_CMD::chrono_ark::seal::{"note":"ledger"}
```

`parseWireLine` 做的正是插件不该重复实现的事：

1. 前缀必须原样出现在偏移 0，等于 `COMMAND_PREFIX`；
2. service id 经 `normaliseServiceId`，它接受节点自己也接受的那些别名，然后必须落进 `SERVICE_IDS`；
3. action 经 `normaliseAction`，且必须是该服务确实提供的一个规范 action；
4. payload 必须是一个 JSON 对象，且其字素簇数量要落进下面这个预算。

预算按字素簇计数，与节点上 Swift `String.count` 用的是同一个单位：整行上限
`MAX_SIGNAL_PAYLOAD_CHARACTERS` 是 1024，所以一条命令可用
`1024 - serviceId - action - 2`。当字符串里带有组合符号或 emoji 时，让两侧对齐的正是
`Intl.Segmenter`。

## 十个服务，以及唯一被拒绝的 action

`ROUTES` 由一张规格表生成，是插件能发什么的唯一来源：

| 服务 | 规范 action | 写法数 | 被拒 |
| --- | --- | --- | --- |
| `shadow_cos` | `briefing`、`negotiation_prompt` | 10 | |
| `zero_trust_warroom` | `assign`、`embed`、`registry`、`trace` | 12 | |
| `zerotrace_studio` | `anchor`、`process`、`shred`、`strip` | 13 | |
| `solo_autopilot` | `run`、`script` | 6 | |
| `edge_compute_mesh` | `enable`、`offer`、`poll`、`settle`、`status` | 11 | |
| `morning_tv` | `broadcast`、`digest`、`schedule`、`scheduled` | 11 | |
| `phantom_sentinel` | `status` | 7 | `lockdown` |
| `chrono_ark` | `check`、`heartbeat`、`list`、`reveal`、`seal`、`unseal` | 18 | |
| `health_sentinel` | `binaural`、`read` | 8 | |
| `creator_paywall_hub` | `claim`、`grant`、`status`、`verify` | 12 | |

十个服务、35 个节点分支、这里接受 108 种写法、节点自己的 `switch` 里有 117 种。多出的 9 种是 action
为空时落到 `unsupported` 的那些分支；桥接侧从不接受空 action，所以它更早拒绝，并且给出名字。

`phantom_sentinel lockdown` 是唯一的拒绝项，因为只有它对身体动手：清空剪贴板、卸载卷、让显示器休眠、挂起
登录会话，而且没有确认、没有冷却、没有撤销。`assertSendable` 在任何 socket 存在之前就拒绝它，除非调用方同时
给出 `allowLockdown: true` **和** 一个至少 16 字符的 `secret`（`PPX_BRIDGE_SECRET`）。开启之前请先读
契约第 7 节。

## 调用控制台

| 方法 | 请求 | 说明 |
| --- | --- | --- |
| `health()` | `GET /api/health` | 控制台自身的存活状态 |
| `snapshot()` | `GET /api/snapshot` | 任何事件流结束之后的对账点 |
| `invoke(command)` | `POST /api/engine/invoke` | 一条命令，一个答复 |
| `runLine(line)` | 先解析，再 `invoke` | 即使什么都没发出去，也会把解析结果返回 |
| `invokeWithRetry(command)` | `POST`，遵守下一节的重试规则 | 契约允许的唯一一次重试 |
| `events(signal)` | `GET /api/events` | SSE，见下一节 |

每个请求都带 `X-PPX-Token` 与 `Accept: application/json`，POST 再加
`Content-Type: application/json`；fetch 固定在 `redirect: "manual"` 下运行，并套一层
`AbortSignal.timeout`，所以既不会跟随重定向，也不会让一次卡住的调用把插件吊死。没有 cookie、没有
session、没有"本机例外"：所有 `/api/` 路由都要 bearer，`/api/health` 也不例外。
`tokenFingerprint` 只报长度和末四位，这也正是日志里唯一允许出现的内容。

## 错误码，以及何时允许重试

`BridgeErrorCode` 分三组：传输层（`tokenRejected`、`methodNotAllowed`、`lengthRequired`、
`payloadTooLarge`、`nodeUnreachable`、`nodeBusy`、`badResponse`）、在任何 socket 之前就定论文法层
（`malformedCommand`、`unknownService`、`emptyAction`、`payloadBudget`）、以及策略层
（`lockdownDenied`、`secretRequired`、`nonLoopbackTarget`、`inFlightLimit`）。

`isRetryable` 只对 `nodeUnreachable` 与 `nodeBusy` 返回 true，但这不是通行证：重试还要求
`mayHaveExecuted === false`，而只有"连接被拒绝"能证明这一点。再往后的任何失败——超时、连接重置、响应体
截断——结果都是未知的，而 `chrono_ark seal` 与 `creator_paywall_hub grant` 并不幂等。节点不会替你重放
命令，所以一个不明的结果该拿去和 `snapshot()` 对账，而不是再打一遍。

## 观看事件

控制台只推送一条 SSE 通道 `/api/events`，带九个具名事件（`install`、`pairing`、`engine`、`bridge`、
`result`、`mesh`、`sentinel`、`settings`、`system`）。帧里只有 `event:` 与 `data:`：没有 `id:` 字段，
也没有重放，所以一条在半途结束的事件流必须与 `snapshot()` 对账，而不是续传。节点在排满 64 个事件之后会
主动结束这条流；这正是 `EventStream` 要有 `maxReconnects` 的原因，一次性命令的默认值就是一次读完。

## 夹具与漂移门禁

`test/fixtures/service-table.json` 是生成的，绝不手改：

```sh
npm run export:table
```

有三道门禁读它，这也正是 TypeScript 与 Swift 彼此约束的地方：

| 门禁 | 比对对象 |
| --- | --- |
| `test/serviceTable.test.ts` | 夹具与当前真实导入的 `ROUTES` |
| `IntegrationsContractTests.testTheBridgeRoutingTableMatchesTheNodesDispatchSwitch` | 路由表与 `TenBusinessEngines.swift` 里的 `dispatch`，从源码重新推导 |
| `IntegrationsContractTests.testTheSharedCorpusGradesTheNodesOwnParser` | 夹具里的接受与拒绝语料，交给 `NodeWire.parseCommand` 判卷 |

改一个引擎，夹具就会过期；夹具过期不动，两道门禁就红。这就是目的：漂移必须由一条命令抓住，而不是由一个
读者的眼睛抓住。

## 目录结构与脚本

```
shared/
  src/{wireCommand,consoleClient,eventStream,errors,index}.ts
  scripts/exportServiceTable.mjs
  test/{wireCommand,consoleClient,eventStream,serviceTable}.test.ts
  test/fixtures/service-table.json
```

| 脚本 | 作用 |
| --- | --- |
| `npm run build` | `tsc -p tsconfig.json`，产物进 `dist/` |
| `npm run typecheck` | 同样编译，但 `--noEmit` |
| `npm run export:table` | 从 `ROUTES` 重新生成夹具 |
| `npm test` | 先构建，再对 `dist/test` 跑 `node --test` |

## 许可

AGPL-3.0-only，与节点一致。商业条款见仓库根目录的 `LICENSE-COMMERCIAL.md`。

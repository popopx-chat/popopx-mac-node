# OpenClaw 技能插件 · `@popopx/openclaw-skill`

语言：[English](README.md) · [简体中文](README.zh-CN.md) · 契约：[English](../CONTRACT.md) · [简体中文](../CONTRACT.zh-CN.md) · 内核：[../shared/README.md](../shared/README.md)

这是一个按读取 `openclaw.plugin.json` 的宿主形状写成的插件：它为 POPOPX Mac Node 的每个业务引擎注册一个工具，
一共十个，而每一次调用都走节点自己已经在跑的那个控制台 `http://127.0.0.1:18920`。它不开端口、不铸造凭据，并在
socket 存在之前就拒绝物理锁定那条路。

OpenClaw 本身不是这个包的依赖，也不在这几个仓库里。已验证的是：TypeScript 以 `tsc --strict` 干净编译、
`router.test.ts` 对着假传输层驱动每一个工具（不需要节点）、`deploy.test.ts` 渲染并解析两个单元模板、
`readme.test.ts` 保证两份语言文件仍是同一份文档，以及下面那段对着活节点的手工步骤。

---

## 这个插件是什么

| 文件 | 职责 |
| --- | --- |
| `src/index.ts` | 宿主适配层：`registerTool` 调用、插件元数据、配置形状 |
| `src/handlers/tenServicesRouter.ts` | 工具定义，以及关于"什么可以发出去"的全部判断 |
| `src/log.ts` | 每个事件一行 JSON，交接串会被从中抹掉 |
| `openclaw.plugin.json` | 宿主读取的清单，包括它必须披露的那条拒绝 |
| `deploy/` | POSIX 安装脚本，以及它渲染的 launchd 与 systemd 模板 |

工具的 `action` 枚举由内核的路由表生成，所以宿主不可能拿到一个节点并不路由的动作。内核就是
`@popopx/node-bridge`（`file:../shared`），且只从 barrel 入口导入：文法、策略、传输都在那里，这个包不自建任何
依赖。

```ts
import { register } from "@popopx/openclaw-skill";

register({ registerTool: (tool, handler) => host.add(tool, handler), config: { handoff } });
```

## 安装

```sh
cd integrations/shared && npm install && npm run build
cd ../openclaw-skill && npm install && npm run build && npm test
```

`npm install` 会把 `@popopx/node-bridge` 链到 `../shared`，这一步不下载任何东西。锁文件里来自 registry 的包是
`typescript`、`@types/node`，以及 `@types/node` 自身需要的 `undici-types`，它们全都是 devDependencies，所以构建
好的插件只有一个依赖，而那个依赖就是本仓库。

## 上线的那一行

每一次工具调用最终都是一行文本，在 socket 打开之前由内核组装并校验完成：

```text
::popopx_sys::NODE_CMD::chrono_ark::seal::{"note":"ledger"}
```

那套文法属于节点，见 `Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`：前缀之后恰好四段，payload 按
字素簇计数、受节点自己那条 1024 预算约束，service id 则走引擎接受的那套别名折叠。插件从不发送一行自己没解析过
的文本，也从不发送空的 `action`。

## 交接串

插件依次从 `config.handoff`、`PPX_BRIDGE_HANDOFF`、`PPX_CONSOLE_TOKEN` 取 Token。交接串要么是节点打印出来的那个
带 Token 的控制台 URL，要么就是裸 Token；内核里的 `resolveTarget` 会在任何请求之前拒绝非回环主机、`https` 的控制台
和空 Token。Token 不落盘、不打印，也永远不会出现在渲染出来的单元里。`src/log.ts` 在写下第一行日志之前就把 Token
登记为密钥，因此即便交接串写错了，日志里也不会留下可读的东西。

| 配置项 | 默认值 | 含义 |
| --- | --- | --- |
| `handoff` | 先 `PPX_BRIDGE_HANDOFF`，再 `PPX_CONSOLE_TOKEN` | 带 `?t=` 的控制台 URL，或裸 Token |
| `allowLockdown` | `false`，除非 `PPX_ALLOW_LOCKDOWN` 为真 | 唯一能解除插件侧拒绝的开关 |
| `secret` | `PPX_BRIDGE_SECRET`，否则为空 | 必须与它同时给出，且至少 16 字符 |
| `timeoutMs` | 15000 | 一次请求，超时即 `nodeUnreachable` |
| `fetchImpl` | `globalThis.fetch` | 测试里替代真实节点的那个实现 |
| `logger` | stderr 上的一个 `BridgeLogger` | 宿主日志通道，与插件自己的日志并行 |

## 宿主拿到的十个工具

每个工具名是 `popopx_` 加上 service id，必填 `action`，可选 `payload` 对象，后者原样进入
`POST /api/engine/invoke`：

| 工具 | 规范动作 | 被拒 |
| --- | --- | --- |
| `popopx_shadow_cos` | `briefing`, `negotiation_prompt` | |
| `popopx_zero_trust_warroom` | `assign`, `embed`, `registry`, `trace` | |
| `popopx_zerotrace_studio` | `anchor`, `process`, `shred`, `strip` | |
| `popopx_solo_autopilot` | `run`, `script` | |
| `popopx_edge_compute_mesh` | `enable`, `offer`, `poll`, `settle`, `status` | |
| `popopx_morning_tv` | `broadcast`, `digest`, `schedule`, `scheduled` | |
| `popopx_phantom_sentinel` | `status` | `lockdown` |
| `popopx_chrono_ark` | `check`, `heartbeat`, `list`, `reveal`, `seal`, `unseal` | |
| `popopx_health_sentinel` | `binaural`, `read` | |
| `popopx_creator_paywall_hub` | `claim`, `grant`, `status`, `verify` | |

```text
shadow_cos           briefing  negotiation_prompt
zero_trust_warroom   assign  embed  registry  trace
zerotrace_studio     anchor  process  shred  strip
solo_autopilot       run  script
edge_compute_mesh    enable  offer  poll  settle  status
morning_tv           broadcast  digest  schedule  scheduled
phantom_sentinel     status                    refused: lockdown
chrono_ark           check  heartbeat  list  reveal  seal  unseal
health_sentinel      binaural  read
creator_paywall_hub  claim  grant  status  verify
```

枚举里同时带着节点也接受的别名写法，因为要 `lock` 的模型和要 `lockdown` 的模型必须得到同一个答复：插件先规范化
再校验，而上表每行第一个名字就是真正上线的那个。`status` 会出现在多个服务之下，这是有意的——每个引擎各自报告自己
的状态。

## 锁定，以及为什么把拒绝写出来

`phantom_sentinel lockdown` 会清空剪贴板
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5568-5572`）、卸载卷
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5581-5585`）、让显示器休眠
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5606-5610`）、挂起登录会话
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5611-5615`）——没有确认、没有冷却、没有演练、没有撤销。
它在引擎自身的开关判断之前就会被触达
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2113-2120`），在命令行路径上受设置版本号约束
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2061-2069`），并且是那 35 个分支之一
（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2199-2328`）。

那是节点的行为，不是这个插件的行为，所以插件默认拒绝它，并把拒绝写在操作者读得到的地方：清单里的
`deniedTools`、宿主展示的工具描述、以及那条拒绝日志。一个只表现为通用错误的拒绝，只会让操作者去猜。

```json
{
  "console": { "port": 18920, "loopbackOnly": true, "portFallback": false },
  "policy": { "allowLockdown": false, "minimumSecretCharacters": 16 },
  "serialisation": { "maxInFlightCommandsPerNode": 1 }
}
```

打开它需要两样东西同时到位：`allowLockdown: true` **且**至少 16 字符的 `PPX_BRIDGE_SECRET`，由内核的
`assertSendable` 检查。此外 `deploy/install.sh` 会拒绝渲染任何授予该路径的单元——把一条自我锁机的服务无人值守地
部署出去，不是安装脚本该做的决定。先读契约第 7 节。

## 部署成用户级服务

```sh
export PPX_CONSOLE_TOKEN=<the token the node printed>
sh deploy/install.sh --target auto --host /absolute/path/to/host --instance default
```

POSIX sh、`set -eu`、不用 sudo、不联网：脚本什么都不下载，因此也就不存在把下载内容交给 shell 这回事。它只写
launchd 单元、systemd 用户单元和一个仅属主可读的日志目录，然后用 `launchctl print` 与
`systemctl --user status` 去验证，而不是假定单元已经起来。

| 选项 | 作用 |
| --- | --- |
| `--target auto` | macOS 走 launchd，Linux 走 systemd；另有 `launchd`、`systemd`、`both` |
| `--instance NAME` | systemd 单元的实例名，由 `%i` 说明符填充 |
| `--host PATH` | 加载该插件的可执行文件绝对路径 |
| `--render-only` | 只渲染并检查，不碰任何 init 系统 |
| `--help` | 打印选项清单，不写任何文件、不调用 init 系统 |

## 对着活节点手工运行

```sh
# 0 - build, then drive one tool with the token in the environment rather than in a file
npm run build
PPX_CONSOLE_TOKEN=<token> node --input-type=module -e 'import { TenServicesRouter } from "./dist/src/handlers/tenServicesRouter.js"; console.log(await new TenServicesRouter().call("chrono_ark", "list", {}));'
```

```sh
# 1 - an alias spelling and an empty action: canonicalised, then refused before the socket
PPX_CONSOLE_TOKEN=<token> node --input-type=module -e 'import { TenServicesRouter } from "./dist/src/handlers/tenServicesRouter.js"; const router = new TenServicesRouter(); console.log(await router.call("phantom_sentinel", "lock", {})); console.log(await router.call("morning_tv", "", {}));'
```

```sh
# 2 - the same line the host would build, sent as one wire command
PPX_CONSOLE_TOKEN=<token> node --input-type=module -e 'import { TenServicesRouter } from "./dist/src/handlers/tenServicesRouter.js"; console.log(await new TenServicesRouter().runLine("::popopx_sys::NODE_CMD::shadow_cos::briefing::{}"));'
```

第 1 步在节点停机时仍然回答 `lockdownDenied` 与 `emptyAction`，这正是重点：这两个答复不是网络上来的。控制台只在
App 运行期间存在，所以第 0 步里一次被拒绝的连接意味着节点没在跑，而不是插件出了问题。所有 `/api/` 路由都要
bearer，健康检查也不例外（`Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3559-3566`）。

## 目录结构、脚本与门禁

```text
openclaw-skill/
  src/index.ts
  src/log.ts
  src/handlers/tenServicesRouter.ts
  openclaw.plugin.json
  deploy/install.sh
  deploy/launchd.com.popopx.bridge.plist.template
  deploy/popopx-bridge@.service.template
  test/router.test.ts
  test/deploy.test.ts
  test/readme.test.ts
```

| 命令 | 它证明什么 |
| --- | --- |
| `npm run build` | 整个包在严格模式下通过 `tsc` 编译 |
| `npm test` | 先构建，再对 `dist` 跑 `node --test` |
| `sh -n deploy/install.sh` | 安装脚本按 POSIX sh 解析 |
| `swift test --filter IntegrationsContractTests` | 清单、路由表与节点三者一致 |

## 许可

AGPL-3.0-only，与节点和内核一致。商业条款见仓库根目录的 `LICENSE-COMMERCIAL.md`。

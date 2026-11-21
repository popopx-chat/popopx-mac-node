# OpenClaw skill · `@popopx/openclaw-skill`

Language: [English](README.md) · [Chinese](README.zh-CN.md) · contract: [English](../CONTRACT.md) · [Chinese](../CONTRACT.zh-CN.md) · kernel: [../shared/README.md](../shared/README.md)

A plugin shaped for a host that reads `openclaw.plugin.json`: it registers one tool per POPOPX Mac Node
business engine, ten in total, and every call goes to the console the node already runs at
`http://127.0.0.1:18920`. It opens no port, mints no credential, and refuses the physical lockdown path
before a socket exists.

OpenClaw itself is not a dependency of this package and is not in these repositories. What is verified: the
TypeScript compiles under `tsc --strict`, `router.test.ts` drives every tool against a fake transport with
no node involved, `deploy.test.ts` renders and parses both unit templates, `readme.test.ts` keeps the two
language files one document, and the manual steps below run against a live node.

---

## What this is

| File | Role |
| --- | --- |
| `src/index.ts` | the host adapter: `registerTool` calls, plugin metadata, config shape |
| `src/handlers/tenServicesRouter.ts` | the tool definitions and every decision about what is sent |
| `src/log.ts` | one JSON line per event, with the handoff scrubbed out of it |
| `openclaw.plugin.json` | the manifest a host reads, including the denial it must disclose |
| `deploy/` | POSIX installer plus the launchd and systemd templates it renders |

A tool's `action` enum is generated from the kernel's routing table, so a host cannot be offered an action
the node does not route. The kernel is `@popopx/node-bridge` (`file:../shared`), imported from the barrel
only: grammar, policy and transport all live there, and this package adds no dependency of its own.

```ts
import { register } from "@popopx/openclaw-skill";

register({ registerTool: (tool, handler) => host.add(tool, handler), config: { handoff } });
```

## Install

```sh
cd integrations/shared && npm install && npm run build
cd ../openclaw-skill && npm install && npm run build && npm test
```

`npm install` links `@popopx/node-bridge` to `../shared`; nothing is fetched for it. The registry packages
in the lockfile are `typescript`, `@types/node` and the `undici-types` that `@types/node` requires, all of
them devDependencies, so the built plugin has exactly one dependency and it is this repository.

## The wire line

Every tool call ends as one line, assembled and validated in the kernel before the socket opens:

```text
::popopx_sys::NODE_CMD::chrono_ark::seal::{"note":"ledger"}
```

That grammar is the node's, in `Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`: four segments
after the prefix, the payload budgeted in grapheme clusters against the same 1024 the node enforces, the
service id folded through the aliases the engine accepts. The plugin never sends a line it did not parse
first, and it never sends an empty `action`.

## The handoff

The plugin takes the token from `config.handoff`, then `PPX_BRIDGE_HANDOFF`, then `PPX_CONSOLE_TOKEN`. A
handoff is either the tokenised console URL the node printed or the bare token; `resolveTarget` in the
kernel rejects a non-loopback host, an `https` console and an empty token before any request. The token is
never written to a file, never printed, and never appears in a rendered unit. `src/log.ts` registers it as a
secret before the first line is written, so even a handoff mistake leaves nothing readable behind.

| Config key | Default | Meaning |
| --- | --- | --- |
| `handoff` | `PPX_BRIDGE_HANDOFF`, then `PPX_CONSOLE_TOKEN` | console URL with `?t=`, or the bare token |
| `allowLockdown` | `false`, unless `PPX_ALLOW_LOCKDOWN` is truthy | the only switch that can lift the plugin-side refusal |
| `secret` | `PPX_BRIDGE_SECRET`, else empty | required alongside it, at least 16 characters |
| `timeoutMs` | 15000 | one request, then `nodeUnreachable` |
| `fetchImpl` | `globalThis.fetch` | what the tests hand in instead of a node |
| `logger` | a `BridgeLogger` on stderr | host log channel, kept beside the plugin's own |

## Tools the host is offered

Each tool is named `popopx_` plus the service id, requires `action`, and takes an optional `payload` object
sent verbatim to `POST /api/engine/invoke`:

| Tool | Canonical actions | Refused |
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

The enum also carries the alias spellings the node accepts, because a model that asks for `lock` and a model
that asks for `lockdown` must get the same answer: the plugin canonicalises before it validates, and the
first name in each row above is what goes on the wire. `status` answers for several engines on purpose,
because each engine reports for itself.

## The lockdown, and why the refusal is disclosed

`phantom_sentinel lockdown` clears the pasteboard
(`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5568-5572`), unmounts volumes
(`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5581-5585`), puts the display to sleep
(`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5606-5610`) and suspends the login session
(`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5611-5615`) — no confirmation, no cooldown, no
dry run, no undo. It is reached before the engine's own on or off switch
(`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2113-2120`), it is gated by the settings revision
on the command path (`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2061-2069`), and it is one of
the 35 arms in `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:2199-2328`.

That is the node's behaviour, not this plugin's, so the plugin refuses it by default and names the refusal
where an operator can read it: in `deniedTools` in the manifest, in the tool description the host displays,
and in the logged refusal. A refusal that only appeared as a generic error would leave the operator
guessing.

```json
{
  "console": { "port": 18920, "loopbackOnly": true, "portFallback": false },
  "policy": { "allowLockdown": false, "minimumSecretCharacters": 16 },
  "serialisation": { "maxInFlightCommandsPerNode": 1 }
}
```

Turning it on takes two things at once: `allowLockdown: true` **and** a `PPX_BRIDGE_SECRET` of at least 16
characters, checked by `assertSendable` in the kernel. `deploy/install.sh` additionally refuses to render a
unit that grants the path, because deploying a self-locking service unattended is not an installer's call to
make. Read the contract, section 7, first.

## Deploying as a user service

```sh
export PPX_CONSOLE_TOKEN=<the token the node printed>
sh deploy/install.sh --target auto --host /absolute/path/to/host --instance default
```

POSIX sh, `set -eu`, no sudo, no network: the script downloads nothing, so nothing is piped into a shell. It
writes only the launchd agent, the systemd user unit and an owner-only log directory, then verifies with
`launchctl print` and `systemctl --user status` instead of assuming the unit came up.

| Option | Effect |
| --- | --- |
| `--target auto` | launchd on macOS, systemd on Linux; also `launchd`, `systemd`, `both` |
| `--instance NAME` | the systemd unit instance, filled by the `%i` specifier |
| `--host PATH` | absolute path of the executable that loads the plugin |
| `--render-only` | render and check, touch neither init system |
| `--help` | the flag list, with no write and no init-system call |

## Manual run against a live node

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

Step 1 answers `lockdownDenied` and `emptyAction` with the node stopped, which is the point: those answers
did not come from the network. The console only exists while the app is up, so a refused connection in step
0 means the node is not running rather than that the plugin failed. Every `/api/` route needs the bearer,
the health check included (`Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3556-3563`).

## Layout, scripts and gates

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

| Command | What it proves |
| --- | --- |
| `npm run build` | the package compiles with `tsc` under strict mode |
| `npm test` | build, then `node --test` over `dist` |
| `sh -n deploy/install.sh` | the installer parses as POSIX sh |
| `swift test --filter IntegrationsContractTests` | the manifest, the routing table and the node agree |

## License

AGPL-3.0-only, the same as the node and the kernel. Commercial terms are in `LICENSE-COMMERCIAL.md` at the
repository root.

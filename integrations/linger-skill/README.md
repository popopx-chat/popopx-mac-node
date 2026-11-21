# Linger skill · `@popopx/linger-skill`

Language: [English](README.md) · [Chinese](README.zh-CN.md) · contract: [English](../CONTRACT.md) · [Chinese](../CONTRACT.zh-CN.md)

An adapter that lets a skill host named Linger call the ten business engines of a POPOPX Mac Node
through the console the node already runs. It takes three arguments — `service`, `action`, `payload` —
builds one canonical `NODE_CMD` line, validates it with `@popopx/node-bridge`, and posts it to
`http://127.0.0.1:18920/api/engine/invoke`. It opens no other port, speaks no other transport, and
refuses a physical lockdown before any socket exists.

Neither Linger nor a skill host exists in these repositories. This package is forward-looking, and it
does not claim otherwise. What is verified: `tsc --strict` builds clean, the unit suite runs against a
fake transport with no node involved, and the manual steps near the end of this file run against a live
node.

---

## What this is

One function, one answer shape, no exceptions thrown at the host.

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

`answer` is a typed union. Success carries the node's own `CommandResult` fields: `headline`, `body`,
`artifacts`, `durationMs`, `at`, `engine`, `deterministic`, `metrics`, and `nodeOk` — the engine's own
verdict, which is how `ok: true` with `nodeOk: false` can honestly mean "the node answered and refused".
`body` is not re-truncated: the node already cuts it at 1 800 characters
(`Sources/PopopxMacNode/Models/MacNodeModels.swift:1196-1200`). Failure carries
`{ ok: false, code, message, detail? }` with `code` from the shared error vocabulary
plus `badConfig`.

The order inside `run()` is the safety property:

1. **grammar** — build the canonical line, let the shared parser judge it
2. **settings** — resolve config, falling back to the safe defaults if the file is unreadable
3. **policy** — `assertSendable`, before a target is resolved and before a socket exists
4. **target** — loopback-only handoff resolution
5. **execution** — `ConsoleClient.invokeWithRetry`, never a hand-rolled `fetch`

A grammar or policy verdict therefore costs zero network calls, and a broken config file cannot make
step 3 permissive: if `PPX_SKILL_CONFIG` cannot be read, `allowLockdown` is `false`.

---

## Install

Requires Node 20.10 or newer. One runtime dependency, `@popopx/node-bridge`, which is this repository's
own `integrations/shared` linked by path. No `ws`, no `eventsource`, no test framework: the suite runs on
`node:test`, and the only transport is the `fetch` built into Node.

```sh
cd integrations/linger-skill
npm install --no-audit --fund=false
npm run build
npm test
```

`npm test` builds first, then runs `node --test` over `dist`. `npm run typecheck` checks without emitting.

---

## Configure the handoff

The console token is 24 random bytes minted once per launch and deliberately never persisted
(`Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3224-3226`). It is accepted as the
`X-PPX-Token` header or the `t` query parameter (`:3701-3708`). Copy it from what `--headless` prints or
from the menu bar's copy-console-URL action; the skill never writes it to disk and never puts it in a
log line, only `tokenFingerprint` (length plus last four characters).

Two consequences follow, and both are features of the node rather than of this adapter:

* a node restart invalidates every saved configuration, surfaced as one typed `tokenRejected` instead of
  a retry loop (`../CONTRACT.md` §2)
* a handoff pointing anywhere but loopback is refused as `nonLoopbackTarget`, because the transport is
  clear HTTP and the token is a bearer secret

```sh
cp config/popopx-bridge.example.json popopx-bridge.json
export PPX_SKILL_CONFIG="$PWD/popopx-bridge.json"
export PPX_CONSOLE_TOKEN="paste-the-value-the-node-printed"
```

The example config holds four keys and nothing else: `handoff`, `timeoutMs`, `allowLockdown`,
`logRefusals`. An unknown key is a `badConfig` failure, because a typo that silently does nothing is a
worse outcome than a refusal. `handoff: ""` means "read `PPX_CONSOLE_TOKEN`".

Precedence: the `handoff` argument, then `handoff` in the config file named by `PPX_SKILL_CONFIG`, then
the environment (`PPX_CONSOLE_TOKEN`, `PPX_CONSOLE_HOST`, `PPX_CONSOLE_PORT`), then the safe default.
The plugin shared secret comes from the `secret` argument or `PPX_BRIDGE_SECRET`. Set `PPX_SKILL_LOG`
to `silent` to drop `info` lines: refusals are still written, because CONTRACT §7 gives them no opt-out.

---

## What goes on the wire

One line, built for you. The host's alias and spelling are resolved first, so `daily` reaches the node
as `briefing`:

```text
::popopx_sys::NODE_CMD::shadow_cos::briefing::{"tone":"terse"}
```

The grammar is `NodeWire.parseCommand` (`Sources/PopopxMacNode/Models/MacNodeModels.swift:106-139`):
the prefix must be at position 0, exactly two `::` separators are consumed so a payload may contain
`::`, `serviceId`, `action` and `payload` must all be non-empty, and `payload` may use
`1024 - (serviceId + action + 2)` grapheme clusters — counted the way Swift counts them, so a CJK
ideograph or an emoji costs one, not the two or four UTF-16 units JavaScript would report
(`MacNodeModels.swift:52,129-131`). `serviceId` must be the exact lowercase `EngineKind` raw value: no
aliases and no case folding survive onto the wire, which is why the adapter canonicalises before it
validates (`TenBusinessEngines.swift:2151-2170`).

The line is only an internal representation. Execution goes to the one route that can actually run an
engine, `POST /api/engine/invoke` with the body `{ kind, action, payload }`, where `payload` must be a
JSON object because the node decodes it as a dictionary
(`LocalWebConsoleServer.swift:3638-3645,3878-3882`). `POST /api/command` is kept for diagnostics only
and is never used here: its engine calls are refused by the node's whitelist gate
(`TenBusinessEngines.swift:2097-2108`) with the literal wording
`Refused: the sender key is not on the paired-device whitelist.`

Concurrency and retries follow the node rather than inventing a second scheduler
(`../CONTRACT.md` §8): one client is cached per node, so one command is in flight per node and a second
concurrent call answers `inFlightLimit` instead of queueing. There is exactly one retry, and only when
the failure proves the request never arrived (a refused connection); a timeout or a lost answer is
reported with `outcomeUnknown` rather than resent, because `chrono_ark seal` and
`creator_paywall_hub grant` are not idempotent.

---

## Services and actions

Every id and every action spelling this package can send. Canonical names are what reaches the node;
`also` lists the aliases the node routes; `as service` lists accepted service-id aliases. The empty
action `""`, which the node treats as a default, is rejected by this bridge.

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

`chrono_ark lock` seals a time-locked vault. It is not a screen lock, and the two have nothing in
common beyond the word.

---

## Refusals, and the lockdown

`phantom_sentinel` is the one service this adapter refuses by default. The node really acts on it:
`lockdown` clears the general pasteboard, unmounts volumes with `diskutil unmount` /
`diskutil unmountDisk` (refusing the boot volume, never `--force`), sleeps the displays with
`/usr/bin/pmset displaysleepnow` and locks the screen with `CGSession -suspend`
(`TenBusinessEngines.swift:5568-5576,5600-5615,5741-5780`). Everything is user-space, and there is no
confirmation, no cooldown, no dry-run and no undo: `lastLockAt` is written and displayed but never read
as a throttle (`:5636-5638,5692`).

Two orderings inside the node are why a plugin has to be the one to say no:

* `invoke()` evaluates the lock trigger **before** it checks whether the engine is switched off, so
  `{"kind":"phantom_sentinel","action":"lock_all"}` to `/api/engine/invoke` locks the machine even with
  the engine disabled (`TenBusinessEngines.swift:2118-2123`, triggers at `MacNodeModels.swift:98`)
* `execute()` reaches the deterministic-lock branch before the paired-device whitelist gate (`:2059-2075`, `:2097`)

So a line whose canonical action is `lockdown`, `lock`, `lock_all`, `sentinel` or `🔒` is refused before
any socket opens, unless the operator sets `allowLockdown: true` **and** supplies a plugin shared secret
of at least 16 characters (`PPX_BRIDGE_SECRET`). The codes are `lockdownDenied` and `secretRequired`,
every refusal is written to the log with the canonical line and the opt-in state, and `status` (alias
`probe`) stays available because it is report-only (`:5678-5710`).

Note the asymmetry, because it is the part a host most often misreads: `sentinel` and `lockdown` are
legitimate *service* aliases, while `lockdown`, `lock`, `lock_all`, `sentinel` and `🔒` are blocked
*actions* of that service. `phantom_sentinel status` runs; `lockdown lockdown` does not.

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
| `badConfig` | the file named by `PPX_SKILL_CONFIG` is unreadable or carries an unknown key | no |

---

## Manual run against a live node

Start the node, copy the console URL it prints, then run these from the package directory. Each step
names what a correct answer looks like, so a failure is a fact about the node rather than a mystery.

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

Step 2 must answer `ok: true` with `action: "status"`, the canonical spelling. Step 3 must answer
`lockdownDenied` with a `blocked canonical actions` detail and no HTTP request in sight; the node's own
log shows nothing. Step 4 must answer `zero_trust_warroom` with `assign`. If step 2 returns
`tokenRejected`, the node restarted and minted a new token: paste a fresh handoff, that is the design,
not a bug.

---

## What this package does not do

* it opens no port, adds no transport and creates no authority; `127.0.0.1:18920` is the only endpoint,
  and there is no WebSocket on it. The chat daemon's control socket on `127.0.0.1:5225` is unauthenticated
  by design and the node itself is its client, so this package never connects there (`../CONTRACT.md` §1)
* it never writes a token to disk, never logs one, and never puts one in a committed file
* it does not simulate a physical action: if the node would not execute it, this adapter does not offer it
* it does not queue. One in-flight command per node, because one actor already serialises the engines
* it does not claim silent delivery: `NODE_CMD` is not yet a signal kind on iOS, so a node command
  renders as a visible bubble and the node records `iosSignalGap` on the console event
  (`MacNodePopopxBridge.swift:2200-2214`)
* it does not read the render queue as an excuse for a delayed lock: that gate is never on the lockdown
  path (`TenBusinessEngines.swift:63-69`)

---

## Layout

| path | role |
| --- | --- |
| `src/index.ts` | `run()`, the typed output union, the per-node client cache |
| `src/handlers.ts` | host arguments to canonical line, config resolution, the policy call |
| `src/log.ts` | one-line JSON records, token scrubbing, refusal writing |
| `SKILL.md` | the host-facing card: inputs, services, actions, the lockdown disclosure |
| `config/popopx-bridge.example.json` | copy-it template, four keys, no secret |
| `test/skill.test.ts` | the suite, against a fake `fetch` with no node involved |

---

## Troubleshooting

| symptom | read this |
| --- | --- |
| `tokenRejected` on every call | the node restarted; the token dies with the process, paste a fresh handoff |
| `nonLoopbackTarget` | the handoff is not a loopback console URL; `https` is refused too, the console is plain HTTP on loopback |
| `badResponse` with HTTP 404 on invoke | something else answers that port; the node's console is the only thing this bridge speaks to |
| `payloadBudget` on a payload that looks short | the budget is graphemes, and `serviceId` plus `action` are charged against it; use a canonical id and a canonical action |
| `malformedCommand` naming a payload | the route decodes `payload` as a dictionary, so it must be a JSON object, not an array, a bare string or a number |
| `inFlightLimit` | a previous call is still running on that node; await it |
| a refusal you did not expect | grep the log for `"event":"refusal"`; every refusal records its code, the line and the opt-in state |
| nothing in the log | `PPX_SKILL_LOG=silent` drops `info` lines only; refusals are always written |

---

## Sources this package is measured from

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

## License

AGPL-3.0-only, like the node itself. Commercial terms: `../../LICENSE-COMMERCIAL.md`.

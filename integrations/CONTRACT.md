# Ecosystem bridge contract · 生态桥接契约

[English](CONTRACT.md) · [简体中文](CONTRACT.zh-CN.md)

This file is the **only** specification for `integrations/shared`,
`integrations/linger-skill` and `integrations/openclaw-skill`. It describes a bridge that
*reuses what the node already runs*; it does not add a port, a transport or an authority.

Every claim below cites the Swift source it was measured from. The Swift tree is the
producer: if this file and `Sources/` disagree, `Sources/` is right and this file is a bug.

---

## 1 · Transports, and the one port

| Direction | Mechanism | Real endpoint | Source |
| --- | --- | --- | --- |
| bridge → node | HTTP `POST`, JSON, identity encoding | `http://127.0.0.1:18920/api/engine/invoke` | `Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift:3638-3645` |
| bridge → node | HTTP `POST` (diagnostics only, see §6) | `http://127.0.0.1:18920/api/command` | `LocalWebConsoleServer.swift:3647-3654` |
| node → bridge | Server-Sent Events, one long-lived response | `GET /api/events?t=<token>` | `LocalWebConsoleServer.swift:3686-3700` |
| node → anyone | Outbound webhook with HMAC signature, **off by default** | whatever `sentinel.webhookURL` is set to | `Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:5795-5831` |

The listener binds loopback only and refuses to serve otherwise
(`LocalWebConsoleServer.swift:3244,3267-3276,3410-3418,3428-3435`; `NodeWire.consoleHost`,
`NodeWire.consolePort` at `Sources/PopopxMacNode/Models/MacNodeModels.swift:58,89`). The port is
fixed with no fallback: a bind failure is an error, never a different port
(`LocalWebConsoleServer.swift:3256,3292-3298`).

**There is no WebSocket endpoint on `18920`.** The only `ws://` in this system is the chat
daemon's control socket on `127.0.0.1:5225`, which is unauthenticated by design and to which the
node itself is the client (`MacNodeModels.swift:60-67`;
`Sources/PopopxMacNode/Core/MacNodePopopxBridge.swift:323,940,1712-1741`). A bridge plugin must
not connect there: it would be an unauthenticated second session that cannot reach the paired
conversation. Request/response plus SSE is the pair this contract uses.

## 2 · Authentication

The console token is 24 `SecRandomCopyBytes` bytes, base64url without padding, generated once per
launch and **deliberately never persisted** — `LocalWebConsoleServer.swift:3224-3226,3249` and
`MacNodeModels.swift:3064-3071`. It is accepted in the `X-PPX-Token` header or the `t` query
parameter, compared in a timing-safe way (`LocalWebConsoleServer.swift:3704-3711`;
`MacNodeModels.swift:92,95,3098-3103`), and a missing or wrong value is `401` with a plain-language
body (`LocalWebConsoleServer.swift:83`).

Handoff used by these plugins (choice 甲): the operator pastes the tokenised console URL, or sets
`PPX_CONSOLE_TOKEN`. The URL is printed by `--headless` and offered by the menu-bar "Copy console
URL" action, which writes it to the pasteboard (`Sources/PopopxMacNodeApp/PopopxMacNodeApp.swift:486-493,537-541`).
Because the token dies with the process, **a node restart invalidates every plugin configuration**;
`consoleClient` surfaces that as one typed error (`tokenRejected`) rather than a retry loop.

## 3 · Command grammar

Canonical form, one space-separated line, no wrapping:

```text
::popopx_sys::NODE_CMD::<serviceId>::<action>::<payload>
```

* prefix `::popopx_sys::NODE_CMD::` (`MacNodeModels.swift:40`, segment count `:44`)
* splitting consumes exactly **two** `::` separators; everything after the second one stays verbatim,
  so a payload may contain `::` (`MacNodeModels.swift:113-139`)
* `serviceId` and `action` must be non-empty; **`payload` must be non-empty too**
* `payload` budget: `payload.count <= NodeWire.maxSignalPayloadCharacters - (serviceId.count + action.count + 2)`,
  where the ceiling is `1_024` and the two leading segments are charged against it
  (`MacNodeModels.swift:52,129-131`)
* payload is raw JSON text. No base64, no percent-encoding. A payload that is not valid JSON is not
  an error: the node keeps it as a string (`MacNodePopopxBridge.swift:375-380`, `MacNodeModels.swift:1136`)

The node has **two** parsers and they do not agree, which is why this contract names one:

| Parser | Where it runs | Marker position | Empty payload | Unknown serviceId |
| --- | --- | --- | --- | --- |
| `NodeWire.parseCommand` — "the one and only parser" (`MacNodeModels.swift:106`) | local console injection | prefix | rejected | rejected |
| `SBCommandCodec.parse` | inbound SMP chat | anywhere in the line (`MacNodePopopxBridge.swift:656-658`) | accepted (`:667`) | accepted, then refused downstream (`TenBusinessEngines.swift:2077-2091`) |

Bridges implement the strict column. Aliases from `engine(for:)` (`TenBusinessEngines.swift:2151-2170`)
are canonicalised **before** validation, so `warroom` reaches `zero_trust_warroom` while remaining
invalid as a raw wire id. Actions are matched case-insensitively with spaces folded to `_`
(`TenBusinessEngines.swift:2172-2175`).

Machine-readable vectors live in `shared/test/fixtures/wire-vectors.json`. They are consumed by the
TypeScript tests **and** by `Tests/PopopxMacNodeTests/MacNodeContractTests.swift`, so the two
runtimes are graded on the same corpus. Do not copy vectors into prose.

## 4 · The ten services

`serviceId` is `EngineKind.rawValue` (`MacNodeModels.swift:1207-1217`). Accepted aliases
(`TenBusinessEngines.swift:2151-2170`):

| serviceId | aliases | name |
| --- | --- | --- |
| `shadow_cos` | `cos`, `chief_of_staff` | Chief of Staff briefing |
| `zero_trust_warroom` | `warroom`, `zero_trust`, `gop_watermark` | War room attribution |
| `zerotrace_studio` | `studio`, `zero_trace` | Metadata sanitising studio |
| `solo_autopilot` | `solo`, `autopilot` | Solo video pipeline |
| `edge_compute_mesh` | `mesh`, `edge_mesh`, `compute_mesh` | Edge compute sharing |
| `morning_tv` | `tv`, `morning` | Morning broadcast |
| `phantom_sentinel` | `sentinel`, `lockdown` | Deterministic lockdown |
| `chrono_ark` | `ark`, `time_lock` | Time-locked vault |
| `health_sentinel` | `health` | Health read and audio |
| `creator_paywall_hub` | `paywall`, `creator` | Entitlement verification |

## 5 · Action table

Transcribed from the single routing table that both `execute` and `invoke` share
(`TenBusinessEngines.swift:2199-2328`). `∅` means an empty action string; the bridge must send the
canonical name, and the listed aliases are what the node also accepts.

| serviceId | canonical actions | also accepted |
| --- | --- | --- |
| `shadow_cos` | `briefing` · `negotiation_prompt` | `∅`,`brief`,`run`,`daily`,`daily_brief`,`generate` / `negotiation`,`tactics`,`prompt` |
| `zero_trust_warroom` | `assign` · `embed` · `trace` · `registry` | `register`,`queue_assign` / `mark`,`distribute` / `extract`,`identify`,`decode` / `status` |
| `zerotrace_studio` | `process` · `strip` · `anchor` · `shred` | `∅`,`run`,`ingest`,`sanitize`,`sanitise` / `clean`,`metadata` / `briefing_clip`,`broadcast` / `destroy` |
| `solo_autopilot` | `run` · `script` | `∅`,`generate`,`video`,`clip` / `copy` |
| `edge_compute_mesh` | `status` · `offer` · `poll` · `enable` · `settle` | `∅`,`summary` / `accept`,`execute`,`run` / `drain` / `sharing` |
| `morning_tv` | `broadcast` · `digest` · `scheduled` · `schedule` | `∅`,`run`,`tv` / `headlines`,`feeds` / `fire`,`on_time` / `next` |
| `phantom_sentinel` | `status` (report-only) | `probe`. **`lockdown` and its aliases are denied by the bridge — see §7** |
| `chrono_ark` | `seal` · `list` · `unseal` · `heartbeat` · `check` · `reveal` | `lock`,`store` / `∅`,`vaults`,`status` / `open`,`recover` / `ping`,`alive` / `watch`,`release_check` / `dir`,`folder` |
| `health_sentinel` | `read` · `binaural` | `∅`,`report`,`parse`,`interpret` / `tone`,`sleep`,`wav` |
| `creator_paywall_hub` | `verify` · `grant` · `claim` · `status` | `∅`,`ticket`,`admit` / `deliver`,`drop`,`distribute` / `red_packet`,`redpacket` / `ledger` |

Every engine's `default:` arm returns `unsupported(kind, action, allowed)` with the headline
`未知动作 · unknown action “…” for …` and `metrics.unknownAction = true`
(`TenBusinessEngines.swift:2188-2196`).

## 6 · What the console cannot do — and the refusal wording

`POST /api/command` wraps bare text into the canonical prefix (`LocalWebConsoleServer.swift:3653-3654`)
and submits it as a **local** command with `senderPublicKey: "local-console"` and
`authenticated: false` (`MacNodeModels.swift:115-116`; `PopopxMacNodeApp.swift:361-375,402-404`).
`execute` then refuses it at its second gate (`TenBusinessEngines.swift:2097-2108`):

```text
Refused: the sender key is not on the paired-device whitelist.
```

So the literal `NODE_CMD` string is **not** an HTTP-triggerable execution path, even though the
grammar is real. Execution for a bridge goes through `POST /api/engine/invoke`, whose body is
`{ kind, action, payload }` (`LocalWebConsoleServer.swift:3878-3882`) and which is synchronous JSON,
not a stream. The bridge parses the canonical line (§3), then maps it onto `invoke`; `/api/command`
stays available only for reading the node's own parse verdicts, and is disabled by default.

Other refusals worth matching in a plugin:

| Condition | Wording | Source |
| --- | --- | --- |
| unknown engine id | `Unknown service identifier “…”. Known ids: …` | `TenBusinessEngines.swift:2086-2090` |
| engine switched off | `引擎已关闭 · … is switched off.` / `Nothing was executed.` | `:2177-2186` |
| malformed line (SMP path) | `NODE_CMD 段数不足或 serviceId/action 为空` — logged locally, **nothing is replied on the wire** | `MacNodePopopxBridge.swift:2165-2174` |
| bad token | `401` + `Missing or wrong console token. …` | `LocalWebConsoleServer.swift:83` |
| wrong method | `405` + `Allow` | `:3661-3671,3742-3744` |
| body > 8 MiB | `413`; missing `Content-Length` → `411` | `:3163,4083-4088` |

## 7 · `phantom_sentinel`, and why the bridge denies it

The lockdown really acts. `lockdown` clears the pasteboard with
`NSPasteboard.general.clearContents()` (`TenBusinessEngines.swift:5568-5576`), probes volumes with
`diskutil info -all -plist` and unmounts them with `diskutil unmount` / `diskutil unmountDisk`
(refusing the boot volume, never `--force`, `:5741-5780`), sleeps the displays with
`/usr/bin/pmset displaysleepnow` (`:5605-5607`) and locks the screen with `CGSession -suspend`
(`:5610-5615`). All of it is user-space: no `sudo`, no `pkexec`, no daemon
(`:5600-5615`). Defaults: clipboard/lock/sleep on, `unmountPaths = []`, webhook empty
(`MacNodeModels.swift:1494-1501`). There is **no** confirmation, cooldown, dry-run or undo —
`lastLockAt` is written and displayed but never read as a throttle
(`TenBusinessEngines.swift:5636-5638,5692`).

Two orderings in the node make this dangerous from HTTP, and the bridge compensates rather than
silently fixing the node:

1. `execute()` evaluates the deterministic-lock branch (`:2059-2075`) **before** the paired-device
   gate (`:2097`). That ordering is deliberate and documented — 🔒 from the owner's phone must land
   mid-render — but it means a local console injection can lock the machine if the engine switch is on.
2. `invoke()` evaluates the lock trigger (`:2118-2122`) **before** `document.isEnabled(kind)`
   (`:2123`) and never consults `authenticated` at all. So
   `{"kind":"phantom_sentinel","action":"lock_all"}` to `/api/engine/invoke` locks the machine even
   with the engine switched off. Triggers are `["🔒","LOCK_ALL","lock_all"]`
   (`MacNodeModels.swift:98`), compared lowercased.

Empty actions are *not* a hole over HTTP: the route rejects an empty action before `invoke` sees it
(`LocalWebConsoleServer.swift:3644`), even though `invoke` itself treats `""` as a lock.

Bridge-side policy, enforced in `shared/src/wireCommand.ts` and both plugins:

* any action canonicalising into `lockdown`/`lock`/`lock_all`/`sentinel`/`🔒` is refused before any
  network call, unless `allowLockdown: true` **and** a plugin shared secret is presented;
* the only `phantom_sentinel` action allowed by default is `status`/`probe`, which is report-only
  (`TenBusinessEngines.swift:5678-5710`);
* a refusal is recorded in the plugin's own log so an operator can see it happened;
* `CONTRACT` states the node-side ordering as an open risk instead of describing the bridge as
  hardening.

## 8 · Serialisation

Do not build a second lock. One actor owns all ten engines so that the SMP entry point and the
console button path share a single scheduler (`TenBusinessEngines.swift:7-9,1917`), and the app
routes commands through one task (`PopopxMacNodeApp.swift:165-171`). Commands fan out to subscribers
through `AsyncStream(bufferingPolicy: .bufferingNewest(64))`
(`MacNodePopopxBridge.swift:1309-1324`). A plugin therefore keeps at most one in-flight
`engine/invoke` per node, with one retry, and lets the actor do the rest. The heavy/light render gate
(`TenBusinessEngines.swift:63-69`) is never on the lockdown path, so a bridge must not present
render-queue depth as a reason a lock was delayed.

## 9 · Replies, and the known iOS gap

There is no acknowledgement kind. The node's reply to a remote command is an ordinary chat card:
`✅`/`⚠️` + engine name + headline, body truncated to 1 800 characters
(`MacNodeModels.swift:1196-1200`; `MacNodePopopxBridge.swift:2476-2512`), with at-least-once
re-queue on failure (`:2471-2475,2518-2541`). `NodeWire.signalMarker` is declared but never used
outbound. `NODE_CMD` is not yet a `PopopxCommerceSignalKind` on iOS, so a node command renders as a
visible bubble; the node records that per command as a **console event** field
`iosSignalGap` (`MacNodePopopxBridge.swift:2200-2214`, notice text at `:982-985`) — it is not part
of a `POST /api/engine/invoke` response, and the event carries `payloadHash` rather than the payload
(`:2205`). A bridge must not claim silent delivery.

## 10 · Out of scope, on purpose

* no new listening socket, no `18925`, no localhost webhook in front of the kill switch;
* no `ws://5225` reuse (§1) and no `ws` dependency of any kind — these plugins run on Node built-ins
  (`fetch`, `http`, `test`), with `typescript` as the only devDependency;
* no credential file, no token on disk, nothing world-readable;
* no simulation of a physical action: if the node does not execute it, the plugin does not offer it;
* no claim that a Linger- or OpenClaw-shaped host was used to verify this. Neither host exists in
  these three repositories, so the acceptance bar is: shared corpus passes in both runtimes, `tsc`
  strict build passes, and the manual script in each plugin README against a live node.

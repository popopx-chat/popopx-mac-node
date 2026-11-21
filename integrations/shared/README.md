# Shared bridge kernel · `@popopx/node-bridge`

Language: [English](README.md) · [Chinese](README.zh-CN.md) · contract: [English](../CONTRACT.md) · [Chinese](../CONTRACT.zh-CN.md) · node: [../../README.md](../../README.md)

The kernel both plugins import: the wire-grammar parser, the console client, and the SSE reader. It is
the only place the rules of `integrations/CONTRACT.md` exist as code, which is why the plugins import
from the barrel and nowhere else — a plugin cannot skip the policy check by reaching into a module
file, because nothing else is exported to it.

Zero runtime dependencies, `node:` builtins only, loopback only, port 18920 only.

---

## What this is

Four modules behind one entry point:

| Module | Exports | Role |
| --- | --- | --- |
| `wireCommand.ts` | `parseWireLine`, `renderWireLine`, `assertSendable`, `ROUTES`, `SERVICE_IDS` | grammar, canonicalisation, policy |
| `consoleClient.ts` | `resolveTarget`, `ConsoleClient`, `ROUTE` | one HTTP client against the console |
| `eventStream.ts` | `EventStream`, `splitFrames`, `decodeFrame`, `EVENT_CHANNELS` | the SSE reader |
| `errors.ts` | `BridgeError`, `BridgeErrorCode`, `isRetryable` | one error shape for all three |

`NodeBridge` wires them together in one constructor call so that no plugin re-implements target
resolution and no plugin can widen the lockdown rule without naming `allowLockdown` and a secret.

```ts
import { NodeBridge } from "@popopx/node-bridge";

const bridge = new NodeBridge({ handoff: process.argv[2] ?? "" });
const outcome = await bridge.run("::popopx_sys::NODE_CMD::shadow_cos::briefing::{}");
console.log(outcome.line, outcome.result?.ok);
```

## The handoff

`resolveTarget` accepts exactly two shapes and refuses everything else:

| Input | Result |
| --- | --- |
| `http://127.0.0.1:18920/?t=<token>` | host, port and token read from the URL the node printed |
| `<token>` | the bare token, with host and port taken from `PPX_CONSOLE_HOST` / `PPX_CONSOLE_PORT` |

The env fallback exists for the systemd and launchd units, which must not repeat the token in a
command line. Empty input with an empty `PPX_CONSOLE_TOKEN` is `tokenRejected` before any socket.

Refusals that happen here, before the first request:

- a non-loopback host, or an `https://` console → `nonLoopbackTarget`;
- a `PPX_CONSOLE_HOST` outside loopback, or a `PPX_CONSOLE_PORT` that is not a real port → same code;
- a URL with no `?t=` and no `PPX_CONSOLE_TOKEN` → `tokenRejected`.

The reason is not tidiness: the token is a bearer secret carried in clear HTTP, so a typo that pointed
at a routable address would ship it off the machine.

## The wire grammar

A command line is the prefix, the service id, the action, and the payload joined by `::` — four
segments, nothing else:

```
::popopx_sys::NODE_CMD::chrono_ark::seal::{"note":"ledger"}
```

`parseWireLine` does the work a plugin must not duplicate:

1. the prefix must be exactly `COMMAND_PREFIX` at offset zero;
2. the service id goes through `normaliseServiceId`, which accepts the aliases the node itself
   accepts and then must name one of `SERVICE_IDS`;
3. the action goes through `normaliseAction` and must be a canonical action that service offers;
4. the payload must be a JSON object, and its grapheme count must fit the budget below.

The budget is measured in grapheme clusters, the same unit Swift uses for `String.count` on the node:
`MAX_SIGNAL_PAYLOAD_CHARACTERS` is 1024 for the whole line, so a command gets
`1024 - serviceId - action - 2`. `Intl.Segmenter` is what makes the two sides agree on a string with
combining marks or an emoji in it.

## Services, and the one denied action

`ROUTES` is generated from one specification table and is the only source of what a plugin may send:

| Service | Canonical actions | Spellings | Denied |
| --- | --- | --- | --- |
| `shadow_cos` | `briefing`, `negotiation_prompt` | 10 | |
| `zero_trust_warroom` | `assign`, `embed`, `registry`, `trace` | 12 | |
| `zerotrace_studio` | `anchor`, `process`, `shred`, `strip` | 13 | |
| `solo_autopilot` | `run`, `script` | 6 | |
| `edge_compute_mesh` | `enable`, `offer`, `poll`, `settle`, `status` | 11 | |
| `morning_tv` | `broadcast`, `digest`, `schedule`, `scheduled` | 11 | |
| `phantom_sentinel` | `status` | 7 | `lockdown` |
| `chrono_ark` | `check`, `heartbeat`, `list`, `reveal`, `seal`, `unseal` | 18 | |
| `health_sentinel` | `binaural`, `read` | 8 | |
| `creator_paywall_hub` | `claim`, `grant`, `status`, `verify` | 12 | |

Ten services, 35 node arms, 108 accepted spellings here and 117 in the node's own `switch`. The nine
extra node spellings are the arms that reach `unsupported` when the action is empty; the bridge never
accepts an empty action, so it refuses them earlier and with a name.

`phantom_sentinel lockdown` is the only denial, because it is the only action that physically acts on
the machine: it clears the pasteboard, unmounts volumes, puts the display to sleep and suspends the
session, and it does so with no confirmation, no cooldown and no undo. `assertSendable` refuses it
before a socket exists unless the caller passes `allowLockdown: true` **and** a `secret` of at least 16
characters (`PPX_BRIDGE_SECRET`). Read CONTRACT section 7 before turning it on.

## Calling the console

| Method | Request | Notes |
| --- | --- | --- |
| `health()` | `GET /api/health` | the console's own liveness |
| `snapshot()` | `GET /api/snapshot` | the reconcile point after any event stream ends |
| `invoke(command)` | `POST /api/engine/invoke` | one command, one answer |
| `runLine(line)` | parse, then `invoke` | returns the parse result even when nothing was sent |
| `invokeWithRetry(command)` | `POST` with the retry rule below | the only retry the contract allows |
| `events(signal)` | `GET /api/events` | SSE; see the next section |

Every request carries `X-PPX-Token` and `Accept: application/json`, and a POST adds
`Content-Type: application/json`; the fetch is `redirect: "manual"` behind an `AbortSignal.timeout`, so
a redirect is never followed and a stalled call cannot hang the plugin. There is no cookie, no session
and no "localhost is special": every `/api/` route requires the bearer, `/api/health` included.
`tokenFingerprint` reports length and last four characters and nothing more, and it is what a log line
may contain.

## Errors, and when a retry is allowed

`BridgeErrorCode` splits in three groups: transport (`tokenRejected`, `methodNotAllowed`,
`lengthRequired`, `payloadTooLarge`, `nodeUnreachable`, `nodeBusy`, `badResponse`), grammar, decided
before any socket (`malformedCommand`, `unknownService`, `emptyAction`, `payloadBudget`), and policy
(`lockdownDenied`, `secretRequired`, `nonLoopbackTarget`, `inFlightLimit`).

`isRetryable` returns true only for `nodeUnreachable` and `nodeBusy`, and that is not a licence: a
retry additionally requires `mayHaveExecuted === false`, and only a refused connection proves that.
Anything later — a timeout, a reset, a truncated body — leaves the outcome unknown, and
`chrono_ark seal` and `creator_paywall_hub grant` are not idempotent. The node never replays a command
for you, so an unclear outcome is something to reconcile against `snapshot()`, not something to fire
twice.

## Watching events

The console pushes one SSE channel, `/api/events`, with nine named events (`install`, `pairing`,
`engine`, `bridge`, `result`, `mesh`, `sentinel`, `settings`, `system`). Frames carry `event:` and
`data:` only: there is no `id:` field and no replay, so a stream that ends mid-work must be reconciled
with `snapshot()` rather than resumed. The node ends a stream on purpose once 64 events have queued;
that is why `EventStream` takes `maxReconnects` and defaults a one-shot command to one pass.

## The fixture and the drift gates

`test/fixtures/service-table.json` is generated, never hand-edited:

```sh
npm run export:table
```

Three gates read it, which is what keeps the TypeScript and the Swift honest with each other:

| Gate | Compares |
| --- | --- |
| `test/serviceTable.test.ts` | the fixture against `ROUTES` as it is imported right now |
| `IntegrationsContractTests.testTheBridgeRoutingTableMatchesTheNodesDispatchSwitch` | the routing table against `dispatch` in `TenBusinessEngines.swift`, re-derived from source |
| `IntegrationsContractTests.testTheSharedCorpusGradesTheNodesOwnParser` | the fixture's accept and reject vectors against `NodeWire.parseCommand` |

Change an engine and the fixture goes stale; leave the fixture stale and two gates fail. That is the
point: the drift has to be caught by a command, not by a reader.

## Layout and scripts

```
shared/
  src/{wireCommand,consoleClient,eventStream,errors,index}.ts
  scripts/exportServiceTable.mjs
  test/{wireCommand,consoleClient,eventStream,serviceTable}.test.ts
  test/fixtures/service-table.json
```

| Script | Does |
| --- | --- |
| `npm run build` | `tsc -p tsconfig.json` into `dist/` |
| `npm run typecheck` | the same compile with `--noEmit` |
| `npm run export:table` | regenerates the fixture from `ROUTES` |
| `npm test` | build, then `node --test` over `dist/test` |

## License

AGPL-3.0-only, the same as the node. Commercial terms are in `LICENSE-COMMERCIAL.md` at the repository
root.

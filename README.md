<div align="center">

# POPOPX Mac Node

**Connect Everything.**

*Connect Freely · Communicate Privately · Collaborate Intelligently*

**Privacy-First Intelligent Connection Platform** — this repository is its on-device edge compute and privacy execution node.

> POPOPX does not merely provide connection tools — it builds an open ecosystem where people, AI, agents, devices, and services connect securely and collaborate freely.

**Turn your own Mac into the local compute and deterministic-execution host for the 10 "Discover" businesses of the POPOPX iOS client — zero cloud, no account, no telemetry, end-to-end encrypted.**

[![Apple Silicon Native](https://img.shields.io/badge/Apple%20Silicon-native-A272E1?style=for-the-badge&logo=apple&logoColor=white)](LICENSE)
[![Zero-ID SMP E2EE](https://img.shields.io/badge/zero--ID-SMP%20%2F%20XFTP%20E2EE-00C2A8?style=for-the-badge)](LICENSE)
[![AGPL-3.0 + Commercial](https://img.shields.io/badge/open%20core-AGPL--3.0%20%2B%20commercial-FF8A3D?style=for-the-badge)](LICENSE-COMMERCIAL.md)
[![iOS Companion](https://img.shields.io/badge/iOS-companion%20%28Discover%20tab%29-111827?style=for-the-badge&logo=ios&logoColor=white)](LICENSE)

[![Release](https://img.shields.io/github/v/release/popopx-chat/popopx-mac-node?include_prereleases&label=release&style=flat-square)](https://github.com/popopx-chat/popopx-mac-node/releases)
![Release workflow](https://img.shields.io/github/actions/workflow/status/popopx-chat/popopx-mac-node/release.yml?branch=main&label=release%20build&style=flat-square)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-555?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square)
![Dependencies](https://img.shields.io/badge/third--party%20deps-0-brightgreen?style=flat-square)

**English** | [简体中文](./README.zh-CN.md)

</div>

---

## What this is

POPOPX Mac Node is a native menu-bar host app for macOS 14+. It runs the **local compute + deterministic physical execution** layer on hardware you own: Ollama (tiered Qwen3.8), LTX-2.5 MLX video rendering, FFmpeg frequency-domain watermarking and metadata destruction, Vision/CoreImage analysis, CryptoKit keys and cryptographic time locks, plus a set of physical probes (`sysctl`, `diskutil`, mounted volumes, smart-home webhooks).

Commands for the 10 Discover businesses arrive from the iOS client over **your own popopx-chat queue** (SMP/XFTP, end-to-end encrypted); rendered `.mp4` files, result cards and audio go back into the matching service thread. **Not one step needs our server.**

---

## Install in one minute

1. Grab **`POPOPX-Mac-Node-Universal.dmg`** and **`POPOPX-Mac-Node-Universal.dmg.sha256`** from [Releases](https://github.com/popopx-chat/popopx-mac-node/releases) — both files, same folder.
2. Verify what you downloaded, with both files side by side:

   ```sh
   shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
   # expected: POPOPX-Mac-Node-Universal.dmg: OK
   ```

3. Mount it and drag **POPOPX Mac Node** into `Applications`.
4. Builds published here are ad-hoc signed (no Apple notarization). If Gatekeeper objects on first launch:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
   ```

5. Launch. The app **quietly lives in the menu bar** (`LSUIElement`, no Dock tile) and opens the local wizard at **http://127.0.0.1:18920** in your default browser.
6. Wizard step 1: hit **“Deploy local AI engines automatically”** — the node profiles your chip / unified memory / SSD, pulls the Qwen3.8 quantisation that fits your memory tier, initialises the `ltx2` workspace, and streams the terminal log to the page live.
7. Wizard step 2: a **`PPXNODE1-…`** end-to-end encrypted pairing QR code appears.
8. **iOS funnel**: open the POPOPX app → bottom **“Discover”** tab → **“Mac Node pairing”** → scan. The web page flips to “✅ encrypted tunnel to your iPhone established”.
9. Wizard step 3: per-engine switches, idle compute sharing, physical-sentinel volumes/webhooks, Chrono Ark heartbeat period — turn on what you actually use. This is the screen where Discover stops being a demo and starts being your hardware.

### The chat daemon (`popopx-chat`)

Wizard step 2 and the SMP bridge need the chat daemon on `PATH`; the ten engines themselves do not. The
node probes one executable, `popopx-chat`, and has no fallback: an upstream build would answer a version
line here and then fail every command afterwards, so it is not probed at all. Install it yourself, and
check the download before you run it:

```sh
curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh
echo "5a8d7c4572efed20fc545ea4ce256fd61cd5becee7cb82d0e86be9973d7d07f1  popopx-install.sh" | shasum -a 256 -c
# expected: popopx-install.sh: OK
bash popopx-install.sh
```

The digest is the one this repository measured for `master/install.sh` on 2026-11-21. `master` is a
mutable branch, so a mismatch means upstream edited the script: take it again from a release you can
attribute, or compile it from source, instead of running the difference. The installer uses no sudo and
writes `~/.local/bin/popopx-chat`; if that directory is not on your `PATH`, wizard step 1 keeps reporting
the daemon as missing.

### Build from source

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node

swift build                 # compile check
swift test                  # unit tests

swift build -c release      # optional: a standalone release binary first
                            #   -> .build/release/PopopxMacNodeApp
                            # single arch only:
                            #   swift build -c release --arch arm64

bash Scripts/build_dmg.sh   # one command -> distributable Universal DMG + sha256
                            # (it runs the release build itself)
# outputs ->  dist/POPOPX-Mac-Node-Universal.dmg
#            dist/POPOPX-Mac-Node-Universal.dmg.sha256

# repackage without recompiling:
bash Scripts/build_dmg.sh --skip-build --output dist --version 1.0.2 --build 3
```

`Scripts/build_dmg.sh` needs no Xcode project: it assembles the `.app` bundle, generates `Info.plist`, renders the brand icon with the binary it just built, ad-hoc signs, packs with `hdiutil`, and finally **audits the artifacts for leaked developer machine paths** — a leak fails the release. Flags: `--output <dir>`, `--version <x.y.z>`, `--build <n>` (CFBundleVersion on its own counter), `--single-arch <arm64|x86_64>`, `--skip-build`, `--no-sign`, `--no-strip`.

---

## Architecture: the zero-cloud boundary

The rule at the top of the diagram is the whole point of this project: **there is nothing above it**. The chain consists of one QR scan on your iPhone and a set of local processes on your Mac. The web console binds `127.0.0.1` only, rotates a random token on every launch, and is unreachable from the rest of your LAN.

```text
  ========================================================================================
   ZERO CLOUD BOUNDARY | no account | no sign-in | no telemetry | no push
   no cloud storage | no analytics SDK | no crash reporter | no third-party CDN
   the ONLY bytes that ever cross this line are SMP/XFTP end-to-end ciphertext
  ========================================================================================

   +----------------------------------------+
   |[ iOS CLIENT - POPOPX app ]             |
   |Tab "Discover" > "Mac Node"             |
   |                                        |
   |scan the PPXNODE1-... QR once:          |
   |that pins one device keypair            |
   |per iPhone. No account, no              |
   |e-mail, no server-side ID.              |
   +----------------------------------------+
        | NODE_CMD (E2EE)                | cards / .mp4
        |                                |
        v                                ^
   +----------------------------------------+            +--------------------------------+
   |[ MAC NODE GATEWAY - Core/ ]            |            |[ LOCAL WEB CONSOLE ]           |
   |MacNodePopopxBridge.swift               |+---------->|WebConsole/LocalWebConsoleServer|
   |  popopx-chat daemon :5225              |            |.swift   (NWListener, no web fw)|
   |  ::popopx_sys::NODE_CMD::              |            |                                |
   |    {serviceId}::{action}::{payload}    |            |http://127.0.0.1:18920          |
   |  allowedPairedPublicKeys gate          |            |random dynamic token per launch |
   |  -> paired owner devices only          |            |loopback bind only, never LAN   |
   +----------------------------------------+            |dark OLED wizard zh/en/zh-Hant  |
        | enqueue task                   | done + receipt|NSWorkspace opens your browser  |
        |                                |               |on launch: 3-step setup         |
        v                                ^               +--------------------------------+
   +----------------------------------------+
   |[ TEN SOVEREIGN ENGINES ]               |
   |Engines/TenBusinessEngines.swift        |
   |  tiered + serial actor queues          |
   |  concurrency lock, OOM guard           |
   |  Core/HardwareProfilerAndInstaller     |
   |  .swift chooses the model tier         |
   |  from your unified memory size         |
   +----------------------------------------+
        | render / sign / probe          | artefacts
        |                                |
        v                                ^
   +----------------------------------------+
   |[ LOCAL SUBSTRATES - this Mac ]         |
   |  Ollama :11434  Qwen3.8 tiers          |
   |  LTX-2.5 MLX    video + 48kHz          |
   |  FFmpeg         metadata wipe,         |
   |                 GOP/freq watermark     |
   |  Vision + CoreImage  detect/render     |
   |  CryptoKit  keys, timelocks, HMAC      |
   +----------------------------------------+

  ----------------------------------------------------------------------------------------
   EVERYTHING ABOVE THIS LINE RUNS ON HARDWARE YOU PHYSICALLY OWN.
```

| Port | Bind address | Purpose |
| --- | --- | --- |
| `5225` | `127.0.0.1` | local `popopx-chat` WebSocket daemon, `--chat-server-port 5225` |
| `11434` | `127.0.0.1` | local Ollama, if installed |
| `18920` | `127.0.0.1` | zero-config web console, dynamic token |

Data root: `~/Library/Application Support/PopopxMacNode/`

---

## The 10 Sovereign Engines

Engine IDs are part of the wire contract: the `{serviceId}` in `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}` must match this table **character for character** (snake_case). Renaming one is a protocol break.

| Engine ID | Name | What it does | Local substrate | LLM in the loop |
| --- | --- | --- | --- | --- |
| `shadow_cos` | Shadow Chief of Staff | Reads authorised folders, calendars and briefing sources to produce daily action briefs and live negotiation prompt cards. | Ollama (Qwen3.8) | ✅ yes |
| `zero_trust_warroom` | Zero-Trust War Room | Injects unique blind watermarks into video distributed to different cohort queues by FFmpeg frequency-domain / GOP-slice A+B composition; drag in a leaked video and it reverse-decodes the leaker's queue ID in about a second. | FFmpeg (deterministic signal processing) | ❌ no |
| `zerotrace_studio` | Zero-Trace Studio | `ffmpeg -map_metadata -1` destroys EXIF and device fingerprints, local vision and speech models extract the core facts, a synthetic digital-anchor briefing is re-rendered, then the originals are securely shredded. | FFmpeg + Vision/local models + Ollama | ✅ yes |
| `solo_autopilot` | Solo Autopilot | Generates short-video scripts locally from keywords and renders them end-to-end into HD cuts with a native 48 kHz audio track, pushed to the iOS review channel. | Ollama + LTX-2.5 MLX + FFmpeg | ✅ yes |
| `edge_compute_mesh` | Edge Compute Mesh | Watches the bounty queue during idle hours, runs inference/video jobs inside throwaway isolated sandboxes, encrypts results back, wipes the sandbox and banks compute-point receipts. | Ollama / LTX-2.5 MLX (in-sandbox) | ⚙️ task-dependent |
| `morning_tv` | Morning TV | Aggregates your local RSS/finance feeds at your chosen hour into a personalised 5-minute broadcast script and a dynamic video briefing, delivered on schedule. | Ollama + LTX-2.5 MLX | ✅ yes |
| `phantom_sentinel` | Phantom Sentinel | On `🔒` or `LOCK_ALL`: clears the pasteboard, unmounts the configured encrypted volumes and NAS mounts, fires the smart-home/webhook away-from-home lockdown, locks the screen, and returns a deterministic execution receipt. | deterministic state machine + `diskutil` / `NSPasteboard` | ❌ **never touches an LLM** |
| `chrono_ark` | Chrono Ark | A cryptographic time-lock vault plus heartbeat watchdog: on expiry, or after the missed-heartbeat window with no iOS beat, it unseals the pre-set encrypted archive and blessing video and delivers them to the heir's queue. | CryptoKit (time lock / HMAC / key wrapping) | ❌ no |
| `health_sentinel` | Health Sentinel | Parses a dropped lab report fully offline into plain language, and synthesises binaural-beat sleep audio at a requested difference frequency by pure maths (no model, no cloud), handed straight to iOS. | local model + deterministic DSP synthesis | ⚠️ partial: report parsing uses a local model; **audio synthesis is pure maths, no model** |
| `creator_paywall_hub` | Creator Paywall Hub | Works with the invisible-fingerprint engine to ticket-check new members, distribute per-viewer fingerprinted ciphertext, redeem in-group compute red packets and return the receipts. | CryptoKit + invisible fingerprint engine (reuses `zero_trust_warroom`) | ❌ no |

Three boundaries worth calling out separately:

- **`phantom_sentinel` is a deterministic state machine.** A lock-down is never "interpreted", "rewritten" or delayed by a model. `🔒`/`LOCK_ALL` in, physical action out, receipt back. Handing a physical security action to a probability model is not acceptable.
- **`zero_trust_warroom` and `creator_paywall_hub` are signal processing plus cryptography.** They never read content semantics — so semantics never leave the machine.
- **All 10 engines are Swift Concurrency actors** with tiered/serial scheduling and a concurrency memory lock: renders never block the main thread or drag the web console down, and two model weight sets never load at once and OOM the box.

---

## Apple Silicon memory tier ladder

On launch, `HardwareProfilerAndInstaller` reads `sysctl` (chip model, CPU core count, physical unified memory, free SSD) and picks a tier **automatically**. Move the app to another Mac and the tier moves with the memory — nothing to reconfigure.

| Unified memory | Typical SoC (M1–M5 Max) | Text model | Video model | Time to first token* | Generation rate* | Resident peak* | Mode |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `< 48 GB` | lower M1/M2 Max and Pro-class parts | smaller Qwen3.8 tier | not rendered locally, routed to Edge Compute Mesh | ~0.6–1.5 s | 25–45 tok/s | ~10–18 GB | lightweight inference |
| `48 GB` | M1 Max / M2 Max 64-core-GPU configs | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.5–3 s | 18–26 tok/s | ~20–26 GB | balanced (48–64 GB) |
| `64 GB` | M3 Max / M4 Max 64 GB configs | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.2–2.5 s | 20–28 tok/s | ~24–30 GB | balanced (48–64 GB) |
| `96 GB` | M2 Ultra / M3 Max 96–128 GB configs | Qwen3.8-27B **Q8_0** | **LTX-2.5 original BF16, full weights** | ~2.5–5 s | 12–18 tok/s | ~40–52 GB | full strength |
| `128 GB` | M3 Max / M4 Max / M5 Max 128 GB configs | Qwen3.8-27B **Q8_0** (room for a second concurrent session) | **LTX-2.5 original BF16, full weights** | ~2–4 s | 12–20 tok/s | ~52–68 GB | full strength |

\* **Every number in those three columns is an estimate, not a lab measurement.** They are back-of-the-envelope figures derived from memory-bandwidth-bound decode of a dense 27B model plus a quantisation-ratio reading of the LTX-2.5 weight footprint. Sustained thermals, chip generation, background load, clip length and the number of concurrent jobs can move real numbers by 2–3×. Treat them as tier-selection intuition, not as a performance promise.

The rules verbatim, as they appear in the product spec:

- `>= 96 GB` → **LTX-2.5 original BF16 full weights + Qwen3.8-27B (Q8_0)**
- `48 GB – 64 GB` → **LTX-2.5 MLX 8-bit quantised + Qwen3.8-27B (Q4_K_M)**
- `< 48 GB` → **lightweight inference mode**, heavy video jobs are surfaced and routed to the Edge Compute Mesh

### Optional model: Inkling-2-Mini

The ladder above is the **default**, and nothing about it changes for a Mac that never pulls anything else. The catalog additionally offers **`Inkling-2-Mini`** as an optional local model, selectable from the menu bar's `Local Model` menu or the console's model panel.

| Unified memory | Admission | What the node does |
| --- | --- | --- |
| `>= 48 GB` | safe alongside other work | runs beside ordinary media and system services |
| `32 GB – 47 GB` | meets the recommendation | loads it; the desktop memory floor gets thin |
| `25 GB – 31 GB` | constrained | loads it, refuses a second heavy local job |
| `<= 24 GB` | memory-swap warning | **refuses the load** rather than risk an OOM hang |

Roughly **20 GB of weights**, about 24 GB resident once the context window is counted, and **32 GB of unified memory is the recommendation**. Selecting the model shows that estimate, the `ollama pull inkling-2-mini` hint and, for a hand-imported GGUF, the `ollama create inkling-2-mini:q4_k_m -f Inkling-2-Mini.Modelfile` instruction.

The tag a local import actually landed under is machine-local, so the reference is overridable without editing the catalog: `config/model_refs.json` (`{"refs": {"inkling-2-mini": "inkling-2-mini:q4_k_m"}}`), or the `POPOPX_OLLAMA_REF_INKLING_2_MINI` environment variable, which wins. A value that is not a plain local reference — no registry host, no path traversal — is dropped and the catalog default is kept.

Selecting a model rewrites the `model` field of the request body and nothing else: Ollama calls still go to `http://127.0.0.1:11434`, the reference never becomes part of the URL, and no model request or telemetry leaves the machine.

---

## Languages and localisation

The node's language list is not its own invention — it is the iOS app's `knownRegions` from `POPOPX.xcodeproj` (17 locales, `Base` excluded because it is an Xcode folder rather than a locale), plus the one entry iOS does not have, **`zh-Hant`**. `system` follows the Mac's per-app display language exactly as the phone follows iOS's, and both ends speak the same BCP-47 tags, so pairing never has to translate a language.

Traditional Chinese is not a second hand-written table: it is **derived** from the page's own Simplified column with Apple's own `CFStringTransform` (`Hans-Hant`), so a string added to one catalog cannot be missing from the other. The single systematic defect that audit found is a glyph choice: for the Simplified character U+542F the transform answers U+5553, a variant form, where the Taiwan standard is U+555F — `TraditionalChinese.fixUps` rewrites that pair, and a test pins it.

| Interface surface | Proof-read copy | Derived copy | Fallback |
| --- | --- | --- | --- |
| web console (`127.0.0.1:18920`) | `zh-Hans`, `en` | `zh-Hant` | the other 15 regions read English |
| menu bar (`PopopxMacNodeApp`) | `zh-Hans`, `en` | `zh-Hant` | the other 15 regions read English |
| engine output (briefs / scripts / copy) | `zh-Hans`, `en` | `zh-Hant` | the chosen language is named in the model prompt |

Fallback is stated, not hidden: the console's `langFallback` notice says out loud that a language has no proof-read catalog and that the page is showing English, instead of pretending the translation exists. The menu bar's log lines, `hub.publish` notifications and `lastError` deliberately keep this project's house style of two scripts on one line ("Chinese / english") regardless of the console language — a log is troubleshooting material, and both scripts on the line beat a half-translated one.

**Where the choice lives**: the language picked in wizard step 3 or in Settings is written once for the whole node, as the `language` field of `config/settings.json`, defaulting to `system`; iOS has no in-app switcher either and reads `Bundle.main.preferredLocalizations`. There is no third-party i18n framework: on the Swift side a `ConsoleLanguage` enum plus one fallback rule (`text(zh:en:)`), on the web side one key table inside the served HTML, and the language dropdown is generated from that enum and injected into the page.

**Adding a language**: ① add a case to `ConsoleLanguage` whose `rawValue` is a tag iOS already ships (`zh-Hant` is the one declared exception, because iOS has no Traditional catalog at all; when iOS gains a region, add it there first); ② add a row for every referenced key in the `I18N` table of `LocalWebConsoleServer` and give it the third language — `testConsoleCatalogCoversEveryReferencedKey` fails the moment a key is missing; ③ add the language to `ConsoleLanguage.curated`, otherwise the page keeps falling back to English. `MacNodeContractTests` guards the locale set on both ends: when iOS gains a region the node has not caught up with, the test goes red instead of the two apps quietly offering different language lists.

---

## Ecosystem bridges

`integrations/` is the supported way to drive these ten engines from somewhere other than the console: a
TypeScript bridge kernel plus two adapters that plug it into an agent host. It adds no port, no daemon and no
third-party runtime dependency — it reuses what this repository already runs, namely the loopback console on
`127.0.0.1:18920` with its per-launch token, and the `::popopx_sys::NODE_CMD::{service}::{action}::{payload}`
signal the node already parses. Both paths into the node are honest about the same fact: the console never
broadcasts or connects out, so an operator hands the token over once.

| Package | Role | Talks to the node through |
| --- | --- | --- |
| `integrations/shared` | the bridge kernel: wire parser, console client, event reader, policy gate | `POST /api/engine/invoke` |
| `integrations/linger-skill` | adapter for a Linger-style agent host | the kernel, never a socket |
| `integrations/openclaw-skill` | adapter for an OpenClaw-style plugin host | the kernel, never a socket |

The kernel refuses one action before it opens a socket: `phantom_sentinel` / `lockdown`. On the node that call
really happens — the pasteboard is cleared, external volumes are unmounted, the display sleeps and the session
locks — with no confirmation, no cooldown and no undo, and it is reachable before the engine's own on/off
switch is even consulted. Sending it is therefore opt-in twice over: `allowLockdown: true` **and** a
`PPX_BRIDGE_SECRET` of at least 16 characters, and a refusal is written to the plugin log so an operator can
see that it happened. The same rule covers retries: a command is resent only when the node demonstrably never
received it, because `chrono_ark` `seal` and `creator_paywall_hub` `grant` are not idempotent.

```sh
cd integrations/shared && npm install && npm test
swift test --filter IntegrationsContractTests
```

The [bridge contract](integrations/CONTRACT.md) (and its [Chinese counterpart](integrations/CONTRACT.zh-CN.md))
pins every claim above to a `file:line` in this repository, records where the bridge is deliberately
stricter than the node, and states what a plugin may never assume. `MacNodeContractTests` and
`IntegrationsContractTests` grade the TypeScript parser and the Swift parser against the same corpus, so a
drift between the two runtimes fails a test instead of surprising a running node.

---

## Security self-audit guide

Every check below is copy-pasteable. You do not have to believe a word we wrote — **the red lines are machine-verifiable.**

### 1 · the console is loopback-only

```sh
lsof -nP -iTCP:18920 -sTCP:LISTEN
```

Expect: only `127.0.0.1:18920 (LISTEN)`. **Never `*:18920`, `TCP:*`, or a LAN interface address.**

```sh
sudo netstat -anp tcp | grep 18920
```

Expect: every line starts with `127.0.0.1`; no external listener and no ESTABLISHED socket pointing off-box.

### 2 · per-process egress audit

```sh
lsof -nP -p "$(pgrep -x PopopxMacNodeApp)" -i
lsof -nP -p "$(pgrep -x popopx-chat)" -i
```

Expect: under those PIDs you should only see `127.0.0.1` listeners and loopback ESTABLISHED pairs (5225 / 11434 / 18920). Any non-loopback address should make you suspicious — this is your own packet-level evidence, not our claim.

### 3 · artifact signature and Gatekeeper

```sh
codesign -dv --verbose=4 "/Applications/POPOPX Mac Node.app"
codesign --verify --deep --strict --verbose=2 "/Applications/POPOPX Mac Node.app"
spctl -a -vv "/Applications/POPOPX Mac Node.app"
```

In `codesign -dv --verbose=4` you should see:

```
Identifier=chat.popopx.node
Format=app bundle with Mach-O thin (arm64)      # or fat, for the universal build
flags=0x2(adhoc)                                 # published here ad-hoc signed, not notarized
```

`spctl -a -vv` **will return `rejected` for an ad-hoc signature**. That is the expected result, not a vulnerability — it means "this package is not backed by an Apple-issued developer certificate", not "this package was tampered with". The second command is the one that checks tampering, and it must **pass silently**.

### 4 · where your data lands, and where keys do not

```sh
ls -la ~/Library/Application\ Support/PopopxMacNode/
```

This is the node's only data root (engine workspaces, logs, SSE console state, the `engines/ltx2/` weight workspace). It is not inside an iCloud-synced location and not in any shared container.

```sh
LC_ALL=C grep -a -R -- "$HOME" ~/Library/Application\ Support/PopopxMacNode/ 2>/dev/null | wc -l
```

Seeing *your own* absolute path here is normal: that is your local configuration, your data, and it never leaves. What must be audited is *someone else's* path — see check 5.

**Keys**: the paired-device public-key whitelist, the time-lock key wrappers and the fingerprint blinding parameters live in the macOS **login keychain** (search `popopx` in `security` / Keychain Access) and in **CryptoKit-generated key files** under `PopopxMacNode/`. They do **not** appear in logs, do not appear in SMP signalling, and there is no upstream channel that could carry them out. To spot-check: `grep -a -R -i 'privatekey\|secret' ~/Library/Application\ Support/PopopxMacNode/ | wc -l` should come back close to zero, because keys are not in plaintext logs.

### 5 · no developer paths inside the shipped binary

```sh
LC_ALL=C grep -a -o '/Users/[A-Za-z0-9._-]*' \
  "/Applications/POPOPX Mac Node.app/Contents/MacOS/PopopxMacNodeApp" | sort -u
```

Expect: **empty output.** Swift `#filePath` / `#file` / `#function` debug strings and un-stripped DWARF are the usual leak vectors. `Scripts/build_dmg.sh` treats any occurrence of the build machine's `$HOME` inside an artifact as a **hard failure** that blocks the release (step 6 of 8), and CI runs that gate on every published build.

### 6 · verify what you downloaded

```sh
shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
```

The sidecar contains only `<64 hex>  <relative filename>` (two spaces, no directory), so it has to be run next to the `.dmg` — and note that it can never encode somebody else's absolute path.

### 7 · revoking a paired device

1. Menu-bar icon → **Paired devices** → select the device → **Revoke**. Its public key leaves `allowedPairedPublicKeys` immediately, and any straggling command from that device is dropped at the gateway layer.
2. For the nuclear option: quit the node from the menu bar first, then remove the pairing and key records (file names containing `peer` / `pair` / `keys`) under the data root. On relaunch the QR code carries a brand-new key set.
3. To clean the login keychain as well: search `popopx` in Keychain Access and delete those items.

### 8 · when Gatekeeper blocks first launch

```sh
xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
```

Run this only **after** check 6 passed. Verify first, unquarantine second — in the other order you are only comforting yourself.

---

## Open Core licensing

One licence covers the whole chain. This repository, the relay servers and the client are three AGPL-3.0 repositories carrying byte-identical licence text:

```sh
# with the three repositories checked out side by side
shasum -a 256 LICENSE ../popopxmq/LICENSE ../popopx-chat/LICENSE
# 8486a10c4393cee1c25392769ddd3b2d6c242d6ec7928e1414efff7dfb2f07ef  — three times
```

| Scope | License | What that means |
| --- | --- | --- |
| every source file here — the 10 engines, the SMP gateway, the web console, the GOP/frequency-domain watermark (`ENGGopWatermark`), the compute-point ledger, `Scripts/build_dmg.sh` | **[AGPL-3.0-only](LICENSE)** | run, study, modify and redistribute freely — with the network-service copyleft of §13, which also binds anyone hosting a modified node for other people |
| the SMP/XFTP **relay server** source and the BBS+ (BLS12-381) blind-signature credential code | **AGPL-3.0-only** | [popopxmq](https://github.com/popopx-chat/popopxmq) · its [NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) states: “No further restrictions are imposed on recipients of this work (AGPL-3.0 sections 10 and 12)”. Self-host the fleet, and self-host the credential issuer, if you want |
| the companion iOS client source | **AGPL-3.0-only** | [popopx-chat](https://github.com/popopx-chat/popopx-chat) |
| the artwork this fork drew | AGPL-3.0-only, **or CC0-1.0 at your option** | [ASSETS_LICENSE-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/ASSETS_LICENSE-POPOPX.md) — files byte-identical to upstream’s stay SimpleX Chat Ltd’s, and we cannot release them |
| the officially hosted relay network and its bandwidth, the official release/update channel, enterprise support with an SLA | **service terms — not code** | [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) |
| `POPOPX`, `POPOPX Chat`, the wordmark, the logo and the icons derived from it, `popopx.chat` | **not licensed at all** — a trade mark sits outside any copyright grant | [TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md): fork it, ship it, keep our drawings — then rename and re-logo |

In one line: **every byte of code on this chain is AGPL-3.0 and self-hostable; the commercial track buys operation and endorsement, never source.**

- Full AGPL-3.0 text: [`LICENSE`](LICENSE)
- The bilingual boundary, the §13 explainer, the support tiers — and the 2026-11-21 correction that stopped describing the relay servers, the blind signature and the watermarking as closed products: [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)
- **No hidden core.** The credential algorithm is in popopxmq (`src/Popopx/Messaging/Crypto/BBS.hs`, `Crypto/Entitlement.hs`, specified in `protocol/crypto-registry.md`); the watermark and its extraction are here (`ENGGopWatermark`, `TenBusinessEngines.swift:987-1198`). Nothing in the paid scope is a code gate — the paid scope is data centres, on-call, channels and paperwork.
- **The marks are unregistered**, and the policy conditions nothing about the code: “no sentence here adds a condition on running, studying, modifying or redistributing the source code.” Say “a fork of POPOPX Mac Node”; do not name your build POPOPX.

---

## Roadmap

- **v1.0 (now)** — menu-bar host, `NWListener` three-step wizard, SMP pairing with a public-key whitelist, hardware probe + one-click engine deployment, all 10 engines executing locally, Universal DMG + sha256 + fully automated GitHub Actions releases.
- **v1.1** — per-engine usage dashboard on the local console only (real token/s and watts per tier, so the estimates on this page can be replaced with your own measurements), task timelines with failure causes surfaced back in iOS, human proof-read catalogs for the remaining 15 regions (`zh-Hant` already ships in v1.0, derived from Simplified).
- **v1.2** — hardened `edge_compute_mesh` isolation (dedicated throwaway containers, per-task keys, automatic post-run sandbox shredding), a local compute-points earnings ledger with exportable statements.
- **v1.3** — multi-heir sharded custody and a wider time-lock primitive matrix for `chrono_ark`; more supported lab-report layouts for `health_sentinel` (still completely offline).
- **v1.4** — Developer ID signing and Apple notarization pipelines, Mac App Store evaluation, additional `LTX-2.5` resolution/duration tiers.
- **What we will never do** — telemetry, cloud accounts, uploading any local material to our servers, or letting an LLM decide what `phantom_sentinel` does.

---

## Contributing

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node
swift build && swift test
bash Scripts/build_dmg.sh --output dist --version 0.0.0-dev
```

The non-negotiables:

1. **Zero third-party dependencies.** Apple frameworks only (`Network`, `CryptoKit`, `CoreImage`, `SwiftUI`, `AppKit`, `Vision`, `ServiceManagement`). Open an issue before challenging this — the zero-dependency property is an audit selling point, not a stylistic preference.
2. **No placeholders.** No `// TODO`, no ellipsis stubs, no "rest of the code here". Code, the embedded web console, documentation and CI must all be 100% runnable.
3. **Never hardcode a developer machine path.** Use `FileManager.default.homeDirectoryForCurrentUser` and `~/Library/Application Support/PopopxMacNode/`. Self-audit check 5 and the privacy gate inside `build_dmg.sh` stop violators at packaging time.
4. **Concurrency means Swift Concurrency.** `actor`, `async`/`await` and `AsyncStream` manage the task queues and local `Process` handling; never push a render onto the main thread or the web console.
5. Run `swift build && swift test` before opening a PR; CI repeats both on `macos-15` (Apple Silicon) and produces a real DMG.

Releasing:

```sh
git tag v1.0.2 && git push origin v1.0.2   # triggers .github/workflows/release.yml
```

---

<div align="center">

**If this hands you back control of your own data, a Star is the cheapest way to say so.**

[![Release](https://img.shields.io/github/v/release/popopx-chat/popopx-mac-node?include_prereleases&label=latest&style=for-the-badge)](https://github.com/popopx-chat/popopx-mac-node/releases)
![Stars](https://img.shields.io/github/stars/popopx-chat/popopx-mac-node?style=for-the-badge&logo=github&label=stars)
![Forks](https://img.shields.io/github/forks/popopx-chat/popopx-mac-node?style=for-the-badge&label=forks)
![Issues](https://img.shields.io/github/issues/popopx-chat/popopx-mac-node?style=for-the-badge)

[Releases](https://github.com/popopx-chat/popopx-mac-node/releases) · [LICENSE](LICENSE) · [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) · [Report a bug](https://github.com/popopx-chat/popopx-mac-node/issues/new)

[English](./README.md) | [简体中文](./README.zh-CN.md)

---

**Star counts move; red lines don't.** This page deliberately ships no invented download counts, no fake stars, and no "measured in the lab" performance tables — every figure above is labelled an estimate.

Copyright © 2026 POPOPX Chat · Code across all three repositories: [AGPL-3.0](LICENSE) · Hosted relays, official channels and brand: [commercial terms](LICENSE-COMMERCIAL.md)

</div>

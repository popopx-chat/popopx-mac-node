<div align="center">

# POPOPX Mac Node

**把你自己那台 Mac 变成 POPOPX iOS 客户端「发现」10 大业务的本地算力与确定性执行中枢 —— 零云端、无账号、无遥测、端到端加密。**

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

</div>

---

## 这是什么 · What this is

**中文** — POPOPX Mac Node 是一个常驻 macOS 菜单栏的原生宿主应用。它在你自己的机器上跑起 **本地算力 + 确定性物理执行** 这一层：调度 Ollama（Qwen3.8 分档）、LTX-2.5 MLX 视频渲染、FFmpeg 频域水印与元数据粉碎、Vision/CoreImage 识别、CryptoKit 密钥与时间锁，以及一组物理探针（`sysctl`、`diskutil`、挂载卷、智能家居 Webhook）。iOS 客户端「发现」里的 10 个业务，指令通过 **你自己的 popopx-chat 队列**（SMP/XFTP，端到端加密）进来，成片、卡片和音频再原路推回对应服务号对话。**没有任何一环需要经过我们的服务器。**

**English** — POPOPX Mac Node is a native menu-bar host app for macOS 14+. It runs the **local compute + deterministic physical execution** layer on hardware you own: Ollama (tiered Qwen3.8), LTX-2.5 MLX video rendering, FFmpeg frequency-domain watermarking and metadata destruction, Vision/CoreImage analysis, CryptoKit keys and cryptographic time locks, plus physical probes (`sysctl`, `diskutil`, mounted volumes, smart-home webhooks). Commands for the 10 Discover businesses arrive from the iOS client over **your own popopx-chat queue** (SMP/XFTP, end-to-end encrypted); rendered `.mp4` files, result cards and audio go back into the matching service thread. **Not one step needs our server.**

---

## 一分钟极速安装 · Install in one minute

**中文**

1. 到 [Releases](https://github.com/popopx-chat/popopx-mac-node/releases) 下载 **`POPOPX-Mac-Node-Universal.dmg`** 和 **`POPOPX-Mac-Node-Universal.dmg.sha256`**（同一个目录里，两个文件都要下）。
2. 校验完整性 —— 两个文件放在同一目录下执行：

   ```sh
   shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
   # 期望输出: POPOPX-Mac-Node-Universal.dmg: OK
   ```

3. 双击挂载，把 **POPOPX Mac Node** 拖进 `Applications`。
4. 本仓库发布的构建是 Ad-hoc 签名（未做 Apple 公证），首次启动被 Gatekeeper 拦下时执行一次：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
   ```

5. 启动。应用**静默驻留菜单栏**（`LSUIElement`，不占 Dock），并自动在你的默认浏览器打开本地向导 **http://127.0.0.1:18920** 。
6. 向导第 1 步：点 **“一键自动部署本地 AI 引擎”** —— 节点自动体检芯片/统一内存/SSD，按内存档位拉取适配的 Qwen3.8 量化权重、初始化 `ltx2` 工作区，日志实时流回网页。
7. 向导第 2 步：屏幕出现 **`PPXNODE1-…`** 端到端加密配对二维码。
8. **iOS 端漏斗**：打开 POPOPX App → 底部 **「发现」** Tab → **「Mac Node 配对」** → 扫一扫。网页端会立刻跳到 “✅ 已成功与 iPhone 建立加密隧道”。
9. 向导第 3 步：10 大业务独立开关、空闲算力共享、物理哨兵挂载卷/Webhook、时光方舟心跳周期 —— 全部按需开启。配完这一屏，iPhone 上的「发现」页从"演示态"变成"你家的算力真的在跑"。

**English**

1. Grab **`POPOPX-Mac-Node-Universal.dmg`** and **`POPOPX-Mac-Node-Universal.dmg.sha256`** from [Releases](https://github.com/popopx-chat/popopx-mac-node/releases) — both files, same folder.
2. Verify what you downloaded:

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
9. Wizard step 3: per-engine switches, idle compute sharing, physical-sentinel volumes/webhooks, Chrono Ark heartbeat period. This is the screen where Discover stops being a demo and starts being your hardware.

### 从源码构建 · Build from source

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node

swift build                 # 编译校验 / compile check
swift test                  # 单元测试 / unit tests

swift build -c release      # 可选：先单独出 release 二进制 / optional standalone release
                            #   -> .build/release/PopopxMacNodeApp
                            # 想只要单架构 / single arch only:
                            #   swift build -c release --arch arm64

bash Scripts/build_dmg.sh   # 一键产出可分发的 Universal DMG + sha256（内部会自己跑 release 编译）
# 产物 / outputs ->  dist/POPOPX-Mac-Node-Universal.dmg
#                    dist/POPOPX-Mac-Node-Universal.dmg.sha256

# 只重打包、不重编译 / repackage without recompiling:
bash Scripts/build_dmg.sh --skip-build --output dist --version 1.0.0
```

`Scripts/build_dmg.sh` 不依赖任何 Xcode 工程文件：它自己组装 `.app` Bundle、生成 `Info.plist`、用刚编译出来的二进制渲染品牌图标、Ad-hoc 签名、`hdiutil` 打包，最后**审计产物内有没有泄漏开发机绝对路径**——泄漏就直接让发布失败。常用参数：`--output <dir>`、`--version <x.y.z>`、`--single-arch <arm64|x86_64>`、`--skip-build`、`--no-sign`、`--no-strip`。

`Scripts/build_dmg.sh` needs no Xcode project: it assembles the `.app` bundle, generates `Info.plist`, renders the brand icon with the binary it just built, ad-hoc signs, packs with `hdiutil`, and finally **audits the artifacts for leaked developer machine paths** — a leak fails the release. Flags: `--output <dir>`, `--version <x.y.z>`, `--single-arch <arm64|x86_64>`, `--skip-build`, `--no-sign`, `--no-strip`.

---

## 端侧隐私与算力闭环架构 · Architecture

**中文** — 顶部的横线就是本项目的存在理由：**横线以上什么都没有**。整条链路只有你 iPhone 上的一次扫码，和你的 Mac 上的一堆本地进程。网页控制台只绑定 `127.0.0.1`，每次启动换一个随机 Token，局域网里其他设备连端口都摸不到。

**English** — The rule at the top is the whole point of this project: **there is nothing above it**. The chain consists of one QR scan on your iPhone and a set of local processes on your Mac. The web console binds `127.0.0.1` only, rotates a random token on every launch, and is unreachable from the rest of your LAN.

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
   |MacNodeSimplexBridge.swift              |+---------->|WebConsole/LocalWebConsoleServer|
   |  popopx-chat daemon :5225              |            |.swift   (NWListener, no web fw)|
   |  ::popopx_sys::NODE_CMD::              |            |                                |
   |    {serviceId}::{action}::{payload}    |            |http://127.0.0.1:18920          |
   |  allowedPairedPublicKeys gate          |            |random dynamic token per launch |
   |  -> paired owner devices only          |            |loopback bind only, never LAN   |
   +----------------------------------------+            |dark OLED wizard  zh / en       |
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

| 端口 / Port | 绑定地址 / Bind | 用途 / Purpose |
| --- | --- | --- |
| `5225` | `127.0.0.1` | 本地 `popopx-chat`（上游 `simplex-chat`）WebSocket 守护进程 / local chat daemon, `--chat-server-port 5225` |
| `11434` | `127.0.0.1` | 本地 Ollama（若已安装）/ local Ollama, if present |
| `18920` | `127.0.0.1` | 零配置网页控制台，动态 Token / zero-config web console, dynamic token |

数据目录 / data root: `~/Library/Application Support/PopopxMacNode/`

---

## 十大主权引擎 · The 10 Sovereign Engines

**中文** — 引擎 ID 是协议字段的一部分：iOS 端下发的 `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}` 里的 `{serviceId}` 必须与下表**逐字符一致**（snake_case）。改名等于换协议。

**English** — Engine IDs are part of the wire contract: the `{serviceId}` in `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}` must match this table **character for character** (snake_case). Renaming one is a protocol break.

| 引擎 ID / Engine ID | 名称 / Name | 做什么 / What it does | 本地基座 / Local substrate | 大模型参与 / LLM in the loop |
| --- | --- | --- | --- | --- |
| `shadow_cos` | 影子首席幕僚 · Shadow Chief of Staff | 读取授权目录、日程摘要与简报源，产出每日行动简报与实时谈判提词卡片 / reads authorised folders, calendars and briefings to produce daily action briefs and live negotiation prompts | Ollama (Qwen3.8) | ✅ 是 / yes |
| `zero_trust_warroom` | 零信任微团队暗室 · Zero-Trust War Room | 对分发给不同群队列的视频做 FFmpeg 频域/GOP 切片 A/B 组合盲化水印注入；拖入外网泄露视频可 1 秒逆向解出泄露者队列编号 / embeds unique binary series per cohort via frequency-domain / GOP-slice A+B blinding, and reverse-decodes the leaker's queue ID in ~1 s | FFmpeg（确定性信号处理）/ deterministic signal processing | ❌ 否 / no |
| `zerotrace_studio` | 零痕视觉脱敏工作台 · Zero-Trace Visual Studio | `ffmpeg -map_metadata -1` 彻底抹除 EXIF/设备指纹，本地视觉与语音模型提取核心事实，重构虚拟数字播报员简报视频，随后安全粉碎原始素材 / strips all EXIF/device fingerprints, extracts facts with local vision+speech models, re-renders a synthetic anchor briefing, then securely shreds the originals | FFmpeg + Vision/本地模型 + Ollama | ✅ 是 / yes |
| `solo_autopilot` | 一人公司全自动流水线 · Solo Autopilot | 按关键词生成本地短视频脚本并直接渲染带 48kHz 原生音轨的高清成片，推送到 iOS 审核频道 / keyword-driven scripts rendered end-to-end into 48 kHz audio video, pushed to the iOS review channel | Ollama + LTX-2.5 MLX + FFmpeg | ✅ 是 / yes |
| `edge_compute_mesh` | 边缘算力共享节点 · Edge Compute Mesh | 空闲时段监听悬赏队列，在独立临时沙箱内隔离执行推理/视频任务，加密回传结果后自动清理沙箱并累计算力点回执 / serves the idle-time bounty queue inside throwaway sandboxes, encrypts results back, wipes the sandbox, banks compute points | Ollama / LTX-2.5 MLX（沙箱内 / in-sandbox） | ⚙️ 依任务而定 / task-dependent |
| `morning_tv` | 私人定制早间电视台 · Morning TV | 每天清晨按设定时点聚合本地 RSS/财经源，生成 5 分钟专属播报脚本与动态视频简报并定时推送 / aggregates your local RSS/finance feeds at your chosen hour into a 5-minute personalised broadcast briefing video | Ollama + LTX-2.5 MLX | ✅ 是 / yes |
| `phantom_sentinel` | 物理空间哨兵与一键闭锁 · Phantom Sentinel | 收到 `🔒` 或 `LOCK_ALL`：清空系统剪贴板、卸载指定加密外置卷/NAS 挂载点、触发智能家居/Webhook 离家闭锁、锁定屏幕，并回传确定性执行回执 / on `🔒`/`LOCK_ALL`: clears the pasteboard, unmounts the configured volumes/webhooks the house lock, locks the screen, returns a deterministic receipt | 确定性状态机 + `diskutil`/`NSPasteboard` · deterministic state machine | ❌ **不经过任何大模型 / never touches an LLM** |
| `chrono_ark` | 时光数字方舟 · Chrono Ark | 本地密码学时间锁保险箱 + 心跳守护；时间锁到期或超过失联周期未收到 iOS 心跳时，自动解封预设加密档案与祝福视频并投递给指定继承人队列 / a cryptographic time-lock vault plus heartbeat watchdog: on expiry, or after a missed heartbeat window, unseals the archive and delivers it to the heir's queue | CryptoKit（时间锁/HMAC/密钥封装）· CryptoKit | ❌ 否 / no |
| `health_sentinel` | 零泄露私人健康哨兵 · Health Sentinel | 本地离线解析拖入的体检报告生成通俗解读；内置纯数学波形合成器生成指定差频的双耳节拍助眠 WAV/MP3 直传 iOS / parses dropped health reports fully offline into plain language, and synthesises binaural-beat sleep audio by pure maths (no model, no cloud) | 本地模型 + 纯数学波形合成 / local model + deterministic DSP | ⚠️ 部分：报告解读走本地模型；**音频合成为纯数学，不经模型** |
| `creator_paywall_hub` | 大 V 防盗版付费频道自动化管家 · Creator Paywall Hub | 配合隐形指纹引擎完成新成员入群验票、分发带独立指纹的加密内容、核销群内算力红包并回传回执 / ticket-checks new members, distributes per-viewer fingerprinted ciphertext, redeems in-group compute red packets | CryptoKit + 隐形指纹引擎（复用 `zero_trust_warroom`） | ❌ 否 / no |

三条值得单独强调的边界 / three boundaries worth calling out:

- **`phantom_sentinel` 是确定性状态机。** 闭锁指令不会被任何模型"理解"、"改写"或"延迟"：`🔒`/`LOCK_ALL` 进，物理动作出，回执回传。安全动作交给概率模型是不可接受的。
  **`phantom_sentinel` is a deterministic state machine.** A lock-down is never "interpreted", "rewritten" or delayed by a model. Physical security actions must not depend on a probability distribution.
- **`zero_trust_warroom` / `creator_paywall_hub` 全程是信号处理与密码学**，不看内容语义，也就不会把内容语义交给任何第三方。
  **`zero_trust_warroom` / `creator_paywall_hub` are signal processing plus cryptography.** They never read semantics — so semantics never leave.
- **10 个引擎全部走 Swift Concurrency actor 队列**，串行/分级调度并带并发内存锁：渲染任务不会把主线程或网页控制台拖死，也不会同时塞进两份模型权重把机器 OOM。
  **All 10 engines are Swift Concurrency actors** with tiered/serial scheduling and a memory-lock guard: renders never block the main thread or the console, and two model weights never load at once and OOM the box.

---

## Apple Silicon 内存算力自适应阶梯 · Memory tier ladder

节点启动时由 `HardwareProfilerAndInstaller` 读取 `sysctl`（芯片型号、CPU 核心数、物理统一内存、可用 SSD），**自动**选定下面这一档；换机器不用重配，档位随内存走。

On launch, `HardwareProfilerAndInstaller` reads `sysctl` (chip, core count, physical unified memory, free SSD) and picks a tier **for you**. Move the app to another Mac and the tier moves with the memory.

| 统一内存 / Unified memory | 典型芯片 / Typical SoC (M1–M5 Max) | 文本模型 / LLM | 视频模型 / Video | 首 token 延迟* / Time to first token* | 生成吞吐* / Generation* | 常驻内存峰值* / Resident peak* | 模式 / Mode |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `< 48 GB` | M1/M2 Max 低配、Pro 系列 / lower Max & Pro parts | Qwen3.8 小档 / smaller Qwen3.8 tier | 不本地渲染，路由至边缘算力共享节点 / not rendered locally, routed to Edge Compute Mesh | ~0.6–1.5 s | 25–45 tok/s | ~10–18 GB | 轻量推理模式 · **lightweight** |
| `48 GB` | M1 Max / M2 Max 64C-GPU 档 / 48 GB configs | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.5–3 s | 18–26 tok/s | ~20–26 GB | 48–64 GB 档 · **balanced** |
| `64 GB` | M3 Max / M4 Max 64 GB 档 / 64 GB configs | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.2–2.5 s | 20–28 tok/s | ~24–30 GB | 48–64 GB 档 · **balanced** |
| `96 GB` | M2 Ultra / M3 Max 96–128 GB 档 / 96 GB+ configs | Qwen3.8-27B **Q8_0** | **LTX-2.5 原版 BF16 满血** / original BF16, full weight | ~2.5–5 s | 12–18 tok/s | ~40–52 GB | 满血档 · **full strength** |
| `128 GB` | M3 Max / M4 Max / M5 Max 128 GB 档 / 128 GB configs | Qwen3.8-27B **Q8_0**（可并行为双会话 / room for a second session） | **LTX-2.5 原版 BF16 满血** / original BF16, full weight | ~2–4 s | 12–20 tok/s | ~52–68 GB | 满血档 · **full strength** |

\* **以上全部是估算值（approximate），不是实验室实测数据。** 数量级依据是"统一内存带宽受限 + 27B 稠密模型的常规 token/秒区间 + LTX-2.5 权重按量化位宽的显存占用比例"推导出来的工程估计；真实数字受散热、机型世代、后台负载、片段长度与并发任务数影响，可能相差 2–3 倍。请把它当成"选档位的直觉"，而不是"性能承诺"。

\* **Every number in those three columns is an estimate, not a lab measurement.** They are back-of-the-envelope figures from memory-bandwidth-bound decode of a dense 27B model plus a quantisation-ratio reading of the LTX-2.5 weights. Sustained thermals, chip generation, background load, clip length and concurrent jobs can move real numbers by 2–3×. Treat them as tier-selection intuition, not as a performance promise.

规则原文（与产品规范一致）/ the rules, verbatim from the spec:

- `>= 96 GB` → **LTX-2.5 原版 BF16 满血权重 + Qwen3.8-27B (Q8_0)**
- `48 GB – 64 GB` → **LTX-2.5 MLX 8-bit 量化版 + Qwen3.8-27B (Q4_K_M)**
- `< 48 GB` → **轻量推理模式**，重型视频任务自动提示路由至「边缘算力共享节点」/ lightweight inference mode, heavy video routed to the edge compute mesh

---

## 语言与本地化 · Languages

**中文**：节点的语言清单不是自己拟的 —— 它等于 iOS 端 `POPOPX.xcodeproj` 的 `knownRegions`（17 个语言，不含 `Base`，那是 Xcode 目录而不是语言），外加一项 iOS 端没有的 **`zh-Hant`**。`system` 跟随 Mac 的本 App 显示语言，与 iPhone 跟随 iOS 显示语言的行为一致；两边都只认这套 BCP-47 代码，配对时不需要翻译语言。繁体不是第二份手写文案，而是用 Apple 自家的 `CFStringTransform`（`Hans-Hant`）从简体中文那一列**派生**出来的，所以它永远不会漏掉某个新增字符串；派生过程中唯一被审计出来的系统性偏差（转换器把「启」写成异体「啓」）在 `TraditionalChinese.fixUps` 里修掉，并由测试锁住。

**English**: The node's language list is not its own invention — it is the iOS app's `knownRegions` (17 locales, `Base` excluded because it is an Xcode folder rather than a locale), plus the one entry iOS does not have, **`zh-Hant`**. `system` follows the Mac's per-app display language exactly as the phone follows iOS's, and both ends speak the same BCP-47 tags, so pairing never has to translate a language. Traditional Chinese is not a second hand-written table: it is **derived** from the page's own Simplified column with Apple's own `CFStringTransform` (`Hans-Hant`), so a string added to one catalog cannot be missing from the other. The single systematic defect the audit found — the converter writing 启 as the variant 啓 — is corrected in `TraditionalChinese.fixUps` and pinned by a test.

| 界面表面 · surface | 校对文案 · proof-read | 派生文案 · derived | 兜底 · fallback |
| --- | --- | --- | --- |
| 网页控制台（`127.0.0.1:18920`）/ web console | `zh-Hans`, `en` | `zh-Hant` | 其余 15 个区域用英文 / the other 15 read English |
| 菜单栏（`PopopxMacNodeApp`）/ menu bar | `zh-Hans`, `en` | `zh-Hant` | 其余 15 个区域用英文 / the other 15 read English |
| 引擎产出（简报 / 脚本 / 文案）/ engine output | `zh-Hans`, `en` | `zh-Hant` | 按所选语言提示本地模型 / the chosen language is named in the model prompt |

兜底不是隐藏起来的偷工：控制台的 `langFallback` 提示会**明说**当前语言还没有校对文案、页面暂以英文显示，而不是假装已经翻译完。菜单栏的日志、`hub.publish` 通知与 `lastError` 一律保持「中文 / english」双语并列的既定文风，不随控制台语言切换 —— 日志是排障材料，两种脚本同时在场比翻对一半更有用。

Fallback is stated, not hidden: the console's `langFallback` notice says out loud that a language has no proof-read catalog and that the page is showing English. The menu bar's log lines, `hub.publish` notifications and `lastError` deliberately stay in this project's bilingual "中文 / english" house style regardless of the console language — a log is troubleshooting material, and both scripts on one line beat a half-translated one.

**语言存在哪 · Where the choice lives**: 控制台第 3 步或设置里的语言写入 `config/settings.json` 的 `language` 字段，整台节点一个值，默认 `system`；iOS 端同样没有应用内开关，它读 `Bundle.main.preferredLocalizations`。没有第三方 i18n 框架：Swift 侧是 `ConsoleLanguage` 枚举加一条回落规则 `text(zh:en:)`，网页侧是 HTML 里的一张键表，语言下拉菜单由该枚举生成注入。/ The choice is stored once for the whole node, as `language` in `config/settings.json`, defaulting to `system`; iOS has no in-app switcher either and reads `Bundle.main.preferredLocalizations`. There is no third-party i18n framework: a `ConsoleLanguage` enum plus one fallback rule (`text(zh:en:)`) in Swift, one key table in the served HTML, and the picker generated from that enum into the page.

**加一门语言 · Adding a language**: ① 在 `ConsoleLanguage` 加一个 case，`rawValue` 必须是 iOS 端 `knownRegions` 里已有的标签（`zh-Hant` 是唯一声明过的例外，因为 iOS 根本没有繁体 catalog），若 iOS 端新增了 region 则先在那边加；② 在 `LocalWebConsoleServer` 的 `I18N` 表里为每个被引用的键补一行 `{ zh:, en: }` 并加上第三种语言，`testConsoleCatalogCoversEveryReferencedKey` 会在缺键时直接失败；③ 把该语言加入 `ConsoleLanguage.curated`，页面才会停止英文兜底。`MacNodeContractTests` 会守住两端语言集合的一致性：iOS 端新增 region 而节点没跟上时，测试会红，而不是两个应用悄悄给出不同的语言列表。/ ① add a case to `ConsoleLanguage` whose `rawValue` is a tag iOS already ships (`zh-Hant` is the one declared exception, because iOS has no Traditional catalog at all; when iOS gains a region, add it there first); ② fill in `{ zh:, en: }` for every referenced key in `LocalWebConsoleServer`'s `I18N` table and add the third language — `testConsoleCatalogCoversEveryReferencedKey` fails the moment a key is missing; ③ add the language to `ConsoleLanguage.curated` so the page stops falling back. The parity tests fail when iOS gains a region the node has not caught up with, instead of the two apps quietly offering different lists.
## 安全自检指南 · Security self-audit guide

下面每一条都可以直接复制粘贴运行 —— 不需要相信我们说的任何一句话，**红线是机器可验证的**。

Every check below is copy-pasteable. You do not have to believe a word we wrote — **the red lines are machine-verifiable.**

### 1 · 控制台只绑回环 / the console is loopback-only

```sh
lsof -nP -iTCP:18920 -sTCP:LISTEN
```

期望 / expect: 只有 `127.0.0.1:18920 (LISTEN)`，**绝不出现 `*:18920`、`TCP:*` 或某个外部网卡地址**。
Only `127.0.0.1:18920 (LISTEN)`. **Never `*:18920`, `TCP:*`, or a LAN address.**

```sh
sudo netstat -anp tcp | grep 18920
```

期望 / expect: 每一行都以 `127.0.0.1` 开头；没有外部监听、也没有指向远端的 ESTABLISHED 连接。
Every line starts with `127.0.0.1`; no external listener and no ESTABLISHED socket pointing off-box.

### 2 · 进程级外连审计 / per-process egress audit

```sh
lsof -nP -p "$(pgrep -x PopopxMacNodeApp)" -i
lsof -nP -p "$(pgrep -x popopx-chat || pgrep -x simplex-chat)" -i
```

期望 / expect: 该进程名下只应出现 `127.0.0.1` 的 LISTEN 与本机回环 ESTABLISHED（5225 / 11434 / 18920）。出现任何非回环地址都应当让你警觉 —— 那是你自己抓包验证的证据，不是我们的声明。
Under those PIDs you should only see loopback listeners and loopback ESTABLISHED pairs (5225 / 11434 / 18920). Any non-loopback address should make you suspicious — this is your evidence, not our claim.

### 3 · 产物签名与 Gatekeeper / artifact signature and Gatekeeper

```sh
codesign -dv --verbose=4 "/Applications/POPOPX Mac Node.app"
codesign --verify --deep --strict --verbose=2 "/Applications/POPOPX Mac Node.app"
spctl -a -vv "/Applications/POPOPX Mac Node.app"
```

`codesign -dv --verbose=4` 里应当看到 / you should see:

```
Identifier=chat.popopx.node
Format=app bundle with Mach-O thin (arm64)      # 或 universal / or fat for the universal build
flags=0x2(adhoc)                                 # 本仓库发布为 Ad-hoc，未公证 / ad-hoc, not notarized
```

`spctl -a -vv` 对 Ad-hoc 签名**会返回 `rejected`**，这是预期结果，不是漏洞 —— 它意味着"这个包不是 Apple 背书的开发者"，而不是"这个包被篡改"。第二行的 `--verify --deep --strict` 才负责后者，它必须**静默通过**。
`spctl -a -vv` **will return `rejected` for an ad-hoc signature**. That is expected, not a vulnerability: it means "not backed by an Apple-issued developer certificate", not "tampered with". The second command checks tampering, and it must pass silently.

### 4 · 数据落点与密钥 / where your data lands, and where keys do not

```sh
ls -la ~/Library/Application\ Support/PopopxMacNode/
```

这是节点唯一的数据根目录（引擎工作区、日志、SSE 控制台状态、`engines/ltx2/` 权重工作区）。它不在 iCloud 同步范围内，也不在任何共享容器里。
This is the node's only data root (engine workspaces, logs, console state, `engines/ltx2/`). It is not in an iCloud-synced location and not in any shared container.

```sh
LC_ALL=C grep -a -R -- "$HOME" ~/Library/Application\ Support/PopopxMacNode/ 2>/dev/null | wc -l
```

这里出现你自己的绝对路径是**正常的**（那是你机器上的配置，属于你的数据，不会外传）。需要被审计的是**别人的**路径 —— 见第 5 条。
Seeing *your own* absolute path here is fine: that is your local configuration, your data, and it never leaves. What must be audited is *someone else's* path — see check 5.

**密钥 / keys:** 配对设备公钥白名单、时间锁密钥封装、指纹盲化参数分别存放在 macOS **登录钥匙串**（`security` / Keychain Access 里搜 `popopx`）与 `PopopxMacNode/` 下由 **CryptoKit 生成的本地密钥文件**中。它们**不会**出现在日志、不会出现在 SMP 信令里、也不会有任何上行通道可以带走它们。想验证：`grep -a -R -i 'privatekey\|secret' ~/Library/Application\ Support/PopopxMacNode/ | wc -l` 应当接近 0（密钥在钥匙串与专用密钥文件里，不在明文日志中）。
**Keys:** the paired-device public-key whitelist, time-lock key wrappers and fingerprint blinding parameters live in the macOS **login keychain** (search `popopx` in Keychain Access) and in **CryptoKit-generated key files** under `PopopxMacNode/`. They never appear in logs, never appear in SMP signalling, and there is no upstream channel that could carry them out. Spot-check with the `grep` above: it should return close to zero, because keys are not in plaintext logs.

### 5 · 二进制里没有开发机绝对路径 / no developer paths inside the shipped binary

```sh
LC_ALL=C grep -a -o '/Users/[A-Za-z0-9._-]*' \
  "/Applications/POPOPX Mac Node.app/Contents/MacOS/PopopxMacNodeApp" | sort -u
```

期望 / expect: **空输出**。Swift 的 `#filePath` / `#file` / `#function` 调试字符串与未剥离的 DWARF 是最常见的泄漏源；本项目的 `Scripts/build_dmg.sh` 在第 6/8 步把"编译机 `$HOME` 前缀出现在产物里"设成**硬失败**，命中即阻断发布。CI 上每一次发布构建都跑过这道门。
**Empty output.** `#filePath` / `#file` / `#function` debug strings and un-stripped DWARF are the usual leak vectors. `Scripts/build_dmg.sh` treats any occurrence of the build machine's `$HOME` inside the artifact as a **hard failure** that blocks the release, and CI runs that gate on every published build.

### 6 · 校验下载物 / verify what you downloaded

```sh
shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
```

`.sha256` 文件里只写 `<64位十六进制>␣␣<相对文件名>`（两个空格、不带任何目录），所以它必须在与 `.dmg` 同一目录下执行，也永远不会指向别人的路径。
The sidecar contains only `<64 hex>  <relative filename>` (two spaces, no directory), so run it next to the `.dmg` — and note it can never encode somebody else's absolute path.

### 7 · 撤销一台已配对设备 / revoking a paired device

1. 菜单栏图标 → **已配对设备 / Paired devices** → 选中设备 → **撤销 / Revoke**。撤销后该机器的公钥立刻从 `allowedPairedPublicKeys` 白名单移除，残留信令会在网关层被丢弃。
   Menu-bar icon → **Paired devices** → select → **Revoke**. The key leaves `allowedPairedPublicKeys` immediately; straggling commands are dropped at the gateway.
2. 想连根拔掉：先停节点（菜单栏 → 退出），再清掉数据根目录下的配对与密钥记录（文件名含 `peer` / `pair` / `keys`），重启后二维码会换一批全新密钥。
   For the nuclear option: quit the node from the menu bar, then remove the pairing/key records (names containing `peer` / `pair` / `keys`) under the data root. On relaunch the QR code carries a brand-new key set.
3. 想连登录钥匙串一起清理：打开「钥匙串访问」搜 `popopx` 删除对应条目。
   To clean the login keychain too: search `popopx` in Keychain Access and delete those items.

### 8 · 被 Gatekeeper 拦住时 / when Gatekeeper blocks first launch

```sh
xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
```

只在你**已经跑过第 6 条的 sha256 校验**之后再执行这一步。先验签，后放行 —— 顺序反了就是自我安慰。
Run this only **after** check 6 passed. Verify first, unquarantine second; in the other order you are just comforting yourself.

---

## Open Core 授权 · Licensing

| | 授权 / License | 你可以做什么 / What you may do |
| --- | --- | --- |
| 本仓库全部源码（引擎、SMP 网关、Web 控制台、`Scripts/build_dmg.sh`） | **[AGPL-3.0](LICENSE)** | 自由运行、研究、修改、再分发 —— 含网络服务场景下的同源开源义务 / run, study, modify, redistribute, with copyleft that also covers network services |
| POPOPX 全球私有 SMP/XFTP 中继集群、盲签算力点结算协议、抗合谋隐形指纹算法 SDK、POPOPX 名称与商标、iOS App Store 伴生分发 | **商业闭源授权** | 见 [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) / see the commercial terms |

一句话：**你机器上跑的东西 100% 开源可审计；跨机器的高可用基建与品牌，是我们卖的东西。**
In one line: **everything executing on your machine is 100% open and auditable; the cross-machine high-availability infrastructure and the brand are what we sell.**

- 完整 AGPL-3.0 正文 / the full AGPL-3.0 text: [`LICENSE`](LICENSE)
- 双语商业条款、AGPL §13 "反白嫖传染条款" 说明、授权档位与商标政策 / bilingual commercial terms, the AGPL §13 network-copyleft explanation, tiers and trademark policy: [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)
- **商标 / Trademark:** AGPL 授权**不包含** POPOPX 名称、标志与域名的使用权。拿走源码改一改自己上线，可以；叫自己 POPOPX，不行。
  The AGPL grant **does not** include rights to the POPOPX name, logo or domains. Fork the code and ship it: fine. Call it POPOPX: not fine.

---

## 路线图 · Roadmap

**中文**

- **v1.0（当前）** — 菜单栏宿主、`NWListener` 本地控制台三步向导、SMP 配对与公钥白名单、硬件体检 + 一键引擎部署、10 大引擎本地执行、Universal DMG + sha256 + GitHub Actions 全自动发布。
- **v1.1** — 引擎级用量仪表盘（每档内存的实际 token/s 与瓦特，把本页的估算值换成你的实测值）、任务时间线与失败原因回传 iOS、其余 15 个区域的人工校对文案（`zh-Hant` 已在 v1.0 由简转繁派生）。
- **v1.2** — `edge_compute_mesh` 沙箱隔离强化（独立临时容器、逐任务密钥、执行后自动粉碎）、算力点收益明细本地账本与可导出报表。
- **v1.3** — `chrono_ark` 多继承人分片托管与更长的时间锁原语矩阵；`health_sentinel` 支持的体检报告版式扩展（仍然完全离线）。
- **v1.4** — Developer ID 签名与 Apple 公证流水线、Mac App Store 评估、更多 `LTX-2.5` 分辨率/时长档位适配。
- **不做的事 / what we will never do** — 遥测、云账号、把任何本地素材上传到我们的服务器、把 `phantom_sentinel` 交给大模型决策。

**English**

- **v1.0 (now)** — menu-bar host, `NWListener` 3-step wizard, SMP pairing with a public-key whitelist, hardware probe + one-click engine deployment, all 10 engines executing locally, Universal DMG + sha256 + fully automated GitHub Actions releases.
- **v1.1** — per-engine telemetry *on the local console only* (real token/s and watts per tier, so the estimates on this page can be replaced with yours), task timelines with failure causes surfaced in iOS, fuller console i18n.
- **v1.2** — hardened `edge_compute_mesh` sandboxes (per-task keys, post-run shredding), a local compute-points ledger with exportable statements.
- **v1.3** — multi-heir sharding and a wider time-lock primitive matrix for `chrono_ark`; more offline lab-report layouts for `health_sentinel`.
- **v1.4** — Developer ID signing and Apple notarization pipelines, Mac App Store evaluation, additional `LTX-2.5` resolution/duration tiers.
- **Never** — telemetry, cloud accounts, uploading your material to our servers, or letting an LLM decide what `phantom_sentinel` does.

---

## 贡献 · Contributing

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node
swift build && swift test
bash Scripts/build_dmg.sh --output dist --version 0.0.0-dev
```

几条硬规矩 / the non-negotiables:

1. **零第三方依赖。** 只用 Apple 框架（`Network`、`CryptoKit`、`CoreImage`、`SwiftUI`、`AppKit`、`Vision`、`ServiceManagement`）。想加依赖请先开 issue 讨论 —— 这个"零依赖"是审计卖点，不是洁癖。
   **Zero third-party dependencies.** Apple frameworks only. The zero-dependency property is an audit selling point, not a stylistic preference — open an issue before challenging it.
2. **禁止占位符。** 不允许 `// TODO`、省略号存根、"其余代码略"。代码、内嵌网页、文档、CI 必须 100% 可运行。
   **No placeholders.** No `// TODO`, no ellipsis stubs, no "rest of the code here". Code, the embedded web console, docs and CI must all be complete.
3. **禁止硬编码开发机绝对路径。** 统一使用 `FileManager.default.homeDirectoryForCurrentUser` 与 `~/Library/Application Support/PopopxMacNode/`。第 5 条自检和 `build_dmg.sh` 会在打包阶段把违反者拦下来。
   **Never hardcode a developer machine path.** Use `FileManager.default.homeDirectoryForCurrentUser`. The privacy gate in `build_dmg.sh` enforces this at packaging time.
4. **并发用 Swift Concurrency。** `actor` / `async` / `await` / `AsyncStream` 管理任务队列与本地 `Process`，不要把渲染压进主线程或网页控制台。
   **Concurrency means Swift Concurrency.** `actor`, `async`/`await`, `AsyncStream` for queues and local `Process` handling; never block the main actor with a render.
5. 提 PR 前跑一遍 `swift build && swift test`，CI 会在 `macos-15` (Apple Silicon) 上再跑一次并真打出 DMG。
   Run `swift build && swift test` locally; CI repeats both on `macos-15` (Apple Silicon) and produces a real DMG.

发布 / releasing:

```sh
git tag v1.0.0 && git push origin v1.0.0   # 触发 .github/workflows/release.yml
```

---

<div align="center">

**如果这个项目让你重新拿回了自己数据的处理权，点个 Star 就是最直接的支持。**
**If this hands you back control of your own data, a Star is the cheapest way to say so.**

[![Release](https://img.shields.io/github/v/release/popopx-chat/popopx-mac-node?include_prereleases&label=latest&style=for-the-badge)](https://github.com/popopx-chat/popopx-mac-node/releases)
![Stars](https://img.shields.io/github/stars/popopx-chat/popopx-mac-node?style=for-the-badge&logo=github&label=stars)
![Forks](https://img.shields.io/github/forks/popopx-chat/popopx-mac-node?style=for-the-badge&label=forks)
![Issues](https://img.shields.io/github/issues/popopx-chat/popopx-mac-node?style=for-the-badge)

[Releases](https://github.com/popopx-chat/popopx-mac-node/releases) · [LICENSE](LICENSE) · [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) · [Report a bug](https://github.com/popopx-chat/popopx-mac-node/issues/new)

---

**Star history 会变，红线不会。** 本页刻意不放伪造的下载量、星标数或"实验室实测性能表" —— 所有性能数字都标了「估算值」。
**Star counts move; red lines don't.** This page deliberately ships no invented download counts, no fake stars, and no "measured in the lab" performance tables — every figure above is labelled an estimate.

Copyright © 2026 POPOPX Chat · Code: [AGPL-3.0](LICENSE) · Brand & relay: [commercial](LICENSE-COMMERCIAL.md)

</div>

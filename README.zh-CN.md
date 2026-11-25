<div align="center">

# POPOPX Mac Node

**把你自己那台 Mac 变成 POPOPX iOS 客户端「发现」10 大业务的本地算力与确定性物理执行中枢 —— 零云端、无账号、无遥测、端到端加密。**

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

[English](./README.md) | **简体中文**

</div>

---

## 这是什么

POPOPX Mac Node 是一个常驻 macOS 菜单栏的原生宿主应用（macOS 14+）。它在你自己的机器上跑起 **本地算力 + 确定性物理执行** 这一层：调度 Ollama（Qwen3.8 分档）、LTX-2.5 MLX 视频渲染、FFmpeg 频域水印与元数据粉碎、Vision/CoreImage 识别、CryptoKit 密钥与密码学时间锁，以及一组物理探针（`sysctl`、`diskutil`、挂载卷、智能家居 Webhook）。

iOS 客户端「发现」里 10 个业务的指令，通过 **你自己的 popopx-chat 队列**（SMP/XFTP，端到端加密）进来；渲染好的 `.mp4` 成片、结果卡片与音频再原路推回对应服务号对话。**没有任何一环需要经过我们的服务器。**

---

## 一分钟极速安装

1. 到 [Releases](https://github.com/popopx-chat/popopx-mac-node/releases) 下载 **`POPOPX-Mac-Node-Universal.dmg`** 和 **`POPOPX-Mac-Node-Universal.dmg.sha256`** —— 两个文件都要下，放在同一个目录。
2. 先校验完整性，再谈安装：

   ```sh
   shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
   # 期望输出：POPOPX-Mac-Node-Universal.dmg: OK
   ```

3. 双击挂载，把 **POPOPX Mac Node** 拖进 `Applications`。
4. 本仓库发布的构建是 Ad-hoc 签名（未做 Apple 公证），首次启动被 Gatekeeper 拦下时执行一次：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
   ```

5. 启动。应用**静默驻留菜单栏**（`LSUIElement`，不占 Dock），并自动在你的默认浏览器打开本地向导 **http://127.0.0.1:18920**。
6. 向导第 1 步：点 **“一键自动部署本地 AI 引擎”** —— 节点自动体检芯片 / 统一内存 / SSD，按内存档位拉取适配的 Qwen3.8 量化权重，初始化 `ltx2` 工作区，安装日志实时流回网页。
7. 向导第 2 步：屏幕出现 **`PPXNODE1-…`** 端到端加密配对二维码。
8. **iOS 端漏斗**：打开 POPOPX App → 底部 **「发现」** Tab → **「Mac Node 配对」** → 扫一扫。网页端会立刻跳到 “✅ 已成功与 iPhone 建立加密隧道”。
9. 向导第 3 步：10 大业务独立开关、空闲算力共享、物理哨兵挂载卷 / Webhook、时光方舟心跳周期 —— 按需开启。配完这一屏，iPhone 上的「发现」页就从“演示态”变成“你家的算力真的在跑”。

### 聊天守护进程（`popopx-chat`）

向导第 2 步与 SMP 桥接需要聊天守护进程在 `PATH` 上；十个引擎本身不需要它。节点只探测一个可执行文件 `popopx-chat`，没有任何回退：上游构建会先答出一行版本号，然后把之后每一条指令都跑失败，所以我们根本不探测它。请自己安装，并在执行之前先校验下载内容：

```sh
curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh
echo "5a8d7c4572efed20fc545ea4ce256fd61cd5becee7cb82d0e86be9973d7d07f1  popopx-install.sh" | shasum -a 256 -c
# 期望：popopx-install.sh: OK
bash popopx-install.sh
```

这条摘要值来自本仓库在 2026-11-21 对 `master/install.sh` 的实测。`master` 是可变分支，摘要不符说明上游改过脚本：请重新取自一个可以归属的发布版本，或者自行编译，而不是把这份差异直接喂给 shell。安装脚本不使用 sudo，写入 `~/.local/bin/popopx-chat`；若该目录不在你的 `PATH` 上，向导第 1 步会持续报告守护进程缺失。

### 从源码构建

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node

swift build                 # 编译校验
swift test                  # 单元测试

swift build -c release      # 可选：先单独出 release 二进制
                            #   -> .build/release/PopopxMacNodeApp
                            # 想只要单架构：
                            #   swift build -c release --arch arm64

bash Scripts/build_dmg.sh   # 一键产出可分发的 Universal DMG + sha256
                            #   （内部会自己跑 release 编译）
# 产物 ->  dist/POPOPX-Mac-Node-Universal.dmg
#          dist/POPOPX-Mac-Node-Universal.dmg.sha256

# 只重打包、不重编译：
bash Scripts/build_dmg.sh --skip-build --output dist --version 1.0.2 --build 3
```

`Scripts/build_dmg.sh` 不依赖任何 Xcode 工程文件：它自己组装 `.app` Bundle、生成 `Info.plist`、用刚编译出来的二进制渲染品牌图标、Ad-hoc 签名、`hdiutil` 打包，最后**审计产物里有没有泄漏开发机绝对路径** —— 泄漏就直接让发布失败。常用参数：`--output <dir>`、`--version <x.y.z>`、`--build <n>`（让 CFBundleVersion 走独立构建号）、`--single-arch <arm64|x86_64>`、`--skip-build`、`--no-sign`、`--no-strip`。

---

## 架构：零云端边界

下面这张图顶部的横线就是本项目的存在理由：**横线以上什么都没有**。整条链路只有你 iPhone 上的一次扫码，和你的 Mac 上的一堆本地进程。网页控制台只绑定 `127.0.0.1`，每次启动换一个随机 Token，局域网里其他设备连端口都摸不到。

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

| 端口 | 绑定地址 | 用途 |
| --- | --- | --- |
| `5225` | `127.0.0.1` | 本地 `popopx-chat` WebSocket 守护进程，`--chat-server-port 5225` |
| `11434` | `127.0.0.1` | 本地 Ollama（若已安装） |
| `18920` | `127.0.0.1` | 零配置网页控制台，动态 Token |

数据根目录：`~/Library/Application Support/PopopxMacNode/`

---

## 十大主权引擎

引擎 ID 是协议字段的一部分：iOS 端下发的 `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}` 里的 `{serviceId}` 必须与下表**逐字符一致**（snake_case）。改名等于换协议。

| 引擎 ID | 名称 | 做什么 | 本地基座 | 大模型参与 |
| --- | --- | --- | --- | --- |
| `shadow_cos` | 影子首席幕僚 | 读取授权目录、日程摘要与简报源，产出每日行动简报与实时谈判提词卡片。 | Ollama（Qwen3.8） | ✅ 是 |
| `zero_trust_warroom` | 零信任微团队暗室 | 对分发给不同群队列的视频做 FFmpeg 频域 / GOP 切片 A+B 组合盲化水印注入，每个队列一组唯一二进制序列；拖入外网泄露视频，约 1 秒逆向解出泄露者的队列编号。 | FFmpeg（确定性信号处理） | ❌ 否 |
| `zerotrace_studio` | 零痕视觉脱敏工作台 | 用 `ffmpeg -map_metadata -1` 彻底抹除 EXIF 与设备指纹，本地视觉与语音模型提取核心事实，重构虚拟数字播报员简报视频，随后安全粉碎原始素材。 | FFmpeg + Vision/本地模型 + Ollama | ✅ 是 |
| `solo_autopilot` | 一人公司全自动流水线 | 按关键词在本地生成短视频脚本，直接渲染成带 48 kHz 原生音轨的高清成片，推送到 iOS 审核频道。 | Ollama + LTX-2.5 MLX + FFmpeg | ✅ 是 |
| `edge_compute_mesh` | 边缘算力共享节点 | 空闲时段监听悬赏队列，在独立临时沙箱内隔离执行推理 / 视频任务，加密回传结果后自动清理沙箱并累计算力点回执。 | Ollama / LTX-2.5 MLX（沙箱内） | ⚙️ 依任务而定 |
| `morning_tv` | 私人定制早间电视台 | 每天清晨按设定时点聚合本地 RSS / 财经源，生成 5 分钟专属播报脚本与动态视频简报并定时推送。 | Ollama + LTX-2.5 MLX | ✅ 是 |
| `phantom_sentinel` | 物理空间哨兵 | 收到 `🔒` 或 `LOCK_ALL`：清空系统剪贴板、卸载指定加密外置卷 / NAS 挂载点、触发智能家居 / Webhook 离家闭锁、锁定屏幕，并回传确定性执行回执。 | 确定性状态机 + `diskutil` / `NSPasteboard` | ❌ **不经过任何大模型** |
| `chrono_ark` | 时光数字方舟 | 本地密码学时间锁保险箱 + 心跳守护；时间锁到期，或超过失联周期没收到 iOS 心跳时，自动解封预设加密档案与祝福视频，投递给指定继承人队列。 | CryptoKit（时间锁 / HMAC / 密钥封装） | ❌ 否 |
| `health_sentinel` | 零泄露私人健康哨兵 | 本地离线解析拖入的体检报告并生成通俗解读；内置纯数学波形合成器，生成指定差频的双耳节拍助眠 WAV/MP3 直传 iOS。 | 本地模型 + 纯数学波形合成 | ⚠️ 部分：报告解读走本地模型；**音频合成为纯数学，不经模型** |
| `creator_paywall_hub` | 大 V 防盗版付费频道管家 | 配合隐形指纹引擎完成新成员入群验票、分发带独立指纹的加密内容、核销群内算力红包并回传回执。 | CryptoKit + 隐形指纹引擎（复用 `zero_trust_warroom`） | ❌ 否 |

三条值得单独强调的边界：

- **`phantom_sentinel` 是确定性状态机。** 闭锁指令不会被任何模型“理解”“改写”或“延迟”：`🔒` / `LOCK_ALL` 进，物理动作出，回执回传。把安全动作交给概率模型是不可接受的。
- **`zero_trust_warroom` 与 `creator_paywall_hub` 全程是信号处理与密码学。** 它们不看内容语义，也就不会把内容语义交给任何第三方。
- **10 个引擎全部走 Swift Concurrency actor 队列**，串行 / 分级调度并带并发内存锁：渲染任务不会把主线程或网页控制台拖死，也不会同时塞进两份模型权重把机器 OOM。

---

## Apple Silicon 内存算力自适应阶梯

节点启动时由 `HardwareProfilerAndInstaller` 读取 `sysctl`（芯片型号、CPU 核心数、物理统一内存、可用 SSD），**自动**选定下面这一档；换机器不用重配，档位随内存走。

| 统一内存 | 典型芯片（M1–M5 Max） | 文本模型 | 视频模型 | 首 token 延迟* | 生成吞吐* | 常驻内存峰值* | 模式 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `< 48 GB` | M1/M2 Max 低配、Pro 系列 | Qwen3.8 小档 | 不本地渲染，路由至边缘算力共享节点 | ~0.6–1.5 s | 25–45 tok/s | ~10–18 GB | 轻量推理模式 |
| `48 GB` | M1 Max / M2 Max 64 核 GPU 档 | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.5–3 s | 18–26 tok/s | ~20–26 GB | 均衡档（48–64 GB） |
| `64 GB` | M3 Max / M4 Max 64 GB 档 | Qwen3.8-27B **Q4_K_M** | LTX-2.5 MLX **8-bit** | ~1.2–2.5 s | 20–28 tok/s | ~24–30 GB | 均衡档（48–64 GB） |
| `96 GB` | M2 Ultra / M3 Max 96–128 GB 档 | Qwen3.8-27B **Q8_0** | **LTX-2.5 原版 BF16 满血权重** | ~2.5–5 s | 12–18 tok/s | ~40–52 GB | 满血档 |
| `128 GB` | M3 Max / M4 Max / M5 Max 128 GB 档 | Qwen3.8-27B **Q8_0**（可并行为双会话） | **LTX-2.5 原版 BF16 满血权重** | ~2–4 s | 12–20 tok/s | ~52–68 GB | 满血档 |

\* **这三列数字全部是估算值，不是实验室实测数据。** 数量级依据是“统一内存带宽受限的稠密 27B 解码 + LTX-2.5 权重按量化位宽的占用比例”推导出来的工程估计；真实数字受散热、机型世代、后台负载、片段长度与并发任务数影响，可能相差 2–3 倍。请把它当成“选档位的直觉”，而不是“性能承诺”。

规则原文（与产品规范一致）：

- `>= 96 GB` → **LTX-2.5 原版 BF16 满血权重 + Qwen3.8-27B（Q8_0）**
- `48 GB – 64 GB` → **LTX-2.5 MLX 8-bit 量化版 + Qwen3.8-27B（Q4_K_M）**
- `< 48 GB` → **轻量推理模式**，重型视频任务自动提示路由至「边缘算力共享节点」

### 可选模型：Inkling-2-Mini

上面的阶梯是**默认档**：没有拉取其他模型的 Mac，行为完全不变。模型目录另外把 **`Inkling-2-Mini`** 作为可选本地模型列出，可在菜单栏「本地模型」或控制台的模型面板里切换。

| 统一内存 | 准入判定 | 节点行为 |
| --- | --- | --- |
| `>= 48 GB` | 可并行运行 | 与常规多媒体、系统服务同时驻留 |
| `32 GB – 47 GB` | 达到推荐内存 | 可加载，桌面内存余量偏薄 |
| `25 GB – 31 GB` | 低于推荐值 | 可加载，但拒绝第二个本机重任务 |
| `<= 24 GB` | 内存交换预警 | **拒绝本机加载**，以免 OOM 卡死 |

约 **20 GB 权重**，连同上下文窗口常驻约 24 GB，**建议 32 GB 统一内存起步**。选中该模型后，界面会给出这份内存估算、`ollama pull inkling-2-mini` 指令，以及手工导入 GGUF 时的 `ollama create inkling-2-mini:q4_k_m -f Inkling-2-Mini.Modelfile` 说明。

本地导入实际落地的 tag 是机器相关的，因此不改目录也能覆盖引用：写 `config/model_refs.json`（`{"refs": {"inkling-2-mini": "inkling-2-mini:q4_k_m"}}`），或用优先级更高的环境变量 `POPOPX_OLLAMA_REF_INKLING_2_MINI`。不是合法本地引用的值（注册表主机、路径穿越）一律丢弃，回落到目录默认引用。

切换模型只改写请求体里的 `model` 字段：Ollama 调用仍然只发往 `http://127.0.0.1:11434`，引用不会进入 URL，任何模型请求与遥测都不会离开本机。

---

## 语言与本地化

节点的语言清单不是自己拟的 —— 它等于 iOS 端 `POPOPX.xcodeproj` 的 `knownRegions`（17 个语言区域，不含 `Base`，那是 Xcode 目录而不是语言），外加一项 iOS 端没有的 **`zh-Hant`**。`system` 跟随 Mac 的本 App 显示语言，与 iPhone 跟随 iOS 显示语言的行为一致；两边都只认这套 BCP-47 代码，配对时不需要翻译语言。

繁体不是第二份手写文案，而是用 Apple 自家的 `CFStringTransform`（`Hans-Hant`）从简体中文那一列**派生**出来的，所以它永远不会漏掉某个新增字符串。派生过程中唯一被审计出来的系统性偏差 —— 转换器把「启」写成异体「啓」而不是台湾标准字形「啟」—— 在 `TraditionalChinese.fixUps` 里修掉，并由测试锁住。

| 界面表面 | 校对文案 | 派生文案 | 兜底 |
| --- | --- | --- | --- |
| 网页控制台（`127.0.0.1:18920`） | `zh-Hans`、`en` | `zh-Hant` | 其余 15 个区域读英文文案 |
| 菜单栏（`PopopxMacNodeApp`） | `zh-Hans`、`en` | `zh-Hant` | 其余 15 个区域读英文文案 |
| 引擎产出（简报 / 脚本 / 文案） | `zh-Hans`、`en` | `zh-Hant` | 按所选语言写进模型提示词 |

兜底不是隐藏起来的偷工：控制台的 `langFallback` 提示会**明说**当前语言还没有校对文案、页面暂以英文显示，而不是假装已经翻译完。菜单栏的日志、`hub.publish` 通知与 `lastError` 一律保持本项目“中英文同排”的既定文风，不随控制台语言切换 —— 日志是排障材料，两种脚本同时在场比翻对一半更有用。

**语言存在哪**：向导第 3 步或设置里选的语言写入 `config/settings.json` 的 `language` 字段，整台节点一个值，默认 `system`；iOS 端同样没有应用内开关，它读 `Bundle.main.preferredLocalizations`。没有第三方 i18n 框架：Swift 侧是 `ConsoleLanguage` 枚举加一条回落规则 `text(zh:en:)`，网页侧是服务页面里的一张键表，语言下拉菜单由该枚举生成后注入页面。

**加一门语言**：① 在 `ConsoleLanguage` 加一个 case，`rawValue` 必须是 iOS 端 `knownRegions` 里已有的标签（`zh-Hant` 是唯一声明过的例外，因为 iOS 根本没有繁体 catalog；若 iOS 端新增了 region，先在那边加）；② 在 `LocalWebConsoleServer` 的 `I18N` 表里为每个被引用的键补一行 `{ zh:, en: }` 并加上第三种语言，`testConsoleCatalogCoversEveryReferencedKey` 会在缺键的瞬间直接失败；③ 把该语言加入 `ConsoleLanguage.curated`，页面才会停止英文兜底。`MacNodeContractTests` 会守住两端语言集合的一致性：iOS 端新增 region 而节点没跟上时，测试会红，而不是两个应用悄悄给出不同的语言列表。

---

## 生态桥接

`integrations/` 是从控制台以外的地方调用这十个引擎的受支持路径：一个 TypeScript 桥接内核，加上两个接入 Agent 宿主的适配器。它不新增端口、不额外起守护进程、不引入任何第三方运行时依赖 —— 它复用的就是本仓库已经在跑的东西：绑定 `127.0.0.1:18920` 的控制台与它的每进程一次性 Token，以及节点本来就会解析的 `::popopx_sys::NODE_CMD::{service}::{action}::{payload}` 信令。两条入口路径对同一个事实都很诚实：控制台从不广播、也从不向外连接，所以 Token 由操作者手动交接一次。

| 包 | 角色 | 通过什么访问节点 |
| --- | --- | --- |
| `integrations/shared` | 桥接内核：信令解析、控制台客户端、事件读取、策略闸门 | `POST /api/engine/invoke` |
| `integrations/linger-skill` | 接入 Linger 一类 Agent 宿主的适配器 | 只经内核，不碰 socket |
| `integrations/openclaw-skill` | 接入 OpenClaw 一类插件宿主的适配器 | 只经内核，不碰 socket |

内核会在打开 socket 之前拒绝一个动作：`phantom_sentinel` / `lockdown`。节点上这一条是真实执行的 —— 清空剪贴板、卸载外挂卷、熄屏并锁定会话 —— 没有确认、没有冷却、没有撤销，而且它绕在引擎自身开关之前就会被命中。所以发送它是双重选择加入：`allowLockdown: true` **且** `PPX_BRIDGE_SECRET` 至少 16 个字符；被拒绝这件事会写进插件日志，让操作者看得见它发生过。同一条规则也管重试：只有当节点确实没收到请求时才重发，因为 `chrono_ark` 的 `seal` 与 `creator_paywall_hub` 的 `grant` 不幂等。

```sh
cd integrations/shared && npm install && npm test
swift test --filter IntegrationsContractTests
```

[桥接契约](integrations/CONTRACT.zh-CN.md)（以及 [English contract](integrations/CONTRACT.md)）把上面每一句都钉到本仓库的某个 `file:line`，写明桥接在哪些地方故意比节点更严，也写明插件永远不该假设什么。`MacNodeContractTests` 与 `IntegrationsContractTests` 用同一份语料分别给 TypeScript 解析器和 Swift 解析器打分，所以两端运行时的偏移会先让测试变红，而不是在跑着的节点上给你意外。

---

## 安全自检指南

下面每一条都可以直接复制粘贴运行 —— 你不需要相信我们说的任何一句话，**红线是机器可验证的**。

### 1 · 控制台只绑回环

```sh
lsof -nP -iTCP:18920 -sTCP:LISTEN
```

期望：只有 `127.0.0.1:18920 (LISTEN)`，**绝不出现 `*:18920`、`TCP:*` 或某个外部网卡地址**。

```sh
sudo netstat -anp tcp | grep 18920
```

期望：每一行都以 `127.0.0.1` 开头；没有外部监听，也没有指向远端的 ESTABLISHED 连接。

### 2 · 进程级外连审计

```sh
lsof -nP -p "$(pgrep -x PopopxMacNodeApp)" -i
lsof -nP -p "$(pgrep -x popopx-chat)" -i
```

期望：这些进程名下只应出现 `127.0.0.1` 的 LISTEN 与本机回环 ESTABLISHED（5225 / 11434 / 18920）。出现任何非回环地址都应当让你警觉 —— 那是你自己抓包验证的证据，不是我们的声明。

### 3 · 产物签名与 Gatekeeper

```sh
codesign -dv --verbose=4 "/Applications/POPOPX Mac Node.app"
codesign --verify --deep --strict --verbose=2 "/Applications/POPOPX Mac Node.app"
spctl -a -vv "/Applications/POPOPX Mac Node.app"
```

`codesign -dv --verbose=4` 里应当看到：

```
Identifier=chat.popopx.node
Format=app bundle with Mach-O thin (arm64)      # 通用二进制的包则是 fat
flags=0x2(adhoc)                                 # 本仓库发布为 Ad-hoc，未公证
```

`spctl -a -vv` 对 Ad-hoc 签名**会返回 `rejected`**，这是预期结果，不是漏洞 —— 它意味着“这个包不是 Apple 背书的开发者”，而不是“这个包被篡改”。第二行的 `--verify --deep --strict` 才负责后者，它必须**静默通过**。

### 4 · 数据落点与密钥

```sh
ls -la ~/Library/Application\ Support/PopopxMacNode/
```

这是节点唯一的数据根目录（引擎工作区、日志、SSE 控制台状态、`engines/ltx2/` 权重工作区）。它不在 iCloud 同步范围内，也不在任何共享容器里。

```sh
LC_ALL=C grep -a -R -- "$HOME" ~/Library/Application\ Support/PopopxMacNode/ 2>/dev/null | wc -l
```

这里出现**你自己的**绝对路径是正常的：那是你机器上的配置，属于你的数据，不会外传。需要被审计的是**别人的**路径 —— 见第 5 条。

**密钥**：配对设备公钥白名单、时间锁密钥封装、指纹盲化参数分别存放在 macOS **登录钥匙串**（`security` / 钥匙串访问里搜 `popopx`）与 `PopopxMacNode/` 下由 **CryptoKit 生成的本地密钥文件**中。它们**不会**出现在日志里、不会出现在 SMP 信令里，也不会有任何上行通道能把它们带走。验证方式：`grep -a -R -i 'privatekey\|secret' ~/Library/Application\ Support/PopopxMacNode/ | wc -l` 应当接近 0 —— 密钥在钥匙串与专用密钥文件里，不在明文日志中。

### 5 · 二进制里没有开发机绝对路径

```sh
LC_ALL=C grep -a -o '/Users/[A-Za-z0-9._-]*' \
  "/Applications/POPOPX Mac Node.app/Contents/MacOS/PopopxMacNodeApp" | sort -u
```

期望：**空输出**。Swift 的 `#filePath` / `#file` / `#function` 调试字符串与未剥离的 DWARF 是最常见的泄漏源；`Scripts/build_dmg.sh` 在第 6/8 步把“编译机 `$HOME` 前缀出现在产物里”设成**硬失败**，命中即阻断发布。CI 上每一次发布构建都跑过这道门。

### 6 · 校验下载物

```sh
shasum -a 256 -c POPOPX-Mac-Node-Universal.dmg.sha256
```

`.sha256` 文件里只写 `<64 位十六进制>␣␣<相对文件名>`（两个空格、不带任何目录），所以它必须在与 `.dmg` 同一目录下执行，也永远不会指向别人的路径。

### 7 · 撤销一台已配对设备

1. 菜单栏图标 → **已配对设备** → 选中设备 → **撤销**。撤销后该机器的公钥立刻从 `allowedPairedPublicKeys` 白名单移除，残留信令会在网关层被丢弃。
2. 想连根拔掉：先停节点（菜单栏 → 退出），再清掉数据根目录下的配对与密钥记录（文件名含 `peer` / `pair` / `keys`），重启后二维码会换一批全新密钥。
3. 想连登录钥匙串一起清理：打开「钥匙串访问」搜 `popopx`，删除对应条目。

### 8 · 被 Gatekeeper 拦住时

```sh
xattr -dr com.apple.quarantine "/Applications/POPOPX Mac Node.app"
```

只在你**已经跑过第 6 条的 sha256 校验**之后再执行这一步。先验签，后放行 —— 顺序反了就是自我安慰。

---

## Open Core 授权

整条链只有一份许可。本仓库、中继服务端、iOS 客户端是**三个 AGPL-3.0 仓库，带着逐字节相同的许可原文**：

```sh
# 三个仓库并排 checkout 时执行
shasum -a 256 LICENSE ../popopxmq/LICENSE ../popopx-chat/LICENSE
# 8486a10c4393cee1c25392769ddd3b2d6c242d6ec7928e1414efff7dfb2f07ef —— 三个文件，同一个摘要
```

| 范围 | 授权 | 这意味着什么 |
| --- | --- | --- |
| 本仓库全部源码 —— 10 大引擎、SMP 网关、Web 控制台、GOP/频域隐形水印（`ENGGopWatermark`）、算力点记账、`Scripts/build_dmg.sh` | **[AGPL-3.0-only](LICENSE)** | 自由运行、研究、修改、再分发；§13 的网络服务同源义务一并生效 —— 把改动过的节点提供给别人用，就要提供你那份对应源码 |
| SMP/XFTP **中继服务端源码**，以及 BBS+（BLS12-381）盲签凭证代码 | **AGPL-3.0-only** | [popopxmq](https://github.com/popopx-chat/popopxmq)，其 [NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) 原文：“No further restrictions are imposed on recipients of this work (AGPL-3.0 sections 10 and 12)”。中继网络与凭证签发方，你都可以自建 |
| 伴生 iOS 客户端源码 | **AGPL-3.0-only** | [popopx-chat](https://github.com/popopx-chat/popopx-chat) |
| 本 fork 自己绘制的图形资产 | AGPL-3.0-only，**或由你选择 CC0-1.0** | [ASSETS_LICENSE-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/ASSETS_LICENSE-POPOPX.md) —— 与上游逐字节相同的文件仍属 SimpleX Chat Ltd，我们无权放行 |
| 官方托管的中继网络与带宽、官方发行与更新通道、带 SLA 的企业支持 | **服务条款 —— 不是代码** | [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) |
| `POPOPX`、`POPOPX Chat`、wordmark、logo 及其派生图标、`popopx.chat` | **完全不授权** —— 商标在著作权许可之外 | [TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md)：可以 fork、可以分发、可以留着我们画的图 —— 但必须改名换标 |

一句话：**这条链上的每一字节代码都开源、都可自建；商业那一轨买的是运营与背书，从来不是源码。**

- 完整 AGPL-3.0 正文：[`LICENSE`](LICENSE)
- 双语边界、§13 同源义务说明、支持档位，以及 2026-11-21 那次纠正 —— 不再把中继服务端、盲签算法与水印实现说成闭源产品：[`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)
- **没有隐藏核心。** 凭证算法在 popopxmq（`src/Popopx/Messaging/Crypto/BBS.hs`、`Crypto/Entitlement.hs`，参数与套件见 `protocol/crypto-registry.md`）；水印与逆向解出在本仓库（`ENGGopWatermark`，`TenBusinessEngines.swift:987-1198`）。付费范围里没有任何一道源码门槛 —— 那一轨卖的是机房、值班、发行通道与合规文件。
- **这些标志尚未注册**，而且那份政策对代码不作任何规定：“no sentence here adds a condition on running, studying, modifying or redistributing the source code.” 你可以说“POPOPX Mac Node 的一个 fork”，不可以把你的构建物命名为 POPOPX。

---

## 路线图

- **v1.0（当前）** —— 菜单栏宿主、`NWListener` 本地控制台三步向导、SMP 配对与公钥白名单、硬件体检 + 一键引擎部署、10 大引擎本地执行、Universal DMG + sha256 + GitHub Actions 全自动发布。
- **v1.1** —— 引擎级用量仪表盘（只在本机控制台呈现，每档内存的实际 token/s 与瓦特，把本页的估算值换成你的实测值）、任务时间线与失败原因回传 iOS、其余 15 个区域的人工校对文案（`zh-Hant` 已在 v1.0 由简转繁派生）。
- **v1.2** —— `edge_compute_mesh` 沙箱隔离强化（独立临时容器、逐任务密钥、执行后自动粉碎）、算力点收益明细本地账本与可导出报表。
- **v1.3** —— `chrono_ark` 多继承人分片托管与更长的时间锁原语矩阵；`health_sentinel` 支持的体检报告版式扩展（仍然完全离线）。
- **v1.4** —— Developer ID 签名与 Apple 公证流水线、Mac App Store 评估、更多 `LTX-2.5` 分辨率 / 时长档位适配。
- **不做的事** —— 遥测、云账号、把任何本地素材上传到我们的服务器、把 `phantom_sentinel` 交给大模型决策。

---

## 贡献

```sh
git clone https://github.com/popopx-chat/popopx-mac-node.git
cd popopx-mac-node
swift build && swift test
bash Scripts/build_dmg.sh --output dist --version 0.0.0-dev
```

几条硬规矩：

1. **零第三方依赖。** 只用 Apple 框架（`Network`、`CryptoKit`、`CoreImage`、`SwiftUI`、`AppKit`、`Vision`、`ServiceManagement`）。想加依赖请先开 issue 讨论 —— 这个“零依赖”是审计卖点，不是洁癖。
2. **禁止占位符。** 不允许 `// TODO`、省略号存根、“其余代码略”。代码、内嵌网页、文档、CI 必须 100% 可运行。
3. **禁止硬编码开发机绝对路径。** 统一使用 `FileManager.default.homeDirectoryForCurrentUser` 与 `~/Library/Application Support/PopopxMacNode/`。第 5 条自检和 `build_dmg.sh` 会在打包阶段把违反者拦下来。
4. **并发用 Swift Concurrency。** `actor` / `async` / `await` / `AsyncStream` 管理任务队列与本地 `Process`，不要把渲染压进主线程或网页控制台。
5. 提 PR 前跑一遍 `swift build && swift test`，CI 会在 `macos-15`（Apple Silicon）上再跑一次并真打出 DMG。

发布：

```sh
git tag v1.0.2 && git push origin v1.0.2   # 触发 .github/workflows/release.yml
```

---

<div align="center">

**如果这个项目让你重新拿回了自己数据的处理权，点个 Star 就是最直接的支持。**

[![Release](https://img.shields.io/github/v/release/popopx-chat/popopx-mac-node?include_prereleases&label=latest&style=for-the-badge)](https://github.com/popopx-chat/popopx-mac-node/releases)
![Stars](https://img.shields.io/github/stars/popopx-chat/popopx-mac-node?style=for-the-badge&logo=github&label=stars)
![Forks](https://img.shields.io/github/forks/popopx-chat/popopx-mac-node?style=for-the-badge&label=forks)
![Issues](https://img.shields.io/github/issues/popopx-chat/popopx-mac-node?style=for-the-badge)

[发布版本](https://github.com/popopx-chat/popopx-mac-node/releases) · [LICENSE](LICENSE) · [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) · [报告问题](https://github.com/popopx-chat/popopx-mac-node/issues/new)

[English](./README.md) | [简体中文](./README.zh-CN.md)

---

**Star history 会变，红线不会。** 本页刻意不放伪造的下载量、星标数或“实验室实测性能表” —— 所有性能数字都标了「估算值」。

Copyright © 2026 POPOPX Chat · 三个仓库的代码全部：[AGPL-3.0](LICENSE) · 托管中继、官方发行通道与品牌：[商业条款](LICENSE-COMMERCIAL.md)

</div>

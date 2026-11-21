# POPOPX Mac Node — 开源与商业边界 / Open-Core Boundary

> **本文件不是法律建议，也不是合同。 / This document is not legal advice, and it is not a contract.**
>
> 版权 / Copyright © 2026 POPOPX Chat.
> 本仓库的代码授权是 [`LICENSE`](LICENSE)（GNU AGPL-3.0，FSF 原文未改动）。本文件只做一件事：说清**哪些东西不在那份著作权许可里** —— 服务与商标。
> The code licence for this repository is [`LICENSE`](LICENSE) (GNU AGPL-3.0, the unmodified FSF text). This document does one job: stating **what is not inside that copyright grant** — services and trade marks.
> 本文件**不削减** `LICENSE` 授予你的任何一项权利；任何一处读起来像削减的措辞，以 `LICENSE` 为准。
> Nothing here narrows a single right `LICENSE` gives you; where the two appear to disagree, `LICENSE` wins.

---

## 0 · 全栈同许可 / The whole stack is under one licence

POPOPX 不是单仓库项目。这条链上的三个仓库 —— 节点宿主（本仓库）、中继服务端、iOS 客户端 —— **都是 AGPL-3.0，而且是同一份未经改动的 FSF 许可原文**：

```sh
# 三个仓库并排 checkout 时执行 / with the three repositories checked out side by side
shasum -a 256 LICENSE ../popopxmq/LICENSE ../popopx-chat/LICENSE
```

三个文件的摘要相同：`8486a10c4393cee1c25392769ddd3b2d6c242d6ec7928e1414efff7dfb2f07ef`（661 行，即 FSF 公布的 AGPL-3.0 正文）。

| 仓库 | 上游 | 授权 | 本文件此前被误称为"闭源"的东西 |
| --- | --- | --- | --- |
| [popopx-chat/popopx-mac-node](https://github.com/popopx-chat/popopx-mac-node)（本仓库） | 原创 | AGPL-3.0 | 隐形水印与逆向溯源：`ENGGopWatermark`（`Sources/PopopxMacNode/Engines/TenBusinessEngines.swift:987-1198`，纯数学段自 :957 起）+ FFmpeg 频域/DCT 流水线，全在源码里 |
| [popopx-chat/popopxmq](https://github.com/popopx-chat/popopxmq) | fork of [simplexmq](https://github.com/simplex-chat/simplexmq) | AGPL-3.0-only | SMP/XFTP 中继服务端源码：`src/Popopx/Messaging/Server*`（SMP）、`src/Popopx/FileTransfer/Server*`（XFTP），对应可执行目标 `smp-server` / `xftp-server` / `ntf-server`；盲签凭证：`src/Popopx/Messaging/Crypto/BBS.hs`、`Crypto/Entitlement.hs`，其下是两个 **Apache-2.0** 的 vendored submodule（`cbits/libbbs` → `simplex-chat/libbbs`、`cbits/blst` → `supranational/blst`），经 FFI 调用 |
| [popopx-chat/popopx-chat](https://github.com/popopx-chat/popopx-chat) | fork of [simplex-chat](https://github.com/simplex-chat/simplex-chat) | AGPL-3.0-only | 伴生 iOS 客户端源码与协议层 |

密码学细节不是黑盒：[popopxmq/protocol/crypto-registry.md](https://github.com/popopx-chat/popopxmq/blob/master/protocol/crypto-registry.md) 第 78 行把这套凭证写明了 —— **BBS+ over BLS12-381、SHA-256 suite**，`sk 32, pk 96, sig 80, proof 272 + 32 per undisclosed message`，头部常量 `POPOPX badges v1`，用途是 badge 权益凭证与其证明，以及 XFTP 存储时长延期。绑定层的工程记录在 `plans/2026-06-01-bbs-bindings.md`，同样是公开文件。

姊妹仓库自己怎么说的（原文，不是我们的转述）：

> The license is AGPL-3.0-only and the license text in ./LICENSE is unmodified. **No further restrictions are imposed on recipients of this work (AGPL-3.0 sections 10 and 12).**
> — [popopxmq/NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE)，第 1 节

> The source code of this software is licensed under the GNU Affero General Public License version 3 (AGPLv3) … The artwork this fork created carries the same grant, or CC0-1.0 at the recipient's option, since 2026-11-16.
> — [popopx-chat/README.md](https://github.com/popopx-chat/popopx-chat/blob/master/README.md)，License 一节

所以**图形资产也不在商业授权里**：本 fork 自己画的图，由 [ASSETS_LICENSE-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/ASSETS_LICENSE-POPOPX.md) 以 AGPL-3.0-only（或按接收方选择 CC0-1.0）授权；那份文件同时列明哪些文件与上游 SimpleX 逐字节相同 —— 那些是 SimpleX Chat Ltd 的，我们无权放行。

一句话：**这条链上没有任何一层代码需要向我们购买。付费买的从来不是源码，是运营与背书。**

---

# 第一部分 · 中文

## 1. AGPL-3.0 免费范围：哪些东西永远不需要付钱

以下权利由 [`LICENSE`](LICENSE) 直接授予，**不需要联系我们、不需要登记、不需要付费，也不受本文件其余条款的任何限制**：

1. **运行**。在你自己的任意数量设备上编译、安装、运行 POPOPX Mac Node，用于任何目的，包括商业用途。
2. **研究与审计**。阅读全部源码；用 [`README.zh-CN.md` 的安全自检指南](README.zh-CN.md) 验证它的网络行为、密钥落点与产物完整性。我们不要求你信任我们。
3. **修改**。改代码、改引擎调度策略、改 Web 控制台前端、改打包脚本，不需要报备。
4. **再分发**。分发原版或修改版都可以，条件是继续以 AGPL-3.0 提供完整对应源码（源码形式即已满足，因为本仓库本身就是源码）。
5. **自建全部基建 —— 包括中继集群本身**。SMP/XFTP 服务端源码在 [popopxmq](https://github.com/popopx-chat/popopxmq)，它自己就按 AGPL-3.0 §13 给出了对应源码承诺。你完全可以只用开源侧：自建 `popopx-chat` 队列、自建 SMP/XFTP 中继、自建 Web 控制台，不接我们的任何服务。
6. **自建算力点签发与对账**。盲签凭证是**代码**，不是我们的私产：BBS+ 实现、权益签发与校验逻辑都在 popopxmq 源码里，你可以自己部署签发方。**我们出售的是"由 POPOPX 签发"这一层信任与可用性，不是那段算法。**
7. **自建隐形水印与溯源**。GOP 切片盲化、频域嵌入与逆向解出的实现、参数与边界条件都在本仓库，连"这套编码挡不住什么"都写在代码注释里。
8. **打包与发布工具**。`Scripts/build_dmg.sh` 与 `.github/workflows/release.yml` 属于开源范围，可直接复用于你自己的 fork（打你自己的包、发你自己的 Release）。
9. **本 fork 自己绘制的图形资产**。AGPL-3.0-only，或由你选择 CC0-1.0（[ASSETS_LICENSE-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/ASSETS_LICENSE-POPOPX.md)）；与上游逐字节相同的文件除外，那些属于 SimpleX Chat Ltd。

一句话：**凡是代码，都是你的；凡是"我们运营"与"我们背书"，才是商品。**

## 2. AGPL-3.0 第 13 条：网络服务的同源义务

这一条常被误解，所以我们只陈述它的法律机制，不加威胁。

AGPL-3.0 与 GPL 的唯一实质差别在 **第 13 条（Remote Network Interaction）**：

> 如果你修改了这个程序，并且让最终用户通过网络与之交互，那么你必须向这些用户提供该修改版本的对应源码。

落到本项目上的实际含义：

- **只是自用 / 只在内部使用** → 第 13 条不触发。你可以修改本仓库、只在自家跑，**没有义务**公开你的改动。
- **把节点（原版或修改版）作为网络服务提供给别人** → 第 13 条触发。你必须向你服务的用户提供**你那个修改版本的完整对应源码**，并且继续以 AGPL-3.0 授权。典型场景：把节点架在机房里，按次或包月卖给不特定公众。
- **不想提供源码怎么办？** 只有两条路：（a）不要把它作为网络服务提供；（b）走「商业范围」与「支持档位」里的授权（见下文，以及你自己的律师的意见）。这就是双轨授权的经济模型 —— 你要么承担第 13 条的合规成本换取免费使用，要么付费换取免除。

需要明确的三点：

1. 第 13 条是 **AGPL-3.0 本身的条款**，不是我们额外附加的限制。你从本仓库拿到的每一个字节都已经带着它。
2. 它**不传染你放在节点旁边的自有业务代码**：你自己的私有前端、你自己的私钥、你自己的用户数据、你通过 SMP 队列下发的私有内容，都不因此变成开源。
3. 它约束的是"**你的修改版本**"：如果你没有改动程序，第 13 条的源码提供义务不适用；而 AGPL 的再分发条款仍然适用于你分发的任何副本。

同一件事在自建中继那一侧也成立：如果你把 popopxmq 跑给别人用，第 13 条要求你向用户提供你那个版本的对应源码 —— [popopxmq/NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) 第 4 节把这条承诺写成了文本。

如果你正在评估自己的部署形态是否触发第 13 条，请直接读 [`LICENSE`](LICENSE) 原文，并咨询你自己的律师。

## 3. 本文件修正了什么（2026-11-21）

诚实起见，把旧的错误留在页面上，而不是悄悄改掉。本文件与 `README` 此前把下面三项列为"**商业闭源授权**"：

| 旧表述 | 为什么是错的 | 现在的表述 |
| --- | --- | --- |
| 「POPOPX 全球私有 SMP/XFTP 中继集群」当作闭源资产 | 中继服务端源码在 popopxmq，AGPL-3.0-only，公开可下载、可自建 | 「商业范围」第 1 项：**官方托管服务与带宽**，代码开源 |
| 「盲签算力点结算协议」当作闭源 | BBS+ / BLS12-381 凭证实现、`Crypto/Entitlement.hs` 与密码学登记表全部开源（依赖项 Apache-2.0） | 第 1 节第 6 项 +「商业范围」第 1 项：算法与代码开源，出售的是官方签发与运营 |
| 「抗合谋隐形指纹算法 SDK」当作闭源 | 本仓库的 `ENGGopWatermark` 就是该能力的实现与逆向流程，可编译、可审计 | 第 1 节第 7 项：开源；更强的编码属于工程演进，不作为"隐藏的闭源核心"回售 |

错误不只在商业判断上，也在**法律事实上**：AGPL-3.0 §10 禁止对接收方施加进一步限制，§12 规定此类附加限制一律不具约束力。姊妹仓库据此在 2026-11-16 **撤回**了自己对图形资产的严格授权条款，并在 NOTICE 里写下 "No further restrictions are imposed on recipients of this work"。本仓库那份旧文案若被当真，就是在同一套代码上对外宣称一个姊妹仓库明确否认的限制。所以这次不是"放宽"，是**改成与真实授权状态一致**。

确实属于商业范围的，只剩「商业范围」一节那三项。

## 4. 商业范围：只有三项

下列三项**不在** `LICENSE` 的著作权许可之内。4.1 与 4.3 卖的是服务，4.2 是著作权许可从来管不着的东西：

### 4.1 官方托管 SMP/XFTP 中继网络与带宽

由 POPOPX Chat 运营的那张网：跨地域部署、多可用区冗余、机房、带宽、路由与抗干扰调度、就近接入、容量与运维值班。要点说清楚：

- **服务端源码是开源的**（[popopxmq](https://github.com/popopx-chat/popopxmq)，AGPL-3.0-only）。你不需要买它 —— 你买的是"不用自己熬夜"。
- 接入按**服务条款**（使用政策、速率限制、可用性承诺、滥用处置）提供，不按著作权许可提供。
- 直说现状：**截至本文件修订日，官方中继网络尚无公开运营的生产部署**（[popopxmq/NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) 记录了 "the client application is unreleased, no deployment exists"）。因此本节描述的是**授权边界**，不是一份今天就能下单的清单。要现在跑起来，请自建。

### 4.2 POPOPX 名称与品牌资产

`POPOPX`、`POPOPX Chat`、wordmark、logo 及其派生图标、`popopx.chat` 域名。详见「商标政策」一节。**AGPL 授权完全不包含商标许可 —— 与商业条款无关，那份许可本来就不含。**

### 4.3 官方发行通道与企业支持

- 由 POPOPX Chat 发布、并保有更新通道的发行物：本仓库的 GitHub Releases 与官方 iOS 客户端的上架主体。你可以自行发布 fork，但那是**你的**发行渠道，也不带我们的背书（见「商标政策」）。
- 企业支持：约定 SLA 的响应通道、合同与发票、合规文件、部署评审与故障共担。
- **本仓库的发布物目前是 Ad-hoc 签名、未经 Apple 公证**（`README.zh-CN.md`「安全自检指南」第 3 条）。Developer ID 与公证流水线在路线图上（v1.4）。我们不在文案里假装它已经存在。

## 5. 支持档位

**价格请来信获取报价（contact us for pricing）。** 下表描述的是**服务边界**，不是报价单，也不是功能解锁表：源码、10 大引擎、水印、算力点记账在任何一档都是同一份、完整的。本页刻意不印数字价格。

| 权益 | Community | Indie | Studio | Enterprise |
| --- | --- | --- | --- | --- |
| 三个仓库的全部源码（AGPL-3.0） | ✅ | ✅ | ✅ | ✅ |
| 本地 10 大引擎、Web 控制台、SSE 日志流 | ✅ | ✅ | ✅ | ✅ |
| 自建 `popopx-chat` 队列与 SMP/XFTP 中继 | ✅ | ✅ | ✅ | ✅ |
| GOP / 频域隐形水印与逆向溯源（含参数与边界条件） | ✅ | ✅ | ✅ | ✅ |
| 算力点本地记账、回执与核销状态机 | ✅ | ✅ | ✅ | ✅ |
| `build_dmg.sh` 自用打包 / 自建 CI | ✅ | ✅ | ✅ | ✅ |
| 本 fork 自绘图形资产（AGPL-3.0-only 或 CC0-1.0） | ✅ | ✅ | ✅ | ✅ |
| **官方托管中继网络接入与带宽**（服务，见 4.1） | ❌ 自建 | 1 条接入配额 | 团队配额 | 专属容量 + 就近接入 |
| **官方凭证签发与跨节点对账**（服务；算法本身开源） | ❌ 自建签发 | 只读查询 | ✅ 签发接入 | ✅ 签发 + 对账 API |
| **官方发行与更新通道**（背书，不是源码门槛） | ❌ | ❌ | 白名单接入 | ✅ 官方上架与更新通道 |
| **技术支持时效** | 社区 Issue，无 SLA | 邮件，尽力而为 | 工作日优先响应 | 专属通道 + 约定 SLA |
| **合同、发票、合规文件** | ❌ | ✅ | ✅ | ✅ |
| **POPOPX 品牌与商标使用权** | ❌ | ❌ | ❌ | 不随档位授予，需单独书面许可 |

选择建议 / how to pick:

- **只是自己用** → Community。你什么都不用买，也什么都不用签。
- **不想自己运维中继与签发方** → 从 Indie 起，买的是"接入"，不是"功能解锁"。
- **对外交付内容、要跨网可用与稳定对账** → Studio。
- **要把这套东西并入自己的商业产品，或不接受 AGPL §13 的源码提供义务** → Enterprise（同时按「商标政策」评估你的合规与命名路径）。

## 6. 商标政策

政策原文只有一份，在客户端仓库：[popopx-chat/TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md)。本节是它的摘要与在本仓库的落地，**不覆盖、不扩大它**。

1. **主张范围**：`POPOPX`、`POPOPX Chat`、POPOPX wordmark、POPOPX logo 及其派生图标、`popopx.chat` 域名。这些标志**尚未注册** —— 政策原文自陈 "**These marks are not registered**"；POPOPX 只在其使用已经建立起权利的范围内主张未注册标志的权利，本文件也不声称任何注册。`POPOPXMQ` 是 popopxmq 的项目名，该仓库同样声明"仓库内没有任何授权延伸为商标许可"；而任何**含 `POPOPX` 的名称**都落在下面第 3 条的命名规则里。
2. **AGPL-3.0 授予的是著作权许可，不包含任何商标许可。** 这两件事法律上彼此独立；那份政策自己也写明它对代码不作任何规定："no sentence here adds a condition on running, studying, modifying or redistributing the source code"。
3. 因此：
   - ✅ 你可以说 "a fork of POPOPX Mac Node"、"compatible with POPOPX Mac Node"、"connects to a POPOPX relay"（真实、不误导，且不作为你自己软件的名字）；
   - ✅ 你可以分发你自己的构建物，**前提是换成你自己的名字与标志**；
   - ❌ 你不可以把你的分发版命名为 POPOPX —— 产品名、包名、bundle identifier、logo 均不可 —— 也不可以暗示官方出品；
   - ❌ 你不可以注册含 `popopx` 或近似拼写的域名、或公布让人误认为是 POPOPX 运营的 SMP/XFTP 地址；
   - ❌ 你不可以未经书面许可，以 POPOPX 之名面向公众投放广告、售卖周边或提供服务。
4. **上游是第二个品牌。** 本 fork 派生自 SimpleX Chat，因此下游 fork 继承的是**两条**义务：POPOPX 的标志受上述政策约束；`SimpleX` / `SimpleX Chat` 的名称、logo 与上游图形资产属 SimpleX Chat Ltd（上游 [TRADEMARK.md](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md) 与 [ASSETS_LICENSE.md](https://github.com/simplex-chat/simplex-chat/blob/master/assets/ASSETS_LICENSE.md)），我们没有权力放行。
5. 那份政策要求的救济方式，原文照录：**"rename the software, replace the marks, keep the code. We act against confusion, not against forks."** 品牌使用权需要单独签署书面许可，且不属于「支持档位」任何一档自动附带的内容。

## 7. 为什么还要商业那一轨

立场是一句话：**用户应当拥有并审计自己的算力层，而熬夜运维跨地域高可用基建的人应当被付费。**

代码全开、按 AGPL 传染回流，这一层人人可审计 —— 包括"零云端"这句承诺本身。而把机房、带宽、签发信任、值班与合规文件也免费给出，结局通常只有两种：停摆，或者靠卖你的数据换钱。我们选第三条路：**代码归你，运营归我们，品牌不许冒充。**

AGPL-3.0 在这套模型里承担两个作用：（1）保证任何人对这一层的改动都必须回流给使用同一份代码的人；（2）让"把别人的开源工程直接包装成自己的托管服务转售"这件事要么公开源码、要么付授权费。它不惩罚自用者，也不惩罚研究者 —— 这两类人一分钱不用付，也永远不用付。

## 8. 联系方式

- **授权与商务咨询**：`licensing@popopx.chat`。
  **必须先说的实话**：`popopx.chat` 目前**没有发布 MX 记录**（`dig +short MX popopx.chat` 返回空，可自验），因此该地址**可能无法送达** —— 客户端仓库也如实记录了同一件事。邮件未获回复，请直接开 [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues) 并在标题标注 `licensing`。
  请在邮件中说明：用途（自用/内部/对外服务）、预计节点数量与部署形态、是否触发 AGPL §13、需要的档位与合规文件类型。
- 开源协作、Bug 与功能请求走 [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues)。

## 9. 声明

- **本文件不是法律建议**，也不构成合同；具体权利义务以你与 POPOPX Chat 单独签署的书面授权协议为准。
- 本文件与 [`LICENSE`](LICENSE) 冲突时，**一律以 `LICENSE` 为准**：AGPL 授权范围内的权利不受本文件任何措辞削减。第 3 节记录的正是这样一次纠正。
- 本文件的商标边界以 [popopx-chat/TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md) 为原文，两者不一致时以那份政策为准。
- 本文件可能随版本更新；请以你实际取用代码时的版本为准。
- **Copyright (C) 2026 POPOPX Chat.**

---

# Part II · English

## 1. What AGPL-3.0 gives you for free — forever

The following rights are granted directly by [`LICENSE`](LICENSE). They require **no contact with us, no registration and no payment, and none of the other sections of this document limits them**:

1. **Run.** Compile, install and operate POPOPX Mac Node on as many of your own devices as you like, for any purpose, including commercial ones.
2. **Study and audit.** Read every line; verify its network behaviour, key storage and artifact integrity using the [security self-audit guide](README.md). We do not ask you to trust us.
3. **Modify.** Change the code, the engine scheduling, the web console front end or the packaging script. No notification required.
4. **Redistribute.** Verbatim or modified copies may be redistributed, provided you keep distributing the complete corresponding source under AGPL-3.0 (this repository already is that source).
5. **Operate your own infrastructure — the relay fleet included.** The SMP/XFTP server source lives in [popopxmq](https://github.com/popopx-chat/popopxmq), and it carries its own AGPL-3.0 section 13 corresponding-source offer. You can run entirely on the open side: your own `popopx-chat` queues, your own SMP/XFTP relays, your own console, without touching a single service of ours.
6. **Operate your own credential issuer and settlement.** The blind signature is **code**, not our private property: the BBS+ implementation and the entitlement issuance and verification logic are in the popopxmq source, and you may deploy your own issuer. **What we sell is the trust and availability of "issued by POPOPX", never the algorithm.**
7. **Operate your own invisible watermarking and attribution.** The GOP-slice blinding, the frequency-domain embedding and the reverse extraction — implementation, parameters and edge conditions — are all in this repository, together with the code comments saying what the scheme does *not* survive.
8. **Packaging and release tooling.** `Scripts/build_dmg.sh` and `.github/workflows/release.yml` are part of the open-source grant and are reusable in your own fork — your own bundles, your own Releases.
9. **The artwork this fork drew.** AGPL-3.0-only, or CC0-1.0 at your option ([ASSETS_LICENSE-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/ASSETS_LICENSE-POPOPX.md)). Files byte-identical to upstream's are excluded: those belong to SimpleX Chat Ltd.

In short: **the code is yours; what is for sale is operations and endorsement.**

## 2. AGPL-3.0 section 13: the network-service copyleft duty

This clause is widely misunderstood, so we state only the legal mechanics — no threats.

The single substantive difference between GPL and AGPL is **section 13 (Remote Network Interaction)**:

> If you modify the Program, and the Program gives users a means of interacting with it remotely over a computer network, you must offer those users a way to get the corresponding source of your modified version.

Applied to this project:

- **Purely personal or internal use** → section 13 is not engaged. You may modify this repository and keep the modifications private, with **no obligation** to publish them.
- **Offering the node (original or modified) as a network service to other people** → section 13 is engaged. You must provide the **complete corresponding source of your modified version** to the users of that service, still under AGPL-3.0. Typical case: racking the node in a data centre and selling access, per-use or subscription.
- **What if you do not want to publish the source?** Exactly two routes: (a) do not offer it as a network service; (b) take a licence from the "commercial scope" and "support tiers" sections below (and your own lawyer's view on the rest). That is the whole economic model of dual licensing — you either carry the section 13 compliance cost in exchange for free use, or you pay to be relieved of it.

Three clarifications:

1. Section 13 **is part of AGPL-3.0 itself**, not an extra restriction bolted on by us. Every byte you take from this repository already carries it.
2. It **does not reach your separate business code** sitting next to the node: your private front end, your private keys, your user data and the private content you push over the SMP queue do not become open source because of it.
3. It binds **your modified version**: modify nothing and that duty does not arise — while AGPL's redistribution terms continue to apply to any copies you distribute.

The same logic runs on the self-hosted relay side: if you operate popopxmq for other people, section 13 obliges you to offer them the corresponding source of your version — [popopxmq/NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) section 4 puts that offer in writing.

If you are assessing whether your own deployment model engages section 13, read [`LICENSE`](LICENSE) itself and consult your own lawyer.

## 3. What this document corrected (2026-11-21)

Honesty means leaving the mistake on the page instead of quietly deleting it. This file and the `README` used to list three items as a **"commercial closed-source licence"**:

| Former wording | Why it was wrong | What it says now |
| --- | --- | --- |
| the "POPOPX global private SMP/XFTP relay cluster" as a closed asset | the relay server source is in popopxmq, AGPL-3.0-only, publicly downloadable and self-hostable | "commercial scope" item 1: a **hosted service with bandwidth**; the code is open |
| the "blind-signed compute-point settlement protocol" as closed | the BBS+ / BLS12-381 credential code, `Crypto/Entitlement.hs` and the crypto registry are all open (their dependencies Apache-2.0) | section 1 item 6 plus "commercial scope" item 1: algorithm and code open; official issuance and operation are what is sold |
| the "anti-collusion invisible fingerprinting algorithm SDK" as closed | `ENGGopWatermark` in this repository *is* that capability plus its extraction pipeline — compilable and auditable | section 1 item 7: open; tougher encodings are engineering roadmap, not a hidden closed core sold back to you |

The error was not only commercial but **legal**: AGPL-3.0 section 10 forbids imposing further restrictions on recipients, and section 12 renders such restrictions ineffective. The sibling repositories acted on that in full — they **withdrew** their own restrictive grant over artwork on 2026-11-16 and wrote "No further restrictions are imposed on recipients of this work" into their NOTICE. Taken at face value, our old text advertised over the same code a restriction that those repositories explicitly disclaim. This revision is therefore not a loosening; it is **alignment with the actual licence state**.

What genuinely belongs to the commercial track is the three items in "commercial scope".

## 4. The commercial scope: three items only

The following three are **outside** the `LICENSE` grant. 4.1 and 4.3 are services; 4.2 is something a copyright licence never reached:

### 4.1 The official hosted SMP/XFTP relay network and bandwidth

The network POPOPX Chat operates: cross-region deployment, multi-AZ redundancy, data centres, bandwidth, routing and interference-resistant transport scheduling, nearby ingress, capacity, and the people on call. Stated plainly:

- **The server source is open** ([popopxmq](https://github.com/popopx-chat/popopxmq), AGPL-3.0-only). You do not need to buy it — you buy not having to stay up at night.
- Access is provided under **service terms** (usage policy, rate limits, availability commitments, abuse handling), not under a copyright licence.
- The honest status: **as of the date of this revision there is no public production deployment of an official relay network** ([popopxmq/NOTICE](https://github.com/popopx-chat/popopxmq/blob/master/NOTICE) records "the client application is unreleased, no deployment exists"). This section therefore describes an **authorisation boundary**, not a catalogue you can order from today. To run now, self-host.

### 4.2 The POPOPX name and brand assets

`POPOPX`, `POPOPX Chat`, the wordmark, the logo and the icons derived from it, and the `popopx.chat` domain. See the trademark section below. **The AGPL grant contains no trademark licence whatsoever — that has nothing to do with commercial terms; the grant never had one.**

### 4.3 Official distribution channels and enterprise support

- Releases published and update channels maintained by POPOPX Chat: this repository's GitHub Releases, and the publisher identity of the official iOS client. You may publish your own fork — as **your** channel, and without our endorsement (see the trademark section).
- Enterprise support: an agreed-SLA response channel, contracts and invoicing, compliance paperwork, deployment reviews and shared incident handling.
- **Builds from this repository are currently ad-hoc signed and notarisation-free** (item 3 of the security self-audit guide in [`README.md`](README.md)). Developer ID and notarisation are on the roadmap (v1.4). We will not pretend in prose that they already exist.

## 5. Support tiers

**Contact us for pricing.** The table describes **service boundaries**, not a price list and not a feature gate: the source, the 10 engines, the watermarking and the compute-point ledger are identical and complete at every tier. This document deliberately prints no figures.

| Capability | Community | Indie | Studio | Enterprise |
| --- | --- | --- | --- | --- |
| Full source of all three repositories (AGPL-3.0) | ✅ | ✅ | ✅ | ✅ |
| All 10 local engines, web console, SSE log stream | ✅ | ✅ | ✅ | ✅ |
| Self-hosted `popopx-chat` queues and SMP/XFTP relays | ✅ | ✅ | ✅ | ✅ |
| GOP / frequency-domain invisible watermark and extraction (parameters, edge conditions) | ✅ | ✅ | ✅ | ✅ |
| Compute-point local ledger, receipts and redemption state machine | ✅ | ✅ | ✅ | ✅ |
| `build_dmg.sh` self-packaging / own CI | ✅ | ✅ | ✅ | ✅ |
| Artwork this fork drew (AGPL-3.0-only, or CC0-1.0) | ✅ | ✅ | ✅ | ✅ |
| **Official hosted relay access and bandwidth** (service, see 4.1) | ❌ self-host | 1 access quota | team quota | dedicated capacity + nearby ingress |
| **Official credential issuance and cross-node reconciliation** (service; the algorithm itself is open) | ❌ self-issue | read-only queries | ✅ issuance access | ✅ issuance + reconciliation API |
| **Official release and update channel** (endorsement, not a source gate) | ❌ | ❌ | allow-listed access | ✅ official listing and update channel |
| **Support response** | community issues, no SLA | e-mail, best effort | prioritised business-day response | dedicated channel + agreed SLA |
| **Contract, invoice, compliance paperwork** | ❌ | ✅ | ✅ | ✅ |
| **Right to use the POPOPX brand and marks** | ❌ | ❌ | ❌ | never granted by a tier; separate written licence |

How to choose:

- **Just using it yourself** → Community. Nothing to buy, nothing to sign.
- **You do not want to operate relays and an issuer** → from Indie up, what you buy is *access*, not *unlocked functionality*.
- **Shipping content externally, needing cross-network availability and dependable reconciliation** → Studio.
- **Embedding this in your own commercial product, or offering it as a service while unwilling to take on the AGPL §13 source obligation** → Enterprise (and re-read the trademark section before planning your naming).

## 6. Trademark policy

There is exactly one policy document, in the client repository: [popopx-chat/TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md). This section summarises it and applies it here; it neither overrides nor widens it.

1. **What is claimed:** `POPOPX`, `POPOPX Chat`, the POPOPX wordmark, the POPOPX logo and the icons derived from it, and the `popopx.chat` domain. **These marks are not registered** — the policy says so verbatim — and POPOPX asserts only the rights that attach to an unregistered mark where its use has established them; this document claims no registration. `POPOPXMQ` is the project name used by popopxmq, whose own NOTICE states that no grant in that repository extends a trade mark; and any **name containing `POPOPX`** falls under rule 3 below.
2. **AGPL-3.0 grants a copyright licence, not a trademark licence.** These are legally independent, and the policy itself regulates nothing about the code: "no sentence here adds a condition on running, studying, modifying or redistributing the source code".
3. Therefore:
   - ✅ you may say "a fork of POPOPX Mac Node", "compatible with POPOPX Mac Node" or "connects to a POPOPX relay" — truthfully, non-deceptively, and not as the name of the software doing the describing;
   - ✅ you may distribute your own build **renamed and re-logoed**;
   - ❌ you may not name your distribution POPOPX — not as product name, package name, bundle identifier or logo — and you may not present it as official;
   - ❌ you may not register domains containing or resembling `popopx`, or publish SMP/XFTP addresses that read as POPOPX-operated;
   - ❌ you may not advertise, sell merchandise, or offer a service to the public under the POPOPX name without prior written permission.
4. **There is a second brand.** This fork derives from SimpleX Chat, so a downstream fork inherits **two** obligations: the POPOPX marks follow the policy above, while the "SimpleX" / "SimpleX Chat" names, logos and upstream artwork belong to SimpleX Chat Ltd (their [TRADEMARK.md](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md) and [ASSETS_LICENSE.md](https://github.com/simplex-chat/simplex-chat/blob/master/assets/ASSETS_LICENSE.md)) — and we have no power to release them.
5. The remedy that policy asks for, verbatim: **"rename the software, replace the marks, keep the code. We act against confusion, not against forks."** Brand usage requires a separate written licence, which no tier in "support tiers" grants automatically.

## 7. Why keep a commercial track at all

The position is one sentence: **users should own and audit their own compute layer, and the people who stay up operating cross-region high-availability infrastructure should get paid for it.**

With the code fully open and copyleft flowing back, that layer is auditable by anyone — including the "zero cloud" promise itself. Give away the data centres, the bandwidth, the credential trust, the on-call rota and the compliance paperwork for nothing, and there are only two endings: it stops, or it monetises your data. We take the third road: **the code is yours, the operations are ours, the brand may not be impersonated.**

Within this model AGPL-3.0 does two jobs: (1) any change other people make to this layer must flow back to everyone else using the same code; (2) wrapping somebody else's open project directly into a hosted resale offering means either publishing the source or paying for a licence. It does not punish people who run it themselves, and it does not punish researchers — those two groups never pay, and never will.

## 8. Contact

- **Licensing and commercial enquiries**: `licensing@popopx.chat`.
  **The caveat comes first:** `popopx.chat` publishes **no MX record** today (verify with `dig +short MX popopx.chat`, which returns nothing), so that address **may be undeliverable** — the client repository records the same fact. If a message goes unanswered, open a [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues) ticket with `licensing` in the title.
  Please state: intended use (personal / internal / offered as a service), expected node count and deployment topology, whether AGPL §13 is engaged, and which tier plus what compliance paperwork you need.
- Open-source collaboration, bugs and feature requests belong in [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues).

## 9. Disclaimer

- **This document is not legal advice**, and it is not a contract. Your actual rights and obligations are defined by the written licence agreement you separately execute with POPOPX Chat.
- Where this document and [`LICENSE`](LICENSE) appear to conflict, **`LICENSE` governs**: no wording here narrows a right inside the AGPL grant. Section 3 records exactly such a correction.
- Where this document and [popopx-chat/TRADEMARK-POPOPX.md](https://github.com/popopx-chat/popopx-chat/blob/master/TRADEMARK-POPOPX.md) appear to conflict, that policy governs the trademark boundary.
- This document may change with new versions; the applicable text is the one in the version you actually take.
- **Copyright (C) 2026 POPOPX Chat.**

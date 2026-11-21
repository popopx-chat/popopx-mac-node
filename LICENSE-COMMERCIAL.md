# POPOPX Mac Node — Open Core 商业授权条款 / Commercial Licensing Terms

> **本文件不是法律建议。 / This document is not legal advice.**
>
> 版权 / Copyright © 2026 POPOPX Chat.
> 本文件与 [`LICENSE`](LICENSE)（GNU AGPL-3.0）共同构成 POPOPX Mac Node 的完整授权框架。
> This file, together with [`LICENSE`](LICENSE) (GNU AGPL-3.0), forms the complete licensing framework for POPOPX Mac Node.

本仓库采用 **Open Core / 双轨授权（dual licensing）**：

| 范围 | 授权 |
| --- | --- |
| 本仓库中的全部源码（10 大本地引擎、SMP/XFTP 信令网关、本地 Web 控制台、硬件探针、`Scripts/build_dmg.sh`、CI 工作流、测试） | **GNU AGPL-3.0**（见 [`LICENSE`](LICENSE)），无条件、永久、免费 |
| POPOPX 全球私有 SMP/XFTP 中继集群接入、盲签算力点结算协议、抗合谋隐形指纹算法 SDK、POPOPX 名称/标志/域名、iOS App Store 伴生分发 | **商业闭源授权**（本文件） |

---

# 第一部分 · 中文

## 1. AGPL-3.0 免费范围：哪些东西永远不需要付钱

以下权利由 [`LICENSE`](LICENSE) 直接授予，**不需要联系我们、不需要登记、不需要付费，也不受本文件其余条款的任何限制**：

1. **运行**。在你自己的任意数量设备上编译、安装、运行 POPOPX Mac Node，用于任何目的，包括商业用途。
2. **研究与审计**。阅读全部源码；用 [`README.md` 的安全自检指南](README.md) 验证它的网络行为、密钥落点与产物完整性。我们不要求你信任我们。
3. **修改**。改代码、改引擎调度策略、改 Web 控制台前端、改打包脚本，不需要报备。
4. **再分发**。分发原版或修改版都可以，条件是继续以 AGPL-3.0 提供完整对应源码（源码形式即已满足，因为本仓库本身就是源码）。
5. **自建全部基建**。本仓库包含完整的本地执行栈。你完全可以只用开源部分、自己跑 `popopx-chat`（上游 `simplex-chat`）队列、自己部署 SMP 服务，不接我们的任何闭源服务。
6. **打包与发布工具**。`Scripts/build_dmg.sh` 与 `.github/workflows/release.yml` 属于开源范围，可直接复用于你自己的 fork（包括打你自己的包、发你自己的 Release）。

一句话：**凡是运行在你自己硬件上的代码，都是你的。**

## 2. AGPL-3.0 第 13 条：网络服务传染条款（内部称"反白嫖传染条款"）

这一条常被误解，所以我们只陈述它的法律事实，不加威胁。

AGPL-3.0 与 GPL 的唯一实质差别在 **第 13 条（Remote Network Interaction）**：

> 如果你修改了这个程序的版本，并且**让最终用户通过网络与之交互**，那么你必须向这些用户提供该修改版本的对应源码。

落到本项目上的实际含义：

- **只是自用 / 只在内部使用** → 第 13 条不触发。你可以修改本仓库、只在自家跑，**没有义务**公开你的改动。
- **把节点（原版或修改版）作为网络服务提供给别人** → 第 13 条触发。你必须向你服务的用户提供**你那个修改版本的完整对应源码**，并且仍然以 AGPL-3.0 授权。典型场景：把 POPOPX Mac Node 架在机房里、按次或包月卖给不特定公众使用。
- **不想提供源码怎么办？** 只有两条路：（a）不要把它作为网络服务提供；（b）向我们取得**商业闭源授权**（第 3、4 节）。这就是双轨授权的经济模型 —— 你用第 13 条的合规成本换取免费使用，或者付费换取免除。

需要明确的三点：

1. 第 13 条是 **AGPL-3.0 本身的条款**，不是我们额外附加的限制。你从本仓库拿到的每一个字节都已经带着它。
2. 它**不传染你放在节点旁边的自有业务代码**：你自己的私有前端、你自己的私钥、你自己的用户数据、你通过 SMP 队列下发的私有内容，都不因此变成开源。
3. 它**不影响普通 SaaS 场景中的"未修改"**：如果你没有修改程序，第 13 条关于"修改版本"的源码提供义务不适用；但 AGPL 的其他再分发条款仍然适用于你分发的任何副本。

如果你正在评估自己的部署形态是否触发第 13 条，请直接读 [`LICENSE`](LICENSE) 原文，并咨询你自己的律师。

## 3. 需要商业闭源授权的范围

下列内容**不在** AGPL 授权范围内，使用前须取得书面授权：

1. **POPOPX 全球私有高速 SMP/XFTP 中继集群接入**
   官方运营的跨地域、多可用区 SMP/XFTP 中继与队列高可用基建：私有路由、抗干扰传输调度、多线路冗余、跨网穿透优化、SLA 保障。开源节点可以与自建队列正常工作，但不包含这套托管集群的接入权。
2. **盲签算力点结算协议**
   `edge_compute_mesh` 与 `creator_paywall_hub` 所依赖的算力点结算体系：盲签名协议、防双花账本规则、收益核销与对账接口、争议仲裁数据格式。开源部分只实现**本地记账与沙箱执行**，不含跨节点的结算信任根。
3. **抗合谋隐形指纹算法 SDK**
   `zero_trust_warroom` / `creator_paywall_hub` 商用级的抗合谋（anti-collusion）隐形指纹能力：多接收者联合攻击下的鲁棒指纹编码、逆向溯源服务、模型/参数与工程实现。开源仓库提供的是可编译、可审计的基础水印与逆向流程；受专利/商业秘密保护的高抗合谋强度实现以 SDK 形式授权。
4. **POPOPX 名称、标志、域名与品牌资产**
   详见第 5 节。**AGPL 授权完全不包含商标权。**
5. **iOS App Store 伴生分发**
   官方 POPOPX iOS 客户端、「发现」服务号入口、App Store 上架主体与更新通道。你可以为自己的 fork 编写兼容客户端并自行上架，但不得使用官方名称与标志，也不得冒充官方伴生关系。

## 4. 授权档位

**价格请邮件联系销售获取报价（contact sales for pricing）。** 下表描述的是能力边界，不是报价单；本页刻意不印任何数字价格。

| 权益 | Community | Indie | Studio | Enterprise |
| --- | --- | --- | --- | --- |
| 本仓库全部源码（AGPL-3.0） | ✅ | ✅ | ✅ | ✅ |
| 本地 10 大引擎、Web 控制台、SSE 日志流 | ✅ | ✅ | ✅ | ✅ |
| 自建 `popopx-chat` 队列（SMP/XFTP） | ✅ | ✅ | ✅ | ✅ |
| `build_dmg.sh` 自用打包 / 自建 CI | ✅ | ✅ | ✅ | ✅ |
| 官方全球私有 SMP/XFTP 中继集群接入 | ❌ | 1 条接入配额 | 团队配额 | 专属容量 + 就近接入 |
| 盲签算力点结算协议 | ❌（仅本地记账） | 只读查询 | ✅ 结算接入 | ✅ 结算 + 对账 API |
| 抗合谋隐形指纹算法 SDK | ❌ | 评估用（不得商用分发） | ✅ 商用授权 | ✅ 商用 + 源码托管审计 |
| iOS 官方伴生分发通道 | ❌ | ❌ | 白名单接入 | ✅ 官方上架与更新通道 |
| POPOPX 品牌与商标使用权 | ❌ | ❌ | ❌ | 需单独签署品牌许可 |
| 支持时效 | 社区 Issue，无 SLA | 邮件，尽力而为 | 工作日优先响应 | 专属通道 + 约定 SLA |
| 合同、发票、合规文件 | ❌ | ✅ | ✅ | ✅ |

选择建议 / how to pick:

- **只是自己用** → Community。你什么都不用买，也什么都不用签。
- **一个人的工作室，需要跨网可用与算力点结算** → Indie。
- **多人团队 / 对外交付内容、需要商用级防伪与稳定中继** → Studio。
- **要把这套东西并入自己的商业产品或对外提供服务、且不接受 AGPL §13 的源码提供义务** → Enterprise（同时按第 2 节评估你的合规路径）。

## 5. 商标政策

1. `POPOPX`、`POPOPX Mac Node`、`POPOPX Chat` 及其名称、标志、图标、域名与拼写变体，均为 POPOPX Chat 的商标或商号权益。
2. **AGPL-3.0 授予的是著作权许可，不包含任何商标许可。** 这两件事在法律上彼此独立，本仓库的 LICENSE 文件从头到尾没有授予你使用我们品牌的权利。
3. 因此：
   - ✅ 你可以说 "a fork of POPOPX Mac Node"、"compatible with POPOPX Mac Node"（真实、不误导的前提下）；
   - ✅ 你可以分发你自己的构建物，**前提是换成你自己的名字与标志**；
   - ❌ 你不可以把你的分发版命名为 POPOPX、使用紫色盾牌标志、或暗示这是官方出品；
   - ❌ 你不可以用 "POPOPX" 作为你自己的产品名、公司名、域名或 App Store 应用名。
4. 品牌使用权需要单独签署书面品牌许可（Enterprise 档位可附带申请通道）。

## 6. 为什么采用双轨授权

POPOPX Mac Node 的立场是：**用户应当拥有并审计自己的算力层，而运维跨地区高可用基建的人应当被付费。**

如果只有闭源版本，你无法验证"零云端"是不是营销话术；如果只有 AGPL 版本，全球中继集群、结算信任根与抗合谋指纹算法的机房、带宽与研发成本就没有来源，最终要么停摆、要么靠卖你的数据换钱 —— 我们选前者不成立，所以选后者不做的第三条路：**核心可审计、基建可付费**。

AGPL-3.0 在这套模型里承担两个作用：（1）保证任何人对这一层的改动都必须回流给使用同一份代码的人；（2）让"把别人的开源工程直接包装成自己的托管服务转售"这件事要么公开源码、要么付授权费。它不是惩罚自用者，也不是惩罚研究者 —— 这两类人一分钱不用付，也永远不用付。

## 7. 联系方式

- **授权与商务咨询（licensing contact）**：`licensing@popopx.chat`
  请在邮件中说明：用途（自用/内部/对外服务）、预计节点数量与部署形态、是否触发 AGPL §13、需要的档位与合规文件类型。
- 开源协作、Bug 与功能请求请走 [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues)，不要通过 Issues 谈授权。

## 8. 声明

- **本文件不是法律建议**，也不构成合同；具体的权利义务以你与 POPOPX Chat 单独签署的书面授权协议为准。
- 本文件与 [`LICENSE`](LICENSE) 冲突时：AGPL 授权范围内的权利以 `LICENSE` 为准；商业授权范围内的权利以签署的合同为准。
- 本文件可能随版本更新；请以你实际取用代码时的版本为准。
- **Copyright (C) 2026 POPOPX Chat.**

---

# Part II · English

## 1. What AGPL-3.0 gives you for free — forever

The following rights are granted directly by [`LICENSE`](LICENSE). They require **no contact with us, no registration and no payment, and none of the other sections of this document limits them**:

1. **Run.** Compile, install and operate POPOPX Mac Node on as many of your own devices as you like, for any purpose, including commercial ones.
2. **Study and audit.** Read every line; verify its network behaviour, key storage and artifact integrity using the [security self-audit guide in `README.md`](README.md). We do not ask you to trust us.
3. **Modify.** Change the code, the engine scheduling, the web console front end or the packaging script. No notification required.
4. **Redistribute.** Verbatim or modified copies may be redistributed, provided you keep distributing the complete corresponding source under AGPL-3.0 (this repository already is that source).
5. **Operate your own infrastructure.** The repository contains the entire local execution stack. You may run purely on the open-source side, host your own `popopx-chat` (upstream `simplex-chat`) queues and your own SMP servers, and never touch a single closed service of ours.
6. **Packaging and release tooling.** `Scripts/build_dmg.sh` and `.github/workflows/release.yml` are part of the open-source grant and are reusable in your own fork — your own bundles, your own Releases.

In short: **everything that executes on hardware you own belongs to you.**

## 2. AGPL-3.0 section 13: the network-service copyleft clause

This clause is widely misunderstood, so we state only the legal mechanics — no threats.

The single substantive difference between GPL and AGPL is **section 13 (Remote Network Interaction)**:

> If you modify the Program, and the Program gives users a means of interacting with it remotely over a computer network, you must offer those users a way to get the corresponding source of your modified version.

Applied to this project:

- **Purely personal or internal use** → section 13 is not engaged. You may modify this repository and keep the modifications private, with **no obligation** to publish them.
- **Offering the node (original or modified) as a network service to other people** → section 13 is engaged. You must provide the **complete corresponding source of your modified version** to the users of that service, still under AGPL-3.0. Typical case: racking the node in a data centre and selling access to it, per-use or subscription.
- **What if you do not want to publish the source?** There are exactly two routes: (a) do not offer it as a network service; (b) take a **commercial closed-source licence** (sections 3 and 4). That is the whole economic model of dual licensing — you either trade the compliance cost of section 13 for free use, or you pay to be relieved of it.

Three clarifications:

1. Section 13 **is part of AGPL-3.0 itself**, not an extra restriction bolted on by us. Every byte you take from this repository already carries it.
2. It **does not reach your separate business code** sitting next to the node: your private front end, your private keys, your user data and the private content you push over the SMP queue do not become open source because of it.
3. It **does not create a source-publishing duty for unmodified deployments**: the obligation in section 13 concerns *your modified version*; if you modify nothing, that duty does not arise — while AGPL's redistribution terms continue to apply to any copies you distribute.

If you are assessing whether your own deployment model engages section 13, read [`LICENSE`](LICENSE) itself and consult your own lawyer.

## 3. What requires a commercial closed-source licence

The following are **outside** the AGPL grant and require written authorisation before use:

1. **Access to the POPOPX global private high-speed SMP/XFTP relay cluster**
   Our operated cross-region, multi-availability-zone relay and queue high-availability infrastructure: private routing, interference-resistant transport scheduling, multi-line redundancy, traversal optimisation and SLA commitments. The open-source node works fine against self-hosted queues — it simply does not include access to this hosted cluster.
2. **The blind-signed compute-point settlement protocol**
   The settlement layer that `edge_compute_mesh` and `creator_paywall_hub` rely on commercially: blind-signature protocol, double-spend prevention rules, redemption and reconciliation interfaces, dispute-arbitration data formats. The open-source part implements **local accounting and sandboxed execution only**; it contains no cross-node settlement root of trust.
3. **The anti-collusion invisible fingerprinting algorithm SDK**
   Production-grade anti-collusion fingerprinting for `zero_trust_warroom` / `creator_paywall_hub`: fingerprint encodings robust to coalitions of recipients, reverse attribution services, model/parameter and engineering implementations. The repository ships a compilable, auditable baseline watermarking and extraction pipeline; the higher-collusion-resistance implementation is licensed as an SDK.
4. **The POPOPX name, logo, domains and brand assets**
   See section 5. **The AGPL grant contains no trademark licence whatsoever.**
5. **iOS App Store companion distribution**
   The official POPOPX iOS client, its "Discover" service entries, the App Store publisher identity and the update channel. You may write a compatible client for your own fork and publish it yourself, but not under our name or marks and not implying an official pairing.

## 4. Licence tiers

**Contact sales for pricing.** The table below describes capability boundaries, not a price list; this document deliberately prints no figures.

| Capability | Community | Indie | Studio | Enterprise |
| --- | --- | --- | --- | --- |
| Full source of this repository (AGPL-3.0) | ✅ | ✅ | ✅ | ✅ |
| All 10 local engines, web console, SSE log stream | ✅ | ✅ | ✅ | ✅ |
| Self-hosted `popopx-chat` queues (SMP/XFTP) | ✅ | ✅ | ✅ | ✅ |
| `build_dmg.sh` self-packaging / own CI | ✅ | ✅ | ✅ | ✅ |
| Official global private SMP/XFTP relay access | ❌ | 1 access quota | team quota | dedicated capacity + nearby ingress |
| Blind-signed compute-point settlement | ❌ (local ledger only) | read-only queries | ✅ settlement access | ✅ settlement + reconciliation API |
| Anti-collusion invisible fingerprinting SDK | ❌ | evaluation only (no commercial distribution) | ✅ commercial licence | ✅ commercial + escrowed source audit |
| Official iOS companion distribution channel | ❌ | ❌ | allow-listed access | ✅ official listing and update channel |
| Right to use the POPOPX brand and marks | ❌ | ❌ | ❌ | separate brand licence required |
| Support | community issues, no SLA | e-mail, best effort | prioritised business-day response | dedicated channel + agreed SLA |
| Contract, invoice, compliance paperwork | ❌ | ✅ | ✅ | ✅ |

How to choose:

- **Just using it yourself** → Community. Nothing to buy, nothing to sign.
- **A one-person studio that needs cross-network availability and compute-point settlement** → Indie.
- **A team shipping content externally, needing production-grade anti-piracy and stable relays** → Studio.
- **Embedding this into your own commercial product, or offering it as a service while unwilling to take on the AGPL §13 source obligation** → Enterprise (and re-read section 2 while planning your compliance path).

## 5. Trademark policy

1. `POPOPX`, `POPOPX Mac Node` and `POPOPX Chat`, together with their names, logos, icons, domains and spelling variants, are trademarks or trade dress of POPOPX Chat.
2. **AGPL-3.0 grants a copyright licence, not a trademark licence.** These are legally independent, and the LICENSE file in this repository never grants you any right to use our brand.
3. Therefore:
   - ✅ you may say "a fork of POPOPX Mac Node" or "compatible with POPOPX Mac Node" (truthfully and non-deceptively);
   - ✅ you may distribute your own build **renamed and re-logoed**;
   - ❌ you may not name your distribution POPOPX, use the purple shield mark, or present it as official;
   - ❌ you may not use "POPOPX" as your product name, company name, domain or App Store listing name.
4. Brand usage requires a separate written brand licence (available as an application channel on the Enterprise tier).

## 6. Why dual licensing

The position of POPOPX Mac Node is: **users should own and audit their own compute layer, and whoever operates the cross-region high-availability infrastructure should get paid for it.**

A closed-only build means you can never verify that "zero cloud" is more than marketing. An AGPL-only build leaves the global relay cluster, the settlement root of trust and the anti-collusion fingerprint research with no funding — so it either stops, or it monetises your data. We reject both: **the core stays auditable, the infrastructure stays billable.**

Within this model AGPL-3.0 does two jobs: (1) any change other people make to this layer must flow back to everyone else using the same code; (2) wrapping somebody else's open project directly into a hosted resale offering means either publishing the source or paying for a licence. It does not punish people who run it themselves, and it does not punish researchers — those two groups never pay, and never will.

## 7. Contact

- **Licensing and commercial enquiries (the licensing contact)**: `licensing@popopx.chat`
  In your message, please state: intended use (personal / internal / offered as a service), expected node count and deployment topology, whether AGPL §13 is engaged, and which tier plus what compliance paperwork you need.
- Open-source collaboration, bugs and feature requests belong in [GitHub Issues](https://github.com/popopx-chat/popopx-mac-node/issues) — please do not negotiate licensing there.

## 8. Disclaimer

- **This document is not legal advice**, and it is not a contract. Your actual rights and obligations are defined by the written licence agreement you separately execute with POPOPX Chat.
- Where this document and [`LICENSE`](LICENSE) appear to conflict: rights inside the AGPL grant are governed by `LICENSE`; rights inside the commercial grant are governed by the signed agreement.
- This document may change with new versions; the applicable text is the one in the version you actually take.
- **Copyright (C) 2026 POPOPX Chat.**

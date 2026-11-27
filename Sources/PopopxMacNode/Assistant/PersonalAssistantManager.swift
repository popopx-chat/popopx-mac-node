//
//  PersonalAssistantManager.swift
//  PopopxMacNode — the assistant's front door and its composition.
//
//  The manager is where the four pieces meet:
//
//    LocalTaskScheduler ── when
//    MailAssistantBridge ── read / draft / send
//    HomeSentinelLoop ───── watch / propose / repair
//    AssistantApprovalGate ─ one receipt-bound approval for every write
//
//  It owns no policy of its own beyond ordering: the gate decides whether a write
//  is authorized, the mail bridge and sentinel decide whether their slice of the
//  world is enabled, and the scheduler decides when a job is due. The manager's
//  job is to turn their answers into one console snapshot and one phone card.
//

import Foundation

public actor PersonalAssistantManager {
    public typealias Delivery = @Sendable (CommandResult) async -> Bool

    private var config: AssistantConfig
    private var privacy: PrivacyBridgeConfig
    private var hub: HubConfig
    private var godsEyeEnabled: Bool
    private let secrets: HubSecretStoring
    private let gate: AssistantApprovalGate
    private let store: AssistantAuditStore
    private let scheduler: LocalTaskScheduler
    private let mail: MailAssistantBridge
    private let sentinel: HomeSentinelLoop
    private let inkling: Inkling2MiniAdapter?
    private let rag: LocalEpisodicRAG?
    private let voice: LocalVoiceMemoPipeline?
    private let clock: AssistantClock
    private let deliver: Delivery

    private var handlersInstalled = false
    private var pushed: Set<String> = []
    private var lastReport = ""
    /// The owner's zero-model switch. Node-level, so it is set from the console
    /// facade rather than from `AssistantConfig`: the assistant keeps running its
    /// deterministic half while every model call is refused before it is made.
    private var lightweight = false

    public init(
        config: AssistantConfig,
        privacy: PrivacyBridgeConfig,
        hub: HubConfig,
        godsEyeEnabled: Bool,
        secrets: HubSecretStoring,
        gate: AssistantApprovalGate,
        store: AssistantAuditStore,
        scheduler: LocalTaskScheduler,
        mail: MailAssistantBridge,
        sentinel: HomeSentinelLoop,
        inkling: Inkling2MiniAdapter? = nil,
        rag: LocalEpisodicRAG? = nil,
        voice: LocalVoiceMemoPipeline? = nil,
        clock: AssistantClock = SystemAssistantClock(),
        deliver: @escaping Delivery
    ) {
        self.config = config.normalised
        self.privacy = privacy
        self.hub = hub
        self.godsEyeEnabled = godsEyeEnabled
        self.secrets = secrets
        self.gate = gate
        self.store = store
        self.scheduler = scheduler
        self.mail = mail
        self.sentinel = sentinel
        self.inkling = inkling
        self.rag = rag
        self.voice = voice
        self.clock = clock
        self.deliver = deliver
    }

    // MARK: - Lifecycle

    public func start() async {
        await ensureHandlers()
        guard config.enabled, config.briefing.enabled || config.patrol.enabled else { return }
        await scheduler.start()
    }

    public func stop() async {
        await scheduler.stop()
    }

    public func apply(
        config next: AssistantConfig,
        privacy nextPrivacy: PrivacyBridgeConfig? = nil,
        hub nextHub: HubConfig? = nil,
        godsEyeEnabled nextGodsEye: Bool? = nil,
        now: Date? = nil
    ) async {
        let moment = now ?? clock.now
        let before = config
        let normalised = next.normalised
        config = normalised
        if let nextPrivacy { privacy = nextPrivacy }
        if let nextHub { hub = nextHub }
        if let nextGodsEye { godsEyeEnabled = nextGodsEye }

        let connectorChanged = before.mail != normalised.mail || before.repairs != normalised.repairs
        if connectorChanged || !normalised.enabled {
            let cancelled = await gate.cancelPending(reason: normalised.enabled ? "assistant configuration changed" : "assistant switched off", now: moment)
            if cancelled > 0 {
                await store.record(channel: "assistant", event: "pending_cancelled", detail: "\(cancelled) proposals", outcome: "rejected", at: moment)
            }
            pushed.removeAll()
        }
        if before.enabled != normalised.enabled {
            await store.record(
                channel: "assistant",
                event: normalised.enabled ? "enabled" : "disabled",
                detail: "owner switch",
                at: moment
            )
        }
        await scheduler.update(config: normalised, now: moment)
        await mail.update(config: normalised.mail)
        await sentinel.update(config: normalised)
        await syncInkling()
        if !normalised.mail.enabled { await mail.reset() }
        if !normalised.enabled {
            await scheduler.stop()
            await mail.reset()
            await sentinel.reset()
        } else if normalised.briefing.enabled || normalised.patrol.enabled {
            await ensureHandlers()
            await scheduler.start()
        }
        await recordConnectorSummary(now: moment)
    }

    /// The test and console one-shot. Installs the handlers without starting the
    /// background loop, then asks the scheduler which jobs are due at `now`.
    public func tickNow(now: Date? = nil) async {
        await ensureHandlers()
        await syncInkling()
        await scheduler.tick(now: now)
    }

    /// Flips the zero-model mode. The switch is idempotent, and the classifier is
    /// re-bound here so a running triage loop stops handing snippets to the model
    /// the moment the owner flips it.
    public func setLightweight(_ value: Bool, now: Date? = nil) async {
        let moment = now ?? clock.now
        guard value != lightweight else { return }
        lightweight = value
        await store.record(
            channel: "assistant",
            event: value ? "lightweight_on" : "lightweight_off",
            detail: value ? "zero-model mode" : "local model use re-enabled",
            at: moment
        )
        await syncInkling()
    }

    public func schedulerStatus(now: Date? = nil) async -> AssistantSchedulerCard {
        await scheduler.status(now: now)
    }

    // MARK: - Briefing and patrol

    /// The daily briefing handler. Mail triage first, then a home scan, then one
    /// card plus one approval card per draft. The card is delivered over the paired
    /// E2E session; a failed delivery is audited, not hidden.
    public func runBriefing(now: Date? = nil) async -> String {
        let moment = now ?? clock.now
        guard config.enabled else { return "私人助手未开启 / the assistant is off" }
        await syncInkling()
        var lines: [String] = []
        var draftCount = 0

        if config.mail.enabled {
            let triage = await mail.triage(now: moment)
            await index(triage: triage.messages, now: moment)
            let counts = Dictionary(grouping: triage.messages, by: { $0.category })
                .mapValues(\.count)
            lines.append("邮件：待回复 \(counts[.needsReply] ?? 0) · 账单 \(counts[.bill] ?? 0) · 邀请 \(counts[.invitation] ?? 0) · 通知 \(counts[.notification] ?? 0)")
            for message in triage.messages.prefix(5) {
                var row = "· [\(message.category.labelZh)] \(message.subject)"
                if !message.amount.isEmpty { row += " · \(message.amount)" }
                if !message.deadline.isEmpty { row += " · 截止 \(message.deadline)" }
                lines.append(String(row.prefix(180)))
            }
            let proposals = await propose(drafts: Array(triage.drafts.prefix(3)), now: moment)
            draftCount = proposals
            if proposals > 0 { lines.append("回复草稿：\(proposals) 封，已推送到手机等待批准") }
            if !triage.summaryLines.isEmpty { lines.append(contentsOf: triage.summaryLines.prefix(2)) }
        } else {
            lines.append("邮件：未启用")
        }

        if config.patrol.enabled {
            let report = await sentinel.scan(now: moment)
            lines.append("设备巡检：\(report.anomalies.count) 项异常 · \(report.proposed) 项待审批")
            for anomaly in report.anomalies.prefix(4) {
                lines.append("· \(anomaly.display.isEmpty ? anomaly.entityID : anomaly.display)：\(anomaly.state)")
            }
        } else {
            lines.append("设备巡检：未启用")
        }

        lines.append(contentsOf: await ticketLines(now: moment))

        await pushPending(now: moment, limit: 2)
        let facts = lines.joined(separator: "\n")
        var body = facts
        var inklingUsed = false
        var inklingRuntime = ""
        if let synthesized = await synthesizeBriefing(facts: facts, now: moment) {
            body = synthesized.text
            inklingUsed = true
            inklingRuntime = synthesized.runtime
        }
        await rag?.recordBriefing(body, now: moment)
        let delivered = await push(
            headline: "私人助手简报 · \(stamp(moment))",
            body: body,
            metrics: [
                "briefing": .bool(true),
                "drafts": .int(draftCount),
                "connectors": .int(connectors(now: moment).filter(\.enabled).count),
                "inkling": .bool(inklingUsed),
                "inkling_runtime": .string(inklingRuntime)
            ],
            now: moment
        )
        lastReport = body
        await store.record(
            channel: "assistant",
            event: "briefing",
            detail: "drafts \(draftCount) · delivered \(delivered ? "yes" : "no") · \(body.count) chars",
            outcome: delivered ? "ok" : "delivery_failed",
            at: moment
        )
        return "简报已生成 / briefing ready · drafts \(draftCount)"
    }

    /// The patrol handler. It only reports and proposes; no repair is attempted.
    public func runPatrol(now: Date? = nil) async -> String {
        let moment = now ?? clock.now
        guard config.enabled else { return "私人助手未开启 / the assistant is off" }
        guard config.patrol.enabled else { return "巡检未开启 / the patrol is off" }
        let report = await sentinel.scan(now: moment)
        var lines: [String] = [
            "扫描 \(report.anomalies.count) 项异常 · 新建 \(report.proposed) 项修复提案"
        ]
        for anomaly in report.anomalies.prefix(6) {
            lines.append("· \(anomaly.display.isEmpty ? anomaly.entityID : anomaly.display)：\(anomaly.state) · \(max(1, anomaly.offlineSeconds / 60)) 分钟")
        }
        if !report.skipped.isEmpty {
            lines.append("跳过：" + report.skipped.prefix(3).joined(separator: " · "))
        }
        await pushPending(now: moment, limit: 3)
        let body = lines.joined(separator: "\n")
        await rag?.recordPatrol(body, anomalies: report.anomalies.count, now: moment)
        let delivered = await push(
            headline: "家庭设备巡检 · \(report.anomalies.count) 项异常",
            body: body,
            metrics: [
                "patrol": .bool(true),
                "anomalies": .int(report.anomalies.count),
                "proposed": .int(report.proposed)
            ],
            now: moment
        )
        lastReport = body
        await store.record(
            channel: "assistant",
            event: "patrol",
            detail: "anomalies \(report.anomalies.count) · proposed \(report.proposed) · delivered \(delivered ? "yes" : "no")",
            outcome: delivered ? "ok" : "delivery_failed",
            at: moment
        )
        return "巡检完成 / patrol done · \(report.anomalies.count) anomalies · \(report.proposed) proposed"
    }

    // MARK: - Mail actions

    /// Read-only triage on demand, with the same draft proposals the briefing makes.
    public func refreshMail(now: Date? = nil) async -> String {
        let moment = now ?? clock.now
        guard config.enabled, config.mail.enabled else { return "邮件助手未启用 / mail is off" }
        await syncInkling()
        let triage = await mail.triage(now: moment)
        await index(triage: triage.messages, now: moment)
        let proposed = await propose(drafts: Array(triage.drafts.prefix(3)), now: moment)
        await pushPending(now: moment, limit: 3)
        return "邮件 \(triage.messages.count) 封 · 草稿提案 \(proposed) 封"
    }

    /// Wraps drafts in gate proposals and pushes each card. The draft body is held
    /// by the mail bridge, never by the card.
    @discardableResult
    public func propose(drafts: [MailOutgoingDraft], now: Date? = nil) async -> Int {
        let moment = now ?? clock.now
        var count = 0
        for draft in drafts {
            guard let ticket = await mail.propose(draft: draft, now: moment) else { continue }
            count += 1
            pushed.insert(ticket.proposalID)
            await pushApprovalCard(ticket, now: moment)
        }
        return count
    }

    // MARK: - Approval

    /// The only road to execution. Both the console and the phone arrive here with
    /// an id and a receipt; the gate validates the receipt against the binding, and
    /// then the relevant executor revalidates before doing I/O.
    public func decide(
        proposalID: String,
        verb: String,
        receipt: String,
        now: Date? = nil
    ) async -> AssistantDecisionReport {
        let moment = now ?? clock.now
        let cleanVerb = verb.lowercased()
        do {
            _ = try await gate.decide(id: proposalID, verb: cleanVerb, receipt: receipt, now: moment)
        } catch {
            let detail = AssistantRedaction.scrub(String(describing: error))
            await store.record(channel: "assistant", event: "decision_refused", detail: "\(proposalID.prefix(8)) · \(detail)", outcome: "refused", at: moment)
            return AssistantDecisionReport(ok: false, outcome: "refused", detail: detail, assistant: await snapshot(now: moment))
        }
        if cleanVerb == "reject" {
            await store.record(channel: "assistant", event: "rejected", detail: proposalID, outcome: "rejected", at: moment)
            return AssistantDecisionReport(ok: true, outcome: "rejected", detail: "已驳回 / rejected", assistant: await snapshot(now: moment))
        }
        guard let binding = await gate.binding(id: proposalID) else {
            return AssistantDecisionReport(ok: false, outcome: "unknown", detail: "提案不存在 / unknown proposal", assistant: await snapshot(now: moment))
        }

        let approval = AssistantApproval(proposalID: proposalID, receipt: receipt)
        let detail: String
        let ok: Bool
        switch binding.kind {
        case .mailSend:
            guard let draft = await mail.draft(id: proposalID) else {
                await gate.complete(id: proposalID, ok: false, detail: "draft missing", now: moment)
                ok = false
                detail = "草稿不存在 / the draft is gone"
                break
            }
            let outcome = await mail.sendApproved(draft, approval: approval, now: moment)
            ok = outcome.ok
            detail = outcome.detail
        case .homeService:
            let outcome = await sentinel.perform(proposalID: proposalID, approval: approval, now: moment)
            ok = outcome.ok
            detail = outcome.detail
        case .voiceTask:
            guard let voice else {
                await gate.complete(id: proposalID, ok: false, detail: "voice pipeline missing", now: moment)
                ok = false
                detail = "语音管线不存在 / the voice pipeline is missing"
                break
            }
            do {
                _ = try await gate.validateExecution(
                    id: proposalID,
                    receipt: receipt,
                    kind: .voiceTask,
                    target: binding.target,
                    digest: binding.digest,
                    now: moment
                )
                let outcome = await voice.perform(target: binding.target, binding: binding, now: moment)
                ok = outcome.ok
                detail = outcome.detail
                await gate.complete(id: proposalID, ok: ok, detail: detail, now: moment)
            } catch {
                let reason = AssistantRedaction.scrub(String(describing: error))
                await gate.complete(id: proposalID, ok: false, detail: reason, now: moment)
                ok = false
                detail = reason
            }
        }
        await store.record(
            channel: "assistant",
            event: ok ? "executed" : "execution_failed",
            detail: "\(binding.kind.rawValue) · \(binding.target) · \(detail)",
            outcome: ok ? "ok" : "failed",
            at: moment
        )
        if ok { pushed.remove(proposalID) }
        _ = await push(
            headline: "私人助手 · \(ok ? "已执行" : "执行失败") · \(binding.kind.labelZh)",
            body: "\(binding.kind.labelZh)\n目标：\(binding.target)\n结果：\(detail)",
            metrics: ["approved": .bool(true), "executed": .bool(ok)],
            now: moment
        )
        return AssistantDecisionReport(
            ok: ok,
            outcome: ok ? "executed" : "failed",
            detail: detail,
            assistant: await snapshot(now: moment)
        )
    }

    /// The console's click. The page sends only an id and a verb; the receipt is
    /// minted inside the node, so no poll payload carries a write capability.
    public func consoleDecide(proposalID: String, verb: String, now: Date? = nil) async -> AssistantDecisionReport {
        let moment = now ?? clock.now
        guard let receipt = await gate.receipt(id: proposalID, now: moment) else {
            return AssistantDecisionReport(
                ok: false,
                outcome: "refused",
                detail: "提案不存在或已过期 / unknown or expired proposal",
                assistant: await snapshot(now: moment)
            )
        }
        return await decide(proposalID: proposalID, verb: verb, receipt: receipt, now: moment)
    }

    public func pending(now: Date? = nil) async -> [AssistantProposalCard] {
        await gate.pending(now: now)
    }

    // MARK: - Credentials

    /// Stores one mail password. The reply is the reference; the value is never
    /// echoed and never written to the audit row.
    public func storeMailCredential(kind: String, secret: String, now: Date? = nil) async -> AssistantCredentialReport {
        let moment = now ?? clock.now
        let clean = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reference: String
        switch clean {
        case "imap": reference = config.mail.imapPasswordRef
        case "smtp": reference = config.mail.smtpPasswordRef
        default:
            return AssistantCredentialReport(
                ok: false,
                detail: "凭据类别需为 imap 或 smtp / kind must be imap or smtp",
                reference: "",
                assistant: await snapshot(now: moment)
            )
        }
        guard !secret.isEmpty, secret.utf8.count <= HubSecrets.maximumSecretLength else {
            await store.record(channel: "assistant", event: "credential_refused", detail: "\(clean): empty or too long", outcome: "refused", at: moment)
            return AssistantCredentialReport(
                ok: false,
                detail: "凭据为空或过长 / empty or too long",
                reference: "",
                assistant: await snapshot(now: moment)
            )
        }
        let stored = secrets.store(secret, for: reference)
        await store.record(
            channel: "assistant",
            event: stored ? "credential_stored" : "credential_refused",
            detail: "\(clean) → \(reference)",
            outcome: stored ? "ok" : "refused",
            at: moment
        )
        return AssistantCredentialReport(
            ok: stored,
            detail: stored ? "已存入钥匙串 / stored" : "钥匙串写入失败 / the credential store refused",
            reference: stored ? reference : "",
            assistant: await snapshot(now: moment)
        )
    }

    // MARK: - Control

    public func control(verb: String, now: Date? = nil) async -> AssistantControlReport {
        let moment = now ?? clock.now
        let clean = verb.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.enabled else {
            return .refused("私人助手未开启 / the assistant is off", snapshot: await snapshot(now: moment))
        }
        switch clean {
        case "briefingNow":
            guard config.briefing.enabled else {
                return .refused("简报未开启 / the briefing is off", snapshot: await snapshot(now: moment))
            }
            await ensureHandlers()
            let detail = await scheduler.runBriefingNow(now: moment)
            return AssistantControlReport(ok: true, outcome: "briefing", detail: detail, assistant: await snapshot(now: moment))
        case "patrolNow":
            guard config.patrol.enabled else {
                return .refused("巡检未开启 / the patrol is off", snapshot: await snapshot(now: moment))
            }
            await ensureHandlers()
            let detail = await scheduler.runPatrolNow(now: moment)
            return AssistantControlReport(ok: true, outcome: "patrol", detail: detail, assistant: await snapshot(now: moment))
        case "refreshMail", "proposeDrafts":
            guard config.mail.enabled else {
                return .refused("邮件助手未开启 / mail is off", snapshot: await snapshot(now: moment))
            }
            let detail = await refreshMail(now: moment)
            return AssistantControlReport(ok: true, outcome: "mail", detail: detail, assistant: await snapshot(now: moment))
        case "inklingProbe":
            guard !lightweight else {
                return .refused("纯轻量模式不运行本机模型 / lightweight mode runs no local model", snapshot: await snapshot(now: moment))
            }
            guard let inkling else {
                return .refused("本机未装配本地模型适配器 / no local model adapter", snapshot: await snapshot(now: moment))
            }
            let card = await inkling.probe(now: moment)
            let ok = card.state == .ready
            return AssistantControlReport(
                ok: ok,
                outcome: "inkling",
                detail: card.lastDetail,
                assistant: await snapshot(now: moment)
            )
        case "indexHistory", "indexRAG":
            guard let rag else {
                return .refused("本地索引未装配 / no local index", snapshot: await snapshot(now: moment))
            }
            let roots = privacy.allowWorkspaceRead ? privacy.workspaceDirectories : []
            guard !roots.isEmpty else {
                return .refused("没有授权目录 / no authorized scope roots", snapshot: await snapshot(now: moment))
            }
            let report = await rag.indexScopeRoots(roots)
            await store.record(
                channel: "assistant",
                event: "rag_index",
                detail: "indexed \(report.indexed) · skipped \(report.skipped)",
                outcome: report.ok ? "ok" : "failed",
                at: moment
            )
            return AssistantControlReport(ok: report.ok, outcome: "rag", detail: report.detail, assistant: await snapshot(now: moment))
        case "cancelPending":
            let cancelled = await gate.cancelPending(reason: "owner cancelled from the console", now: moment)
            pushed.removeAll()
            await store.record(channel: "assistant", event: "cancelled", detail: "\(cancelled) proposals", at: moment)
            return AssistantControlReport(
                ok: true,
                outcome: "cancelled",
                detail: "已撤销 \(cancelled) 项待审批 / cancelled \(cancelled) proposals",
                assistant: await snapshot(now: moment)
            )
        default:
            return .refused("未知控制指令 / unknown control verb: \(clean)", snapshot: await snapshot(now: moment))
        }
    }

    // MARK: - Memory and voice

    /// Natural-language recall over the sealed local index. The answer is assembled
    /// from retrieved snippets; the local model is not allowed to invent a citation.
    public func askHistory(_ question: String, now: Date? = nil) async -> EpisodicAnswer {
        guard let rag else {
            return EpisodicAnswer(
                ok: false,
                question: question,
                answer: "本地索引未装配 / the local index is not assembled"
            )
        }
        let answer = await rag.ask(question)
        await store.record(
            channel: "assistant",
            event: "rag_query",
            detail: "chars \(question.count) · citations \(answer.citations.count)",
            outcome: answer.ok ? "ok" : "failed",
            at: now ?? clock.now
        )
        return answer
    }

    public func indexHistory(now: Date? = nil) async -> EpisodicIndexReport {
        let moment = now ?? clock.now
        guard let rag else {
            return EpisodicIndexReport(
                ok: false,
                indexed: 0,
                skipped: 0,
                detail: "本地索引未装配 / the local index is not assembled",
                card: .empty
            )
        }
        let roots = privacy.allowWorkspaceRead ? privacy.workspaceDirectories : []
        let report = await rag.indexScopeRoots(roots)
        await store.record(
            channel: "assistant",
            event: "rag_index",
            detail: "indexed \(report.indexed) · skipped \(report.skipped)",
            outcome: report.ok ? "ok" : "failed",
            at: moment
        )
        return report
    }

    /// Phone audio enters only through the quarantine path the bridge chose. The
    /// pipeline transcribes and extracts; this method turns each action into a
    /// receipt-bound proposal and pushes the card, exactly like a mail draft.
    public func handleVoiceMemo(audioURL: URL, now: Date? = nil) async -> VoiceIngestReport {
        let moment = now ?? clock.now
        guard config.enabled else {
            return VoiceIngestReport(ok: false, detail: "私人助手未开启 / the assistant is off")
        }
        guard let voice else {
            return VoiceIngestReport(ok: false, detail: "语音管线未装配 / the voice pipeline is absent")
        }
        let report = await voice.ingest(audioURL: audioURL, now: moment)
        guard report.ok else {
            await store.record(
                channel: "voice",
                event: "ingest_failed",
                detail: report.detail,
                outcome: "failed",
                at: moment
            )
            return report
        }
        var proposed = 0
        for action in report.actions {
            if await gate.hasPending(kind: .voiceTask, target: action.target, now: moment) { continue }
            do {
                let ticket = try await gate.propose(
                    kind: .voiceTask,
                    target: action.target,
                    digest: action.digest,
                    title: "语音待办 · \(action.title)",
                    detail: action.detail,
                    now: moment
                )
                proposed += 1
                pushed.insert(ticket.proposalID)
                await pushApprovalCard(ticket, now: moment)
            } catch {
                await store.record(
                    channel: "voice",
                    event: "proposal_refused",
                    detail: "\(action.target) · \(AssistantRedaction.scrub(String(describing: error)))",
                    outcome: "refused",
                    at: moment
                )
            }
        }
        guard !report.actions.isEmpty else {
            await store.record(
                channel: "voice",
                event: "no_actions",
                detail: "chars \(report.transcriptCharacters)",
                outcome: "ok",
                at: moment
            )
            return report
        }
        await store.record(
            channel: "voice",
            event: "actions_proposed",
            detail: "\(proposed) proposals · \(report.actions.count) actions",
            outcome: proposed > 0 ? "ok" : "refused",
            at: moment
        )
        return VoiceIngestReport(
            ok: report.ok,
            detail: proposed > 0
                ? "\(report.detail) · \(proposed) 项已推送待批准 / \(proposed) approval cards sent"
                : report.detail,
            engine: report.engine,
            onDevice: report.onDevice,
            transcriptCharacters: report.transcriptCharacters,
            actions: report.actions,
            audioHash: report.audioHash,
            boundary: report.boundary
        )
    }

    // MARK: - Snapshot

    public func snapshot(now: Date? = nil) async -> AssistantSnapshot {
        let moment = now ?? clock.now
        var inklingCard = await inkling?.card(now: moment) ?? AssistantInklingCard.saved(config.inkling)
        if lightweight {
            // The cached probe may still say "ready" from before the switch; the
            // card must not claim a model the node has been told not to use.
            inklingCard.state = .off
            inklingCard.lastDetail = "纯轻量模式 · 本机模型不参与 / lightweight mode · the local model is not used"
        }
        return AssistantSnapshot(
            enabled: config.enabled,
            scheduler: await scheduler.status(now: moment),
            mail: await mail.status(),
            connectors: connectors(now: moment),
            pending: await gate.pending(now: moment),
            drafts: await mail.draftCards(),
            audit: await store.recent(limit: AssistantAuditStore.snapshotEntries),
            boundary: "执行层 HMAC 审批回执 · 127.0.0.1 控制台 · 邮件为唯一命名外部出口 / executor HMAC receipts · loopback console · mail is the one named egress exception",
            lastReport: lastReport,
            updatedAt: moment,
            inkling: inklingCard,
            rag: await rag?.status() ?? .empty,
            voice: await voice?.card() ?? .empty
        )
    }

    public func auditRows(limit: Int = 20) async -> [AssistantAuditRow] {
        await store.recent(limit: limit)
    }

    // MARK: - Internals

    /// Pushes the saved switchboard and the workspace roots into the adapter, then
    /// binds the model to mail triage. Called on every entry point rather than only
    /// in `apply`, so a manager built directly by a test or the console's one-shot
    /// path still gets the owner's current settings.
    /// Summaries only: category, subject, amount, deadline and the bridge's own
/// snippet. The full body is never handed to the index.
    private func index(triage: [AssistantMailMessageCard], now: Date) async {
        guard let rag else { return }
        for message in triage {
            if message.category == .bill {
                await rag.recordBill(
                    merchant: message.from,
                    amount: message.amount,
                    due: message.deadline,
                    summary: message.subject,
                    source: "mail/\(message.id)",
                    now: now
                )
            } else {
                let body = [
                    "类别：\(message.category.rawValue)",
                    message.amount.isEmpty ? "" : "金额：\(message.amount)",
                    message.deadline.isEmpty ? "" : "截止：\(message.deadline)",
                    message.snippet
                ].filter { !$0.isEmpty }.joined(separator: "\n")
                _ = await rag.record(
                    kind: .mailSummary,
                    title: message.subject,
                    body: body,
                    source: "mail/\(message.id)",
                    occurredAt: message.receivedAt
                )
            }
        }
    }

    private func syncInkling() async {
        guard let inkling else { return }
        guard !lightweight else {
            await mail.setClassifier(nil)
            return
        }
        await inkling.update(
            config: config.inkling,
            scopeRoots: privacy.allowWorkspaceRead ? privacy.workspaceDirectories : []
        )
        await mail.setClassifier(InklingMailClassifier(adapter: inkling))
    }

    /// The multimodal slice of the briefing. A ticket is read only when its path is
    /// inside an authorized workspace root; every extraction is a suggestion for
    /// the briefing, never a write.
    private func ticketLines(now: Date) async -> [String] {
        guard !lightweight, let inkling, config.inkling.allowMultimodal, !config.inkling.ticketPaths.isEmpty else { return [] }
        guard await inkling.isReady(now: now) else {
            return ["票据：本机 Inkling 2 Mini 未就绪，已跳过 / tickets skipped: the local model is not ready"]
        }
        var lines = ["票据：已指定 \(config.inkling.ticketPaths.count) 份 / \(config.inkling.ticketPaths.count) named"]
        var recognized = 0
        for path in config.inkling.ticketPaths.prefix(3) {
            let analysis = await inkling.analyzeLocalMedia(path: path, now: now)
            guard analysis.ok, let extraction = analysis.extraction else {
                lines.append("· \(analysis.file)：\(String(analysis.degradedReason.prefix(80)))")
                continue
            }
            recognized += 1
            await rag?.recordBill(
                merchant: extraction.merchant,
                amount: extraction.amount,
                due: extraction.dueDate,
                summary: extraction.summary,
                source: "ticket/\(analysis.file)",
                now: now
            )
            var row = "· 票据：\(extraction.merchant.isEmpty ? analysis.file : String(extraction.merchant.prefix(40)))"
            if !extraction.amount.isEmpty { row += " · \(String(extraction.amount.prefix(24)))" }
            if !extraction.dueDate.isEmpty { row += " · 到期 \(String(extraction.dueDate.prefix(20)))" }
            if !extraction.summary.isEmpty { row += " · \(String(extraction.summary.prefix(60)))" }
            lines.append(row)
        }
        lines[0] = "票据：已识别 \(recognized) 份 / \(recognized) recognized"
        return lines
    }

    /// Asks the local model to turn the deterministic facts into one dense briefing,
    /// and falls back to those facts verbatim when it is absent, slow or malformed.
    private func synthesizeBriefing(facts: String, now: Date) async -> (text: String, runtime: String)? {
        guard !lightweight, let inkling, config.inkling.structuredJSON else { return nil }
        let generation = await inkling.generateStructuredJSON(
            prompt: """
            Turn these owner-only facts into one concise briefing. Return JSON with keys: headline (a short line), \
            summary (two sentences at most), priorities (up to five short strings), anomaly_notes (how each home \
            anomaly likely arose; empty when there are none). Restate only facts present in the input; never invent \
            an event, amount, date or device state.

            FACTS:
            \(facts)
            """,
            schema: Inkling2MiniAdapter.briefingSchema,
            system: Inkling2MiniAdapter.briefingSystem,
            now: now
        )
        guard let value = generation.value?.objectValue else { return nil }
        var pieces: [String] = []
        if let headline = value["headline"]?.stringValue, !headline.isEmpty {
            pieces.append("【\(String(headline.prefix(60)))】")
        }
        if let summary = value["summary"]?.stringValue, !summary.isEmpty {
            pieces.append(String(summary.prefix(240)))
        }
        if let notes = value["anomaly_notes"]?.stringValue, !notes.isEmpty {
            pieces.append("归因：\(String(notes.prefix(200)))")
        }
        for row in (value["priorities"]?.arrayValue ?? []).prefix(5) {
            guard let text = row.stringValue, !text.isEmpty else { continue }
            pieces.append("· \(String(text.prefix(80)))")
        }
        guard !pieces.isEmpty else { return nil }
        pieces.append("————")
        pieces.append(facts)
        return (String(pieces.joined(separator: "\n").prefix(1_750)), generation.runtime)
    }

    private func ensureHandlers() async {
        guard !handlersInstalled else { return }
        await scheduler.setHandlers(
            briefing: { [weak self] now in
                guard let self else { return "assistant unavailable" }
                return await self.runBriefing(now: now)
            },
            patrol: { [weak self] now in
                guard let self else { return "assistant unavailable" }
                return await self.runPatrol(now: now)
            }
        )
        handlersInstalled = true
    }

    private func connectors(now: Date) -> [ConnectorCapability] {
        var rows: [ConnectorCapability] = []
        rows.append(ConnectorCapability(
            kind: .calendar,
            permission: privacy.allowCalendarAccess ? .propose : .read,
            enabled: privacy.allowCalendarAccess,
            ready: privacy.allowCalendarAccess,
            detail: privacy.allowCalendarAccess
                ? "EventKit 只读 + 提案；写日程仍走隐私账本 / read + proposals; writes stay behind the privacy ledger"
                : "未授权 / not authorized"
        ))
        rows.append(ConnectorCapability(
            kind: .calDav,
            permission: hub.allowCalDavBridge ? .propose : .read,
            enabled: hub.allowCalDavBridge,
            ready: hub.allowCalDavBridge,
            detail: hub.allowCalDavBridge
                ? "内网 CalDAV 只读 + 提案 / LAN CalDAV read + proposals"
                : "桥接未启用 / bridge off"
        ))
        let smartHome = hub.smartHome.normalised
        rows.append(ConnectorCapability(
            kind: .smartHome,
            permission: hub.allowSmartHomeBridge ? (smartHome.readOnlyMode ? .read : .write) : .read,
            enabled: hub.allowSmartHomeBridge,
            ready: hub.allowSmartHomeBridge && smartHome.usable,
            detail: hub.allowSmartHomeBridge
                ? (smartHome.readOnlyMode ? "只读模式，巡检可看不可修 / read-only" : "巡检只读；修复须审批 / probing is read-only; repair needs approval")
                : "桥接未启用 / bridge off"
        ))
        rows.append(ConnectorCapability(
            kind: .mcp,
            permission: hub.allowMcpBridge ? .propose : .read,
            enabled: hub.allowMcpBridge,
            ready: hub.allowMcpBridge,
            detail: hub.allowMcpBridge
                ? "工具调用；画布写入仍为待审批 / tool calls; canvas writes stay pending"
                : "桥接未启用 / bridge off"
        ))
        rows.append(ConnectorCapability(
            kind: .godsEye,
            permission: .read,
            enabled: godsEyeEnabled,
            ready: godsEyeEnabled,
            detail: godsEyeEnabled ? "只读工具 / read-only tools" : "未启用 / off"
        ))
        let mailConfig = config.mail
        rows.append(ConnectorCapability(
            kind: .mail,
            permission: mailConfig.usable ? .write : .read,
            enabled: mailConfig.enabled,
            ready: mailConfig.usable && secrets.secret(for: mailConfig.imapPasswordRef) != nil
                && secrets.secret(for: mailConfig.smtpPasswordRef) != nil,
            detail: mailConfig.enabled
                ? "IMAP 只读 + SMTP 经批准发送 / IMAP read-only + SMTP after approval"
                : "未启用 / off"
        ))
        return rows
    }

    private func recordConnectorSummary(now: Date) async {
        let enabled = connectors(now: now).filter(\.enabled).map(\.kind.rawValue).sorted()
        await store.record(
            channel: "assistant",
            event: "connectors",
            detail: enabled.isEmpty ? "none" : enabled.joined(separator: ","),
            at: now
        )
    }

    private func pushApprovalCard(_ ticket: AssistantApprovalTicket, now: Date) async {
        let approve = wire(action: "approve", id: ticket.proposalID, receipt: ticket.receipt)
        let reject = wire(action: "reject", id: ticket.proposalID, receipt: ticket.receipt)
        let body = """
        \(ticket.card.kind.labelZh) · 目标：\(ticket.card.target)
        \(ticket.card.detail)
        摘要：\(ticket.card.digest.prefix(16)) · 有效期 \(ticket.card.secondsLeft)s

        批准：\(approve)
        驳回：\(reject)
        """
        let delivered = await push(
            headline: "待批准 · \(ticket.card.title)",
            body: body,
            metrics: [
                "pending": .bool(true),
                "kind": .string(ticket.card.kind.rawValue),
                "digest": .string(String(ticket.card.digest.prefix(16)))
            ],
            now: now
        )
        await store.record(
            channel: "assistant",
            event: delivered ? "card_delivered" : "card_delivery_failed",
            detail: "\(ticket.card.kind.rawValue) · \(ticket.card.target)",
            outcome: delivered ? "ok" : "delivery_failed",
            at: now
        )
    }

    private func pushPending(now: Date, limit: Int) async {
        guard limit > 0 else { return }
        var sent = 0
        for card in await gate.pending(now: now) {
            if sent >= limit { break }
            if pushed.contains(card.id) { continue }
            guard let ticket = await gate.ticket(id: card.id, now: now) else { continue }
            pushed.insert(card.id)
            sent += 1
            await pushApprovalCard(ticket, now: now)
        }
        if pushed.count > 128 { pushed = Set(pushed.suffix(64)) }
    }

    private func push(headline: String, body: String, metrics: [String: JSONValue], now: Date) async -> Bool {
        let result = CommandResult(
            engine: .shadowCos,
            ok: true,
            deterministic: true,
            headline: headline,
            body: String(body.prefix(1_800)),
            at: now,
            metrics: metrics,
            cardLabel: "POPOPX 私人助手 / Private Assistant"
        )
        return await deliver(result)
    }

    private func wire(action: String, id: String, receipt: String) -> String {
        let payload = "{\"id\":\"\(id)\",\"receipt\":\"\(receipt)\"}"
        return "\(NodeWire.commandPrefix)assistant::\(action)::\(payload)"
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
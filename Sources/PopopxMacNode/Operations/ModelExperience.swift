//
//  ModelExperience.swift
//  POPOPX Mac Node
//
//  The zero-terminal experience layer:
//
//  * `ModelPullCenter` drives one `POST /api/pull` stream at a time against the
//    loopback Ollama daemon and reports percent / bytes / readiness. It never
//    names a remote registry: the owner's own Ollama is the only downloader, and
//    the node packages no weights.
//  * `LightweightModePlan` is the explicit zero-model mode: every deterministic
//    feature that keeps working is listed by name, and the model-only rows say
//    they are off rather than silently disappearing.
//  * `NodeIntelligenceMode` and `MenuBarSummary` are the two pure aggregations the
//    menu bar paints, so the health light and the console cannot disagree.
//  * `SetupWizardState` is the four-step wizard's derived state, kept free of
//    SwiftUI so the skip path and the step gates can be tested.
//

import Foundation

// MARK: - Pull state

public enum ModelPullState: String, Codable, Sendable, Equatable {
    case idle
    case pulling
    case verifying
    case ready
    case failed
    case cancelled
    case refused

    /// True while a pull owns the fabric: a second start is ignored rather than
    /// spawning a second download of the same weights.
    public var isRunning: Bool { self == .pulling || self == .verifying }
}

/// What the model card renders under the picker.
///
/// `completedBytes`/`totalBytes` are the daemon's own figures for the artifact it
/// is streaming; `percent` is monotonic (Ollama re-sends layer totals per digest,
/// so the last event is not always the largest fraction).
public struct ModelPullCard: Codable, Sendable, Equatable {
    public var state: ModelPullState
    public var modelRef: String
    public var percent: Int
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var status: String
    public var detail: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var updatedAt: Date

    public init(
        state: ModelPullState = .idle,
        modelRef: String = "",
        percent: Int = 0,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        status: String = "",
        detail: String = "",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.modelRef = modelRef
        self.percent = min(max(percent, 0), 100)
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }

    public static let idle = ModelPullCard()

    /// "1.2 GB / 20.0 GB" — empty until the daemon reports a total.
    public var sizeLine: String {
        guard let totalBytes, totalBytes > 0 else { return "" }
        let done = ByteCount(bytes: completedBytes ?? 0).humanized
        return "\(done) / \(ByteCount(bytes: totalBytes).humanized)"
    }

    public var isReady: Bool { state == .ready }
}

/// One NDJSON line from `POST /api/pull` with `stream: true`.
///
/// Ollama sends a status-only line between layers ("pulling manifest",
/// "verifying sha256 digest", "success") and byte counts only on layer lines.
/// Both shapes decode; a missing field is the normal case, not a failure.
public struct OllamaPullEvent: Decodable, Sendable, Equatable {
    public var status: String?
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?

    public init(status: String? = nil, digest: String? = nil, total: Int64? = nil, completed: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
    }

    public var fraction: Double? {
        guard let total, total > 0, let completed, completed >= 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var isSuccess: Bool {
        (status ?? "").lowercased() == "success"
    }
}

/// The pull grammar, separated from the actor so the parser is testable without a
/// socket. Lines that are not JSON objects (log noise, blank keep-alives) are
/// ignored, and a fraction never moves the bar backwards.
public enum ModelPullProgressParser {
    public static func decode(_ line: String) -> OllamaPullEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        return try? JSONDecoder().decode(OllamaPullEvent.self, from: Data(trimmed.utf8))
    }

    public static func percent(current: Int, event: OllamaPullEvent, ceiling: Int = 99) -> Int {
        guard let fraction = event.fraction else { return min(current, ceiling) }
        let raw = Int((fraction * 100).rounded(.down))
        return min(ceiling, max(current, max(0, raw)))
    }

    /// Ollama lists every model under a tag (`inkling-2-mini:latest`). A pull of
    /// an untagged reference installs `:latest`, so a different tag is a different
    /// artifact — the owner's `model_refs.json` override is the supported way to
    /// point at one, and it changes the reference compared here.
    public static func referenceMatches(_ listed: String, _ wanted: String) -> Bool {
        canonical(listed) == canonical(wanted)
    }

    static func canonical(_ reference: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : trimmed + ":latest"
    }
}

// MARK: - Pull transport

public enum ModelPullError: Error, Equatable, CustomStringConvertible {
    case badEndpoint
    case notHTTP
    case http(Int)
    case refused(String)

    public var description: String {
        switch self {
        case .badEndpoint: return "回环地址校验失败 / the endpoint is not loopback"
        case .notHTTP: return "响应不是 HTTP / the response was not HTTP"
        case .http(let code): return "Ollama 返回 HTTP \(code) / Ollama answered HTTP \(code)"
        case .refused(let reason): return reason
        }
    }
}

/// The seam tests replace. A request can only name a validated `EdgeEndpoint`, so
/// a fake transport is also proof the loopback guard ran.
public protocol ModelPullTransporting: Sendable {
    func pullStream(ref: String) -> AsyncThrowingStream<String, Error>
    func installedRefs() async throws -> [String]
}

/// The real transport. Loopback only, ephemeral session, no cache, no cookies, no
/// redirects — the Ollama daemon on this Mac is the only downloader involved.
public struct OllamaModelPullTransport: ModelPullTransporting {
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(NodeWire.ollamaPort)")!,
        timeout: TimeInterval = 600
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    private func endpoint(_ path: String) throws -> URL {
        let resolved = try EdgeBoundary.resolve(url: baseURL.absoluteString, policy: .loopbackOnly)
        guard let url = resolved.url(path: path) else { throw ModelPullError.badEndpoint }
        return url
    }

    public func pullStream(ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: try endpoint("/api/pull"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = timeout
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: ["model": ref, "stream": true]
                    )
                    let session = HubHTTP.session(timeout: timeout)
                    defer { session.finishTasksAndInvalidate() }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ModelPullError.notHTTP }
                    guard http.statusCode == 200 else { throw ModelPullError.http(http.statusCode) }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func installedRefs() async throws -> [String] {
        var request = URLRequest(url: try endpoint("/api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 20)
        let session = HubHTTP.session(timeout: request.timeoutInterval)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelPullError.notHTTP }
        guard http.statusCode == 200 else { throw ModelPullError.http(http.statusCode) }
        struct TagList: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]?
        }
        let list = try JSONDecoder().decode(TagList.self, from: data)
        return (list.models ?? []).map(\.name)
    }
}

// MARK: - Pull center

/// One pull at a time, owned by the node rather than by a browser tab: closing the
/// console does not cancel a multi-gigabyte download, and reopening it reads the
/// same card.
public actor ModelPullCenter {
    private let transport: any ModelPullTransporting
    private var card: ModelPullCard = .idle
    private var job: Task<Void, Never>?
    private var runID = UUID()

    public init(transport: any ModelPullTransporting = OllamaModelPullTransport()) {
        self.transport = transport
    }

    public func current() -> ModelPullCard { card }

    /// Starts a pull of a catalog id or an Ollama reference. Returns the card it
    /// just set; `refused` means no stream was opened.
    @discardableResult
    public func start(ref raw: String, now: Date = Date()) -> ModelPullCard {
        if card.state.isRunning { return card }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            card = ModelPullCard(
                state: .refused,
                status: "refused",
                detail: "没有指定模型 / no model was named",
                finishedAt: now,
                updatedAt: now
            )
            return card
        }
        let reference: String
        if let option = ModelCatalog.option(matching: trimmed) {
            // A catalog id is a UI token; the daemon needs its reference.
            let submitted = trimmed == option.id ? nil : trimmed
            reference = ModelRefOverrides.resolve(option: option, submitted: submitted)
        } else if ModelRefOverrides.isValid(trimmed) {
            reference = trimmed
        } else {
            card = ModelPullCard(
                state: .refused,
                modelRef: trimmed,
                status: "refused",
                detail: "模型引用不合法 / not a valid local model reference",
                finishedAt: now,
                updatedAt: now
            )
            return card
        }

        let token = UUID()
        runID = token
        card = ModelPullCard(
            state: .pulling,
            modelRef: reference,
            percent: 0,
            status: "starting",
            detail: "正在通过本机 Ollama 拉取 / pulling through the local Ollama",
            startedAt: now,
            updatedAt: now
        )
        let transport = self.transport
        job = Task { [weak self] in
            var percent = 0
            do {
                for try await line in transport.pullStream(ref: reference) {
                    if Task.isCancelled { return }
                    guard let event = ModelPullProgressParser.decode(line) else { continue }
                    percent = ModelPullProgressParser.percent(current: percent, event: event)
                    await self?.apply(event: event, percent: percent, run: token)
                }
                if Task.isCancelled { return }
                await self?.verify(ref: reference, run: token)
            } catch {
                await self?.fail(reason: String(describing: error), run: token)
            }
        }
        return card
    }

    /// Cooperative cancel: the stream task is cancelled and the card says so.
    /// The daemon may finish its own local work, but the node no longer tracks it.
    @discardableResult
    public func cancel(now: Date = Date()) -> ModelPullCard {
        guard card.state.isRunning else { return card }
        runID = UUID()
        job?.cancel()
        job = nil
        card.state = .cancelled
        card.status = "cancelled"
        card.detail = "已取消 / cancelled by the owner"
        card.finishedAt = now
        card.updatedAt = now
        return card
    }

    /// Test and host seam: waits until the pull settles or the bound elapses.
    public func waitForCompletion(timeout: TimeInterval = 30) async -> ModelPullCard {
        let deadline = Date().addingTimeInterval(timeout)
        while card.state.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return card
    }

    private func apply(event: OllamaPullEvent, percent: Int, run: UUID) {
        guard run == runID, card.state.isRunning else { return }
        if let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            card.status = String(status.prefix(80))
        }
        if let total = event.total, total > 0 { card.totalBytes = total }
        if let completed = event.completed, completed >= 0 { card.completedBytes = completed }
        card.percent = percent
        card.updatedAt = Date()
    }

    private func verify(ref: String, run: UUID) async {
        guard run == runID else { return }
        card.state = .verifying
        card.percent = 99
        card.status = "verifying"
        card.detail = "校验本机模型清单 / checking the local model list"
        card.updatedAt = Date()
        do {
            let listed = try await transport.installedRefs()
            guard run == runID else { return }
            guard listed.contains(where: { ModelPullProgressParser.referenceMatches($0, ref) }) else {
                card.state = .failed
                card.status = "not-listed"
                card.detail = "拉取完成但本机清单没有 \(ref) / pull finished but the model is absent from /api/tags"
                card.finishedAt = Date()
                card.updatedAt = Date()
                return
            }
            card.state = .ready
            card.percent = 100
            card.status = "ready"
            card.detail = "\(ref) 已就绪 / ready"
            card.finishedAt = Date()
            card.updatedAt = Date()
            card.totalBytes = card.totalBytes ?? card.completedBytes
            card.completedBytes = card.totalBytes
        } catch {
            guard run == runID else { return }
            card.state = .failed
            card.status = "verify-failed"
            card.detail = "无法读取本机模型清单 / could not read /api/tags: \(String(describing: error))"
            card.finishedAt = Date()
            card.updatedAt = Date()
        }
    }

    private func fail(reason: String, run: UUID) {
        guard run == runID, card.state.isRunning else { return }
        card.state = .failed
        card.status = "failed"
        card.detail = String(reason.prefix(240))
        card.finishedAt = Date()
        card.updatedAt = Date()
    }
}

// MARK: - Lightweight mode

/// One capability row in the lightweight-mode panel. The deterministic rows keep
/// working with zero models; the model-only rows stay visible and say they are off,
/// because "the feature vanished" is not an explanation.
public struct LightweightFeature: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var titleZh: String
    public var titleEn: String
    public var detailZh: String
    public var detailEn: String
    public var needsModel: Bool
    public var enabled: Bool

    public init(
        id: String,
        titleZh: String,
        titleEn: String,
        detailZh: String,
        detailEn: String,
        needsModel: Bool,
        enabled: Bool = true
    ) {
        self.id = id
        self.titleZh = titleZh
        self.titleEn = titleEn
        self.detailZh = detailZh
        self.detailEn = detailEn
        self.needsModel = needsModel
        self.enabled = enabled
    }
}

public enum LightweightModePlan {
    /// Everything the node does without a language model. Order is the render order.
    public static let features: [LightweightFeature] = [
        LightweightFeature(
            id: "rag", titleZh: "本地加密情景记忆", titleEn: "Sealed local episodic memory",
            detailZh: "FTS5 全文 + 关键词检索，标题/正文/来源 AES-GCM 密封，零字节离开本机。",
            detailEn: "FTS5 full-text and keyword recall; titles, bodies and sources are AES-GCM sealed; zero bytes leave this Mac.",
            needsModel: false
        ),
        LightweightFeature(
            id: "voice", titleZh: "语音备忘录本机转写", titleEn: "On-device voice memos",
            detailZh: "Apple Speech 的 requiresOnDeviceRecognition，或回环 whisper.cpp；行动项仍需人工审批。",
            detailEn: "Apple Speech with requiresOnDeviceRecognition, or loopback whisper.cpp; actions still need human approval.",
            needsModel: false
        ),
        LightweightFeature(
            id: "mail", titleZh: "邮件分拣与草稿提案", titleEn: "Mail triage and draft proposals",
            detailZh: "规则驱动的分类、账单/截止日期提取；发送永远生成待审批回执。",
            detailEn: "Rule-based categories and bill/deadline extraction; every send becomes a pending approval receipt.",
            needsModel: false
        ),
        LightweightFeature(
            id: "bridges", titleZh: "日历与工作区桥接", titleEn: "Calendar and workspace bridges",
            detailZh: "EventKit / CalDAV / 文件沙盒，读写都受授权目录与审批约束。",
            detailEn: "EventKit / CalDAV / the file sandbox, with reads and writes bounded by authorized folders and approvals.",
            needsModel: false
        ),
        LightweightFeature(
            id: "sentinel", titleZh: "家庭设备安全哨兵", titleEn: "Smart-home sentinel",
            detailZh: "Home Assistant / MQTT 巡检；修复只能生成待审批提案。",
            detailEn: "Home Assistant / MQTT patrols; repairs can only become pending proposals.",
            needsModel: false
        ),
        LightweightFeature(
            id: "watchdog", titleZh: "系统看门狗与开机自启", titleEn: "Watchdog and launch at login",
            detailZh: "磁盘/内存/守护进程/推理端低频监测，指数退避重启，告警去重后推送手机。",
            detailEn: "Low-frequency disk, memory, daemon and inference checks; exponential restart backoff; deduped phone alerts.",
            needsModel: false
        ),
        LightweightFeature(
            id: "pairing", titleZh: "密封配对、更新与发现", titleEn: "Sealed pairing, updates and discovery",
            detailZh: "/i/v1/ 密封配对信封、签名更新闸门、局域网发现聚合。",
            detailEn: "The /i/v1/ sealed pairing envelope, the signed update gate and the LAN discovery aggregator.",
            needsModel: false
        ),
        LightweightFeature(
            id: "multimodal", titleZh: "本地多模态票据理解", titleEn: "Local multimodal ticket reading",
            detailZh: "需要 Inkling 2 Mini 等本机模型；纯轻量模式不运行任何模型。",
            detailEn: "Needs a local model such as Inkling 2 Mini; lightweight mode runs zero models.",
            needsModel: true
        ),
        LightweightFeature(
            id: "structured", titleZh: "结构化 JSON 推理", titleEn: "Structured JSON reasoning",
            detailZh: "需要本机模型；关闭时助手退回确定性规则与模板。",
            detailEn: "Needs a local model; without one the assistant falls back to deterministic rules and templates.",
            needsModel: true
        )
    ]

    public static func resolve(lightweight: Bool) -> [LightweightFeature] {
        features.map { feature in
            var copy = feature
            copy.enabled = lightweight ? !feature.needsModel : true
            return copy
        }
    }

    public static func disabledByLightweight(_ features: [LightweightFeature]) -> [LightweightFeature] {
        features.filter { $0.needsModel && !$0.enabled }
    }
}

// MARK: - Node mode

/// The model card the console and the menu bar read: the owner's explicit mode,
/// the last pull, and the feature rows that survive with zero models.
public struct LocalModelCard: Codable, Sendable, Equatable {
    public var mode: NodeIntelligenceMode
    public var modelRef: String
    public var pull: ModelPullCard
    public var features: [LightweightFeature]
    public var guidanceZh: String
    public var guidanceEn: String
    public var updatedAt: Date

    public init(
        mode: NodeIntelligenceMode,
        modelRef: String,
        pull: ModelPullCard,
        features: [LightweightFeature],
        guidanceZh: String,
        guidanceEn: String,
        updatedAt: Date = Date()
    ) {
        self.mode = mode
        self.modelRef = modelRef
        self.pull = pull
        self.features = features
        self.guidanceZh = guidanceZh
        self.guidanceEn = guidanceEn
        self.updatedAt = updatedAt
    }

    public static func resolve(
        lightweight: Bool,
        modelRef: String,
        modelReady: Bool,
        pull: ModelPullCard,
        now: Date = Date()
    ) -> LocalModelCard {
        let mode = NodeIntelligenceMode.resolve(lightweight: lightweight, modelReady: modelReady)
        let guidance: (zh: String, en: String)
        if lightweight {
            guidance = (
                "零模型运行：以下确定性能力继续工作。随时可拉取本机模型并关闭纯轻量模式切回 AI 增强。",
                "Zero models run. The deterministic capabilities below keep working; pull a local model and turn lightweight mode off to switch back to AI-enhanced."
            )
        } else if modelReady {
            guidance = (
                "本机模型已就绪，助手将优先使用它；规则回退仍然保留。",
                "The local model is ready and the assistant will prefer it; the deterministic fallback stays in place."
            )
        } else if pull.state == .pulling || pull.state == .verifying {
            guidance = (
                "正在拉取本机模型；期间助手继续按确定性规则工作。",
                "The local model is being pulled; the assistant keeps working from deterministic rules meanwhile."
            )
        } else if pull.state == .failed || pull.state == .refused {
            guidance = (pull.detail, pull.detail)
        } else {
            guidance = (
                "尚未拉取本机模型；可一键拉取，或继续使用纯轻量模式。",
                "No local model is installed yet; pull one with one click, or keep using lightweight mode."
            )
        }
        return LocalModelCard(
            mode: mode,
            modelRef: modelRef,
            pull: pull,
            features: LightweightModePlan.resolve(lightweight: lightweight),
            guidanceZh: guidance.zh,
            guidanceEn: guidance.en,
            updatedAt: now
        )
    }

    public static let idle = LocalModelCard.resolve(
        lightweight: false,
        modelRef: "",
        modelReady: false,
        pull: .idle,
        now: Date(timeIntervalSince1970: 0)
    )
}

/// One owner click's answer. `pull` is the card after the action, so the console
/// can repaint without racing a separate status read.
public struct ModelPullReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var outcome: String
    public var detail: String
    public var pull: ModelPullCard

    public init(ok: Bool, outcome: String, detail: String, pull: ModelPullCard) {
        self.ok = ok
        self.outcome = outcome
        self.detail = detail
        self.pull = pull
    }

    public static func make(_ card: ModelPullCard) -> ModelPullReport {
        ModelPullReport(
            ok: card.state == .pulling || card.state == .verifying || card.state == .ready,
            outcome: card.state.rawValue,
            detail: card.detail,
            pull: card
        )
    }
}

/// The wizard's 「发送测试简报」 answer. It says whether a paired device accepted
/// the card, and how many devices were paired at the time, so "sent" is never a
/// claim about a phone that is not there.
public struct PairingTestReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var delivered: Bool
    public var pairedCount: Int
    public var detail: String

    public init(ok: Bool, delivered: Bool, pairedCount: Int, detail: String) {
        self.ok = ok
        self.delivered = delivered
        self.pairedCount = max(0, pairedCount)
        self.detail = detail
    }
}

/// The two modes the health light distinguishes, plus whether the enhanced mode's
/// model is actually answering. The resolution is one pure function so the menu
/// bar, the console and the wizard agree.
public struct NodeIntelligenceMode: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case enhanced
        case lightweight
    }

    public var mode: Mode
    public var modelReady: Bool

    public init(mode: Mode, modelReady: Bool) {
        self.mode = mode
        self.modelReady = modelReady
    }

    public static func resolve(lightweight: Bool, modelReady: Bool) -> NodeIntelligenceMode {
        NodeIntelligenceMode(mode: lightweight ? .lightweight : .enhanced, modelReady: lightweight ? false : modelReady)
    }

    public var headlineZh: String {
        switch (mode, modelReady) {
        case (.lightweight, _): return "纯轻量模式 · 零模型运行"
        case (.enhanced, true): return "AI 增强模式 · 本机模型已就绪"
        case (.enhanced, false): return "AI 增强模式 · 模型尚未就绪"
        }
    }

    public var headlineEn: String {
        switch (mode, modelReady) {
        case (.lightweight, _): return "Lightweight mode · zero models running"
        case (.enhanced, true): return "AI-enhanced mode · local model ready"
        case (.enhanced, false): return "AI-enhanced mode · model not ready yet"
        }
    }

    /// "ok", "warn" or "off" — the same three values a console dot uses.
    public var health: String {
        switch (mode, modelReady) {
        case (.lightweight, _): return "off"
        case (.enhanced, true): return "ok"
        case (.enhanced, false): return "warn"
        }
    }
}

/// Everything the menu-bar control centre summarises, derived from the snapshot's
/// primitives. Keeping it a value type is what makes "the light and the pending
/// count are right" a unit test rather than a screenshot review.
public struct MenuBarSummary: Codable, Sendable, Equatable {
    public var mode: NodeIntelligenceMode
    public var daemonLive: Bool
    public var pairedCount: Int
    public var pendingCount: Int
    public var watchdogInstalled: Bool
    public var launchAtLogin: Bool

    public init(
        mode: NodeIntelligenceMode,
        daemonLive: Bool,
        pairedCount: Int,
        pendingCount: Int,
        watchdogInstalled: Bool,
        launchAtLogin: Bool
    ) {
        self.mode = mode
        self.daemonLive = daemonLive
        self.pairedCount = max(0, pairedCount)
        self.pendingCount = max(0, pendingCount)
        self.watchdogInstalled = watchdogInstalled
        self.launchAtLogin = launchAtLogin
    }

    public static func resolve(
        lightweight: Bool,
        modelReady: Bool,
        daemonLive: Bool,
        pairedCount: Int,
        pendingCount: Int,
        watchdogInstalled: Bool,
        launchAtLogin: Bool
    ) -> MenuBarSummary {
        MenuBarSummary(
            mode: .resolve(lightweight: lightweight, modelReady: modelReady),
            daemonLive: daemonLive,
            pairedCount: pairedCount,
            pendingCount: pendingCount,
            watchdogInstalled: watchdogInstalled,
            launchAtLogin: launchAtLogin
        )
    }

    public var approvalBadge: String { pendingCount > 0 ? String(pendingCount) : "—" }
}

// MARK: - Setup wizard

/// The four-step wizard's derived state. Nothing here drives the UI's layout; it
/// only answers "is this step done" and "which step is next" from values the node
/// already measures, so the skip-model path is provable in a unit test.
public struct SetupWizardState: Codable, Sendable, Equatable {
    public var installPhase: String
    public var lightweight: Bool
    public var modelReady: Bool
    public var workspaceCount: Int
    public var pairedCount: Int
    public var testSent: Bool

    public init(
        installPhase: String,
        lightweight: Bool,
        modelReady: Bool,
        workspaceCount: Int,
        pairedCount: Int,
        testSent: Bool
    ) {
        self.installPhase = installPhase
        self.lightweight = lightweight
        self.modelReady = modelReady
        self.workspaceCount = max(0, workspaceCount)
        self.pairedCount = max(0, pairedCount)
        self.testSent = testSent
    }

    public static func resolve(
        installPhase: InstallPhase,
        lightweight: Bool,
        modelReady: Bool,
        workspaceCount: Int,
        pairedCount: Int,
        testSent: Bool
    ) -> SetupWizardState {
        SetupWizardState(
            installPhase: installPhase.rawValue,
            lightweight: lightweight,
            modelReady: modelReady,
            workspaceCount: workspaceCount,
            pairedCount: pairedCount,
            testSent: testSent
        )
    }

    /// Step 1 is done when the owner either has a ready model or chose the explicit
    /// zero-model path. A running install is not done, and neither is a bare
    /// hardware scan: "deploy started" must not check a box.
    public var hardwareDone: Bool {
        lightweight || modelReady || installPhase == InstallPhase.ready.rawValue
    }

    public var workspaceDone: Bool { workspaceCount > 0 || lightweight }

    public var pairingDone: Bool { pairedCount > 0 }

    public var testDone: Bool { testSent }

    public var completedSteps: Int {
        [hardwareDone, workspaceDone, pairingDone, testDone].filter { $0 }.count
    }

    public var nextStep: Int {
        if !hardwareDone { return 1 }
        if !workspaceDone { return 2 }
        if !pairingDone { return 3 }
        if !testDone { return 4 }
        return 4
    }

    public var isComplete: Bool { completedSteps == 4 }
}
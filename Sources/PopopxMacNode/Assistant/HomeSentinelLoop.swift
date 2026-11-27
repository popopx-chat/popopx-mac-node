//
//  HomeSentinelLoop.swift
//  PopopxMacNode — watch the owner's critical devices, propose a repair, act only
//  after the owner says yes.
//
//  The loop itself is read-only. It asks a provider for the same whitelisted entity
//  cards the hub panel shows, and it never calls a service to "check" something.
//  When an entity has been unavailable for longer than its rule allows, the loop
//  mints an `AssistantApprovalGate` proposal whose receipt binds:
//
//      kind   = home.service
//      target = "homeassistant.turn_on#switch.living_room_plug"  (action#entity)
//      digest = SHA-256 of the canonical payload
//      expiry = 15 minutes
//
//  `perform` is the executor. It revalidates the receipt, target and digest with
//  the gate *before* it hands the payload to the smart-home bridge, and the bridge
//  re-checks its own switches (bridge on, not read-only, entity still exposed).
//  A read-only bridge therefore cannot be repaired by the assistant even with a
//  valid receipt — the owner's configuration wins.
//

import Foundation

public struct HomeRepairOutcome: Sendable, Equatable {
    public var ok: Bool
    public var detail: String

    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }

    public static func refused(_ detail: String) -> HomeRepairOutcome {
        HomeRepairOutcome(ok: false, detail: detail)
    }
}

/// The two capabilities the sentinel needs. `SmartHomeSentinelAdapter` binds this
/// to the real bridge; tests inject a recording fake with no socket.
public protocol HomeSentinelEntityProviding: Sendable {
    func sentinelEntities() async -> [SmartHomeEntityCard]
    func sentinelReadOnly() async -> Bool
    func performSentinelRepair(_ payload: HubCallPayload) async -> HomeRepairOutcome
}

public actor HomeSentinelLoop {
    public static let offlineStates: Set<String> = [
        "unavailable", "unknown", "offline", "disconnected"
    ]

    private var config: AssistantConfig
    private var provider: any HomeSentinelEntityProviding
    private let gate: AssistantApprovalGate
    private let store: AssistantAuditStore
    private let clock: AssistantClock
    private var firstSeenOffline: [String: Date] = [:]
    private var payloads: [String: HubCallPayload] = [:]
    private var watches: [String: String] = [:]
    private var lastScanAt: Date?
    private var lastError = ""

    public init(
        config: AssistantConfig = .disabled,
        provider: any HomeSentinelEntityProviding,
        gate: AssistantApprovalGate,
        store: AssistantAuditStore,
        clock: AssistantClock = SystemAssistantClock()
    ) {
        self.config = config.normalised
        self.provider = provider
        self.gate = gate
        self.store = store
        self.clock = clock
    }

    public func update(config next: AssistantConfig) {
        config = next.normalised
        if !config.enabled {
            firstSeenOffline.removeAll()
            payloads.removeAll()
            watches.removeAll()
        }
    }

    public func updateProvider(_ next: any HomeSentinelEntityProviding) {
        provider = next
    }

    /// One read-only pass. The returned report is what the patrol handler turns
    /// into a phone card.
    public func scan(now: Date? = nil) async -> SentinelScanReport {
        let moment = now ?? clock.now
        lastScanAt = moment
        guard config.enabled else {
            return SentinelScanReport(skipped: ["assistant off"], scannedAt: moment)
        }
        let entities = await provider.sentinelEntities()
        let readOnly = await provider.sentinelReadOnly()
        guard !entities.isEmpty else {
            lastError = "家居桥接未启用或没有白名单实体 / the smart-home bridge is off or has no exposed entities"
            await store.record(channel: "sentinel", event: "scan_empty", detail: lastError, outcome: "skipped", at: moment)
            return SentinelScanReport(skipped: [lastError], scannedAt: moment)
        }

        let rules = Dictionary(uniqueKeysWithValues: config.repairs.map { ($0.watchEntity, $0) })
        var anomalies: [SentinelAnomalyCard] = []
        var proposed = 0
        var skipped: [String] = []
        var seen = Set<String>()

        for entity in entities {
            let state = entity.state.lowercased()
            seen.insert(entity.entityID)
            guard Self.offlineStates.contains(state) else {
                firstSeenOffline.removeValue(forKey: entity.entityID)
                continue
            }
            let first = firstSeenOffline[entity.entityID] ?? moment
            if firstSeenOffline[entity.entityID] == nil { firstSeenOffline[entity.entityID] = moment }
            let seconds = max(0, Int(moment.timeIntervalSince(first).rounded()))
            let rule = rules[entity.entityID]
            let thresholdMinutes = rule?.offlineMinutes ?? config.patrol.offlineMinutes
            let anomaly = SentinelAnomalyCard(
                entityID: entity.entityID,
                display: entity.display,
                state: entity.state,
                offlineSeconds: seconds,
                repairEntity: rule?.repairEntity ?? "",
                repairAction: rule.map { "\($0.repairDomain).\($0.repairService)" } ?? ""
            )
            anomalies.append(anomaly)
            guard seconds >= thresholdMinutes * 60 else { continue }
            guard let rule, rule.usable else {
                let detail = "\(entity.entityID) 无可用修复规则 / no usable repair rule"
                skipped.append(detail)
                await store.record(channel: "sentinel", event: "anomaly_no_rule", detail: detail, outcome: "skipped", at: moment)
                continue
            }
            guard !readOnly else {
                let detail = "\(entity.entityID) 只读模式，禁止自动修复 / read-only mode"
                skipped.append(detail)
                await store.record(channel: "sentinel", event: "anomaly_read_only", detail: detail, outcome: "refused", at: moment)
                continue
            }
            let target = "\(rule.repairDomain).\(rule.repairService)#\(rule.repairEntity)"
            if await gate.hasPending(kind: .homeService, target: target, now: moment) {
                skipped.append("\(entity.entityID) 已有待审批修复 / approval already pending")
                continue
            }

            let arguments: [String: JSONValue] = [
                "entity_id": .string(rule.repairEntity),
                "source": .string("assistant.sentinel")
            ]
            let payload = HubCallPayload(
                kind: .haService,
                serverID: "homeassistant",
                target: "\(rule.repairDomain).\(rule.repairService)",
                arguments: arguments,
                destination: "",
                label: entity.display.isEmpty ? entity.entityID : entity.display
            )
            let digest = AssistantDigest.home(kind: .homeService, target: payload.target, arguments: arguments)
            let minutes = max(1, seconds / 60)
            do {
                let ticket = try await gate.propose(
                    kind: .homeService,
                    target: target,
                    digest: digest,
                    title: "设备异常修复 · \(payload.label)",
                    detail: "\(entity.entityID) 已 \(minutes) 分钟不可用 · 建议 \(rule.repairDomain).\(rule.repairService) → \(rule.repairEntity)",
                    ttl: AssistantApprovalGate.defaultLifetime,
                    now: moment
                )
                payloads[ticket.proposalID] = payload
                watches[ticket.proposalID] = entity.entityID
                proposed += 1
                await store.record(
                    channel: "sentinel",
                    event: "repair_proposed",
                    detail: "\(entity.entityID) · \(target) · \(digest.prefix(12))",
                    at: moment
                )
            } catch {
                lastError = AssistantRedaction.scrub(String(describing: error))
                skipped.append("\(entity.entityID) 提案失败 / proposal refused")
                await store.record(channel: "sentinel", event: "propose_refused", detail: lastError, outcome: "refused", at: moment)
            }
        }

        // Forget entities that disappeared from the whitelist so the map cannot grow
        // without bound after a config edit.
        firstSeenOffline = firstSeenOffline.filter { seen.contains($0.key) }
        if anomalies.isEmpty {
            lastError = ""
        }
        await store.record(
            channel: "sentinel",
            event: "scan",
            detail: "\(entities.count) entities · \(anomalies.count) anomalies · \(proposed) proposed · \(skipped.count) skipped",
            outcome: "ok",
            at: moment
        )
        return SentinelScanReport(anomalies: anomalies, proposed: proposed, skipped: skipped, scannedAt: moment)
    }

    public func payload(id: String) -> HubCallPayload? { payloads[id] }

    /// The executor entry for a sentinel repair. The gate is checked here, before
    /// the bridge or the network is touched.
    public func perform(
        proposalID: String,
        approval: AssistantApproval,
        now: Date? = nil
    ) async -> HomeRepairOutcome {
        let moment = now ?? clock.now
        guard let payload = payloads[proposalID] else {
            return .refused("修复载荷不存在 / the repair payload is gone")
        }
        guard let entity = payload.arguments["entity_id"]?.stringValue else {
            return .refused("修复载荷缺少实体 / the repair payload has no entity")
        }
        let target = "\(payload.target)#\(entity)"
        let arguments = payload.arguments
        do {
            _ = try await gate.validateExecution(
                id: approval.proposalID,
                receipt: approval.receipt,
                kind: .homeService,
                target: target,
                digest: AssistantDigest.home(kind: .homeService, target: payload.target, arguments: arguments),
                now: moment
            )
        } catch {
            let detail = AssistantRedaction.scrub(String(describing: error))
            await store.record(channel: "sentinel", event: "repair_refused", detail: detail, outcome: "refused", at: moment)
            return .refused(detail)
        }

        let outcome = await provider.performSentinelRepair(payload)
        await gate.complete(id: approval.proposalID, ok: outcome.ok, detail: outcome.detail, now: moment)
        await store.record(
            channel: "sentinel",
            event: outcome.ok ? "repair_executed" : "repair_failed",
            detail: "\(payload.target) → \(entity) · \(outcome.detail)",
            outcome: outcome.ok ? "ok" : "failed",
            at: moment
        )
        if outcome.ok {
            payloads.removeValue(forKey: proposalID)
            if let watch = watches.removeValue(forKey: proposalID) {
                firstSeenOffline.removeValue(forKey: watch)
            }
            lastError = ""
        }
        return outcome
    }

    public func lastScan() -> Date? { lastScanAt }
    public func failureReason() -> String { lastError }

    public func reset() {
        firstSeenOffline.removeAll()
        payloads.removeAll()
        watches.removeAll()
        lastError = ""
    }
}

// MARK: - Production adapter

/// Binds the sentinel to the existing hub bridge without teaching the bridge about
/// gates. The repair method reuses the bridge's own policy checks.
public struct SmartHomeSentinelAdapter: HomeSentinelEntityProviding {
    private let bridge: SmartHomeBridge

    public init(bridge: SmartHomeBridge) {
        self.bridge = bridge
    }

    public func sentinelEntities() async -> [SmartHomeEntityCard] {
        await bridge.entityCards()
    }

    public func sentinelReadOnly() async -> Bool {
        await bridge.assistantReadOnlyMode()
    }

    public func performSentinelRepair(_ payload: HubCallPayload) async -> HomeRepairOutcome {
        let execution = await bridge.performAssistantRepair(payload)
        return HomeRepairOutcome(ok: execution.ok, detail: execution.message)
    }
}
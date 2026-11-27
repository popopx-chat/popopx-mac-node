//
//  SmartHomeBridge.swift
//  PopopxMacNode — the policy layer over Home Assistant and the MQTT broker.
//
//  `HomeAssistantClient` and `MQTTSession` know HTTP and bytes. This is the file that knows
//  the rules, and it is the only reason the brief's sentence about "只允许白名单实体, 高危设备强制二次确认"
//  is a property of the program rather than of the UI:
//
//  1. **An entity that is not in `exposedEntities` does not exist.** Not for reading, not for
//     acting. The HA server returns every entity on the network; the bridge filters before a
//     value is put in a snapshot, so an unexposed `lock.front_door` never reaches the console,
//     the phone, or an audit row.
//  2. **`readOnlyMode` is not a suggestion.** When it is on, no service call and no publish is
//     attempted at all — the request is refused rather than queued, so an owner can see the
//     difference between "this needs a click" and "this cannot happen".
//  3. **Every actuation opens a `pending_user_approval` proposal.** A light toggle is a write.
//     A high-risk domain (lock, alarm, siren, camera, vacuum) is a write that additionally
//     cannot be reached by a retained MQTT byte and is labelled 「高危」 on the card, because
//     the second confirmation the owner gives should be an informed one.
//  4. **Credentials resolve from `HubSecretStoring` at use time.** The settings document holds
//     a *reference*; a client is built with the secret, and the secret is never put in a card,
//     an error string, or the snapshot.
//
//  The MQTT byte source is injected as a factory returning `HubByteStream`, so the whole gate
//  is testable with a scripted in-memory stream — no broker, no socket, no writes to the real
//  application-support directory.
//

import Foundation

/// The console's row for one whitelisted entity.
public struct SmartHomeEntityCard: Codable, Sendable, Equatable {
    public var entityID: String
    public var display: String
    public var domain: String
    public var state: String
    /// `homeassistant` or `mqtt`, so an owner can see which bridge answered.
    public var source: String
    public var highRisk: Bool
    /// Whether pressing this can ever do something: false when the bridge is off or the
    /// config is read-only, which the panel shows instead of a button that cannot work.
    public var controllable: Bool
    public var lastSeen: String

    public init(
        entityID: String,
        display: String = "",
        domain: String = "",
        state: String = "",
        source: String = "homeassistant",
        highRisk: Bool = false,
        controllable: Bool = false,
        lastSeen: String = ""
    ) {
        self.entityID = entityID
        self.display = display
        self.domain = domain
        self.state = state
        self.source = source
        self.highRisk = highRisk
        self.controllable = controllable
        self.lastSeen = lastSeen
    }
}

/// One telemetry message the broker pushed, kept small.
public struct SmartHomeTelemetryCard: Codable, Sendable, Equatable {
    public var topic: String
    public var entityID: String
    public var value: String
    public var at: Date

    public init(topic: String, entityID: String = "", value: String, at: Date = Date()) {
        self.topic = topic
        self.entityID = entityID
        self.value = value
        self.at = at
    }
}

/// What the panel says about the two transports, without the node having to reach the network
/// to answer a poll.
public struct SmartHomeStatusCard: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var homeAssistantConfigured: Bool
    public var homeAssistantReachable: Bool
    public var brokerConfigured: Bool
    public var brokerConnected: Bool
    public var readOnlyMode: Bool
    public var exposedCount: Int
    public var credentialBacking: String
    public var reason: String

    public init(
        enabled: Bool = false,
        homeAssistantConfigured: Bool = false,
        homeAssistantReachable: Bool = false,
        brokerConfigured: Bool = false,
        brokerConnected: Bool = false,
        readOnlyMode: Bool = true,
        exposedCount: Int = 0,
        credentialBacking: String = "",
        reason: String = ""
    ) {
        self.enabled = enabled
        self.homeAssistantConfigured = homeAssistantConfigured
        self.homeAssistantReachable = homeAssistantReachable
        self.brokerConfigured = brokerConfigured
        self.brokerConnected = brokerConnected
        self.readOnlyMode = readOnlyMode
        self.exposedCount = exposedCount
        self.credentialBacking = credentialBacking
        self.reason = reason
    }
}

public actor SmartHomeBridge {
    public static let maximumTelemetryRows = 12
    public static let maximumPayloadCharacters = 240

    private let ledger: PrivacyProposalLedger
    private let secrets: HubSecretStoring
    private var config: HubConfig
    /// How a broker becomes a socket. Injectable, and `nil` refuses to connect at all, which
    /// is what a node without `Network.framework` entitlements should do rather than fail late.
    private let makeStream: @Sendable (EdgeEndpoint, MQTTConnectOptions) -> HubByteStream?

    private var session: MQTTSession?
    private var telemetry: [SmartHomeTelemetryCard] = []
    private var lastStates: [HAEntityState] = []
    private var lastStatesAt = Date.distantPast
    private var lastError = ""

    public init(
        config: HubConfig = .disabled,
        secrets: HubSecretStoring = VolatileSecretStore(),
        ledger: PrivacyProposalLedger,
        streamFactory: @escaping @Sendable (EdgeEndpoint, MQTTConnectOptions) -> HubByteStream? = { _, _ in nil }
    ) {
        self.config = config
        self.secrets = secrets
        self.ledger = ledger
        self.makeStream = streamFactory
    }

    public func update(config: HubConfig) {
        self.config = config
        if !config.allowSmartHomeBridge {
            if let session { Task { await session.disconnect() } }
            session = nil
            lastStates = []
            telemetry = []
        }
    }

    // MARK: - Credentials

    /// Stores a Home Assistant Long-Lived Token. The value goes to the Keychain (or to memory,
    /// when the process has no bundle identity) and the *reference* is what the caller keeps.
    public func storeHomeAssistantToken(_ token: String) -> HubSecretOutcome {
        let reference = HubSecrets.reference("smarthome", "homeassistant", "token")
        guard !token.isEmpty, token.utf8.count <= HubSecrets.maximumSecretLength else {
            return .refused(reason: "令牌为空或过长 / the token is empty or too long")
        }
        return secrets.store(token, for: reference)
            ? .stored(reference: reference)
            : .refused(reason: "钥匙串写入失败 / the credential store refused")
    }

    public func storeBrokerPassword(_ password: String) -> HubSecretOutcome {
        let reference = HubSecrets.reference("smarthome", "mqtt", "password")
        guard !password.isEmpty, password.utf8.count <= HubSecrets.maximumSecretLength else {
            return .refused(reason: "口令为空或过长 / the password is empty or too long")
        }
        return secrets.store(password, for: reference)
            ? .stored(reference: reference)
            : .refused(reason: "钥匙串写入失败 / the credential store refused")
    }

    private func homeAssistantToken(_ smartHome: SmartHomeConfig) -> String? {
        secrets.secret(for: smartHome.homeAssistantTokenRef)
    }

    // MARK: - Reading

    /// The whitelisted entities, from the last state poll. Filtered here, at the only boundary
    /// the console has, so nothing downstream has to remember to filter.
    public func entityCards() async -> [SmartHomeEntityCard] {
        guard config.allowSmartHomeBridge else { return [] }
        let smartHome = config.smartHome
        await refreshStatesIfNeeded()
        return lastStates
            .filter { smartHome.isExposed($0.entityID) }
            .prefix(Self.maximumEntitiesForCard)
            .map { state in
                SmartHomeEntityCard(
                    entityID: state.entityID,
                    display: state.display,
                    domain: state.domain,
                    state: String(state.state.prefix(60)),
                    source: "homeassistant",
                    highRisk: smartHome.isHighRisk(state.entityID),
                    controllable: !smartHome.readOnlyMode,
                    lastSeen: state.lastUpdated
                )
            }
    }

    public static let maximumEntitiesForCard = 64

    public func telemetryCards() async -> [SmartHomeTelemetryCard] {
        guard config.allowSmartHomeBridge else { return [] }
        if let session {
            let fresh = await session.poll(timeout: 0.4)
            if fresh > 0 { await collectInbox(from: session) }
        }
        return Array(telemetry.suffix(Self.maximumTelemetryRows)).reversed()
    }

    public func status() async -> SmartHomeStatusCard {
        let smartHome = config.smartHome
        var reachable = false
        var reason = ""
        if config.allowSmartHomeBridge, smartHome.hasHomeAssistant {
            if homeAssistantToken(smartHome) != nil {
                reachable = await canReachHomeAssistant()
                if !reachable { reason = lastError }
            } else {
                reason = "令牌未存入钥匙串 / no token stored for \(smartHome.homeAssistantTokenRef)"
            }
        } else if config.allowSmartHomeBridge, !smartHome.usable {
            reason = "配置不完整：需要内网地址与至少一个白名单实体 / config needs a LAN url and one exposed entity"
        } else if !config.allowSmartHomeBridge {
            reason = "桥接未启用 / the bridge is off"
        }
        let brokerConnected = await (session?.isConnected ?? false)
        return SmartHomeStatusCard(
            enabled: config.allowSmartHomeBridge,
            homeAssistantConfigured: smartHome.hasHomeAssistant,
            homeAssistantReachable: reachable,
            brokerConfigured: smartHome.hasBroker,
            brokerConnected: brokerConnected,
            readOnlyMode: smartHome.readOnlyMode,
            exposedCount: smartHome.exposedEntities.count,
            credentialBacking: secrets.backingName,
            reason: reason
        )
    }

    // MARK: - Acting

    /// Calls a Home Assistant service for one entity. Every accepted request becomes a
    /// proposal; nothing here executes.
    public func call(
        entity: String,
        service: String,
        data: [String: JSONValue] = [:],
        source: String = "console"
    ) async -> HubCallOutcome {
        guard config.allowSmartHomeBridge else {
            return .refused("家居桥接未启用 / the smart-home bridge is off")
        }
        let smartHome = config.smartHome.normalised
        let wanted = SmartHomeConfig.normalise(entity)
        guard wanted.contains(".") else {
            return .refused("实体标识需为 domain.name / an entity id is domain.name")
        }
        guard smartHome.isExposed(wanted) else {
            // Audited, because "the node refused to control something" is the fact an owner
            // needs when a device they expected to see is missing from the panel.
            await record("refused", "entity not exposed: \(wanted)")
            return .refused("该实体未在白名单中 / the entity is not in exposedEntities: \(wanted)")
        }
        guard !smartHome.readOnlyMode else {
            await record("refused", "read-only mode: \(wanted)")
            return .refused("只读模式已开启 / the bridge is in read-only mode")
        }
        let parts = service.lowercased().split(separator: ".")
        guard parts.count == 2,
              let domain = HubHTTP.segment(String(parts[0]), maximumLength: 40),
              let action = HubHTTP.segment(String(parts[1]), maximumLength: 40) else {
            return .refused("服务名需为 domain.service / the service name must be a domain.service pair")
        }
        guard smartHome.homeAssistantEndpoint != nil else {
            return .refused("未配置 Home Assistant 内网地址 / no reachable Home Assistant url is configured")
        }

        var arguments = data
        arguments["entity_id"] = .string(wanted)
        let payload = HubCallPayload(
            kind: .haService,
            serverID: "homeassistant",
            target: "\(domain).\(action)",
            arguments: arguments,
            destination: smartHome.homeAssistantEndpoint?.origin ?? "",
            label: lastStates.first(where: { $0.entityID == wanted })?.display ?? wanted
        )

        let highRisk = smartHome.isHighRisk(wanted)
        let proposal = PrivacyProposal(
            domain: .smartHome,
            action: .invoke,
            source: source,
            title: (highRisk ? "高危设备操作 · " : "控制设备 · ") + (payload.label.isEmpty ? wanted : payload.label),
            detail: payload.preview,
            hubCall: payload
        )
        let stored = await ledger.propose(proposal)
        await record(PrivacyProposalState.pendingUserApproval.rawValue, "\(payload.target) → \(stored.id)")
        return .proposed(stored)
    }

    /// Publishes a retained MQTT command. Admissible only when the owner configured a command
    /// prefix *and* the topic names an exposed, non-high-risk entity.
    public func publish(entity: String, payload data: [String: JSONValue], source: String = "console") async -> HubCallOutcome {
        guard config.allowSmartHomeBridge else {
            return .refused("家居桥接未启用 / the smart-home bridge is off")
        }
        let smartHome = config.smartHome.normalised
        guard let topic = smartHome.commandTopic(for: entity) else {
            await record("refused", "publish outside the command prefix: \(entity)")
            return .refused("该实体不允许 MQTT 下发 / MQTT command publishing is not allowed for this entity")
        }
        guard !smartHome.isHighRisk(entity) else {
            await record("refused", "high-risk publish: \(entity)")
            return .refused("高危实体不接受 MQTT 直控 / a high-risk entity cannot be driven by a raw publish")
        }
        let payload = HubCallPayload(
            kind: .mqttPublish,
            serverID: "mqtt",
            target: topic,
            arguments: data,
            destination: smartHome.mqttEndpoint?.origin ?? "",
            label: entity
        )
        let proposal = PrivacyProposal(
            domain: .smartHome,
            action: .invoke,
            source: source,
            title: "下发 MQTT 指令 · \(entity)",
            detail: payload.preview,
            hubCall: payload
        )
        let stored = await ledger.propose(proposal)
        await record(PrivacyProposalState.pendingUserApproval.rawValue, "publish \(topic) → \(stored.id)")
        return .proposed(stored)
    }

    /// Reached only through the ledger's executor, after a receipt-signed 「批准」.
    public func executeApproved(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        guard proposal.domain == .smartHome, proposal.action == .invoke, let payload = proposal.hubCall else {
            return PrivacyExecution(ok: false, message: "提案不是家居指令 / proposal is not a smart-home call")
        }
        guard config.allowSmartHomeBridge, !config.smartHome.readOnlyMode else {
            return PrivacyExecution(ok: false, message: "桥接已关闭或转为只读 / the bridge was switched off or set read-only")
        }
        let smartHome = config.smartHome.normalised
        // Re-checked at execution, not only at proposal time: a config edit between the two
        // must be able to stop the write, because the config is the owner's intent.
        let entity = payload.arguments["entity_id"]?.stringValue ?? payload.label
        guard !entity.isEmpty, smartHome.isExposed(entity) else {
            return PrivacyExecution(ok: false, message: "实体已不在白名单 / the entity is no longer exposed")
        }

        switch payload.kind {
        case .haService:
            guard let endpoint = smartHome.homeAssistantEndpoint,
                  let token = homeAssistantToken(smartHome) else {
                return PrivacyExecution(ok: false, message: "缺少地址或令牌 / no url or token available")
            }
            let parts = payload.target.split(separator: ".")
            guard parts.count == 2, let domain = HubHTTP.segment(String(parts[0]), maximumLength: 40),
                  let action = HubHTTP.segment(String(parts[1]), maximumLength: 40) else {
                return PrivacyExecution(ok: false, message: "服务名不合法 / malformed service name")
            }
            var data = payload.arguments
            data["entity_id"] = .string(entity)
            let client = HomeAssistantClient(endpoint: endpoint, token: token)
            do {
                let message = try await client.callService(domain: domain, service: action, data: data)
                await record("approved_executed", "\(domain).\(action) on \(entity) → \(proposal.id)")
                await refresh()
                return PrivacyExecution(ok: true, identifier: proposal.id, message: message)
            } catch {
                await record("failed", "\(payload.target) on \(entity): \(error)")
                return PrivacyExecution(ok: false, message: String(describing: error))
            }
        case .mqttPublish:
            guard await ensureBroker() else {
                return PrivacyExecution(ok: false, message: lastError.isEmpty ? "MQTT 不可用 / broker unavailable" : lastError)
            }
            guard smartHome.commandTopic(for: entity) == payload.target else {
                return PrivacyExecution(ok: false, message: "主题与白名单不符 / the topic no longer matches the whitelist")
            }
            let body = JSONValue.object(payload.arguments.filter { $0.key != "entity_id" })
            guard let encoded = NodeJSON.encodeLine(body), let text = String(data: encoded, encoding: .utf8) else {
                return PrivacyExecution(ok: false, message: "载荷无法编码 / the payload could not be encoded")
            }
            guard let session else {
                return PrivacyExecution(ok: false, message: "未连接 Broker / no broker connection")
            }
            let sent = await session.publish(
                topic: payload.target,
                payload: String(text.prefix(Self.maximumPayloadCharacters)),
                qos: 1
            )
            guard sent else {
                let reason = await session.failureReason
                return PrivacyExecution(ok: false, message: reason.isEmpty ? "发布失败 / publish failed" : reason)
            }
            await record("approved_executed", "publish \(payload.target) → \(proposal.id)")
            return PrivacyExecution(ok: true, identifier: proposal.id, message: "已下发 / published")
        case .mcpTool:
            return PrivacyExecution(ok: false, message: "载荷类型不符 / payload kind is not a smart-home action")
        }
    }

    /// Used by the assistant sentinel before it mints a repair card: a read-only
    /// bridge or a switched-off bridge can be watched, never repaired.
    public func assistantReadOnlyMode() -> Bool {
        !config.allowSmartHomeBridge || config.smartHome.readOnlyMode
    }

    /// The sentinel's execution seam. The assistant gate validated the signed
    /// receipt before calling this; the bridge still re-checks its own rules
    /// (switch, read-only, whitelist) because the configuration is the owner's
    /// later opinion and must be able to stop the write.
    ///
    /// This deliberately does not create a second privacy proposal: the approval
    /// already happened on the assistant card, and minting another queued write
    /// would hide it from the owner.
    public func performAssistantRepair(_ payload: HubCallPayload) async -> PrivacyExecution {
        let proposal = PrivacyProposal(
            domain: .smartHome,
            action: .invoke,
            source: "assistant",
            title: "私人助手修复 · \(payload.label)",
            detail: payload.preview,
            hubCall: payload
        )
        return await executeApproved(proposal)
    }

    public func disconnect() async {
        if let session { await session.disconnect() }
        session = nil
        lastStates = []
        telemetry = []
    }

    // MARK: - Internals

    private func refreshStatesIfNeeded() async {
        let fresh = Date().timeIntervalSince(lastStatesAt) < 5
        if fresh, !lastStates.isEmpty { return }
        await refresh()
    }

    private func refresh() async {
        let smartHome = config.smartHome.normalised
        guard config.allowSmartHomeBridge else { return }
        guard let endpoint = smartHome.homeAssistantEndpoint, let token = homeAssistantToken(smartHome) else { return }
        let client = HomeAssistantClient(endpoint: endpoint, token: token)
        do {
            lastStates = try await client.states()
            lastStatesAt = Date()
            lastError = ""
        } catch {
            lastError = String(describing: error)
        }
    }

    private func canReachHomeAssistant() async -> Bool {
        let smartHome = config.smartHome.normalised
        guard smartHome.homeAssistantEndpoint != nil, homeAssistantToken(smartHome) != nil else { return false }
        await refresh()
        return !lastStates.isEmpty
    }

    /// Opens (once) the MQTT session and subscribes to the configured filters.
    private func ensureBroker() async -> Bool {
        if let session, await session.isConnected { return true }
        let smartHome = config.smartHome.normalised
        guard let endpoint = smartHome.mqttEndpoint else {
            lastError = "未配置 Broker 地址 / no broker host configured"
            return false
        }
        guard let stream = makeStream(endpoint, connectOptions(smartHome)) else {
            lastError = "无法建立 socket / the node could not open a connection"
            return false
        }
        let next = MQTTSession(stream: stream, options: connectOptions(smartHome))
        session = next
        guard await next.connect() else {
            lastError = await next.failureReason
            session = nil
            await next.disconnect()
            return false
        }
        if smartHome.allowMqttTelemetry, !smartHome.mqttTopicFilters.isEmpty {
            guard await next.subscribe(smartHome.mqttTopicFilters, qos: 0) else {
                lastError = await next.failureReason
                return false
            }
        }
        return true
    }

    private func connectOptions(_ smartHome: SmartHomeConfig) -> MQTTConnectOptions {
        MQTTConnectOptions(
            clientID: smartHome.mqttClientID,
            keepAliveSeconds: 60,
            cleanSession: true,
            username: smartHome.mqttUsername.isEmpty ? nil : smartHome.mqttUsername,
            password: secrets.secret(for: smartHome.mqttPasswordRef)
        )
    }

    private func collectInbox(from session: MQTTSession) async {
        let smartHome = config.smartHome.normalised
        for message in await session.drainInbox() {
            let value = String((message.text ?? "").prefix(Self.maximumPayloadCharacters))
            telemetry.append(SmartHomeTelemetryCard(
                topic: String(message.topic.prefix(160)),
                entityID: smartHome.entity(forCommandTopic: message.topic) ?? "",
                value: value
            ))
        }
        if telemetry.count > Self.maximumTelemetryRows * 2 {
            telemetry.removeFirst(telemetry.count - Self.maximumTelemetryRows * 2)
        }
    }

    private func record(_ outcome: String, _ detail: String) async {
        await ledger.record(PrivacyAuditEntry(
            domain: PrivacyDomain.smartHome.rawValue,
            action: PrivacyProposalAction.invoke.rawValue,
            outcome: outcome,
            // The detail is entity ids and verbs only. A device's attribute text is server
            // content and has no business in a log an owner pastes into a support thread.
            detail: String(detail.prefix(200))
        ))
    }
}

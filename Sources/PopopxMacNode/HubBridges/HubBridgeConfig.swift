//
//  HubBridgeConfig.swift
//  PopopxMacNode — the switches and endpoints of the v1.1 edge-hub bridges.
//
//  One document (`config/settings.json`, field `hubBridges`), four sub-configs. Two
//  rules govern the whole file:
//
//  * **Everything starts closed.** All three bridge switches default to `false`, and a
//    settings document that predates v1.1 decodes to exactly that. There is no
//    "enabled unless told otherwise" here.
//  * **A secret is never a config value.** Home Assistant's long-lived token and the
//    MQTT password are stored as a *Keychain reference* (`tokenRef`), so this document —
//    which the console POSTs whole, which is copied into bug reports, and which sits in
//    a plain file — contains nothing worth stealing. The console writes a reference when
//    the owner pastes a token, and the token itself goes to `HubSecretStore`.
//
//  Every struct here hand-writes `init(from:)` with `decodeIfPresent`. `NodeSettings`
//  and its sub-documents have no custom decoder, and Swift's synthesised one *throws* on
//  a missing non-optional key — `NodeJSON.decode` is a `try?`, and `SettingsStore` turns
//  a nil into a fresh default. So one added `Bool` would silently reset an owner's whole
//  configuration on upgrade. Optionality is what keeps that from happening.
//

import Foundation

// MARK: - Document

public struct HubConfig: Codable, Sendable, Equatable {
    public static let maximumServers = 8
    public static let maximumEntities = 64
    public static let maximumCalDavServers = 4
    public static let maximumDiscoveryTargets = 8

    /// Task 2 — the local MCP client. Off until the owner registers a server and flips it.
    public var allowMcpBridge: Bool
    /// Task 3 — Home Assistant and MQTT on the LAN.
    public var allowSmartHomeBridge: Bool
    /// Task 4 — non-Apple calendars over CalDAV.
    public var allowCalDavBridge: Bool

    public var mcpServers: MCPServersDocument?
    public var smartHome: SmartHomeConfig
    public var calDav: CalDavConfig
    public var discovery: DiscoveryConfig

    public init(
        allowMcpBridge: Bool = false,
        allowSmartHomeBridge: Bool = false,
        allowCalDavBridge: Bool = false,
        mcpServers: MCPServersDocument? = nil,
        smartHome: SmartHomeConfig = SmartHomeConfig(),
        calDav: CalDavConfig = CalDavConfig(),
        discovery: DiscoveryConfig = DiscoveryConfig()
    ) {
        self.allowMcpBridge = allowMcpBridge
        self.allowSmartHomeBridge = allowSmartHomeBridge
        self.allowCalDavBridge = allowCalDavBridge
        self.mcpServers = mcpServers
        self.smartHome = smartHome
        self.calDav = calDav
        self.discovery = discovery
    }

    public static let disabled = HubConfig()
    public static let allSwitchesOff = HubConfig.disabled

    public var anyBridgeEnabled: Bool {
        allowMcpBridge || allowSmartHomeBridge || allowCalDavBridge
    }

    /// Trims, caps and drops what cannot work. The bridges read this rather than the raw
    /// document, so a hand-edited settings file cannot widen a ceiling the console enforces.
    public var normalised: HubConfig {
        var copy = self
        copy.mcpServers = mcpServers?.normalised
        copy.smartHome = smartHome.normalised
        copy.calDav = calDav.normalised
        copy.discovery = discovery.normalised
        // A switch with no usable target behind it is off, so the console's badge and the
        // engine's answer cannot disagree about what is enabled.
        if copy.allowMcpBridge, copy.mcpServers?.usableServers.isEmpty != false { copy.allowMcpBridge = false }
        if copy.allowSmartHomeBridge, !copy.smartHome.usable { copy.allowSmartHomeBridge = false }
        if copy.allowCalDavBridge, copy.calDav.usableServers.isEmpty { copy.allowCalDavBridge = false }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case allowMcpBridge, allowSmartHomeBridge, allowCalDavBridge
        case mcpServers, smartHome, calDav, discovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowMcpBridge = try container.decodeIfPresent(Bool.self, forKey: .allowMcpBridge) ?? false
        self.allowSmartHomeBridge = try container.decodeIfPresent(Bool.self, forKey: .allowSmartHomeBridge) ?? false
        self.allowCalDavBridge = try container.decodeIfPresent(Bool.self, forKey: .allowCalDavBridge) ?? false
        self.mcpServers = try container.decodeIfPresent(MCPServersDocument.self, forKey: .mcpServers)
        self.smartHome = try container.decodeIfPresent(SmartHomeConfig.self, forKey: .smartHome) ?? SmartHomeConfig()
        self.calDav = try container.decodeIfPresent(CalDavConfig.self, forKey: .calDav) ?? CalDavConfig()
        self.discovery = try container.decodeIfPresent(DiscoveryConfig.self, forKey: .discovery) ?? DiscoveryConfig()
    }
}

// MARK: - MCP

/// The MCP half of the document: the operator's command allow-list plus the servers.
///
/// This shape is what `config/mcp_servers.json` holds, and it is a *separate file* from
/// `settings.json` on purpose: registering an executable is a different act from turning a
/// switch on, and the file is the one an owner is expected to edit by hand.
///
/// Two levels of allow-list, deliberately. `allowedCommands` is the list of executables
/// this node will ever `exec`, and a server entry has to name something inside it. Keeping
/// the allow-list *outside* the server entries means adding a server pointing at `/bin/sh`
/// is refused by itself, and widening the allow-list is the separate step a human
/// authorises.
public struct MCPServersDocument: Codable, Sendable, Equatable {
    public static let relativePath = "config/mcp_servers.json"
    public static let maximumAllowedCommands = 16
    public static let maximumArguments = 32
    public static let maximumServers = HubConfig.maximumServers

    public var allowedCommands: [String]
    public var servers: [MCPServerConfig]

    public init(allowedCommands: [String] = [], servers: [MCPServerConfig] = []) {
        self.allowedCommands = allowedCommands
        self.servers = servers
    }

    public var usableServers: [MCPServerConfig] {
        servers.filter { $0.enabled && $0.acceptance(inside: allowedCommands) == nil }
    }

    /// Per-server refusal reasons, in file order. Rendered by the console so an owner
    /// sees which entry is wrong and why instead of a blank card.
    public var rejections: [(id: String, reason: String)] {
        servers.compactMap { server in
            guard let reason = server.acceptance(inside: allowedCommands) else { return nil }
            return (server.id.isEmpty ? "—" : server.id, reason)
        }
    }

    public var normalised: MCPServersDocument {
        var copy = self
        copy.allowedCommands = Array(Set(allowedCommands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && !$0.contains("..") }))
            .sorted()
            .prefix(Self.maximumAllowedCommands)
            .map { $0 }
        copy.servers = Array(servers.prefix(Self.maximumServers))
        return copy
    }

    private enum CodingKeys: String, CodingKey { case allowedCommands, servers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowedCommands = try container.decodeIfPresent([String].self, forKey: .allowedCommands) ?? []
        self.servers = try container.decodeIfPresent([MCPServerConfig].self, forKey: .servers) ?? []
    }
}

/// One registered MCP server.
public struct MCPServerConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Transport: String, Codable, Sendable, CaseIterable {
        /// A child process speaking newline-delimited JSON-RPC on stdin/stdout.
        case stdio
        /// A loopback HTTP(S) endpoint speaking the MCP streamable-HTTP transport.
        case http
    }

    public var id: String
    public var label: String
    public var transport: Transport
    /// `stdio` only. Must be absolute and inside `MCPServersDocument.allowedCommands`.
    public var command: String
    public var arguments: [String]
    /// Names of environment variables copied from the node's own environment — never
    /// values, so a token cannot end up in a settings document.
    public var environmentNames: [String]
    /// `http` only. Must resolve to a loopback address (`EdgeHostPolicy.loopbackOnly`).
    public var url: String
    /// Tools the owner permits. Empty means "every read-only tool the server lists"; a
    /// mutating tool is never reachable through an empty list.
    public var allowedTools: [String]
    public var enabled: Bool

    public init(
        id: String,
        label: String = "",
        transport: Transport = .stdio,
        command: String = "",
        arguments: [String] = [],
        environmentNames: [String] = [],
        url: String = "",
        allowedTools: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environmentNames = environmentNames
        self.url = url
        self.allowedTools = allowedTools
        self.enabled = enabled
    }

    public var displayName: String { label.isEmpty ? id : label }

    /// Why this entry cannot be started, or `nil` when it can.
    ///
    /// The answer is a *reason string* rather than a Bool because the console renders it:
    /// an owner who typed `homeassistant.local:8123` into an MCP field deserves to be told
    /// which field and why, not shown "invalid".
    public func acceptance(inside allowed: [String]) -> String? {
        guard !id.isEmpty, id.count <= 64 else { return "标识需为 1–64 个字符 / id must be 1–64 characters" }
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return "标识仅可用字母、数字、短横线与下划线 / id accepts letters, digits, dash and underscore only"
        }
        switch transport {
        case .stdio:
            guard command.hasPrefix("/") else {
                return "stdio 必须使用绝对路径 / an stdio command must be an absolute path"
            }
            // A path that needs a shell to interpret it is not a command; it is a way of
            // getting the node to run something else.
            if command.contains(" ") || command.contains("&") || command.contains(";")
                || command.contains("|") || command.contains("$") || command.contains("`")
                || command.contains("*") || command.contains(">") || command.contains("<") {
                return "命令含 shell 元字符 / the command contains shell metacharacters"
            }
            guard allowed.contains(command) else {
                return "命令不在白名单内 / the command is not in mcp.allowedCommands"
            }
            guard arguments.count <= MCPServersDocument.maximumArguments else {
                return "参数过多 / too many arguments"
            }
        case .http:
            guard (try? EdgeBoundary.resolve(url: url, policy: .loopbackOnly)) != nil else {
                return "URL 必须指向本机回环（127.0.0.1 / localhost）/ an http MCP url must point at loopback"
            }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, transport, command, arguments, environmentNames, url, allowedTools, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
        self.command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environmentNames = try container.decodeIfPresent([String].self, forKey: .environmentNames) ?? []
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - Smart home

public struct SmartHomeConfig: Codable, Sendable, Equatable {
    public static let defaultMqttPort = 1883
    public static let defaultHighRiskDomains: [String] = [
        "lock", "alarm_control_panel", "siren", "camera", "vacuum"
    ]

    /// Home Assistant base URL. `privateNetworkOnly`: loopback or RFC 1918 or `.local`.
    public var homeAssistantUrl: String
    /// Keychain reference for the Long-Lived Access Token, never the token.
    public var homeAssistantTokenRef: String
    public var mqttHost: String
    public var mqttPort: Int
    public var mqttUsername: String
    public var mqttPasswordRef: String
    public var mqttClientID: String
    /// The entities the node may read *and* the only ones it may control. An entity that
    /// is not here does not exist as far as the bridge is concerned.
    public var exposedEntities: [String]
    /// Entity domains that can never be actuated without a 「批准」 click, even when they
    /// are in `exposedEntities`. A door lock is exactly the thing an unattended
    /// automation should not be able to disarm.
    public var highRiskDomains: [String]
    /// Read-only mode: state is mirrored, no service call or publish is ever attempted.
    /// Kept because "I want the temperature in the briefing but nothing switchable" is the
    /// common case, and a switch the owner can see is better than a hidden refusal.
    public var readOnlyMode: Bool
    /// Subscribe to MQTT for live state. Off by default: a subscription is an inbound
    /// channel, and inbound channels are what an allow-list is for.
    public var allowMqttTelemetry: Bool
    /// Topic filters to subscribe to when telemetry is on. The owner types them; the node
    /// never guesses a topic, and a filter starting with `$` (the broker's own namespace) is
    /// dropped by `MQTTSession.subscribe`.
    public var mqttTopicFilters: [String]
    /// Raw MQTT publishing is off while this is empty. When set, a publish may only go to
    /// `<prefix>/<exposed entity id>` — a broker the node can reach is otherwise a way to
    /// send arbitrary bytes to every device on the LAN.
    public var mqttCommandPrefix: String

    public init(
        homeAssistantUrl: String = "",
        homeAssistantTokenRef: String = "",
        mqttHost: String = "",
        mqttPort: Int = SmartHomeConfig.defaultMqttPort,
        mqttUsername: String = "",
        mqttPasswordRef: String = "",
        mqttClientID: String = "popopx-mac-node",
        exposedEntities: [String] = [],
        highRiskDomains: [String] = SmartHomeConfig.defaultHighRiskDomains,
        readOnlyMode: Bool = true,
        allowMqttTelemetry: Bool = false,
        mqttTopicFilters: [String] = [],
        mqttCommandPrefix: String = ""
    ) {
        self.homeAssistantUrl = homeAssistantUrl
        self.homeAssistantTokenRef = homeAssistantTokenRef
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUsername = mqttUsername
        self.mqttPasswordRef = mqttPasswordRef
        self.mqttClientID = mqttClientID
        self.exposedEntities = exposedEntities
        self.highRiskDomains = highRiskDomains
        self.readOnlyMode = readOnlyMode
        self.allowMqttTelemetry = allowMqttTelemetry
        self.mqttTopicFilters = mqttTopicFilters
        self.mqttCommandPrefix = mqttCommandPrefix
    }

    public var homeAssistantEndpoint: EdgeEndpoint? {
        try? EdgeBoundary.resolve(url: homeAssistantUrl, policy: .privateNetworkOnly)
    }

    public var mqttEndpoint: EdgeEndpoint? {
        mqttHost.isEmpty ? nil : try? EdgeBoundary.resolve(host: mqttHost, port: mqttPort)
    }

    public var hasHomeAssistant: Bool { !homeAssistantUrl.isEmpty && homeAssistantEndpoint != nil }
    public var hasBroker: Bool { !mqttHost.isEmpty && mqttEndpoint != nil }
    public var usable: Bool { (hasHomeAssistant || hasBroker) && !exposedEntities.isEmpty }

    /// Whether an entity may be read.
    public func isExposed(_ entity: String) -> Bool {
        exposedEntities.contains { Self.normalise($0) == Self.normalise(entity) }
    }

    /// Whether controlling an entity needs a human. True for any high-risk domain, and
    /// also for an entity the config does not name at all — a call for something outside
    /// the whitelist is refused outright, not downgraded.
    public func isHighRisk(_ entity: String) -> Bool {
        let domain = Self.domain(of: entity)
        return highRiskDomains.map(Self.normalise).contains(domain)
    }

    /// Whether a raw MQTT publish to `topic` is admissible: the prefix must be configured,
    /// the tail must name an exposed entity, and a high-risk entity may not be driven by a
    /// retained byte even when the owner exposed it.
    public func commandTopic(for entity: String) -> String? {
        guard !mqttCommandPrefix.isEmpty, isExposed(entity) else { return nil }
        let normalised = Self.normalise(entity)
        guard normalised.contains("."), !normalised.contains("..") else { return nil }
        let base = mqttCommandPrefix.hasSuffix("/") ? String(mqttCommandPrefix.dropLast()) : mqttCommandPrefix
        return "\(base)/\(normalised)"
    }

    public func entity(forCommandTopic topic: String) -> String? {
        guard !mqttCommandPrefix.isEmpty, topic.hasPrefix(mqttCommandPrefix) else { return nil }
        let tail = String(topic.dropFirst(mqttCommandPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return isExposed(tail) ? tail : nil
    }

    static func domain(of entity: String) -> String {
        let parts = normalise(entity).split(separator: ".")
        return parts.first.map(String.init) ?? ""
    }

    static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalised: SmartHomeConfig {
        var copy = self
        copy.exposedEntities = Array(Set(exposedEntities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.contains(".") }))
            .sorted()
            .prefix(HubConfig.maximumEntities)
            .map { $0 }
        copy.highRiskDomains = highRiskDomains
            .map { Self.normalise($0) }
            .filter { !$0.isEmpty }
        copy.mqttTopicFilters = mqttTopicFilters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { MQTTTopics.isValidFilter($0) && !$0.hasPrefix("$") }
        copy.mqttCommandPrefix = mqttCommandPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "+", with: "")
        if copy.mqttClientID.isEmpty { copy.mqttClientID = "popopx-mac-node" }
        copy.mqttPort = min(max(copy.mqttPort, 1), 65_535)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case homeAssistantUrl, homeAssistantTokenRef, mqttHost, mqttPort, mqttUsername
        case mqttPasswordRef, mqttClientID, exposedEntities, highRiskDomains, readOnlyMode
        case allowMqttTelemetry, mqttTopicFilters, mqttCommandPrefix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.homeAssistantUrl = try container.decodeIfPresent(String.self, forKey: .homeAssistantUrl) ?? ""
        self.homeAssistantTokenRef = try container.decodeIfPresent(String.self, forKey: .homeAssistantTokenRef) ?? ""
        self.mqttHost = try container.decodeIfPresent(String.self, forKey: .mqttHost) ?? ""
        self.mqttPort = try container.decodeIfPresent(Int.self, forKey: .mqttPort) ?? Self.defaultMqttPort
        self.mqttUsername = try container.decodeIfPresent(String.self, forKey: .mqttUsername) ?? ""
        self.mqttPasswordRef = try container.decodeIfPresent(String.self, forKey: .mqttPasswordRef) ?? ""
        self.mqttClientID = try container.decodeIfPresent(String.self, forKey: .mqttClientID) ?? "popopx-mac-node"
        self.exposedEntities = try container.decodeIfPresent([String].self, forKey: .exposedEntities) ?? []
        self.highRiskDomains = try container.decodeIfPresent([String].self, forKey: .highRiskDomains)
            ?? Self.defaultHighRiskDomains
        self.readOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .readOnlyMode) ?? true
        self.allowMqttTelemetry = try container.decodeIfPresent(Bool.self, forKey: .allowMqttTelemetry) ?? false
        self.mqttTopicFilters = try container.decodeIfPresent([String].self, forKey: .mqttTopicFilters) ?? []
        self.mqttCommandPrefix = try container.decodeIfPresent(String.self, forKey: .mqttCommandPrefix) ?? ""
    }
}

// MARK: - CalDAV

public struct CalDavConfig: Codable, Sendable, Equatable {
    public var servers: [CalDavServerConfig]
    /// How far ahead the free/busy `REPORT` asks for, when a caller names no window.
    public var lookaheadDays: Int

    public init(servers: [CalDavServerConfig] = [], lookaheadDays: Int = 14) {
        self.servers = servers
        self.lookaheadDays = lookaheadDays
    }

    public var usableServers: [CalDavServerConfig] {
        servers.filter { $0.enabled && $0.acceptance == nil }
    }

    public var normalised: CalDavConfig {
        var copy = self
        copy.servers = Array(servers.prefix(HubConfig.maximumCalDavServers))
        copy.lookaheadDays = min(max(lookaheadDays, 1), 92)   // matches CalendarProbe.maximumWindowDays
        return copy
    }

    private enum CodingKeys: String, CodingKey { case servers, lookaheadDays }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = try container.decodeIfPresent([CalDavServerConfig].self, forKey: .servers) ?? []
        self.lookaheadDays = try container.decodeIfPresent(Int.self, forKey: .lookaheadDays) ?? 14
    }
}

public struct CalDavServerConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// Base URL of the server (`https://cloud.example.com/remote.php/dav` on Nextcloud).
    public var url: String
    public var username: String
    /// Keychain reference for the password or app token.
    public var passwordRef: String
    /// The user's calendar collection path. Empty means "discover it with PROPFIND",
    /// which is what a Radicale install with non-standard roots needs.
    public var calendarPath: String
    public var enabled: Bool
    public var timeoutSeconds: Int

    public init(
        id: String,
        label: String = "",
        url: String = "",
        username: String = "",
        passwordRef: String = "",
        calendarPath: String = "",
        enabled: Bool = true,
        timeoutSeconds: Int = 10
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.username = username
        self.passwordRef = passwordRef
        self.calendarPath = calendarPath
        self.enabled = enabled
        self.timeoutSeconds = timeoutSeconds
    }

    public var displayName: String { label.isEmpty ? id : label }

    public var endpoint: EdgeEndpoint? {
        try? EdgeBoundary.resolve(url: url, policy: .privateNetworkOnly)
    }

    /// `nil` when admissible. A self-hosted Radicale on the LAN is fine; Nextcloud on
    /// `nextcloud.com` is not, because the node's guarantee is that this data never
    /// touches a third-party server.
    public var acceptance: String? {
        guard !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return "标识不合法 / invalid server id"
        }
        guard !url.isEmpty else { return "缺少服务器地址 / no server url" }
        guard endpoint != nil else {
            return "仅允许内网地址（10/8、172.16/12、192.168/16、.local、回环）/ only LAN or loopback hosts are admitted"
        }
        guard !username.isEmpty else { return "缺少用户名 / no username" }
        guard !passwordRef.isEmpty else { return "缺少口令引用 / no stored credential reference" }
        guard (1...60).contains(timeoutSeconds) else { return "超时需在 1–60 秒内 / timeout must be 1–60 seconds" }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, url, username, passwordRef, calendarPath, enabled, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.passwordRef = try container.decodeIfPresent(String.self, forKey: .passwordRef) ?? ""
        self.calendarPath = try container.decodeIfPresent(String.self, forKey: .calendarPath) ?? ""
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 10
    }
}

// MARK: - Discovery

public struct DiscoveryConfig: Codable, Sendable, Equatable {
    public var autoScanOnLaunch: Bool
    /// LAN services the *owner* named. Adding an entry is the authorization; the node
    /// never looks for a host nobody pointed it at.
    public var lanTargets: [String]
    /// Loopback Ollama stays probed regardless: the console already reports the local
    /// toolchain, and a TCP connect to this machine is not an outbound channel.
    public var probeOllama: Bool

    public init(autoScanOnLaunch: Bool = false, lanTargets: [String] = [], probeOllama: Bool = true) {
        self.autoScanOnLaunch = autoScanOnLaunch
        self.lanTargets = lanTargets
        self.probeOllama = probeOllama
    }

    /// The targets this config may actually probe.
    public var admissibleTargets: [EdgeEndpoint] {
        lanTargets.compactMap { try? EdgeBoundary.resolve(url: $0, policy: .privateNetworkOnly) }
    }

    public var normalised: DiscoveryConfig {
        var copy = self
        copy.lanTargets = Array(Set(lanTargets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted()
            .prefix(HubConfig.maximumDiscoveryTargets)
            .map { $0 }
        return copy
    }

    private enum CodingKeys: String, CodingKey { case autoScanOnLaunch, lanTargets, probeOllama }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoScanOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoScanOnLaunch) ?? false
        self.lanTargets = try container.decodeIfPresent([String].self, forKey: .lanTargets) ?? []
        self.probeOllama = try container.decodeIfPresent(Bool.self, forKey: .probeOllama) ?? true
    }
}

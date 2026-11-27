//
//  MacNodeModels.swift
//  PopopxMacNode — shared model layer.
//
//  This file is the frozen contract between every module of POPOPX Mac Node:
//  the hardware probe, the SMP signalling bridge, the ten business engines,
//  the loopback web console and the menu-bar host. Types, wire constants and
//  actor protocols declared here are the only surface modules are allowed to
//  share; anything private stays inside its own file.
//
//  Privacy red line: no absolute developer paths anywhere. Every writable
//  location is derived from the running user's Application Support directory.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Node constants

/// Wire-level and product-level constants shared by the bridge, the engines and
/// the web console. Changing a value here changes the protocol — treat these as
/// versioned on-disk/on-wire identifiers.
public enum NodeWire {
    /// Marker prefix of every command the iOS "Discover" service account sends.
    ///
    /// The iOS side already defines the outer marker `::popopx_sys::` and splits
    /// the text after it on the **first** `::` into a kind plus an opaque payload
    /// (`PopopxSysMarker` / `PopopxCommerceSignalKind`, apps/ios/Shared/Features/
    /// BadgeCredits/PopopxBadgeCreditsModels.swift:1136-1159). `NODE_CMD` is the
    /// kind this product adds, and the three segments below it are ours — which is
    /// why the payload may itself contain `::` and must be re-joined, not split.
    public static let commandPrefix = "::popopx_sys::NODE_CMD::"

    /// `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}`
    /// Number of `::`-separated segments after the marker prefix.
    public static let commandSegmentCount = 3

    /// Outer silent-signal marker understood by the iOS client.
    public static let signalMarker = "::popopx_sys::"

    /// The iOS parser rejects any payload longer than this
    /// (`PopopxCommerceLimits.maximumSignalPayloadCharacters`), so a result card
    /// that exceeds it must be shortened or carried as an artifact file instead.
    public static let maxSignalPayloadCharacters = 1_024

    /// Prefix of a pairing code rendered as a QR payload.
    public static let pairingCodePrefix = "PPXNODE1"

    /// Loopback console port.
    public static let consolePort: UInt16 = 18920

    /// Local chat-daemon WebSocket control port. The daemon has **no** default:
    /// it only listens when `--chat-server-port` is passed, and it binds
    /// `127.0.0.1` with plain `ws://` and no authentication. 5225 is the value the
    /// client libraries use, so we pass it explicitly.
    public static let popopxControlPort: UInt16 = 5225

    /// Flag that turns the daemon into a WebSocket server (`short 'p'`).
    public static let chatServerPortFlag = "--chat-server-port"

    /// The only daemon this node drives is our fork's `popopx-chat`. An upstream
    /// build is never probed: it speaks a different wire, so resolving it would
    /// turn a visible "missing dependency" into an unexplainable handshake failure.
    public static let chatDaemonCandidates: [String] = ["popopx-chat"]

    /// Connection-request scheme actually emitted by the fork
    /// (`ServiceScheme.hs:23` — `SSPopopx -> "popopx:"`).
    public static let invitationScheme = "popopx:/"

    /// Web host that `popopx:/` links are rewritten to, and back.
    public static let invitationShareHost = "https://popopx.chat/"

    /// Invitation links become one space-separated command-line argument, so the
    /// client caps their length and forbids shell-sensitive characters.
    public static let maxInvitationLinkCharacters = 2_048
    public static let forbiddenLinkCharacters: [Character] = ["\"", "'", "`", "\\", "$", " "]

    /// Local Ollama HTTP port.
    public static let ollamaPort: UInt16 = 11434

    /// Host the console binds. Never anything but loopback.
    public static let consoleHost = "127.0.0.1"

    /// Header carrying the per-launch console token.
    public static let consoleTokenHeader = "X-PPX-Token"

    /// Query item carrying the per-launch console token.
    public static let consoleTokenQuery = "t"

    /// Deterministic lock triggers that bypass every model.
    public static let lockTriggers: [String] = ["🔒", "LOCK_ALL", "lock_all"]

    /// Default lifetime of a one-time pairing offer.
    public static let pairingOfferLifetime: TimeInterval = 15 * 60

    /// How long a privacy-bridge proposal stays approvable. Same 15 minutes as a
    /// pairing offer, and for the same reason: long enough to answer from a phone,
    /// short enough that an unanswered proposal is not a standing permission.
    public static let proposalLifetime: TimeInterval = 15 * 60

    /// Minimum wall time between two console heartbeat events.
    public static let heartbeatInterval: TimeInterval = 20

    /// Services this node will run: the ten engines, plus the two privacy-bridge
    /// namespaces and the two control namespaces this release adds. None of them
    /// is an `EngineKind` case — that enum is the subscription catalogue, it drives
    /// the engine grid, the pull ladder and the generated `service-table.json` — but
    /// a confirmation card has to be replayable through this parser, so the grammar
    /// accepts both.
    public static func isKnownService(_ serviceId: String) -> Bool {
        EngineKind(rawValue: serviceId) != nil
            || PrivacyToolNamespace(rawValue: serviceId) != nil
            || serviceId == "updates"
            || serviceId == "discover"
            || serviceId == "assistant"
    }

    /// The one and only parser for `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}`.
    ///
    /// Exactly two separators are consumed, so a JSON payload that contains `::`
    /// survives intact — matching the iOS parser, which also splits on the first
    /// `::` only and treats everything after it as opaque. Returns nil (never a
    /// partially-filled command) for a foreign marker, a missing segment, an
    /// unknown service id, or a payload over the length the iOS side accepts.
    public static func parseCommand(
        _ text: String,
        senderPublicKey: String = "local-console",
        authenticated: Bool = false
    ) -> NodeCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(commandPrefix) else { return nil }
        let body = String(trimmed.dropFirst(commandPrefix.count))
        let segments = body.components(separatedBy: "::")
        guard segments.count >= commandSegmentCount else { return nil }
        let serviceId = segments[0].trimmingCharacters(in: .whitespaces)
        let action = segments[1].trimmingCharacters(in: .whitespaces)
        let payload = segments[2...].joined(separator: "::")
        guard !serviceId.isEmpty, !action.isEmpty, !payload.isEmpty else { return nil }
        guard isKnownService(serviceId) else { return nil }
        // The 1024-char ceiling the iOS parser enforces covers everything after
        // `::popopx_sys::NODE_CMD::`, so the two leading segments are charged too.
        let used = serviceId.count + action.count + 2
        guard payload.count <= maxSignalPayloadCharacters - used else { return nil }
        return NodeCommand(
            serviceId: serviceId,
            action: action,
            payload: payload,
            senderPublicKey: senderPublicKey,
            authenticated: authenticated
        )
    }
}

/// Product identity strings surfaced in the console, the menu bar and `--version`.
public struct NodeVersion: Codable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let channel: String

    public init(major: Int, minor: Int, patch: Int, channel: String = "stable") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.channel = channel
    }

    public static let current = NodeVersion(major: 1, minor: 0, patch: 2)

    /// Anything that must survive a restart but may legitimately change.
    public static let schemaRevision = 3

    public var semanticString: String { "\(major).\(minor).\(patch)" }
    public var description: String { "POPOPX Mac Node \(semanticString) (\(channel))" }
}

// MARK: - JSON value

/// A Codable, `Sendable`, hashable JSON tree. Engine payloads, SSE frames and
/// the console snapshot all traffic through this type so that no module ever
/// has to pass untyped `[String: Any]` across an actor boundary.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Equatable {}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSONValue"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(1); hasher.combine(value)
        case .int(let value): hasher.combine(2); hasher.combine(value)
        case .double(let value): hasher.combine(3); hasher.combine(value)
        case .string(let value): hasher.combine(4); hasher.combine(value)
        case .array(let value): hasher.combine(5); hasher.combine(value)
        case .object(let value):
            hasher.combine(6)
            for key in value.keys.sorted() { hasher.combine(key); hasher.combine(value[key]) }
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        if case .int(let value) = self { return value != 0 }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let value) = self, value.indices.contains(index) { return value[index] }
        return nil
    }

    /// `true` for `.null` and for empty strings/containers.
    var isEmptyValue: Bool {
        switch self {
        case .null: return true
        case .string(let value): return value.isEmpty
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        default: return false
        }
    }

    /// Compact one-line rendering used by log lines and the audit table.
    var debugSummary: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value.count > 96 ? String(value.prefix(93)) + "..." : value
        case .array(let value): return "[\(value.count)]"
        case .object(let value): return "{\(value.keys.sorted().prefix(6).joined(separator: ","))}"
        }
    }

    /// Best-effort conversion of a decoded JSON document into `JSONValue`.
    init(fromAny value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .double(value.doubleValue)
        case let value as Double:
            self = .double(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(fromAny:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(fromAny:)))
        default:
            self = .string(String(describing: value))
        }
    }

    /// Parses a JSON document, falling back to `.string(raw)` when the text is
    /// not JSON at all (iOS sends plain-text payloads for several actions).
    static func parse(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return .string(text) }
        return JSONValue(fromAny: object)
    }

    /// Serialises back to JSON text; `.string` values are re-emitted verbatim so
    /// that `parse`/`serialized` round-trips user text.
    func serialized(pretty: Bool = false) -> String {
        let encoder = NodeJSON.encoder(prettyPrinted: pretty)
        if let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) {
            return text
        }
        if case .string(let value) = self { return value }
        return "{}"
    }
}

// MARK: - JSON plumbing

public extension CodingUserInfoKey {
    /// Set on an encoder that feeds a *displayed* surface — the console snapshot, the
    /// rotate response — rather than the node's own store. Objects use it to add
    /// derived privacy fields (an opaque link, a mask) without those values ever
    /// being written to disk, where a fresh nonce would rewrite the file on every
    /// poll and put a second copy of a credential in the store.
    static let popopxDisplaysOpaqueLinks = CodingUserInfoKey(rawValue: "popopxDisplaysOpaqueLinks")!
}

/// One encoder/decoder configuration for the whole node so that file formats,
/// the REST console and the SMP wire never disagree about dates or key order.
public enum NodeJSON {
    public static func encoder(prettyPrinted: Bool = false, displayingOpaqueLinks: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        if displayingOpaqueLinks {
            encoder.userInfo[.popopxDisplaysOpaqueLinks] = true
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encodeLine<T: Encodable>(_ value: T) -> Data? {
        try? encoder().encode(value)
    }

    public static func encodePretty<T: Encodable>(_ value: T) -> Data? {
        try? encoder(prettyPrinted: true).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder().decode(type, from: data)
    }
}

public extension Date {
    var ppxISO8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }

    var ppxClock: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }

    static func ppxFromISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - Errors

public enum NodeFailure: Error, LocalizedError, Equatable {
    case missingBinary(String)
    case permissionDenied(String)
    case invalidPayload(String)
    case unpairedSender(String)
    case engineDisabled(String)
    case storageFull(requiredBytes: Int64, availableBytes: Int64)
    case timedOut(String)
    case subprocessFailed(executable: String, exitCode: Int32, stderr: String)
    case networkUnavailable(String)
    case cryptoFailure(String)
    case lockedUntil(Date)

    public var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return "Required binary is not installed: \(name)"
        case .permissionDenied(let target):
            return "The node does not have permission to touch: \(target)"
        case .invalidPayload(let detail):
            return "Malformed command payload: \(detail)"
        case .unpairedSender(let key):
            return "Refused a command from an unpaired device key: \(key.prefix(16))…"
        case .engineDisabled(let engine):
            return "Engine is switched off in the console: \(engine)"
        case .storageFull(let required, let available):
            return "Not enough free disk: need \(ByteCount(required).humanized), have \(ByteCount(available).humanized)"
        case .timedOut(let stage):
            return "Timed out during: \(stage)"
        case .subprocessFailed(let executable, let code, let stderr):
            return "\(executable) exited with \(code): \(stderr.prefix(240))"
        case .networkUnavailable(let host):
            return "Local service unreachable: \(host)"
        case .cryptoFailure(let detail):
            return "Cryptographic operation failed: \(detail)"
        case .lockedUntil(let date):
            return "Time-locked vault stays sealed until \(date.ppxISO8601)"
        }
    }
}

// MARK: - Byte counts

/// Human-readable byte counts used by the hardware dashboard and the installer
/// progress lines. Base-2 sizes, matching what macOS Finder reports.
public struct ByteCount: Codable, Sendable, Equatable, Comparable, ExpressibleByIntegerLiteral {
    public let bytes: Int64

    public init(bytes: Int64) { self.bytes = bytes }
    public init(_ bytes: Int64) { self.bytes = bytes }
    public init(integerLiteral value: Int64) { self.bytes = value }

    public var mebibytes: Double { Double(bytes) / 1_048_576 }
    public var gibibytes: Double { Double(bytes) / 1_073_741_824 }

    public var humanized: String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes > 0 else { return "\(bytes) B" }
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    public var roundedGibibytes: Int { Int((gibibytes).rounded()) }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool { lhs.bytes < rhs.bytes }
}

// MARK: - Hardware model

/// Coarse capability ladder driven purely by unified-memory size, exactly as the
/// product brief specifies.
public enum ComputeTier: String, Codable, Sendable, CaseIterable {
    /// 96 GB and above — full-precision local video plus a large quantised LLM.
    case flagship
    /// 48–63 GB — quantised local video, quantised LLM.
    case high
    /// Below 48 GB — light inference only, heavy video routed to the mesh.
    case light

    public init(memoryGB: Int) {
        switch memoryGB {
        case 96...: self = .flagship
        case 48..<96: self = .high
        default: self = .light
        }
    }

    public var titleZh: String {
        switch self {
        case .flagship: return "满血本机档"
        case .high: return "量化本机档"
        case .light: return "轻量推理档"
        }
    }

    public var titleEn: String {
        switch self {
        case .flagship: return "Full-precision local"
        case .high: return "Quantised local"
        case .light: return "Light inference"
        }
    }

    /// The memory band this tier covers, for the console ladder table.
    public var memoryBand: String {
        switch self {
        case .flagship: return ">= 96 GB"
        case .high: return "48 - 95 GB"
        case .light: return "< 48 GB"
        }
    }
}

/// Everything the wizard shows on step 1.
public struct MacHardwareProfile: Codable, Sendable, Equatable {
    public var chipName: String
    public var modelIdentifier: String
    public var cpuArchitecture: String
    public var logicalCPUCount: Int
    public var physicalCPUCount: Int
    public var performanceCoreCount: Int
    public var efficiencyCoreCount: Int
    public var memoryTotal: ByteCount
    public var memoryGB: Int
    public var freeDisk: ByteCount
    public var totalDisk: ByteCount
    public var systemVolumeName: String
    public var operatingSystem: String
    public var kernelVersion: String
    public var serialMasked: String
    public var isAppleSilicon: Bool
    public var sampledAt: Date

    public init(
        chipName: String,
        modelIdentifier: String,
        cpuArchitecture: String,
        logicalCPUCount: Int,
        physicalCPUCount: Int,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        memoryTotal: ByteCount,
        freeDisk: ByteCount,
        totalDisk: ByteCount,
        systemVolumeName: String,
        operatingSystem: String,
        kernelVersion: String,
        serialMasked: String,
        sampledAt: Date = Date()
    ) {
        self.chipName = chipName
        self.modelIdentifier = modelIdentifier
        self.cpuArchitecture = cpuArchitecture
        self.logicalCPUCount = logicalCPUCount
        self.physicalCPUCount = physicalCPUCount
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.memoryTotal = memoryTotal
        self.memoryGB = memoryTotal.roundedGibibytes
        self.freeDisk = freeDisk
        self.totalDisk = totalDisk
        self.systemVolumeName = systemVolumeName
        self.operatingSystem = operatingSystem
        self.kernelVersion = kernelVersion
        self.serialMasked = serialMasked
        self.isAppleSilicon = cpuArchitecture.contains("arm") || chipName.hasPrefix("Apple ")
        self.sampledAt = sampledAt
    }

    public var tier: ComputeTier { ComputeTier(memoryGB: memoryGB) }

    /// One-line summary for the menu bar.
    public var shortLabel: String { "\(chipName) · \(memoryGB) GB" }

    /// Cores the LTX renderer may occupy without starving the UI session.
    public var renderWorkerBudget: Int { max(2, min(12, physicalCPUCount - 2)) }

    /// Soft ceiling for the edge-compute mesh, leaving headroom for the owner.
    public var meshMemoryCeilingGB: Int { max(8, Int(Double(memoryGB) * 0.55)) }
}

/// The concrete model stack derived from a hardware tier.
public struct ModelPlan: Codable, Sendable, Equatable {
    public var tier: ComputeTier
    public var llmRef: String
    public var llmQuantization: String
    public var llmParameterBillions: Double?
    public var videoRef: String
    public var videoPrecision: String
    public var videoBackend: String
    public var audioSampleRateHz: Int
    public var expectedResidentGB: Int
    public var heavyVideoLocally: Bool
    public var routeHeavyVideoToMesh: Bool
    public var ollamaModelPull: String
    public var ltxWeightsHint: String
    public var rationale: String

    public init(
        tier: ComputeTier,
        llmRef: String,
        llmQuantization: String,
        llmParameterBillions: Double?,
        videoRef: String,
        videoPrecision: String,
        videoBackend: String,
        audioSampleRateHz: Int,
        expectedResidentGB: Int,
        heavyVideoLocally: Bool,
        routeHeavyVideoToMesh: Bool,
        ollamaModelPull: String,
        ltxWeightsHint: String,
        rationale: String
    ) {
        self.tier = tier
        self.llmRef = llmRef
        self.llmQuantization = llmQuantization
        self.llmParameterBillions = llmParameterBillions
        self.videoRef = videoRef
        self.videoPrecision = videoPrecision
        self.videoBackend = videoBackend
        self.audioSampleRateHz = audioSampleRateHz
        self.expectedResidentGB = expectedResidentGB
        self.heavyVideoLocally = heavyVideoLocally
        self.routeHeavyVideoToMesh = routeHeavyVideoToMesh
        self.ollamaModelPull = ollamaModelPull
        self.ltxWeightsHint = ltxWeightsHint
        self.rationale = rationale
    }

    /// Deterministic ladder mandated by the brief:
    /// `>= 96 GB` → LTX-2.5 BF16 full weights + Qwen3.8-27B Q8_0,
    /// `48 - 95 GB` → LTX-2.5 MLX 8-bit + Qwen3.8-27B Q4_K_M,
    /// `< 48 GB` → light inference, heavy video delegated to the mesh.
    public static func recommend(for profile: MacHardwareProfile) -> ModelPlan {
        recommend(memoryGB: profile.memoryGB)
    }

    public static func recommend(memoryGB: Int) -> ModelPlan {
        switch ComputeTier(memoryGB: memoryGB) {
        case .flagship:
            return ModelPlan(
                tier: .flagship,
                llmRef: "qwen3.8:27b-q8_0",
                llmQuantization: "Q8_0",
                llmParameterBillions: 27,
                videoRef: "ltx-2.5",
                videoPrecision: "BF16 full weights",
                videoBackend: "MLX",
                audioSampleRateHz: 48_000,
                expectedResidentGB: min(memoryGB - 12, 84),
                heavyVideoLocally: true,
                routeHeavyVideoToMesh: false,
                ollamaModelPull: "ollama pull qwen3.8:27b-q8_0",
                ltxWeightsHint: "LTX-2-MLX/LTX-2.5-BF16",
                rationale: "Unified memory is large enough to keep the full-precision LTX-2.5 graph and a Q8_0 27B dialogue model resident at the same time."
            )
        case .high:
            return ModelPlan(
                tier: .high,
                llmRef: "qwen3.8:27b-q4_k_m",
                llmQuantization: "Q4_K_M",
                llmParameterBillions: 27,
                videoRef: "ltx-2.5-mlx-8bit",
                videoPrecision: "MLX 8-bit quantised",
                videoBackend: "MLX",
                audioSampleRateHz: 48_000,
                expectedResidentGB: min(memoryGB - 10, 52),
                heavyVideoLocally: true,
                routeHeavyVideoToMesh: false,
                ollamaModelPull: "ollama pull qwen3.8:27b-q4_k_m",
                ltxWeightsHint: "LTX-2-MLX/LTX-2.5-8bit",
                rationale: "An 8-bit LTX graph plus a Q4_K_M 27B model fits the 48-95 GB band with room for the desktop session."
            )
        case .light:
            return ModelPlan(
                tier: .light,
                llmRef: "qwen3.8:9b-q4_k_m",
                llmQuantization: "Q4_K_M",
                llmParameterBillions: 9,
                videoRef: "ltx-2.5-mlx-4bit",
                videoPrecision: "MLX 4-bit quantised",
                videoBackend: "MLX",
                audioSampleRateHz: 48_000,
                expectedResidentGB: min(memoryGB - 8, 28),
                heavyVideoLocally: false,
                routeHeavyVideoToMesh: true,
                ollamaModelPull: "ollama pull qwen3.8:9b-q4_k_m",
                ltxWeightsHint: "LTX-2-MLX/LTX-2.5-4bit (short clips only)",
                rationale: "Below 48 GB the node keeps short renders local and offers heavy video jobs to edge-compute shared nodes."
            )
        }
    }

    /// Memory the desktop session keeps whatever the model needs. The three
    /// figures are the ones `recommend(memoryGB:)` already subtracts, pulled here
    /// so the ladder and a re-drawn plan cannot drift apart.
    public var systemFloorGB: Int {
        switch tier {
        case .flagship: return 12
        case .high: return 10
        case .light: return 8
        }
    }

    /// The most this machine may let one model hold, after the desktop floor.
    public func residentCeilingGB(memoryGB: Int) -> Int {
        max(1, memoryGB - systemFloorGB)
    }

    /// Re-draws the plan around a model the owner picked in the console.
    ///
    /// Only the language model and the memory it may hold change; the video and
    /// audio choices stay with the hardware tier, because a 16 GB Mac does not
    /// gain memory by asking for a 20 GB model.
    ///
    /// A pin the catalog has never heard of still re-points the plan, because
    /// `ENGOllama.resolvedModel` honours it and the console must not name a model
    /// the engine will not ask for; its memory figures stay with the tier, since
    /// nothing can estimate an unknown footprint. Anything that is not a plain
    /// reference is dropped, so a typo degrades to the ladder rather than to a null
    /// model.
    ///
    /// `overrides`/`environment` are injectable so a test can pin a reference
    /// without editing the machine's `config/model_refs.json`.
    public func applying(selection raw: String, memoryGB: Int, overrides: ModelRefOverrides? = nil, environment: [String: String]? = nil) -> ModelPlan {
        let trimmed = raw.trimmedWireReference
        guard !trimmed.isEmpty else { return self }
        var next = self
        guard let option = ModelCatalog.option(matching: trimmed) else {
            guard ModelRefOverrides.isValid(trimmed) else { return self }
            next.llmRef = trimmed
            next.llmQuantization = "—"
            next.llmParameterBillions = nil
            next.ollamaModelPull = "ollama pull \(trimmed)"
            next.rationale = "\(trimmed) is not in the model catalog, so these memory figures still come from the \(tier.titleEn) tier."
            return next
        }
        let ref = ModelRefOverrides.resolve(option: option, submitted: trimmed, environment: environment, file: overrides)
        next.llmRef = ref
        next.llmQuantization = option.quantization
        next.llmParameterBillions = option.parameterBillions
        next.expectedResidentGB = min(option.estimatedResidentGB, residentCeilingGB(memoryGB: memoryGB))
        next.ollamaModelPull = option.pullCommand(for: ref)
        next.rationale = option.memoryNote(ref: ref, memoryGB: memoryGB)
        return next
    }
}

// MARK: - Model catalog

/// How much of this Mac one model may be given, decided from unified memory alone.
///
/// The verdict is an admission gate, not a measurement: it comes from the weight
/// footprint the catalog declares, so it is stable across launches and cannot be
/// talked out of by a momentary spike in `vm_stat`.
public enum ModelAdmission: String, Codable, Sendable, CaseIterable {
    /// Enough memory to hold the model alongside ordinary media and system work.
    case coResident
    /// Enough memory for the model as the node's main load.
    case recommended
    /// Above the swap line, below the recommendation: short contexts only.
    case constrained
    /// At or below the swap line — compression and paging are expected and the box
    /// can hang. The node refuses heavy local jobs here.
    case swapWarning

    /// `false` only for `swapWarning`: refuse rather than risk an OOM hang.
    public var permitsLocalLoad: Bool { self != .swapWarning }

    public var titleZh: String {
        switch self {
        case .coResident: return "可并行运行"
        case .recommended: return "达到推荐内存"
        case .constrained: return "低于推荐值"
        case .swapWarning: return "内存交换预警"
        }
    }

    public var titleEn: String {
        switch self {
        case .coResident: return "Safe alongside other work"
        case .recommended: return "Meets the recommended memory"
        case .constrained: return "Below the recommendation"
        case .swapWarning: return "Memory swap warning"
        }
    }
}

/// One local LLM the node can drive through the loopback Ollama daemon.
///
/// The memory figures cover weights plus the key/value cache of a 4096-token
/// context (the `ENGOllama.generate` default), which is what the render gate has
/// to reserve. They are estimates from the published quantisation size, not lab
/// measurements, and the console says so.
public struct LLMModelOption: Codable, Sendable, Equatable, Identifiable {
    /// Stable key, and the default Ollama model name. Also the override lookup key.
    public var id: String
    public var displayName: String
    /// The model half of the Ollama reference (`inkling-2-mini`).
    public var ollamaModel: String
    /// The tag half of the default reference. Empty means untagged, which is what
    /// a plain `ollama pull inkling-2-mini` installs.
    public var defaultTag: String
    public var quantization: String
    /// `nil` where the node has no published parameter count to assert — a
    /// hand-imported GGUF is sized by its file, not by its architecture.
    public var parameterBillions: Double?
    public var weightGigabytes: Int
    public var contextOverheadGB: Int
    public var recommendedMemoryGB: Int
    public var coResidentMemoryGB: Int
    /// A machine with this much memory or less is warned, not admitted.
    public var swapWarningMemoryGB: Int
    /// Shown when the reference arrives from `ollama create` rather than the hub.
    public var ggufCreateHint: String?
    public var noteZh: String
    public var noteEn: String

    public init(
        id: String,
        displayName: String,
        ollamaModel: String,
        defaultTag: String,
        quantization: String,
        parameterBillions: Double?,
        weightGigabytes: Int,
        contextOverheadGB: Int,
        recommendedMemoryGB: Int,
        coResidentMemoryGB: Int,
        swapWarningMemoryGB: Int,
        ggufCreateHint: String? = nil,
        noteZh: String,
        noteEn: String
    ) {
        self.id = id
        self.displayName = displayName
        self.ollamaModel = ollamaModel
        self.defaultTag = defaultTag
        self.quantization = quantization
        self.parameterBillions = parameterBillions
        self.weightGigabytes = weightGigabytes
        self.contextOverheadGB = contextOverheadGB
        self.recommendedMemoryGB = recommendedMemoryGB
        self.coResidentMemoryGB = coResidentMemoryGB
        self.swapWarningMemoryGB = swapWarningMemoryGB
        self.ggufCreateHint = ggufCreateHint
        self.noteZh = noteZh
        self.noteEn = noteEn
    }

    /// The reference sent to Ollama when nothing overrides it.
    public var ollamaRef: String {
        defaultTag.isEmpty ? ollamaModel : "\(ollamaModel):\(defaultTag)"
    }

    public var estimatedResidentGB: Int { weightGigabytes + contextOverheadGB }

    public func admission(memoryGB: Int) -> ModelAdmission {
        if memoryGB >= coResidentMemoryGB { return .coResident }
        if memoryGB >= recommendedMemoryGB { return .recommended }
        if memoryGB > swapWarningMemoryGB { return .constrained }
        return .swapWarning
    }

    public func pullCommand(for ref: String) -> String { "ollama pull \(ref)" }

    /// The line the console shows under the picker: the estimate, whether this Mac
    /// clears it, and how to bring in a GGUF the hub does not carry.
    public func memoryNote(ref: String, memoryGB: Int) -> String {
        let verdict = admission(memoryGB: memoryGB)
        var note = "\(weightGigabytes) GB weights + \(contextOverheadGB) GB context ≈ \(estimatedResidentGB) GB resident; " +
            "\(memoryGB) GB machine → \(verdict.titleEn.lowercased()) " +
            "(recommended ≥ \(recommendedMemoryGB) GB, co-resident ≥ \(coResidentMemoryGB) GB). " +
            "Pull with \(pullCommand(for: ref))."
        if let ggufCreateHint { note += " Custom GGUF: \(ggufCreateHint)." }
        return note
    }
}

/// Every local model the console may offer. `Qwen3.8` stays the default on all
/// three tiers, so an install that never pulled anything else keeps working.
public enum ModelCatalog {
    public static let qwen38_27b_q8 = LLMModelOption(
        id: "qwen3.8-27b-q8_0",
        displayName: "Qwen3.8-27B · Q8_0",
        ollamaModel: "qwen3.8",
        defaultTag: "27b-q8_0",
        quantization: "Q8_0",
        parameterBillions: 27,
        weightGigabytes: 29,
        contextOverheadGB: 6,
        recommendedMemoryGB: 96,
        coResidentMemoryGB: 96,
        swapWarningMemoryGB: 47,
        noteZh: "旗舰档默认：全精度 LTX-2.5 与 Q8_0 27B 同时常驻。",
        noteEn: "Flagship default: the full-precision LTX-2.5 graph and a Q8_0 27B stay resident together."
    )

    public static let qwen38_27b_q4 = LLMModelOption(
        id: "qwen3.8-27b-q4_k_m",
        displayName: "Qwen3.8-27B · Q4_K_M",
        ollamaModel: "qwen3.8",
        defaultTag: "27b-q4_k_m",
        quantization: "Q4_K_M",
        parameterBillions: 27,
        weightGigabytes: 17,
        contextOverheadGB: 5,
        recommendedMemoryGB: 48,
        coResidentMemoryGB: 64,
        swapWarningMemoryGB: 23,
        noteZh: "量化档默认：8-bit LTX 与 Q4_K_M 27B 在 48–95 GB 之间共存。",
        noteEn: "Quantised default: an 8-bit LTX graph and a Q4_K_M 27B share the 48-95 GB band."
    )

    public static let qwen38_9b_q4 = LLMModelOption(
        id: "qwen3.8-9b-q4_k_m",
        displayName: "Qwen3.8-9B · Q4_K_M",
        ollamaModel: "qwen3.8",
        defaultTag: "9b-q4_k_m",
        quantization: "Q4_K_M",
        parameterBillions: 9,
        weightGigabytes: 6,
        contextOverheadGB: 3,
        recommendedMemoryGB: 16,
        coResidentMemoryGB: 32,
        swapWarningMemoryGB: 11,
        noteZh: "轻量档默认：短任务本机完成，重型视频交给边缘算力。",
        noteEn: "Light default: short jobs stay local, heavy video goes to the mesh."
    )

    /// 20 GB of Q4_K_M weights. The node publishes no parameter count for it, so
    /// `parameterBillions` stays nil rather than guessing one into the interface.
    public static let inkling2Mini = LLMModelOption(
        id: "inkling-2-mini",
        displayName: "Inkling-2-Mini",
        ollamaModel: "inkling-2-mini",
        defaultTag: "",
        quantization: "Q4_K_M",
        parameterBillions: nil,
        weightGigabytes: 20,
        contextOverheadGB: 4,
        recommendedMemoryGB: 32,
        coResidentMemoryGB: 48,
        swapWarningMemoryGB: 24,
        ggufCreateHint: "ollama create inkling-2-mini:q4_k_m -f Inkling-2-Mini.Modelfile",
        noteZh: "可选本地模型：约 20 GB 权重，建议 32 GB 起步；48 GB 起可与常规多媒体、系统服务并行；24 GB 及以下触发内存交换预警，节点将拒绝本机重载任务，以免 OOM 卡死。",
        noteEn: "Optional local model: about 20 GB of weights, 32 GB recommended. From 48 GB it runs alongside ordinary media and system services; at 24 GB or below it raises a swap warning and the node refuses heavy local jobs rather than risk an OOM hang."
    )

    /// The order the console lists them in.
    public static let options: [LLMModelOption] = [
        qwen38_27b_q8, qwen38_27b_q4, qwen38_9b_q4, inkling2Mini
    ]

    public static func option(id: String) -> LLMModelOption? {
        options.first { $0.id == id }
    }

    /// Matches a submitted Ollama reference against the catalog. A tagged
    /// reference whose tag the catalog does not list (`inkling-2-mini:q4_k_m`, the
    /// form an override produces) still resolves through its base model name, so
    /// the admission verdict follows the weights rather than the spelling.
    public static func option(matching ref: String) -> LLMModelOption? {
        let trimmed = ref.trimmedWireReference
        guard !trimmed.isEmpty else { return nil }
        if let exact = options.first(where: { $0.ollamaRef == trimmed }) { return exact }
        if let byID = option(id: trimmed) { return byID }
        let base = trimmed.components(separatedBy: ":").first ?? trimmed
        return options.first { $0.ollamaModel == base || $0.ollamaModel == trimmed }
    }
}

// MARK: - Model reference overrides

/// Maps a catalog id to the reference actually imported on this machine.
///
/// A hand-built GGUF lands as `inkling-2-mini:q4_k_m` while the catalog still
/// says `inkling-2-mini`. Rather than fork the catalog per site, the owner writes
/// one line into `config/model_refs.json` or sets `POPOPX_OLLAMA_REF_INKLING_2_MINI`,
/// and the node asks for the tag that exists locally.
public struct ModelRefOverrides: Codable, Sendable, Equatable {
    /// `POPOPX_OLLAMA_REF_<ID>`: the id uppercased, every non-alphanumeric `_`.
    public static let envPrefix = "POPOPX_OLLAMA_REF_"

    public var refs: [String: String]

    public init(refs: [String: String] = [:]) {
        self.refs = refs
    }

    public static func envKey(forID id: String) -> String {
        let folded = id.uppercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") }
        return envPrefix + String(folded)
    }

    /// A reference reaches `ollama` as one argument-vector element, so a control
    /// character cannot break out into a shell — but a leading `-` would still be
    /// read as a flag, and `registry:5000/ns/model` is not a local tag at all: it
    /// is an address, and Ollama would go and fetch from it. Odd values are dropped,
    /// which falls back to the catalog default.
    public static func isValid(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 128, !ref.hasPrefix("-") else { return false }
        guard !ref.contains(".."), !ref.hasPrefix("/"), !ref.hasSuffix("/"), !ref.contains("//") else { return false }
        // At most one namespace separator, and no colon ahead of it. `library/x:tag`
        // is still a model name; `http://host/x` and `host:5000/x/y` are not.
        if let slash = ref.firstIndex(of: "/") {
            guard !ref[ref.index(after: slash)...].contains("/") else { return false }
            guard !ref[..<slash].contains(":") else { return false }
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-:/")
        return ref.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Reads `AppPaths.modelRefsFile`. An unreadable or malformed file means "no
    /// overrides", so a bad edit cannot stop the node from reaching its models.
    public static func load(from url: URL = AppPaths.modelRefsFile) -> ModelRefOverrides {
        guard let data = try? Data(contentsOf: url),
              let document = NodeJSON.decode(ModelRefOverrides.self, from: data) else {
            return ModelRefOverrides()
        }
        return ModelRefOverrides(refs: document.refs.filter { isValid($0.value) })
    }

    /// env → config file → the reference the caller already had.
    public static func resolve(
        option: LLMModelOption,
        submitted: String? = nil,
        environment: [String: String]? = nil,
        file: ModelRefOverrides? = nil
    ) -> String {
        let submittedRef = (submitted ?? "").trimmedWireReference
        // A catalog id is a user-interface token, not an Ollama name — the menu bar
        // and the console both submit it. Only a reference the daemon could actually
        // resolve may fall back, so an id maps to its catalog reference.
        let resolvedFallback = submittedRef.isEmpty || submittedRef == option.id ? option.ollamaRef : submittedRef
        let env = environment ?? ProcessInfo.processInfo.environment
        if let fromEnv = env[envKey(forID: option.id)]?.trimmedWireReference, isValid(fromEnv) {
            return fromEnv
        }
        let overrides = file ?? load()
        if let fromFile = overrides.refs[option.id]?.trimmedWireReference, isValid(fromFile) {
            return fromFile
        }
        return resolvedFallback
    }
}

extension String {
    /// Trims the surrounding whitespace a copied-and-pasted reference arrives with.
    var trimmedWireReference: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Live load numbers shown next to the static hardware profile.
public struct SystemLoad: Codable, Sendable, Equatable {
    public var cpuLoadPercent: Double
    public var memoryUsed: ByteCount
    public var memoryPressure: MemoryPressure
    public var activeProcessCount: Int
    public var throughputMBps: Double?
    public var sampledAt: Date

    public enum MemoryPressure: String, Codable, Sendable {
        case nominal, warning, critical

        public var isSafeToStartHeavyJob: Bool { self != .critical }
    }

    public init(
        cpuLoadPercent: Double,
        memoryUsed: ByteCount,
        memoryPressure: MemoryPressure,
        activeProcessCount: Int,
        throughputMBps: Double? = nil,
        sampledAt: Date = Date()
    ) {
        self.cpuLoadPercent = cpuLoadPercent
        self.memoryUsed = memoryUsed
        self.memoryPressure = memoryPressure
        self.activeProcessCount = activeProcessCount
        self.throughputMBps = throughputMBps
        self.sampledAt = sampledAt
    }
}

// MARK: - Environment installer

public enum InstallPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case detecting
    case provisioning
    case pullingLLM
    case preparingWorkspace
    case downloadingWeights
    case verifying
    case ready
    case failed
    case cancelled
}

public enum EventLevel: String, Codable, Sendable {
    case debug, info, notice, success, warning, error

    public var glyph: String {
        switch self {
        case .debug: return "·"
        case .info: return "›"
        case .notice: return "•"
        case .success: return "✓"
        case .warning: return "!"
        case .error: return "✕"
        }
    }
}

public enum StepState: String, Codable, Sendable {
    case pending, running, done, skipped, failed
}

/// One line of the streaming installer log, mirrored into SSE and the audit file.
public struct InstallEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(seq)" }
    public var seq: Int
    public var phase: InstallPhase
    public var level: EventLevel
    public var text: String
    public var progress: Double
    public var at: Date

    public init(
        seq: Int,
        phase: InstallPhase,
        level: EventLevel,
        text: String,
        progress: Double = 0,
        at: Date = Date()
    ) {
        self.seq = seq
        self.phase = phase
        self.level = level
        self.text = text
        self.progress = min(max(progress, 0), 1)
        self.at = at
    }
}

/// A checklist row in the wizard.
public struct InstallStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var titleZh: String
    public var titleHant: String
    public var titleEn: String
    public var state: StepState
    public var detail: String
    public var progress: Double
    public var updatedAt: Date

    /// `titleHant` is frozen at initialisation from `titleZh`, the same way
    /// `EngineDescriptor` carries it: the broadcast snapshot cannot know which
    /// language each tab is displaying.
    public init(
        id: String,
        titleZh: String,
        titleEn: String,
        state: StepState = .pending,
        detail: String = "",
        progress: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleZh = titleZh
        self.titleHant = TraditionalChinese.render(titleZh)
        self.titleEn = titleEn
        self.state = state
        self.detail = detail
        self.progress = min(max(progress, 0), 1)
        self.updatedAt = updatedAt
    }
}

public struct InstallState: Codable, Sendable, Equatable {
    public var phase: InstallPhase
    public var running: Bool
    public var progress: Double
    public var steps: [InstallStep]
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastError: String?
    public var tail: [InstallEvent]

    public init(
        phase: InstallPhase = .idle,
        running: Bool = false,
        progress: Double = 0,
        steps: [InstallStep] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastError: String? = nil,
        tail: [InstallEvent] = []
    ) {
        self.phase = phase
        self.running = running
        self.progress = min(max(progress, 0), 1)
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastError = lastError
        self.tail = tail
    }

    public var isComplete: Bool { phase == .ready }
}

/// Presence/version probe results for the host toolchain.
public struct ToolchainProbe: Codable, Sendable, Equatable {
    public var name: String
    public var resolvedPath: String?
    public var versionLine: String?
    public var present: Bool
    public var checkedAt: Date

    public init(
        name: String,
        resolvedPath: String?,
        versionLine: String?,
        present: Bool,
        checkedAt: Date = Date()
    ) {
        self.name = name
        self.resolvedPath = resolvedPath
        self.versionLine = versionLine
        self.present = present
        self.checkedAt = checkedAt
    }
}

// MARK: - Pairing, SMP bridge

public struct NodeIdentity: Codable, Sendable, Equatable {
    public var nodeId: String
    public var publicKey: String
    public var displayName: String
    public var version: String
    public var schemaRevision: Int
    public var startedAt: Date

    public init(
        nodeId: String,
        publicKey: String,
        displayName: String,
        version: String = NodeVersion.current.semanticString,
        schemaRevision: Int = NodeVersion.schemaRevision,
        startedAt: Date = Date()
    ) {
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.displayName = displayName
        self.version = version
        self.schemaRevision = schemaRevision
        self.startedAt = startedAt
    }
}

/// The QR payload minted on wizard step 2.
///
/// Three strings, three jobs. The QR and every copyable link carry
/// `OpaquePairingCodec`'s envelope of `code`, so nothing that leaves the Mac names
/// a relay; `code` itself is the signed credential the pairing whitelist records and
/// what the diagnostics panel shows the node's owner; `invitationURI` is the raw
/// daemon link, kept for the same panel and for a manual paste that cannot work
/// without it.
public struct PairingOffer: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }

    /// `PPXNODE1-<base64url(body)>.<base64url(signature)>`
    public var code: String
    /// Real connection-request link from the daemon: `popopx:/invitation#/?v=…&smp=…`
    /// (long form) or `popopx:/i#<linkId>/<linkKey>` (short form, what we render).
    /// `https://popopx.chat/…` is the share spelling of the same link. The
    /// `simplex://ssmp/#/vi/…` shape written in the product spec does not exist in
    /// either fork, so nothing on earth would parse it — see `NodeWire.invitationScheme`.
    public var invitationURI: String
    public var nodePublicKey: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var oneTime: Bool
    public var used: Bool

    private enum CodingKeys: String, CodingKey {
        case code, invitationURI, nodePublicKey, issuedAt, expiresAt, oneTime, used
    }

    /// Not stored properties, so they stay out of `init(from:)`: the envelope a
    /// displayed surface shows is derived from `code` on every encode.
    private enum DerivedKeys: String, CodingKey {
        case pairingLink, pairingMask
    }

    public init(
        code: String,
        invitationURI: String,
        nodePublicKey: String,
        issuedAt: Date,
        expiresAt: Date,
        oneTime: Bool = true,
        used: Bool = false
    ) {
        self.code = code
        self.invitationURI = invitationURI
        self.nodePublicKey = nodePublicKey
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.oneTime = oneTime
        self.used = used
    }

    public var isValid: Bool { !used && Date() < expiresAt }

    public func secondsRemaining(at now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now)))
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(code, forKey: .code)
        try box.encode(invitationURI, forKey: .invitationURI)
        try box.encode(nodePublicKey, forKey: .nodePublicKey)
        try box.encode(issuedAt, forKey: .issuedAt)
        try box.encode(expiresAt, forKey: .expiresAt)
        try box.encode(oneTime, forKey: .oneTime)
        try box.encode(used, forKey: .used)
        // A displayed surface shows the envelope, never the raw credential: the same
        // bytes the QR carries, so what a user copies is what a phone scans.
        guard encoder.userInfo[.popopxDisplaysOpaqueLinks] != nil,
              let link = try? OpaquePairingCodec.pairingLink(code) else { return }
        var derived = encoder.container(keyedBy: DerivedKeys.self)
        try derived.encode(link, forKey: .pairingLink)
        try derived.encode(OpaquePairingCodec.mask(link), forKey: .pairingMask)
    }
}

/// A rendered QR code, PNG bytes already produced by CoreImage.
public struct QRAsset: Sendable, Equatable {
    public var png: Data
    public var pixelSize: Int
    public var generatedAt: Date

    public init(png: Data, pixelSize: Int, generatedAt: Date = Date()) {
        self.png = png
        self.pixelSize = pixelSize
        self.generatedAt = generatedAt
    }
}

public enum DaemonState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case degraded
    case missingBinary

    public var isLive: Bool { self == .running || self == .degraded }
}

public struct BridgeStatus: Codable, Sendable, Equatable {
    public var daemon: DaemonState
    public var binaryPath: String?
    public var controlPort: UInt16
    public var websocketConnected: Bool
    public var pairedDevices: Int
    public var acceptedCommands: Int
    public var rejectedCommands: Int
    public var deliveredResults: Int
    public var outboxDepth: Int
    public var uptimeSeconds: Int
    public var lastError: String?
    public var sampledAt: Date

    public init(
        daemon: DaemonState,
        binaryPath: String? = nil,
        controlPort: UInt16 = NodeWire.popopxControlPort,
        websocketConnected: Bool = false,
        pairedDevices: Int = 0,
        acceptedCommands: Int = 0,
        rejectedCommands: Int = 0,
        deliveredResults: Int = 0,
        outboxDepth: Int = 0,
        uptimeSeconds: Int = 0,
        lastError: String? = nil,
        sampledAt: Date = Date()
    ) {
        self.daemon = daemon
        self.binaryPath = binaryPath
        self.controlPort = controlPort
        self.websocketConnected = websocketConnected
        self.pairedDevices = pairedDevices
        self.acceptedCommands = acceptedCommands
        self.rejectedCommands = rejectedCommands
        self.deliveredResults = deliveredResults
        self.outboxDepth = outboxDepth
        self.uptimeSeconds = uptimeSeconds
        self.lastError = lastError
        self.sampledAt = sampledAt
    }
}

/// One iPhone that completed the QR handshake.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { publicKey }
    public var publicKey: String
    public var label: String
    public var deviceModel: String?
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var revoked: Bool

    public init(
        publicKey: String,
        label: String,
        deviceModel: String? = nil,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        revoked: Bool = false
    ) {
        self.publicKey = publicKey
        self.label = label
        self.deviceModel = deviceModel
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.revoked = revoked
    }
}

// MARK: - Commands and results

/// A decoded, authenticated instruction from the iOS "Discover" service account.
public struct NodeCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var serviceId: String
    public var action: String
    public var payload: String
    public var senderPublicKey: String
    public var receivedAt: Date
    public var authenticated: Bool

    public init(
        id: String = UUID().uuidString,
        serviceId: String,
        action: String,
        payload: String,
        senderPublicKey: String,
        receivedAt: Date = Date(),
        authenticated: Bool = true
    ) {
        self.id = id
        self.serviceId = serviceId
        self.action = action
        self.payload = payload
        self.senderPublicKey = senderPublicKey
        self.receivedAt = receivedAt
        self.authenticated = authenticated
    }

    /// Payload decoded as JSON when possible, otherwise as a bare string.
    public var jsonPayload: JSONValue { JSONValue.parse(payload) }

    public var isDeterministicLock: Bool {
        let probe = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return NodeWire.lockTriggers.contains(probe) || NodeWire.lockTriggers.contains(alt)
    }

    /// Serialises back to the `::popopx_sys::…` wire form (audit logs, console
    /// command injection on the wizard's developer panel).
    public var wireString: String {
        "\(NodeWire.commandPrefix)\(serviceId)::\(action)::\(payload)"
    }
}

/// What an engine hands back; the bridge turns this into a card plus artifacts.
public struct CommandResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var commandID: String?
    public var engine: EngineKind
    public var ok: Bool
    public var deterministic: Bool
    public var headline: String
    public var body: String
    public var artifacts: [String]
    public var durationMs: Int
    public var at: Date
    public var metrics: [String: JSONValue]
    /// Names the card when the reply is not one of the ten subscription businesses.
    /// The privacy bridges ride this same struct because it is what the outbox
    /// stores, and their cards must not sign as "Shadow Chief of Staff".
    ///
    /// Optional on purpose: `Codable` synthesises a *required* key for
    /// `String = ""`, so a non-optional field would fail to decode every outbox
    /// file written before it existed, silently dropping queued results.
    public var cardLabel: String?

    public init(
        id: String = UUID().uuidString,
        commandID: String? = nil,
        engine: EngineKind,
        ok: Bool,
        deterministic: Bool = false,
        headline: String,
        body: String = "",
        artifacts: [String] = [],
        durationMs: Int = 0,
        at: Date = Date(),
        metrics: [String: JSONValue] = [:],
        cardLabel: String? = nil
    ) {
        self.id = id
        self.commandID = commandID
        self.engine = engine
        self.ok = ok
        self.deterministic = deterministic
        self.headline = headline
        self.body = body
        self.artifacts = artifacts
        self.durationMs = durationMs
        self.at = at
        self.metrics = metrics
        self.cardLabel = cardLabel
    }

    public static func failure(_ engine: EngineKind, _ message: String, commandID: String? = nil) -> CommandResult {
        CommandResult(commandID: commandID, engine: engine, ok: false, headline: message)
    }

    /// Compact card text delivered over SMP when there is no attachment.
    public var cardText: String {
        let flag = ok ? "✅" : "⚠️"
        let timing = durationMs > 0 ? " · \(durationMs) ms" : ""
        let who = cardLabel ?? engine.displayNameEn
        return "\(flag) \(who) · \(headline)\(timing)"
    }
}

// MARK: - Engines

/// The ten subscription businesses the node executes locally. Raw values are the
/// stable iOS-facing identifiers and must never change.
public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case shadowCos = "shadow_cos"
    case zeroTrustWarroom = "zero_trust_warroom"
    case zerotraceStudio = "zerotrace_studio"
    case soloAutopilot = "solo_autopilot"
    case edgeComputeMesh = "edge_compute_mesh"
    case morningTv = "morning_tv"
    case phantomSentinel = "phantom_sentinel"
    case chronoArk = "chrono_ark"
    case healthSentinel = "health_sentinel"
    case creatorPaywallHub = "creator_paywall_hub"

    public var id: String { rawValue }

    public var displayNameZh: String {
        switch self {
        case .shadowCos: return "影子首席幕僚"
        case .zeroTrustWarroom: return "零信任微团队暗室"
        case .zerotraceStudio: return "零痕视觉脱敏工作台"
        case .soloAutopilot: return "一人公司全自动流水线"
        case .edgeComputeMesh: return "边缘算力共享节点"
        case .morningTv: return "私人定制早间电视台"
        case .phantomSentinel: return "物理空间哨兵"
        case .chronoArk: return "时光数字方舟"
        case .healthSentinel: return "零泄露私人健康哨兵"
        case .creatorPaywallHub: return "大 V 防盗版付费频道管家"
        }
    }

    public var displayNameEn: String {
        switch self {
        case .shadowCos: return "Shadow Chief of Staff"
        case .zeroTrustWarroom: return "Zero-Trust War Room"
        case .zerotraceStudio: return "Zero-Trace Studio"
        case .soloAutopilot: return "Solo Autopilot"
        case .edgeComputeMesh: return "Edge Compute Mesh"
        case .morningTv: return "Morning TV"
        case .phantomSentinel: return "Phantom Sentinel"
        case .chronoArk: return "Chrono Ark"
        case .healthSentinel: return "Health Sentinel"
        case .creatorPaywallHub: return "Creator Paywall Hub"
        }
    }

    /// The engine name as this node displays it. Ten businesses have two
    /// maintained names, not seventeen, so a Hungarian menu reads English
    /// rather than a machine-guessed translation — the same rule the console
    /// catalogs and the report copy follow.
    public func displayName(for language: ConsoleLanguage) -> String {
        language.text(zh: displayNameZh, en: displayNameEn)
    }

    public var taglineZh: String {
        switch self {
        case .shadowCos: return "本地简报与谈判提词"
        case .zeroTrustWarroom: return "A/B 切片隐形水印与逆向溯源"
        case .zerotraceStudio: return "抹除指纹并生成数字播报员"
        case .soloAutopilot: return "脚本到成片的全自动短视屏"
        case .edgeComputeMesh: return "空闲时段出借算力赚取算力点"
        case .morningTv: return "清晨定时聚合专属播报"
        case .phantomSentinel: return "确定性一键闭锁状态机"
        case .chronoArk: return "时间锁保险箱与失联托付"
        case .healthSentinel: return "离线解读报告与双耳节拍"
        case .creatorPaywallHub: return "验票、指纹分发与红包核销"
        }
    }

    public var taglineEn: String {
        switch self {
        case .shadowCos: return "Local briefings and negotiation prompts"
        case .zeroTrustWarroom: return "A/B slice blind watermarking and reverse tracing"
        case .zerotraceStudio: return "Strip fingerprints, synthesise an anchor"
        case .soloAutopilot: return "Script to finished clip, unattended"
        case .edgeComputeMesh: return "Lend idle cycles for compute points"
        case .morningTv: return "Scheduled dawn aggregation broadcast"
        case .phantomSentinel: return "Deterministic lockdown state machine"
        case .chronoArk: return "Time-locked vault and succession"
        case .healthSentinel: return "Offline report reading and binaural beats"
        case .creatorPaywallHub: return "Ticket checks, fingerprinted drops, red packets"
        }
    }

    /// SF Symbols name used by the menu and the web console.
    public var symbolName: String {
        switch self {
        case .shadowCos: return "brain.head.profile"
        case .zeroTrustWarroom: return "water.waves"
        case .zerotraceStudio: return "eye.slash"
        case .soloAutopilot: return "film.stack"
        case .edgeComputeMesh: return "point.3.connected.trianglepath.dotted"
        case .morningTv: return "sun.horizon"
        case .phantomSentinel: return "lock.shield"
        case .chronoArk: return "hourglass"
        case .healthSentinel: return "heart.text.square"
        case .creatorPaywallHub: return "play.tv"
        }
    }

    /// `true` when the engine must never call a language model, per the brief.
    public var isDeterministic: Bool {
        self == .phantomSentinel
    }

    /// Substrate the engine leans on, surfaced in the capability matrix.
    public var substrate: String {
        switch self {
        case .shadowCos: return "Ollama / Qwen3.8"
        case .zeroTrustWarroom: return "FFmpeg + GOP slicer"
        case .zerotraceStudio: return "FFmpeg + Vision + Ollama"
        case .soloAutopilot: return "LTX-2.5 MLX + FFmpeg"
        case .edgeComputeMesh: return "Sandboxed Process + CryptoKit"
        case .morningTv: return "RSS + LTX-2.5 MLX"
        case .phantomSentinel: return "AppKit + diskutil + Webhook"
        case .chronoArk: return "CryptoKit hash-chain lock"
        case .healthSentinel: return "Vision + waveform synthesiser"
        case .creatorPaywallHub: return "Watermark engine + ledger"
        }
    }

    public var usesModelInLoop: Bool {
        switch self {
        case .shadowCos, .zerotraceStudio, .soloAutopilot, .morningTv, .edgeComputeMesh, .creatorPaywallHub:
            return true
        case .zeroTrustWarroom, .phantomSentinel, .chronoArk, .healthSentinel:
            return false
        }
    }

    /// Engines that may be switched on before the AI stack is installed.
    public var worksWithoutLocalModels: Bool {
        switch self {
        case .zeroTrustWarroom, .phantomSentinel, .chronoArk, .healthSentinel:
            return true
        case .shadowCos, .zerotraceStudio, .soloAutopilot, .edgeComputeMesh, .morningTv, .creatorPaywallHub:
            return false
        }
    }

    /// Ordering used by the wizard and the menu.
    public static let displayOrder: [EngineKind] = EngineKind.allCases
}

/// Static description of an engine, rendered once into the wizard.
public struct EngineDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: EngineKind
    public var titleZh: String
    public var titleHant: String
    public var titleEn: String
    public var taglineZh: String
    public var taglineHant: String
    public var taglineEn: String
    public var symbolName: String
    public var deterministic: Bool
    public var requires: [String]
    public var order: Int

    /// The `Hant` fields travel on the wire because one snapshot is broadcast to
    /// every browser tab, so the Traditional rendering has to be produced by the
    /// node rather than by whichever language the viewer happens to pick.
    public init(kind: EngineKind, order: Int) {
        self.kind = kind
        self.titleZh = kind.displayNameZh
        self.titleHant = TraditionalChinese.render(kind.displayNameZh)
        self.titleEn = kind.displayNameEn
        self.taglineZh = kind.taglineZh
        self.taglineHant = TraditionalChinese.render(kind.taglineZh)
        self.taglineEn = kind.taglineEn
        self.symbolName = kind.symbolName
        self.deterministic = kind.isDeterministic
        self.requires = kind.worksWithoutLocalModels ? ["ffmpeg"] : ["ffmpeg", "ollama"]
        self.order = order
    }
}

/// Live per-engine state.
public struct EngineRuntime: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: EngineKind
    public var enabled: Bool
    public var busy: Bool
    public var runs: Int
    public var failures: Int
    public var lastRunAt: Date?
    public var lastSummary: String?
    public var lastDurationMs: Int?
    public var artifactsProduced: Int

    public init(
        kind: EngineKind,
        enabled: Bool,
        busy: Bool = false,
        runs: Int = 0,
        failures: Int = 0,
        lastRunAt: Date? = nil,
        lastSummary: String? = nil,
        lastDurationMs: Int? = nil,
        artifactsProduced: Int = 0
    ) {
        self.kind = kind
        self.enabled = enabled
        self.busy = busy
        self.runs = runs
        self.failures = failures
        self.lastRunAt = lastRunAt
        self.lastSummary = lastSummary
        self.lastDurationMs = lastDurationMs
        self.artifactsProduced = artifactsProduced
    }
}

// MARK: - Engine configuration documents

/// A weekday/interval window in which the node may accept mesh work.
public struct TimeWindow: Codable, Sendable, Equatable, Hashable {
    public var startHour: Int
    public var endHour: Int
    public var weekdays: [Int]

    public init(startHour: Int, endHour: Int, weekdays: [Int] = Array(2...6)) {
        self.startHour = min(max(startHour, 0), 23)
        self.endHour = min(max(endHour, 0), 23)
        self.weekdays = weekdays.isEmpty ? Array(2...6) : weekdays
    }

    /// `true` when `date` falls inside the window, wrapping past midnight.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return false }
        guard weekdays.contains(weekday) else { return false }
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }

    public var label: String {
        String(format: "%02d:00-%02d:00", startHour, endHour)
    }
}

public struct MeshConfig: Codable, Sendable, Equatable {
    public var sharingEnabled: Bool
    public var maxMemoryGB: Int
    public var maxConcurrentJobs: Int
    public var idleWindows: [TimeWindow]
    public var minFreeDiskGB: Int
    public var requireOwnerPresent: Bool
    public var accruedPoints: Int
    public var settledJobs: Int

    public init(
        sharingEnabled: Bool = false,
        maxMemoryGB: Int = 16,
        maxConcurrentJobs: Int = 1,
        idleWindows: [TimeWindow] = [TimeWindow(startHour: 1, endHour: 7)],
        minFreeDiskGB: Int = 40,
        requireOwnerPresent: Bool = true,
        accruedPoints: Int = 0,
        settledJobs: Int = 0
    ) {
        self.sharingEnabled = sharingEnabled
        self.maxMemoryGB = max(4, maxMemoryGB)
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        self.idleWindows = idleWindows
        self.minFreeDiskGB = max(10, minFreeDiskGB)
        self.requireOwnerPresent = requireOwnerPresent
        self.accruedPoints = accruedPoints
        self.settledJobs = settledJobs
    }

    public func acceptingWork(at date: Date = Date()) -> Bool {
        sharingEnabled && idleWindows.contains { $0.contains(date) }
    }
}

public struct SentinelConfig: Codable, Sendable, Equatable {
    public var clipboardClear: Bool
    public var unmountPaths: [String]
    public var lockScreen: Bool
    public var sleepDisplays: Bool
    public var webhookURL: String
    public var webhookSecret: String
    public var triggerPhrases: [String]
    public var lastLockAt: Date?

    public init(
        clipboardClear: Bool = true,
        unmountPaths: [String] = [],
        lockScreen: Bool = true,
        sleepDisplays: Bool = true,
        webhookURL: String = "",
        webhookSecret: String = "",
        triggerPhrases: [String] = NodeWire.lockTriggers,
        lastLockAt: Date? = nil
    ) {
        self.clipboardClear = clipboardClear
        self.unmountPaths = unmountPaths
        self.lockScreen = lockScreen
        self.sleepDisplays = sleepDisplays
        self.webhookURL = webhookURL
        self.webhookSecret = webhookSecret
        self.triggerPhrases = triggerPhrases.isEmpty ? NodeWire.lockTriggers : triggerPhrases
        self.lastLockAt = lastLockAt
    }
}

public struct ArkConfig: Codable, Sendable, Equatable {
    public var heartbeatIntervalHours: Int
    public var missedHeartbeatsBeforeRelease: Int
    public var timelockSeconds: Int
    public var sealedArchives: [String]
    public var beneficiaryName: String
    public var beneficiaryQueue: String
    public var blessingClipPath: String?
    public var lastHeartbeatAt: Date?
    public var releasedAt: Date?

    public init(
        heartbeatIntervalHours: Int = 72,
        missedHeartbeatsBeforeRelease: Int = 4,
        timelockSeconds: Int = 60 * 60 * 24 * 365,
        sealedArchives: [String] = [],
        beneficiaryName: String = "",
        beneficiaryQueue: String = "",
        blessingClipPath: String? = nil,
        lastHeartbeatAt: Date? = nil,
        releasedAt: Date? = nil
    ) {
        self.heartbeatIntervalHours = max(1, heartbeatIntervalHours)
        self.missedHeartbeatsBeforeRelease = max(1, missedHeartbeatsBeforeRelease)
        self.timelockSeconds = max(60, timelockSeconds)
        self.sealedArchives = sealedArchives
        self.beneficiaryName = beneficiaryName
        self.beneficiaryQueue = beneficiaryQueue
        self.blessingClipPath = blessingClipPath
        self.lastHeartbeatAt = lastHeartbeatAt
        self.releasedAt = releasedAt
    }

    /// Wall-clock moment at which the grace period expires.
    public var releaseDeadline: Date? {
        guard let last = lastHeartbeatAt ?? releasedAt else { return nil }
        let grace = TimeInterval(heartbeatIntervalHours * max(1, missedHeartbeatsBeforeRelease) * 3600)
        return last.addingTimeInterval(grace)
    }

    /// Absolute expiry derived from the hash-chain time lock.
    public var timelockExpiry: Date? {
        guard lastHeartbeatAt != nil || !sealedArchives.isEmpty else { return nil }
        let anchor = lastHeartbeatAt ?? Date()
        return anchor.addingTimeInterval(TimeInterval(timelockSeconds))
    }
}

public struct WarroomConfig: Codable, Sendable, Equatable {
    public var payloadBits: Int
    public var segmentsPerVideo: Int
    public var queueRegistry: [String: Int]
    public var lastTraceHit: String?

    public init(
        payloadBits: Int = 16,
        segmentsPerVideo: Int = 16,
        queueRegistry: [String: Int] = [:],
        lastTraceHit: String? = nil
    ) {
        self.payloadBits = min(max(payloadBits, 8), 32)
        self.segmentsPerVideo = min(max(segmentsPerVideo, 8), 64)
        self.queueRegistry = queueRegistry
        self.lastTraceHit = lastTraceHit
    }
}

public struct MorningTvConfig: Codable, Sendable, Equatable {
    public var fireHour: Int
    public var fireMinute: Int
    public var feeds: [String]
    public var targetMinutes: Int
    public var voiceRef: String
    public var lastBroadcastAt: Date?

    public init(
        fireHour: Int = 6,
        fireMinute: Int = 30,
        feeds: [String] = [
            "https://feeds.bbci.co.uk/news/technology/rss.xml",
            "https://www.reutersagency.com/feed/?best-topics=tech&post_type=best"
        ],
        targetMinutes: Int = 5,
        voiceRef: String = "default",
        lastBroadcastAt: Date? = nil
    ) {
        self.fireHour = min(max(fireHour, 0), 23)
        self.fireMinute = min(max(fireMinute, 0), 59)
        self.feeds = feeds
        self.targetMinutes = min(max(targetMinutes, 1), 15)
        self.voiceRef = voiceRef
        self.lastBroadcastAt = lastBroadcastAt
    }
}

public struct StudioConfig: Codable, Sendable, Equatable {
    public var ingestDirectories: [String]
    public var shredOriginals: Bool
    public var stripGPS: Bool
    public var stripDeviceTags: Bool
    public var anchorStyle: String

    public init(
        ingestDirectories: [String] = [],
        shredOriginals: Bool = true,
        stripGPS: Bool = true,
        stripDeviceTags: Bool = true,
        anchorStyle: String = "studio-neutral"
    ) {
        self.ingestDirectories = ingestDirectories
        self.shredOriginals = shredOriginals
        self.stripGPS = stripGPS
        self.stripDeviceTags = stripDeviceTags
        self.anchorStyle = anchorStyle
    }
}

public struct HealthConfig: Codable, Sendable, Equatable {
    public var referenceRanges: [String: String]
    public var binauralCarrierHz: Double
    public var binauralBeatHz: Double
    public var binauralDurationSeconds: Int
    public var lastReportAt: Date?

    public init(
        referenceRanges: [String: String] = [
            "systolic": "90-120 mmHg",
            "diastolic": "60-80 mmHg",
            "fasting-glucose": "3.9-6.1 mmol/L",
            "ldl": "< 3.4 mmol/L",
            "hdl": "> 1.0 mmol/L"
        ],
        binauralCarrierHz: Double = 200,
        binauralBeatHz: Double = 2.5,
        binauralDurationSeconds: Int = 600,
        lastReportAt: Date? = nil
    ) {
        self.referenceRanges = referenceRanges
        self.binauralCarrierHz = min(max(binauralCarrierHz, 60), 1200)
        self.binauralBeatHz = min(max(binauralBeatHz, 0.5), 40)
        self.binauralDurationSeconds = min(max(binauralDurationSeconds, 10), 7200)
        self.lastReportAt = lastReportAt
    }
}

public struct PaywallConfig: Codable, Sendable, Equatable {
    public var channelName: String
    public var ticketPublicKey: String
    public var redPacketBudgetPoints: Int
    public var verifiedMembers: [String]
    public var lastDropAt: Date?

    public init(
        channelName: String = "",
        ticketPublicKey: String = "",
        redPacketBudgetPoints: Int = 0,
        verifiedMembers: [String] = [],
        lastDropAt: Date? = nil
    ) {
        self.channelName = channelName
        self.ticketPublicKey = ticketPublicKey
        self.redPacketBudgetPoints = max(0, redPacketBudgetPoints)
        self.verifiedMembers = verifiedMembers
        self.lastDropAt = lastDropAt
    }
}

/// The whole document behind wizard step 3, persisted as `config/settings.json`.
public struct NodeSettings: Codable, Sendable, Equatable {
    public var language: ConsoleLanguage
    public var nodeName: String
    public var enginesEnabled: [String: Bool]
    public var autoStartConsole: Bool
    public var launchAtLogin: Bool
    public var mesh: MeshConfig
    public var sentinel: SentinelConfig
    public var ark: ArkConfig
    public var warroom: WarroomConfig
    public var morningTv: MorningTvConfig
    public var studio: StudioConfig
    public var health: HealthConfig
    public var paywall: PaywallConfig
    public var shadowWorkspaces: [String]
    public var llmModelOverride: String
    public var privacyBridges: PrivacyBridgeConfig?
    public var hubBridges: HubConfig?
    public var updates: UpdateConfig?
    public var discover: DiscoverConfig?
    public var godsEye: GodsEyeViewConfig?
    public var assistant: AssistantConfig?
    public var revision: Int
    public var updatedAt: Date

    public init(
        language: ConsoleLanguage = .system,
        nodeName: String = "POPOPX Node",
        enginesEnabled: [String: Bool] = NodeSettings.defaultEngineSwitches(),
        autoStartConsole: Bool = true,
        launchAtLogin: Bool = false,
        mesh: MeshConfig = MeshConfig(),
        sentinel: SentinelConfig = SentinelConfig(),
        ark: ArkConfig = ArkConfig(),
        warroom: WarroomConfig = WarroomConfig(),
        morningTv: MorningTvConfig = MorningTvConfig(),
        studio: StudioConfig = StudioConfig(),
        health: HealthConfig = HealthConfig(),
        paywall: PaywallConfig = PaywallConfig(),
        shadowWorkspaces: [String] = [],
        llmModelOverride: String = "",
        privacyBridges: PrivacyBridgeConfig? = nil,
        hubBridges: HubConfig? = nil,
        updates: UpdateConfig? = nil,
        discover: DiscoverConfig? = nil,
        godsEye: GodsEyeViewConfig? = nil,
        assistant: AssistantConfig? = nil,
        revision: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.language = language
        self.nodeName = nodeName
        self.enginesEnabled = enginesEnabled
        self.autoStartConsole = autoStartConsole
        self.launchAtLogin = launchAtLogin
        self.mesh = mesh
        self.sentinel = sentinel
        self.ark = ark
        self.warroom = warroom
        self.morningTv = morningTv
        self.studio = studio
        self.health = health
        self.paywall = paywall
        self.shadowWorkspaces = shadowWorkspaces
        self.llmModelOverride = llmModelOverride
        self.privacyBridges = privacyBridges
        self.hubBridges = hubBridges
        self.updates = updates
        self.discover = discover
        self.godsEye = godsEye
        self.assistant = assistant
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public static func defaultEngineSwitches() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: EngineKind.displayOrder.map { kind in
            (kind.rawValue, kind != .edgeComputeMesh)
        })
    }

    public func isEnabled(_ kind: EngineKind) -> Bool {
        enginesEnabled[kind.rawValue] ?? (kind != .edgeComputeMesh)
    }

    public func withEnabled(_ kind: EngineKind, _ value: Bool) -> NodeSettings {
        var copy = self
        copy.enginesEnabled[kind.rawValue] = value
        return copy
    }

    /// Every engine switch name → on/off pair the console can render directly.
    public var enabledEngineList: [EngineKind] {
        EngineKind.displayOrder.filter { isEnabled($0) }
    }

    /// The bridges as they behave when nothing has been stored yet: everything
    /// off. Reading a missing document as "disabled" is what lets the calendar and
    /// workspace tools stay opt-in across an upgrade.
    public var bridges: PrivacyBridgeConfig { privacyBridges ?? PrivacyBridgeConfig.disabled }

    public func withBridges(_ config: PrivacyBridgeConfig) -> NodeSettings {
        var copy = self
        copy.privacyBridges = config
        return copy
    }

    /// The v1.1 edge-hub switches, read the same way: absent means everything off.
    public var hubs: HubConfig { hubBridges ?? HubConfig.disabled }

    public func withHubs(_ config: HubConfig) -> NodeSettings {
        var copy = self
        copy.hubBridges = config
        return copy
    }

    /// Signed-update switches, read like the bridges: absent means off.
    public var updateConfig: UpdateConfig { updates ?? UpdateConfig.disabled }

    public func withUpdates(_ config: UpdateConfig) -> NodeSettings {
        var copy = self
        copy.updates = config
        return copy
    }

    /// Discover aggregator switches, read like the bridges: absent means off.
    public var discoverConfig: DiscoverConfig { discover ?? DiscoverConfig.disabled }

    public func withDiscover(_ config: DiscoverConfig) -> NodeSettings {
        var copy = self
        copy.discover = config
        return copy
    }

    /// Gods Eye View switches, read like the bridges: absent means off.
    public var godsEyeConfig: GodsEyeViewConfig { godsEye ?? .disabled }

    public func withGodsEye(_ config: GodsEyeViewConfig) -> NodeSettings {
        var copy = self
        copy.godsEye = config
        return copy
    }

    /// The private assistant as it behaves when nothing has been stored yet:
    /// switched off, both loops off, mail off.
    public var assistantConfig: AssistantConfig { assistant ?? .disabled }

    public func withAssistant(_ config: AssistantConfig) -> NodeSettings {
        var copy = self
        copy.assistant = config
        return copy
    }
}

// MARK: - Privacy bridges

/// The raw-data capabilities the node may exercise on the owner's behalf, and the
/// availability defaults the calendar tool applies when a caller leaves a probe
/// field out.
///
/// Every capability starts closed and stays closed until the owner flips it in the
/// console, because each one grants access to data that never leaves this Mac:
/// calendar detail, and the file contents inside the authorized directories.
public struct PrivacyBridgeConfig: Codable, Sendable, Equatable {
    /// Hard ceiling on authorized directories. Three is enough for the
    /// "Documents / Projects / Desktop" case and keeps the review surface small.
    public static let maximumDirectories = 3

    public var allowCalendarAccess: Bool
    public var allowWorkspaceRead: Bool
    public var allowWorkspaceWrite: Bool
    /// User-shaped paths (`~/Documents/POPOPX-Workspace`), resolved at use time.
    /// Storing the raw text rather than a resolved URL keeps a settings document
    /// portable across machines and users.
    public var workspaceDirectories: [String]
    /// Empty means "the Mac's current zone", resolved per call rather than frozen
    /// into the settings document.
    public var timezoneIdentifier: String
    public var workingStartHour: Int
    public var workingEndHour: Int
    /// ISO weekday numbers, 1 = Monday … 7 = Sunday.
    public var workdays: [Int]
    public var blockLunch: Bool
    public var lunchStartHour: Int
    public var lunchEndHour: Int
    public var bufferMinutes: Int
    public var defaultDurationMinutes: Int
    /// macOS Notification Center reminder for a new proposal. Tests and headless
    /// runs turn this off; nothing else depends on it.
    public var notifyOnProposal: Bool
    /// Template for the call link written into a created event's `LOCATION` and
    /// `DESCRIPTION`, with `{ref}` and `{node}` placeholders — empty means the tool
    /// proposes meetings without a link.
    ///
    /// A template rather than a constant because the node does not own the call
    /// scheme: minting a plausible `https://…` link here would put a dead button in
    /// the owner's calendar, and the operator pastes their real one once.
    public var callLinkTemplate: String

    public init(
        allowCalendarAccess: Bool = false,
        allowWorkspaceRead: Bool = false,
        allowWorkspaceWrite: Bool = false,
        workspaceDirectories: [String] = [],
        timezoneIdentifier: String = "",
        workingStartHour: Int = 9,
        workingEndHour: Int = 18,
        workdays: [Int] = [1, 2, 3, 4, 5],
        blockLunch: Bool = false,
        lunchStartHour: Int = 12,
        lunchEndHour: Int = 13,
        bufferMinutes: Int = 0,
        defaultDurationMinutes: Int = 30,
        notifyOnProposal: Bool = true,
        callLinkTemplate: String = ""
    ) {
        self.allowCalendarAccess = allowCalendarAccess
        self.allowWorkspaceRead = allowWorkspaceRead
        self.allowWorkspaceWrite = allowWorkspaceWrite
        self.workspaceDirectories = workspaceDirectories
        self.timezoneIdentifier = timezoneIdentifier
        self.workingStartHour = workingStartHour
        self.workingEndHour = workingEndHour
        self.workdays = workdays
        self.blockLunch = blockLunch
        self.lunchStartHour = lunchStartHour
        self.lunchEndHour = lunchEndHour
        self.bufferMinutes = bufferMinutes
        self.defaultDurationMinutes = defaultDurationMinutes
        self.notifyOnProposal = notifyOnProposal
        self.callLinkTemplate = callLinkTemplate
    }

    public static let disabled = PrivacyBridgeConfig()

    /// Clamped copy: the tools read hours and minutes straight from this, so the
    /// bounds are enforced once, on the way in, instead of at every call site.
    public var normalised: PrivacyBridgeConfig {
        var copy = self
        copy.workspaceDirectories = copy.workspaceDirectories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The ceiling is enforced once, here, so no call site has to remember it and a
        // hand-edited settings document cannot widen the readable set past three.
        if copy.workspaceDirectories.count > Self.maximumDirectories {
            copy.workspaceDirectories = Array(copy.workspaceDirectories.prefix(Self.maximumDirectories))
        }
        copy.workingStartHour = min(max(copy.workingStartHour, 0), 23)
        copy.workingEndHour = min(max(copy.workingEndHour, 1), 24)
        if copy.workingEndHour <= copy.workingStartHour { copy.workingEndHour = copy.workingStartHour + 1 }
        copy.lunchStartHour = min(max(copy.lunchStartHour, 0), 23)
        copy.lunchEndHour = min(max(copy.lunchEndHour, 1), 24)
        if copy.lunchEndHour <= copy.lunchStartHour { copy.lunchEndHour = copy.lunchStartHour + 1 }
        copy.workdays = Array(Set(copy.workdays.filter { (1...7).contains($0) })).sorted()
        copy.bufferMinutes = min(max(copy.bufferMinutes, 0), 240)
        copy.defaultDurationMinutes = min(max(copy.defaultDurationMinutes, 5), 720)
        copy.callLinkTemplate = String(copy.callLinkTemplate.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return copy
    }
}

// MARK: - Console language

/// Simplified → Traditional conversion with Apple's own converter, so the node
/// can serve a Traditional interface from the one Chinese catalog it maintains
/// instead of keeping a second copy of every string to drift.
///
/// The conversion is character-wise. That is right for nearly all of this
/// product's wording and wrong for a small class of one-character-two-words
/// cases, and for one variant: the converter answers 启 with 啓, while the
/// standard Traditional form used by macOS's own UI is 啟. Everything the audit
/// of the shipped strings found is listed in `fixUps` and asserted in
/// `MacNodeContractTests`, so the guesswork is visible rather than silent.
public enum TraditionalChinese {
    /// `simplified` must be the node's own `zh` copy, not arbitrary text: the
    /// fix-up table is keyed on phrases from that copy.
    public static func render(_ simplified: String) -> String {
        guard simplified.rangeOfCharacter(from: Self.hanzi) != nil else { return simplified }
        let buffer = NSMutableString(string: simplified) as CFMutableString
        guard CFStringTransform(buffer, nil, Self.transformName as CFString, false) else {
            return simplified
        }
        var converted = buffer as String
        for (wrong, right) in fixUps where converted.contains(wrong) {
            converted = converted.replacingOccurrences(of: wrong, with: right)
        }
        return converted
    }

    /// `CFStringTransform` names its conversions by string, not by constant, so
    /// the spelling is a value rather than a symbol — and the probe in the test
    /// target proves it resolves instead of silently returning the input.
    static let transformName = "Hans-Hant"

    static let hanzi = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")

    /// Post-conversion corrections. Each entry is a finding from auditing the
    /// shipped `zh` copy with the same probe `MacNodeContractTests` runs, not a
    /// guess at what the converter might get wrong.
    ///
    /// Auditing the shipped Chinese surface once — 289 console catalog rows and
    /// 19 menu labels converted and read back, with the 10 engine names and the
    /// checklist titles covered by `MacNodeContractTests` — found one systematic
    /// error: the converter answers 启 with the variant 啓, while the
    /// standard Traditional form, the one macOS's own Traditional UI uses, is 啟
    /// (啟動, 開啟, 啟用). The second entry came with the model catalog: 内存准入
    /// is the standard Simplified term for admission control, and 准 survives the
    /// converter untouched because it is a valid Traditional character in its own
    /// right (批准) — but "admission" is written 準入. Word-dependent characters
    /// that would need a further fix-up (皇**后**, **后**妃, 天**后**, 头**发**,
    /// 面**粉**, 台**风**) do not occur in this copy, and the words that do occur
    /// convert the way a Traditional reader expects: 复制→複製, 控制/限制→unchanged,
    /// 平台→平台, 界面→界面, 里面→這裡, 空闲→空閒, 恢复→恢復, 剩余→剩餘.
    public static let fixUps: [(wrong: String, right: String)] = [
        ("啓", "啟"),
        ("准入", "準入")
    ]
}

/// The languages the node can present: the *same set* as the POPOPX iOS app —
/// `apps/ios/POPOPX.xcodeproj` `knownRegions` minus `Base` (an Xcode artefact,
/// not a locale), i.e. the 17 `.lproj` directories the phone ships — plus
/// `zh-Hant`, which the phone does not have and the node derives from its own
/// Simplified catalog. The raw values are those same BCP-47 tags, so a pairing
/// between phone and node never has to translate a language code, and the
/// `zh` spelling used by the earlier draft is gone: the iOS catalog is
/// `zh-Hans`, and `Locale`/`Bundle` hand back `zh-Hans`, never `zh`.
///
/// The iOS app itself has no in-app switcher — since 2026-11 the only entry
/// point is the per-app system setting (`Me → General → Display language`),
/// read through `Bundle.main.preferredLocalizations`. `.system` reproduces
/// that behaviour for the node: it follows the Mac's own language for this
/// app and stores nothing but the intent.
public enum ConsoleLanguage: String, Codable, Sendable, CaseIterable, Equatable {
    /// Follow the Mac's per-app language, exactly like the iOS app does.
    case system = "system"

    case chineseSimplified = "zh-Hans"
    /// The one language the node offers and the phone does not: POPOPX iOS
    /// ships a single `zh-Hans` catalog, so a Traditional-Chinese iPhone falls
    /// back to English there. Here it is served properly, converted from the
    /// Simplified copy with Apple's own converter (see `TraditionalChinese`).
    case chineseTraditional = "zh-Hant"
    case english = "en"
    case russian = "ru"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case dutch = "nl"
    case czech = "cs"
    case spanish = "es"
    case polish = "pl"
    case japanese = "ja"
    case thai = "th"
    case finnish = "fi"
    case ukrainian = "uk"
    case bulgarian = "bg"
    case turkish = "tr"
    case hungarian = "hu"

    /// Picker order: follow-the-system, then the three regions the node can
    /// actually serve in Chinese or English (the two proof-read catalogs and
    /// the derived Traditional one), then the remaining fourteen in exactly the
    /// relative order the iOS target's `knownRegions` lists them
    /// (en, ru, de, fr, it, nl, cs, zh-Hans, es, pl, ja, th, fi, uk, bg, tr, hu
    /// with `Base` dropped, since `Base` is an Xcode folder and not a language).
    /// Kept as an explicit array because `allCases` from `CaseIterable` would
    /// silently change if a case were inserted in the middle of the enum.
    public static let displayOrder: [ConsoleLanguage] = [
        .system, .chineseSimplified, .chineseTraditional, .english, .russian, .german, .french, .italian,
        .dutch, .czech, .spanish, .polish, .japanese, .thai, .finnish, .ukrainian,
        .bulgarian, .turkish, .hungarian
    ]

    /// Locales whose endonym is used as the picker label, the same mechanism
    /// the iOS app uses (`Locale.localizedString(forIdentifier:)`) but pinned
    /// so the list never re-labels itself while the user is reading it.
    public var nativeName: String {
        switch self {
        case .system: return "系统 / System"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .english: return "English"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        case .czech: return "Čeština"
        case .spanish: return "Español"
        case .polish: return "Polski"
        case .japanese: return "日本語"
        case .thai: return "ไทย"
        case .finnish: return "Suomi"
        case .ukrainian: return "Українська"
        case .bulgarian: return "Български"
        case .turkish: return "Türkçe"
        case .hungarian: return "Magyar"
        }
    }

    /// The language the *interface* is rendered in. Both Chinese scripts read
    /// Chinese copy — they differ only in which glyph set they are shown in —
    /// and every other locale in this list selects English. `isChinese` is what
    /// the report templates and the local-model prompts key off, so a Russian or
    /// Japanese console is honest about which catalog it is showing rather
    /// than half-translating.
    public var isChinese: Bool {
        resolved == .chineseSimplified || resolved == .chineseTraditional
    }

    /// The single place catalog-less regions are resolved: the node writes two
    /// proof-read strings and derives the third, so Simplified selects `zh`,
    /// Traditional selects the converted `zh`, and the other fifteen regions
    /// select English. Both the menu bar and the engines call this, which is how
    /// the app and the console can never disagree about what a language means.
    public func text(zh: String, en: String) -> String {
        switch resolved {
        case .chineseSimplified: return zh
        case .chineseTraditional: return TraditionalChinese.render(zh)
        default: return en
        }
    }

    /// Locales whose console copy is hand-maintained next to the code. The
    /// picker still offers every iOS region, and the page says plainly that the
    /// rest render from the English catalog — inventing 15 unreviewed catalogs
    /// would look complete and read badly.
    public static let curated: Set<ConsoleLanguage> = [.chineseSimplified, .english]

    /// Locales whose catalog the node derives instead of typing out:
    /// Traditional Chinese is converted from the Simplified one by Apple's own
    /// `CFStringTransform` (see `TraditionalChinese`), so it reads as a real
    /// catalog without pretending to be a human translation.
    public static let derived: Set<ConsoleLanguage> = [.chineseTraditional]

    public var isCurated: Bool { Self.curated.contains(self) }

    /// What the page and the notice check: does this language get its own
    /// strings, hand-written or derived?
    public var hasCatalog: Bool { Self.curated.contains(self) || Self.derived.contains(self) }

    /// Which catalog actually paints the interface for this choice.
    public var catalogKey: String {
        switch resolved {
        case .chineseSimplified: return "zh"
        case .chineseTraditional: return "zhHant"
        default: return "en"
        }
    }

    /// The label shown in the menu bar and the console chip.
    public var shortLabel: String {
        switch self {
        case .system: return "系统"
        case .chineseSimplified: return "中文"
        case .chineseTraditional: return "繁"
        case .english: return "EN"
        default: return rawValue.uppercased()
        }
    }

    /// `.system` becomes a concrete language; every other case is itself.
    public var resolved: ConsoleLanguage {
        self == .system ? ConsoleLanguage.matchingCurrentSystemLocale() : self
    }

    /// BCP-47 tag for `Locale`/HTML `lang` attributes.
    public var localeIdentifier: String {
        switch self {
        case .system: return resolved.localeIdentifier
        case .chineseSimplified: return "zh-Hans-CN"
        case .chineseTraditional: return "zh-Hant-TW"
        default: return rawValue
        }
    }

    /// The name handed to the local model so generated briefings, scripts and
    /// news read in the owner's language even where no UI catalog exists.
    public var modelLanguageDirective: String {
        switch resolved {
        case .chineseSimplified: return "Write in Simplified Chinese (简体中文)."
        case .chineseTraditional: return "Write in Traditional Chinese (繁體中文)."
        case .english: return "Write in English."
        case let other: return "Write in \(other.nativeName) (script of that language); keep file names, numbers and tool paths unchanged."
        }
    }

    /// The rule iOS applies when it picks a catalog: match the exact tag, then
    /// the primary subtag, then give up rather than invent a language. Unknown
    /// codes return nil so the caller can keep walking the owner's preference
    /// list — the node only ever returns a case the iOS app also ships.
    public static func matching(_ identifier: String) -> ConsoleLanguage? {
        let normalised = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "@")
            .first
            .map(String.init) ?? identifier
        let lowered = normalised.lowercased()
        if let exact = ConsoleLanguage(rawValue: trimCase(normalised)) { return exact }
        // Script first: the node serves both Chinese catalogs, so `zh-Hant-TW`
        // must not be folded into Simplified, and `zh-CN` must not reach
        // Traditional. A bare `zh` follows the phone, whose only Chinese
        // catalog is `zh-Hans`.
        if lowered.hasPrefix("zh-hant") || lowered.hasPrefix("zh-tw") { return .chineseTraditional }
        if lowered == "zh" || lowered.hasPrefix("zh-") { return .chineseSimplified }
        let primary = lowered.split(separator: "-").first.map(String.init) ?? lowered
        return ConsoleLanguage(rawValue: primary)
    }

    /// The same rule iOS applies, because there is no in-app switcher in either
    /// app: walk the owner's ordered language preferences and take the first one
    /// the 17-region list can serve; if none matches, fall back to the system
    /// locale's own tag. This node ships no `.lproj` catalogs, so
    /// `Bundle.main.preferredLocalizations` would answer with the development
    /// region for everyone and every non-English owner would silently get
    /// English — which is precisely the drift this function exists to prevent.
    public static func matchingCurrentSystemLocale() -> ConsoleLanguage {
        for tag in Locale.preferredLanguages {
            if let hit = matching(tag) { return hit }
        }
        for candidate in [
            Locale.current.identifier,
            Locale.current.language.languageCode?.identifier ?? "",
            Bundle.main.preferredLocalizations.first ?? "",
            "en"
        ] {
            if let hit = matching(candidate) { return hit }
        }
        return .english
    }

    /// `zh-hans` → `zh-Hans`: the stored tag must be the iOS catalog spelling,
    /// not a lowercased guess, or the phone and the node disagree on the code.
    private static func trimCase(_ text: String) -> String {
        let parts = text.split(separator: "-", omittingEmptySubsequences: true)
        guard let head = parts.first else { return text }
        let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return ([head.lowercased()] + rest).joined(separator: "-")
    }
}

// MARK: - Mesh accounting

public struct MeshJob: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var requestedBy: String
    public var kind: String
    public var memoryCapGB: Int
    public var maxSeconds: Int
    public var rewardPoints: Int
    public var state: StepState
    public var sandboxPath: String
    public var acceptedAt: Date
    public var finishedAt: Date?
    public var sha256: String?

    public init(
        id: String = UUID().uuidString,
        requestedBy: String,
        kind: String,
        memoryCapGB: Int,
        maxSeconds: Int,
        rewardPoints: Int,
        state: StepState = .pending,
        sandboxPath: String = "",
        acceptedAt: Date = Date(),
        finishedAt: Date? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.requestedBy = requestedBy
        self.kind = kind
        self.memoryCapGB = memoryCapGB
        self.maxSeconds = maxSeconds
        self.rewardPoints = rewardPoints
        self.state = state
        self.sandboxPath = sandboxPath
        self.acceptedAt = acceptedAt
        self.finishedAt = finishedAt
        self.sha256 = sha256
    }
}

public struct MeshSummary: Codable, Sendable, Equatable {
    public var sharingEnabled: Bool
    public var acceptingNow: Bool
    public var activeJobs: Int
    public var completedJobs: Int
    public var accruedPoints: Int
    public var pendingSettlementPoints: Int
    public var sandboxBytesUsed: Int64
    public var nextWindowLabel: String?

    public init(
        sharingEnabled: Bool = false,
        acceptingNow: Bool = false,
        activeJobs: Int = 0,
        completedJobs: Int = 0,
        accruedPoints: Int = 0,
        pendingSettlementPoints: Int = 0,
        sandboxBytesUsed: Int64 = 0,
        nextWindowLabel: String? = nil
    ) {
        self.sharingEnabled = sharingEnabled
        self.acceptingNow = acceptingNow
        self.activeJobs = activeJobs
        self.completedJobs = completedJobs
        self.accruedPoints = accruedPoints
        self.pendingSettlementPoints = pendingSettlementPoints
        self.sandboxBytesUsed = sandboxBytesUsed
        self.nextWindowLabel = nextWindowLabel
    }
}

// MARK: - Sentinel audit trail

/// One deterministic lockdown row — the point of `phantom_sentinel` is that this
/// table is explainable without ever mentioning a model.
public struct LockdownReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(triggeredAt.timeIntervalSince1970)-\(UUID().uuidString.prefix(6))" }
    public var trigger: String
    public var clipboardCleared: Bool
    public var unmounted: [String]
    public var mountFailures: [String]
    public var screenLocked: Bool
    public var displaysSlept: Bool
    public var webhookStatus: Int?
    public var webhookTarget: String?
    public var elapsedMs: Int
    public var modelInvolved: Bool
    public var triggeredAt: Date

    public init(
        trigger: String,
        clipboardCleared: Bool,
        unmounted: [String],
        mountFailures: [String] = [],
        screenLocked: Bool,
        displaysSlept: Bool = false,
        webhookStatus: Int? = nil,
        webhookTarget: String? = nil,
        elapsedMs: Int,
        modelInvolved: Bool = false,
        triggeredAt: Date = Date()
    ) {
        self.trigger = trigger
        self.clipboardCleared = clipboardCleared
        self.unmounted = unmounted
        self.mountFailures = mountFailures
        self.screenLocked = screenLocked
        self.displaysSlept = displaysSlept
        self.webhookStatus = webhookStatus
        self.webhookTarget = webhookTarget
        self.elapsedMs = elapsedMs
        self.modelInvolved = modelInvolved
        self.triggeredAt = triggeredAt
    }
}

// MARK: - Time-locked vault

public struct TimelockEnvelope: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var path: String
    public var rounds: Int
    public var derivedKeyFingerprint: String
    public var sealedAt: Date
    public var earliestOpenAt: Date
    public var released: Bool

    public init(
        id: String = UUID().uuidString,
        label: String,
        path: String,
        rounds: Int,
        derivedKeyFingerprint: String,
        sealedAt: Date,
        earliestOpenAt: Date,
        released: Bool = false
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.rounds = rounds
        self.derivedKeyFingerprint = derivedKeyFingerprint
        self.sealedAt = sealedAt
        self.earliestOpenAt = earliestOpenAt
        self.released = released
    }

    public func isUnlockable(at now: Date = Date()) -> Bool { now >= earliestOpenAt }
}

// MARK: - SSE / event bus

/// Everything the browser console subscribes to on `GET /api/events`.
public struct ConsoleEvent: Codable, Sendable, Equatable {
    public enum Channel: String, Codable, Sendable {
        case install
        case pairing
        case engine
        case bridge
        case result
        case mesh
        case sentinel
        case settings
        case privacy
        case update
        case discover
        case system
    }

    public var channel: Channel
    public var level: EventLevel
    public var message: String
    public var at: Date
    public var payload: [String: JSONValue]

    public init(
        channel: Channel,
        level: EventLevel = .info,
        message: String,
        at: Date = Date(),
        payload: [String: JSONValue] = [:]
    ) {
        self.channel = channel
        self.level = level
        self.message = message
        self.at = at
        self.payload = payload
    }

    /// Wire form for the menu's one-line status.
    public var line: String { "\(at.ppxClock) \(level.glyph) [\(channel.rawValue)] \(message)" }
}

// MARK: - Snapshot

/// The single JSON document the SPA renders from. Refreshed on `GET /api/snapshot`
/// and implicitly after every mutation.
public struct ConsoleSnapshot: Codable, Sendable, Equatable {
    public var node: NodeIdentity
    public var version: String
    public var serverTime: Date
    public var hardware: MacHardwareProfile
    public var plan: ModelPlan
    public var load: SystemLoad
    public var toolchain: [ToolchainProbe]
    public var install: InstallState
    public var bridge: BridgeStatus
    public var pairing: PairingOffer?
    public var pairedDevices: [PairedDevice]
    public var descriptors: [EngineDescriptor]
    public var engines: [EngineRuntime]
    public var settings: NodeSettings
    public var mesh: MeshSummary
    public var recentResults: [CommandResult]
    public var lockdowns: [LockdownReceipt]
    public var vaults: [TimelockEnvelope]
    public var consoleURL: String
    public var eventsBacklog: [ConsoleEvent]
    public var privacy: PrivacyBridgeSnapshot
    public var update: UpdateSnapshot
    public var discover: DiscoverSnapshot
    public var godsEye: GodsEyeViewSnapshot
    public var assistant: AssistantSnapshot
    public var watchdog: SystemWatchdogCard

    public init(
        node: NodeIdentity,
        hardware: MacHardwareProfile,
        plan: ModelPlan,
        load: SystemLoad,
        toolchain: [ToolchainProbe],
        install: InstallState,
        bridge: BridgeStatus,
        pairing: PairingOffer?,
        pairedDevices: [PairedDevice],
        descriptors: [EngineDescriptor],
        engines: [EngineRuntime],
        settings: NodeSettings,
        mesh: MeshSummary,
        recentResults: [CommandResult],
        lockdowns: [LockdownReceipt],
        vaults: [TimelockEnvelope],
        consoleURL: String,
        eventsBacklog: [ConsoleEvent] = [],
        privacy: PrivacyBridgeSnapshot = PrivacyBridgeSnapshot.empty,
        update: UpdateSnapshot = .disabled,
        discover: DiscoverSnapshot = .disabled,
        godsEye: GodsEyeViewSnapshot = .disabled,
        assistant: AssistantSnapshot = .empty,
        watchdog: SystemWatchdogCard = .disabled
    ) {
        self.node = node
        self.version = NodeVersion.current.semanticString
        self.serverTime = Date()
        self.hardware = hardware
        self.plan = plan
        self.load = load
        self.toolchain = toolchain
        self.install = install
        self.bridge = bridge
        self.pairing = pairing
        self.pairedDevices = pairedDevices
        self.descriptors = descriptors
        self.engines = engines
        self.settings = settings
        self.mesh = mesh
        self.recentResults = recentResults
        self.lockdowns = lockdowns
        self.vaults = vaults
        self.consoleURL = consoleURL
        self.eventsBacklog = eventsBacklog
        self.privacy = privacy
        self.update = update
        self.discover = discover
        self.godsEye = godsEye
        self.assistant = assistant
        self.watchdog = watchdog
    }
}

// MARK: - Privacy bridge snapshot

/// What the 「隐私授权与协作桥接」 panel renders: the switch state, the proposals
/// waiting on a click, and the tail of the audit log.
///
/// Nothing in here can carry calendar or file text from the owner's own data. The
/// only free strings are the ones the node or the assistant authored inside a
/// proposal, which is the whole point of the ledger: an approval always shows its
/// own payload.
public struct PrivacyBridgeSnapshot: Codable, Sendable, Equatable {
    public var calendarAllowed: Bool
    public var workspaceReadAllowed: Bool
    public var workspaceWriteAllowed: Bool
    /// macOS's own answer for the calendar permission — `notDetermined`,
    /// `authorized`, `denied`, `restricted`. Read-only: the node cannot revoke a
    /// TCC decision, so the console shows the state and the button that asks.
    public var eventAuthorization: String
    public var directories: [String]
    /// Directories that currently exist and are reachable, as `~`-anonymised paths.
    public var reachableDirectories: [String]
    public var pendingProposals: [PrivacyProposalCard]
    public var bookings: [PrivacyBookingCard]
    public var auditLog: [PrivacyAuditRow]
    public var notifyOnProposal: Bool
    /// The config the bridge is actually running, so the console can edit a real
    /// document instead of a JavaScript restatement of Swift's defaults. A settings
    /// file may legitimately omit `privacyBridges`; this never does.
    public var bridges: PrivacyBridgeConfig
    /// How many directories the node will keep, so the panel caps its own input with the
    /// number the engine enforces instead of a copy that can drift.
    public var directoryCeiling: Int

    public init(
        calendarAllowed: Bool = false,
        workspaceReadAllowed: Bool = false,
        workspaceWriteAllowed: Bool = false,
        eventAuthorization: String = PrivacyAuthorization.notDetermined,
        directories: [String] = [],
        reachableDirectories: [String] = [],
        pendingProposals: [PrivacyProposalCard] = [],
        bookings: [PrivacyBookingCard] = [],
        auditLog: [PrivacyAuditRow] = [],
        notifyOnProposal: Bool = true,
        bridges: PrivacyBridgeConfig = PrivacyBridgeConfig.disabled,
        directoryCeiling: Int = PrivacyBridgeConfig.maximumDirectories
    ) {
        self.calendarAllowed = calendarAllowed
        self.workspaceReadAllowed = workspaceReadAllowed
        self.workspaceWriteAllowed = workspaceWriteAllowed
        self.eventAuthorization = eventAuthorization
        self.directories = directories
        self.reachableDirectories = reachableDirectories
        self.pendingProposals = pendingProposals
        self.bookings = bookings
        self.auditLog = auditLog
        self.notifyOnProposal = notifyOnProposal
        self.bridges = bridges
        self.directoryCeiling = directoryCeiling
    }

    public static let empty = PrivacyBridgeSnapshot()
}

/// The TCC states the console can display, spelled the way EventKit names them so
/// the string needs no translation table to stay honest.
public enum PrivacyAuthorization {
    public static let notDetermined = "notDetermined"
    public static let authorized = "authorized"
    public static let denied = "denied"
    public static let restricted = "restricted"
    public static let fullAccess = "fullAccess"
    public static let writeOnly = "writeAccess"
}

/// One pending proposal, in the form the console and the phone card both render.
public struct PrivacyProposalCard: Codable, Sendable, Equatable {
    public var id: String
    public var domain: String
    public var action: String
    public var title: String
    public var detail: String
    public var startISO: String
    public var endISO: String
    public var bookingRef: String
    public var path: String
    public var state: String
    public var expiresISO: String
    public var secondsLeft: Int
    public var canApprove: Bool

    public init(
        id: String,
        domain: String,
        action: String,
        title: String = "",
        detail: String = "",
        startISO: String = "",
        endISO: String = "",
        bookingRef: String = "",
        path: String = "",
        state: String = "pending_user_approval",
        expiresISO: String = "",
        secondsLeft: Int = 0,
        canApprove: Bool = true
    ) {
        self.id = id
        self.domain = domain
        self.action = action
        self.title = title
        self.detail = detail
        self.startISO = startISO
        self.endISO = endISO
        self.bookingRef = bookingRef
        self.path = path
        self.state = state
        self.expiresISO = expiresISO
        self.secondsLeft = secondsLeft
        self.canApprove = canApprove
    }
}

/// A POPOPX-created booking, from the local ledger. `title` is text this node
/// authored, never text read back out of the owner's calendar.
public struct PrivacyBookingCard: Codable, Sendable, Equatable {
    public var ref: String
    public var action: String
    public var title: String
    public var startISO: String
    public var endISO: String
    public var sequence: Int

    public init(
        ref: String,
        action: String,
        title: String = "",
        startISO: String = "",
        endISO: String = "",
        sequence: Int = 0
    ) {
        self.ref = ref
        self.action = action
        self.title = title
        self.startISO = startISO
        self.endISO = endISO
        self.sequence = sequence
    }
}

/// One audit row. Refs and results only — the log is the file a user pastes into a
/// support thread, so it must be structurally incapable of leaking a schedule.
public struct PrivacyAuditRow: Codable, Sendable, Equatable {
    public var at: String
    public var domain: String
    public var action: String
    public var outcome: String
    public var detail: String

    public init(at: String, domain: String, action: String, outcome: String, detail: String = "") {
        self.at = at
        self.domain = domain
        self.action = action
        self.outcome = outcome
        self.detail = detail
    }
}

// MARK: - Paths

/// Every writable location on the machine, derived from the running user.
/// Nothing here is ever hardcoded, so the package stays safe to open-source.
public enum AppPaths {
    public static let appName = "POPOPX Mac Node"
    public static let bundleName = "PopopxMacNode"

    public static let fileManager = FileManager.default

    /// `~/Library/Application Support/PopopxMacNode`
    public static var root: URL { resolvedRoot }

    /// Computed once per process. `URL` is a value type and the Application
    /// Support location cannot move underneath a running app, so an immutable
    /// global is both race-free and sufficient.
    private static let resolvedRoot: URL = {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return support.appendingPathComponent(bundleName, isDirectory: true)
    }()

    public static var engines: URL { root.appendingPathComponent("engines", isDirectory: true) }
    public static var ltxWorkspace: URL { engines.appendingPathComponent("ltx2", isDirectory: true) }
    public static var weights: URL { engines.appendingPathComponent("weights", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    public static var vault: URL { root.appendingPathComponent("vault", isDirectory: true) }
    public static var sealed: URL { vault.appendingPathComponent("sealed", isDirectory: true) }
    public static var pairing: URL { root.appendingPathComponent("pairing", isDirectory: true) }
    public static var popopx: URL { root.appendingPathComponent("popopx", isDirectory: true) }
    public static var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    public static var sandboxes: URL { root.appendingPathComponent("sandboxes", isDirectory: true) }
    public static var ledger: URL { root.appendingPathComponent("ledger", isDirectory: true) }
    public static var output: URL { root.appendingPathComponent("output", isDirectory: true) }
    public static var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    /// Signed update offers: state, staged package and the receipt key. The
    /// staged package is deleted again as soon as the installer has consumed it.
    public static var updates: URL { root.appendingPathComponent("updates", isDirectory: true) }
    public static var updateStaging: URL { updates.appendingPathComponent("staging", isDirectory: true) }
    /// The Discover aggregator's own output and signing key. Separate from
    /// `pairing/` so this key can never sign a pairing offer.
    public static var discover: URL { root.appendingPathComponent("discover", isDirectory: true) }

    public static var settingsFile: URL { config.appendingPathComponent("settings.json") }
    /// Optional `{ "refs": { "<catalog id>": "<ollama reference>" } }` document:
    /// the tag actually imported when it is not the one the catalog ships with.
    public static var modelRefsFile: URL { config.appendingPathComponent("model_refs.json") }
    /// The controlled MCP registration file — `{ allowedCommands, servers }`. It lives
    /// apart from `settings.json` because registering an executable this node will spawn
    /// is a step the owner takes in a text editor; the console reads it and, on an
    /// explicit save, writes it back with owner-only permissions.
    public static var mcpServersFile: URL { config.appendingPathComponent("mcp_servers.json") }
    public static var pairedDevicesFile: URL { pairing.appendingPathComponent("devices.json") }
    public static var nodeKeyFile: URL { pairing.appendingPathComponent("node.key") }
    public static var offerFile: URL { pairing.appendingPathComponent("offer.json") }
    public static var lockdownLedgerFile: URL { ledger.appendingPathComponent("lockdown.json") }
    public static var meshLedgerFile: URL { ledger.appendingPathComponent("mesh.json") }
    /// The controlled ledger of POPOPX-created bookings: `bookingRefId` → what this
    /// node wrote into the calendar, and nothing else. It is the only reason a
    /// reschedule or cancel proposal can name a booking at all — the node never
    /// looks up an event it did not create.
    public static var privacyLedgerFile: URL { ledger.appendingPathComponent("privacy.json") }
    /// HMAC key for an approval receipt. Lives in `vault`, like every other secret
    /// this node mints.
    public static var privacyApprovalKeyFile: URL { vault.appendingPathComponent("privacy-approval.key") }
    public static var installLogFile: URL { logs.appendingPathComponent("install.log") }
    public static var auditLogFile: URL { logs.appendingPathComponent("node.log") }
    public static var updateStateFile: URL { updates.appendingPathComponent("state.json") }
    public static var updateApprovalKeyFile: URL { vault.appendingPathComponent("update-approval.key") }
    public static var discoverFeedFile: URL { discover.appendingPathComponent("feed.json") }
    public static var discoverStateFile: URL { discover.appendingPathComponent("state.json") }
    public static var discoverSigningKeyFile: URL { vault.appendingPathComponent("discover-signing.key") }
    /// The Gods Eye View bridge keeps its own JSONL audit and process log apart
    /// from the node's own, so the external tool's transitions can be read and
    /// rotated without touching `node.log`.
    public static var godsEyeAuditFile: URL { logs.appendingPathComponent("godseyeview-audit.jsonl") }
    public static var godsEyeLogFile: URL { logs.appendingPathComponent("godseyeview.log") }
    /// The private assistant's SQLite ledger and the HMAC key its approval receipts
    /// are signed with. The database holds facts, never credentials or mail bodies;
    /// the key lives with the other signing keys in `vault`.
    public static var assistantDatabaseFile: URL { ledger.appendingPathComponent("assistant.sqlite3") }
    public static var assistantApprovalKeyFile: URL { vault.appendingPathComponent("assistant-approval.key") }
    /// The episodic index seals every title and body with this key before SQLite
    /// sees them. It is a file, not a Keychain item, for the same reason the
    /// approval key is: the index has to open before a paired phone exists.
    public static var assistantRAGKeyFile: URL { vault.appendingPathComponent("assistant-rag.key") }
    /// Sealed FTS5 index. Nothing readable is stored in it — titles, bodies and
    /// sources are AES-GCM blobs and FTS only sees HMAC token digests.
    public static var assistantRAGDatabaseFile: URL { ledger.appendingPathComponent("assistant-rag.sqlite3") }
    /// The watchdog's own JSONL trace, next to the node log so a restart can be
    /// audited without opening the assistant ledger.
    public static var watchdogAuditFile: URL { logs.appendingPathComponent("watchdog.jsonl") }
    /// Generated only when the owner flips 「开机自启」. Fixed name so removing the
    /// switch is the same path every time.
    public static var launchAgentFile: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("chat.popopx.mac-node.plist")
    }

    /// Subpaths used by the LTX-2.5 MLX workspace.
    public static var ltxRepo: URL { ltxWorkspace.appendingPathComponent("ltx-2-mlx", isDirectory: true) }
    public static var ltxVenv: URL { ltxWorkspace.appendingPathComponent(".venv", isDirectory: true) }
    public static var ltxModelDir: URL { ltxWorkspace.appendingPathComponent("models", isDirectory: true) }

    /// Creates the whole tree. Idempotent; safe to call on every launch.
    @discardableResult
    public static func ensureLayout() throws -> [URL] {
        let directories = [
            root, engines, ltxWorkspace, weights, logs, config, vault, sealed,
            pairing, popopx, outbox, sandboxes, ledger, output, quarantine,
            updates, updateStaging, discover
        ]
        for url in directories {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try concealFromBackups()
        return directories
    }

    /// Marks the node root so Time Machine skips it: sealed vaults and quarantine
    /// material must not silently replicate into a cloud backup.
    public static func concealFromBackups() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
    }

    /// POSIX path of a directory inside Application Support, created on demand.
    public static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh, unique sandbox directory for one mesh job.
    public static func makeSandbox(jobID: String) throws -> URL {
        let safe = String(jobID.map { $0.isLetter || $0.isNumber ? $0 : Character("-") }.prefix(24))
        let url = sandboxes.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Turns any user-supplied path (`~/…`, `$HOME/…`, a relative fragment) into a
    /// canonical URL without ever baking in a machine-specific prefix.
    public static func resolve(userPath: String) -> URL? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let tail = String(trimmed.dropFirst(trimmed.hasPrefix("~/") ? 2 : 1))
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(tail, isDirectory: tail.hasSuffix("/"))
                .standardizedFileURL
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return root.appendingPathComponent(trimmed, isDirectory: trimmed.hasSuffix("/")).standardizedFileURL
    }

    /// `true` when `url` is the node root or below it, after `..` and symlink-free
    /// normalisation. Every path that arrives from the phone or from the browser
    /// goes through this before it reaches `Process`, `NSWorkspace` or a file write.
    public static func isContained(_ url: URL) -> Bool {
        let standardised = url.standardizedFileURL.path
        let prefix = resolvedRoot.path
        return standardised == prefix || standardised.hasPrefix(prefix + "/")
    }

    /// Like `resolve(userPath:)` but refuses anything that escapes the node root.
    /// Returns nil rather than clamping, because silently rewriting a caller's path
    /// produces artifacts nobody can find later.
    public static func resolveContained(userPath: String) -> URL? {
        guard let url = resolve(userPath: userPath) else { return nil }
        return isContained(url) ? url : nil
    }

    /// Replaces every occurrence of the owner's home directory with `~`.
    ///
    /// Applied to *all* substrings, not only to a prefix, because the path also
    /// shows up mid-string inside `NSError.localizedDescription`, a brew log line
    /// and a Python traceback — and those are exactly the strings this app prints
    /// into a browser console.
    public static func anonymise(_ path: String) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, path.contains(home) else { return path }
        return path.replacingOccurrences(of: home, with: "~")
    }

    public static func anonymise(url: URL) -> String {
        anonymise(url.path)
    }

    /// Removes everything under the node root. Guarded: refuses to run unless the
    /// caller confirms, so it can never be reached by a stray code path.
    public static func eraseNodeData(confirmationToken: String) throws {
        guard confirmationToken == "ERASE-POPOPX-NODE-DATA" else {
            throw NodeFailure.permissionDenied("eraseNodeData requires the literal confirmation token")
        }
        try fileManager.removeItem(at: root)
    }
}

// MARK: - Settings store

/// Owns `config/settings.json`: load, mutate, persist atomically.
public actor SettingsStore {
    public static let shared = SettingsStore()

    private var cached: NodeSettings?
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.settingsFile) {
        self.fileURL = fileURL
    }

    public func current() -> NodeSettings {
        if let cached { return cached }
        let loaded = Self.read(from: fileURL) ?? NodeSettings()
        cached = loaded
        return loaded
    }

    /// Replaces the document wholesale and bumps its revision. The console posts
    /// the full settings object it received, so a stale browser tab cannot
    /// silently drop a field the node added in a later build.
    @discardableResult
    public func apply(_ settings: NodeSettings) -> NodeSettings {
        var next = settings
        next.revision = (cached?.revision ?? settings.revision) + 1
        next.updatedAt = Date()
        cached = next
        persist(next)
        return next
    }

    @discardableResult
    public func mutate(_ change: (inout NodeSettings) -> Void) -> NodeSettings {
        var next = current()
        change(&next)
        return apply(next)
    }

    @discardableResult
    public func setEngine(_ kind: EngineKind, enabled: Bool) -> NodeSettings {
        mutate { $0.enginesEnabled[kind.rawValue] = enabled }
    }

    @discardableResult
    public func persist(_ settings: NodeSettings) -> Bool {
        guard let data = NodeJSON.encodePretty(settings) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    private static func read(from url: URL) -> NodeSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NodeJSON.decode(NodeSettings.self, from: data)
    }
}

// MARK: - Event hub

/// Fan-out of `ConsoleEvent` to any number of subscribers. SSE handlers, the menu
/// bar and the audit log all tap the same hub, so the browser and the native UI
/// can never disagree about what just happened.
public actor ConsoleEventHub {
    public static let shared = ConsoleEventHub()

    /// Ring buffer replayed to a late subscriber so a freshly opened tab still
    /// shows the installer log that scrolled past.
    private let backlogCapacity: Int
    private var backlog: [ConsoleEvent] = []
    private var subscribers: [UUID: AsyncStream<ConsoleEvent>.Continuation] = [:]

    public init(backlogCapacity: Int = 240) {
        self.backlogCapacity = max(16, backlogCapacity)
    }

    public func publish(_ event: ConsoleEvent) {
        backlog.append(event)
        if backlog.count > backlogCapacity {
            backlog.removeFirst(backlog.count - backlogCapacity)
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    public func publish(
        _ channel: ConsoleEvent.Channel,
        _ message: String,
        level: EventLevel = .info,
        payload: [String: JSONValue] = [:]
    ) {
        publish(ConsoleEvent(channel: channel, level: level, message: message, payload: payload))
    }

    public func subscribe(replayBacklog: Bool = true) -> AsyncStream<ConsoleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.attach(id: id, replay: replayBacklog, continuation: continuation)
        }
    }

    public func replay() -> [ConsoleEvent] { backlog }

    public func clear() {
        backlog.removeAll(keepingCapacity: true)
    }

    private func attach(
        id: UUID,
        replay: Bool,
        continuation: AsyncStream<ConsoleEvent>.Continuation
    ) {
        subscribers[id] = continuation
        if replay {
            for event in backlog { continuation.yield(event) }
        }
        continuation.onTermination = { _ in
            Task { await ConsoleEventHub.shared.detach(id: id) }
        }
    }

    private func detach(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public var subscriberCount: Int { subscribers.count }
}

// MARK: - Shell execution

/// Result of one subprocess invocation.
public struct ShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var combinedOutput: String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (out.isEmpty, err.isEmpty) {
        case (false, false): return out + "\n" + err
        case (false, true): return out
        case (true, false): return err
        default: return ""
        }
    }

    /// First non-empty line — enough for a version banner.
    public var firstLine: String {
        combinedOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

/// `Process` wrapper that never blocks a cooperative thread and never accepts a
/// shell string. Callers pass an executable path plus an argument vector, so a
/// payload coming off the SMP wire can not become a command line.
public enum Shell {
    /// Directories a GUI-launched (or login-item-launched) process is missing but
    /// a Terminal user has. Only standard system prefixes — never a home path.
    public static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/Applications/Ollama.app/Contents/Resources"
    ]

    public static var augmentedEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        let merged = (existing.split(separator: ":").map(String.init) + searchPaths).reduce(into: [String]()) { acc, item in
            if !acc.contains(item) { acc.append(item) }
        }
        environment["PATH"] = merged.joined(separator: ":")
        return environment
    }

    /// Resolves an executable name against `searchPaths`, mirroring `which -a`.
    public static func which(_ executable: String) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        let path = (augmentedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in path {
            let candidate = directory + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func isPresent(_ executable: String) -> Bool { which(executable) != nil }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        at directory: URL? = nil,
        environment overrides: [String: String]? = nil,
        timeout: TimeInterval = 60,
        stdin: Data? = nil
    ) async -> ShellResult {
        guard let resolved = which(executable) else {
            return ShellResult(
                exitCode: 127,
                stdout: "",
                stderr: "executable not found: \(executable)",
                timedOut: false
            )
        }
        return await execute(
            launchPath: resolved,
            arguments: arguments,
            directory: directory,
            overrides: overrides,
            timeout: timeout,
            stdin: stdin
        )
    }

    /// Same as `run` but takes an absolute launch path, for callers that already
    /// probed it (the sandboxed mesh runner needs this to pin a known binary).
    @discardableResult
    public static func runAbsolute(
        launchPath: String,
        _ arguments: [String],
        at directory: URL? = nil,
        environment overrides: [String: String]? = nil,
        timeout: TimeInterval = 600
    ) async -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return ShellResult(exitCode: 127, stdout: "", stderr: "not executable: \(launchPath)")
        }
        return await execute(
            launchPath: launchPath,
            arguments: arguments,
            directory: directory,
            overrides: overrides,
            timeout: timeout,
            stdin: nil
        )
    }

    private static func execute(
        launchPath: String,
        arguments: [String],
        directory: URL?,
        overrides: [String: String]?,
        timeout: TimeInterval,
        stdin: Data?
    ) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }

            var environment = augmentedEnvironment
            for (key, value) in overrides ?? [:] { environment[key] = value }
            process.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            if let stdin {
                let inPipe = Pipe()
                process.standardInput = inPipe
                DispatchQueue.global(qos: .utility).async {
                    inPipe.fileHandleForWriting.write(stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
            } else {
                process.standardInput = FileHandle.nullDevice
            }

            let collector = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(std: handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(err: handle.availableData)
            }

            let watchdog = TimeoutWatchdog(seconds: timeout, process: process)

            let box = ContinuationBox(continuation)
            process.terminationHandler = { finished in
                watchdog.cancel()
                // Drain whatever the readability handlers have not yet observed.
                collector.append(std: outPipe.fileHandleForReading.readDataToEndOfFile())
                collector.append(err: errPipe.fileHandleForReading.readDataToEndOfFile())
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let result = ShellResult(
                    exitCode: finished.terminationStatus,
                    stdout: collector.standardText,
                    stderr: collector.errorText + (watchdog.didFire ? "\n(watchdog: killed after \(Int(timeout))s)" : ""),
                    timedOut: watchdog.didFire
                )
                box.resume(with: result)
            }

            do {
                try process.run()
                watchdog.arm()
            } catch {
                watchdog.cancel()
                box.resume(with: ShellResult(
                    exitCode: 126,
                    stdout: "",
                    stderr: "failed to launch \(launchPath): \(error.localizedDescription)"
                ))
            }
        }
    }
}

/// Thread-safe stdout/stderr accumulator for `Pipe` readability handlers.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standard = Data()
    private var error = Data()

    func append(std data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); standard.append(data); lock.unlock()
    }

    func append(err data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); error.append(data); lock.unlock()
    }

    var standardText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: standard, as: UTF8.self)
    }

    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: error, as: UTF8.self)
    }
}

/// One-shot `DispatchSource` kill switch so a hung ffmpeg can never wedge the
/// engine queue.
final class TimeoutWatchdog: @unchecked Sendable {
    private let seconds: TimeInterval
    private weak var process: Process?
    private let lock = NSLock()
    private var source: DispatchSourceTimer?
    private var fired = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    init(seconds: TimeInterval, process: Process) {
        self.seconds = seconds
        self.process = process
    }

    func arm() {
        guard seconds > 0, seconds < 24 * 3600 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, let process = self.process, process.isRunning else { return }
            self.lock.lock(); self.fired = true; self.lock.unlock()
            process.terminate()
        }
        lock.lock(); source = timer; lock.unlock()
        timer.resume()
    }

    func cancel() {
        lock.lock()
        let timer = source
        source = nil
        lock.unlock()
        timer?.cancel()
    }

    deinit { cancel() }
}

/// Guarantees the `withCheckedContinuation` resumes exactly once even if
/// `terminationHandler` races the launch `catch`.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShellResult, Never>?

    init(_ continuation: CheckedContinuation<ShellResult, Never>) {
        self.continuation = continuation
    }

    func resume(with value: ShellResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Sysctl helpers

/// `sysctlbyname` wrappers used by the hardware probe. Pure reads, no allocation
/// beyond the fixed buffers the kernel asks for.
public enum Sysctl {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return Int(value) }
        if let wide = uint64(name) { return Int(wide) }
        return nil
    }

    public static var memorySize: UInt64 { uint64("hw.memsize") ?? 0 }
    public static var chipName: String? { string("machdep.cpu.brand_string") }
    public static var modelIdentifier: String? { string("hw.model") }
    public static var logicalCPUCount: Int { Int(ProcessInfo.processInfo.processorCount) }
    public static var physicalCPUCount: Int { int("hw.physicalcpu") ?? logicalCPUCount }
    public static var performanceCores: Int { int("hw.perflevel0.physicalcpu") ?? 0 }
    public static var efficiencyCores: Int { int("hw.perflevel1.physicalcpu") ?? 0 }
    public static var kernelVersion: String? { string("kern.osrelease") }
    public static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - Protocols (frozen)

/// Hardware probe + one-click environment installer (wizard step 1).
public protocol NodeHardwareProbing: Sendable {
    func profile() async -> MacHardwareProfile
    func plan() async -> ModelPlan
    func loadSample() async -> SystemLoad
    func toolchain() async -> [ToolchainProbe]
    func installState() async -> InstallState
    func startInstall() async
    func cancelInstall() async
    func installEvents() -> AsyncStream<InstallEvent>
}

/// SMP signalling gateway: daemon lifecycle, pairing, whitelist, delivery.
public protocol NodeSignaling: Sendable {
    func start() async
    func stop() async
    func status() async -> BridgeStatus
    func identity() async -> NodeIdentity
    func currentOffer() async -> PairingOffer?
    func rotateOffer() async -> PairingOffer?
    func qrAsset(pixelSize: Int) async -> QRAsset?
    func pairedDevices() async -> [PairedDevice]
    func revokeDevice(publicKey: String) async
    func incomingCommands() -> AsyncStream<NodeCommand>
    func deliver(_ result: CommandResult, to serviceId: String) async -> Bool
}

/// The ten local business engines (wizard step 3).
public protocol NodeEngines: Sendable {
    func descriptors() async -> [EngineDescriptor]
    func runtimes() async -> [EngineRuntime]
    func runtime(for kind: EngineKind) async -> EngineRuntime?
    func setEnabled(_ kind: EngineKind, enabled: Bool) async
    func execute(_ command: NodeCommand) async -> CommandResult
    func invoke(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult
    func meshSummary() async -> MeshSummary
    func recentLockdowns() async -> [LockdownReceipt]
    func recentVaults() async -> [TimelockEnvelope]
}

/// Everything the web console may call. Implemented by the composition root in
/// the menu-bar target so that the console never imports a concrete engine.
public protocol NodeConsoleFacade: Sendable {
    func snapshot() async -> ConsoleSnapshot
    func events() -> AsyncStream<ConsoleEvent>
    func startInstall() async
    func cancelInstall() async
    func setEngineEnabled(_ kind: EngineKind, enabled: Bool) async
    func rotatePairing() async -> PairingOffer?
    func pairingQR(pixelSize: Int) async -> QRAsset?
    func revokePairing(publicKey: String) async
    func updateSettings(_ settings: NodeSettings) async -> NodeSettings
    func submitWireCommand(_ text: String) async -> CommandResult
    func invokeEngine(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult
    func openInFinder(path: String) async
    /// Runs one privacy-bridge tool call, from either entry point. The switches are
    /// checked inside the engine, so a facade cannot accidentally answer a call it
    /// was not authorized to answer.
    func privacyTool(_ call: PrivacyToolCall) async -> PrivacyToolResponse
    /// Raises the EventKit access request. Console-only, and the only way the node
    /// ever asks TCC for calendar access.
    func requestCalendarAccess() async -> String
    /// Applies a console approval or rejection to one proposal. Console-only: the
    /// receipt is minted here, inside the node, so it never travels to the page.
    func privacyDecision(domain: String, id: String, verb: String) async -> PrivacyToolResponse
    /// The local capability card. `force` asks for a fresh measurement and waits for it;
    /// without it the call must return whatever was last measured *immediately*, because the
    /// console polls this and a poll that waits on a TCP timeout stalls the page.
    func discoverySnapshot(force: Bool) async -> DiscoverySnapshot
    /// Console-only: puts one bridge credential into the Keychain and answers with its
    /// reference. The secret is an argument and never a return value, so no poll payload and no
    /// settings document can carry one by accident.
    func storeHubCredential(bridge: String, serverID: String, secret: String) async -> PrivacyToolResponse
    /// The update card's current state. Never dials anything; the manifest host is
    /// only contacted by `updateCheck()`.
    func updateStatus() async -> UpdateSnapshot
    /// One manifest fetch and signature check. Detection only — no package is
    /// downloaded here, and nothing is installed.
    func updateCheck() async -> UpdateCheckReport
    /// Applies an owner's 「立即更新 / 稍后提醒」. The console path mints its own
    /// receipt inside the node; the phone path carries one in its command payload.
    func updateDecision(verb: String) async -> UpdateDecisionReport
    /// The Discover card's current state, served from the last local run.
    func discoverStatus() async -> DiscoverSnapshot
    /// Runs the aggregator now. A no-op refusal when the feature is off.
    func discoverRefresh() async -> DiscoverRefreshReport
    /// One owner click on the 「全球情报地图」 card. The bridge checks the switches
    /// inside, so a facade cannot answer a start it was not authorized to run.
    func godsEyeControl(verb: String) async -> GodsEyeControlReport
    /// Console-only: stores one optional third-party data-source key in the Keychain
    /// and answers with its reference. The value is never echoed.
    func storeGodsEyeCredential(sourceID: String, secret: String) async -> PrivacyToolResponse

    /// One owner click on the personal-assistant card: `briefingNow`, `patrolNow`,
    /// `refreshMail`, `proposeDrafts` or `cancelPending`.
    func assistantControl(verb: String) async -> AssistantControlReport
    /// Applies an approve/reject click. The console path mints the receipt inside
    /// the node; the phone path carries its own in the command payload.
    func assistantDecision(id: String, verb: String) async -> AssistantDecisionReport
    /// Console-only: stores one mail password in the Keychain and answers with its
    /// reference, never the value.
    func storeMailCredential(kind: String, secret: String) async -> AssistantCredentialReport
    /// One owner click on 「全链路连通性体检」. Every probe is loopback or an
    /// already-configured account, and the report is redacted before it is served.
    func assistantDoctor() async -> LiveIntegrationReport
    /// Natural-language recall over the sealed local index, with citations.
    func assistantHistory(query: String) async -> EpisodicAnswer
    /// The LaunchAgent switch and its last check rows.
    func watchdogStatus() async -> SystemWatchdogCard
    /// `install`, `uninstall`, `check` or `status` — console-only.
    func watchdogControl(verb: String) async -> WatchdogControlReport
}

public extension NodeConsoleFacade {
    /// Convenience overload: the console always asks for a 512 px QR.
    func pairingQR() async -> QRAsset? { await pairingQR(pixelSize: 512) }

    /// A facade without a privacy bridge says so rather than inventing an answer.
    /// The bind-path fakes in the test target ride this; `NodeConsole` overrides both.
    func privacyTool(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        PrivacyToolResponse.failure(503, "本节点没有隐私桥接 / this facade has no privacy bridge")
    }

    func requestCalendarAccess() async -> String { PrivacyAuthorization.notDetermined }

    func privacyDecision(domain: String, id: String, verb: String) async -> PrivacyToolResponse {
        PrivacyToolResponse.failure(503, "本节点没有隐私桥接 / this facade has no privacy bridge")
    }

    /// A facade without a discovery probe says so in the card rather than returning an empty
    /// list, which a console would render as "this Mac has nothing".
    func discoverySnapshot(force: Bool) async -> DiscoverySnapshot {
        DiscoverySnapshot(capabilities: [DiscoveryCapability(
            kind: .refusal,
            label: "本地能力发现 / Local capability discovery",
            state: "off",
            detail: "本节点未装配探测器 / this node has no capability probe"
        )], scannedAt: PrivacyStamp.iso(Date()))
    }

    /// A facade without a credential store refuses rather than keeping the value in memory,
    /// because "nothing accepted it" is the only honest answer a fake can give.
    func storeHubCredential(bridge: String, serverID: String, secret: String) async -> PrivacyToolResponse {
        PrivacyToolResponse.failure(503, "本节点没有钥匙串存储 / this facade has no credential store")
    }

    /// Fakes report the feature as off instead of pretending a check succeeded.
    func updateStatus() async -> UpdateSnapshot { .disabled }

    func updateCheck() async -> UpdateCheckReport {
        UpdateCheckReport(outcome: "disabled", detail: "本节点没有更新检查器 / this facade has no update checker", update: .disabled)
    }

    func updateDecision(verb: String) async -> UpdateDecisionReport {
        UpdateDecisionReport(outcome: "refused", ok: false, detail: "本节点没有更新检查器 / this facade has no update checker", update: .disabled)
    }

    func discoverStatus() async -> DiscoverSnapshot { .disabled }

    func discoverRefresh() async -> DiscoverRefreshReport {
        DiscoverRefreshReport(outcome: "disabled", detail: "本节点没有发现聚合器 / this facade has no aggregator", discover: .disabled)
    }

    func godsEyeControl(verb: String) async -> GodsEyeControlReport {
        GodsEyeControlReport(
            outcome: verb.isEmpty ? "disabled" : verb,
            ok: false,
            detail: "本节点没有 Gods Eye View 桥 / this facade has no Gods Eye View bridge",
            godsEye: .disabled
        )
    }

    func storeGodsEyeCredential(sourceID: String, secret: String) async -> PrivacyToolResponse {
        PrivacyToolResponse.failure(503, "本节点没有钥匙串存储 / this facade has no credential store")
    }

    func assistantControl(verb: String) async -> AssistantControlReport {
        .refused("本节点没有私人助手 / this facade has no personal assistant", snapshot: .empty)
    }

    func assistantDecision(id: String, verb: String) async -> AssistantDecisionReport {
        AssistantDecisionReport(
            ok: false,
            outcome: "refused",
            detail: "本节点没有私人助手 / this facade has no personal assistant",
            assistant: .empty
        )
    }

    func storeMailCredential(kind: String, secret: String) async -> AssistantCredentialReport {
        AssistantCredentialReport(
            ok: false,
            detail: "本节点没有钥匙串存储 / this facade has no credential store",
            reference: "",
            assistant: .empty
        )
    }

    func assistantDoctor() async -> LiveIntegrationReport {
        LiveIntegrationReport(
            ok: false,
            headline: "本节点没有体检引擎 / this facade has no doctor",
            checks: [],
            boundary: "无检查 / no checks ran"
        )
    }

    func assistantHistory(query: String) async -> EpisodicAnswer {
        .empty
    }

    func watchdogStatus() async -> SystemWatchdogCard { .disabled }

    func watchdogControl(verb: String) async -> WatchdogControlReport {
        WatchdogControlReport(
            ok: false,
            outcome: "refused",
            detail: "本节点没有系统看门狗 / this facade has no watchdog",
            watchdog: .disabled
        )
    }
}

// MARK: - Console API paths

/// The HTTP surface the SPA is written against. Kept next to the snapshot type so
/// that adding an endpoint cannot silently drift from the server.
public enum ConsoleRoute {
    public static let index = "/"
    public static let snapshot = "/api/snapshot"
    public static let events = "/api/events"
    public static let installStart = "/api/install/start"
    public static let installCancel = "/api/install/cancel"
    public static let pairingRotate = "/api/pairing/rotate"
    public static let pairingQR = "/api/pairing/qr.png"
    public static let pairingRevoke = "/api/pairing/revoke"
    public static let settings = "/api/settings"
    public static let engineToggle = "/api/engine/toggle"
    public static let engineInvoke = "/api/engine/invoke"
    public static let commandInject = "/api/command"
    public static let health = "/api/health"

    // MARK: Privacy-bridge tools
    //
    // The tool surface shares the loopback listener and the bearer token with
    // `/api/*` but keeps its own prefix, because the path is the contract the
    // assistants code against: POST /v1/tools/{domain}/{action}.

    public static let toolPrefix = "/v1/tools/"
    public static let calendarAvailability = "/v1/tools/calendar/availability"
    public static let calendarProposals = "/v1/tools/calendar/proposals"
    public static let workspaceSummarize = "/v1/tools/workspace/summarize"
    public static let workspaceProposals = "/v1/tools/workspace/proposals"
    /// Console-only: flips the switches and, for the calendar, raises the TCC
    /// request. There is no tool path for this on purpose — an authorization grant
    /// is the one thing that must not be reachable from a caller.
    public static let privacyAuthorize = "/api/privacy/authorize"
    /// Console-only: applies a 「批准 / 驳回」 click to a proposal the panel is showing.
    ///
    /// The receipt the ledger demands is minted inside the node from this call instead
    /// of being handed to the page, so no poll payload ever carries a write capability:
    /// what authorizes the console path is the loopback bearer token plus the click on
    /// one specific id, and the ledger still validates exactly one road to the executor
    /// for both entry points.
    public static let privacyDecision = "/api/privacy/decision"
    /// Console-only: stores one bridge credential in the macOS Keychain and answers with its
    /// reference. Deliberately *not* under `/v1/tools/`, because writing a secret is the setup
    /// act that precedes an authorization grant, and the rule for those is that no caller —
    /// paired phone or loopback script — may ask for one. The reply never repeats the value.
    public static let hubCredential = "/api/hub/credential"

    // MARK: Signed updates and the Discover feed
    //
    // Both are console-only POSTs. Detection ("check") is still a POST because it
    // reaches the operator-pinned manifest host; approval ("decision") is the one
    // path that may download and hand a package to macOS, and the receipt it needs
    // is minted inside the node — the page never receives a capability, only the
    // answer to a click. `/api/discover/refresh` runs the aggregator now; the
    // schedule itself lives in the app tick.

    public static let updateCheck = "/api/update/check"
    public static let updateDecision = "/api/update/decision"
    public static let discoverRefresh = "/api/discover/refresh"

    // MARK: Gods Eye View
    //
    // Console-only, for the same reason `/api/hub/credential` is: both write state
    // that a paired caller must never be able to change on its own. The control
    // path carries one verb the bridge allow-lists; the credential path stores a
    // third-party key in the Keychain and answers with its reference, never the
    // value.

    public static let godsEyeControl = "/api/godseye/control"
    public static let godsEyeCredential = "/api/godseye/credential"

    // MARK: Private assistant
    //
    // All three are console-only POSTs. The decision route takes an id and a verb
    // and mints its receipt inside the node, so the page never receives a write
    // capability; the credential route stores a mail password and answers with the
    // Keychain reference only.

    public static let assistantControl = "/api/assistant/control"
    public static let assistantDecision = "/api/assistant/decision"
    public static let assistantMailCredential = "/api/assistant/mail/credential"
    /// Console-only: the owner's 全链路体检, the sealed-index recall, and the
    /// LaunchAgent switch. None of them is under `/v1/tools/` because each one
    /// either reads a credential-backed seam or writes a launch configuration on
    /// this Mac — the exact actions a paired caller must not trigger on its own.
    public static let assistantDoctor = "/api/assistant/doctor"
    public static let assistantHistory = "/api/assistant/history"
    public static let watchdogControl = "/api/watchdog/control"

    /// `/v1/tools/{domain}/proposals/{id}/{verb}` — the approval gate, addressed by
    /// proposal id.
    public static func proposalDecision(_ domain: String, id: String, verb: String) -> String {
        "/v1/tools/\(domain)/proposals/\(id)/\(verb)"
    }

    // MARK: Local capability discovery

    /// The discovery surface keeps its own prefix for the same reason the tools do: the
    /// path is what an assistants-side integration codes against.
    ///
    /// `/capabilities` is a **GET** and answers from the last measurement, so a console poll
    /// can never be blocked by a TCP timeout. `/scan` is a POST because it waits for a real
    /// pass — a read the caller pays for in milliseconds gets a method a stray navigation
    /// cannot trigger.
    public static let discoveryPrefix = "/v1/discovery/"
    public static let discoveryCapabilities = "/v1/discovery/capabilities"
    public static let discoveryScan = "/v1/discovery/scan"

    public static let all: [String] = [
        index, snapshot, events, installStart, installCancel,
        pairingRotate, pairingQR, pairingRevoke, settings,
        engineToggle, engineInvoke, commandInject, health, privacyAuthorize, privacyDecision,
        hubCredential, discoveryCapabilities, discoveryScan,
        updateCheck, updateDecision, discoverRefresh,
        godsEyeControl, godsEyeCredential,
        assistantControl, assistantDecision, assistantMailCredential,
        assistantDoctor, assistantHistory, watchdogControl
    ]

    /// The tool endpoints, kept out of `all` because `all` is the SPA surface the
    /// `ConsoleRoute.count` contract test counts.
    public static let tools: [String] = [
        calendarAvailability, calendarProposals, workspaceSummarize, workspaceProposals
    ]
}

// MARK: - Misc shared helpers

public enum TextKit {
    /// Stable, short identifier derived from arbitrary text (device labels,
    /// artifact names). Not a security primitive — a display fingerprint.
    public static func fingerprint(_ text: String, length: Int = 8) -> String {
        let digest = Digest.sha256Hex(Data(text.utf8))
        return String(digest.prefix(length))
    }

    public static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// Normalises anything that may arrive off the wire into a safe file name.
    public static func safeFileName(_ raw: String, fallback: String = "artifact") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
        // Dots are allowed only as separators, never as a path component: `..`
        // would survive an alphanumerics filter, and this string is used as a
        // single file name for artifacts whose names arrive from the phone.
        let components = collapsed
            .split(separator: ".", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty && $0 != ".." }
        let normalised = components.joined(separator: ".")
        guard !normalised.isEmpty, normalised != "." else { return fallback }
        return String(normalised.prefix(72))
    }

    /// `base64url` without padding — pairing codes and fingerprints.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ text: String) -> Data? {
        var encoded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        return Data(base64Encoded: encoded)
    }

    /// Random URL-safe token; used for the console bearer and sandbox names.
    public static func randomToken(bytes: Int = 24) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        if status != errSecSuccess {
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255) }
        }
        return base64URL(Data(buffer))
    }
}

/// Lower-case hex SHA-256 helper for display fingerprints, audit rows and
/// artifact digests. Everything that guards a secret uses a dedicated
/// `CryptoKit` primitive in the module that owns it; this is the shared,
/// boring digest.
public enum Digest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func sha256Bytes(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Truncated hex digest, the form shown in the console tables.
    public static func short(_ data: Data, length: Int = 12) -> String {
        String(sha256Hex(data).prefix(length))
    }

    /// Constant-time comparison of two digests, so a pairing code can not be
    /// probed byte by byte from the loopback console.
    public static func matches(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var delta: UInt8 = 0
        for (left, right) in zip(a.utf8, b.utf8) { delta |= left ^ right }
        return delta == 0
    }
}


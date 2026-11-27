//
//  UpdateModels.swift
//  PopopxMacNode — the signed-update document and everything that has to be true
//  before a byte is downloaded.
//
//  Four rules, and each one is a test in `UpdateCenterTests`:
//
//  * **The manifest is worthless without the signature.** The node checks an
//    Ed25519 signature over a canonical body (sorted keys, no escaped slashes)
//    with a public key the operator typed into the console. A tampered summary,
//    a swapped package URL or a manifest signed by another key is ignored
//    silently — no card, no download.
//  * **A newer version is necessary, not sufficient.** The version must parse as
//    `major.minor.patch` and be strictly greater than `NodeVersion.current`.
//  * **The egress exception is one host, typed by the owner.** This feature is
//    the only one allowed to reach a public address, and only because the whole
//    point is fetching an official release manifest. `UpdateURLPolicy` admits
//    HTTPS on that exact host (plus any extra package hosts the owner pinned),
//    with no credentials and no non-default port. It never follows a redirect to
//    a host outside the pin — the transport re-checks the final URL.
//  * **Nothing is downloaded before the owner's click.** `UpdateCenter` exposes
//    no path that fetches a package without a receipt, and the receipt is an
//    HMAC bound to `update|version|sha-prefix` plus the verb.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Configuration

public struct UpdateConfig: Codable, Sendable, Equatable {
    public static let maximumSummaryItems = 12
    public static let maximumPackageHosts = 8
    public static let minimumIntervalMinutes = 15
    public static let maximumIntervalMinutes = 7 * 24 * 60
    public static let defaultIntervalMinutes = 6 * 60
    public static let minimumSnoozeHours = 1
    public static let maximumSnoozeHours = 168
    public static let defaultSnoozeHours = 24
    /// The manifest itself is small. A package may be large, but a signed
    /// manifest can never legitimately claim more than this.
    public static let maximumManifestBytes = 256 * 1024
    public static let maximumPackageBytes = 4 * 1024 * 1024 * 1024

    /// Off until the owner types a manifest URL *and* a public key.
    public var enabled: Bool
    public var manifestURL: String
    /// base64url Ed25519 public key, 32 raw bytes. Pinned by the operator, never
    /// fetched from the manifest's own host.
    public var publicKey: String
    /// Extra hosts a signed manifest may point its package at (a CDN, for
    /// example). The manifest's own host is always pinned. Bare host names only.
    public var packageHosts: [String]
    public var intervalMinutes: Int
    public var snoozeHours: Int

    public init(
        enabled: Bool = false,
        manifestURL: String = "",
        publicKey: String = "",
        packageHosts: [String] = [],
        intervalMinutes: Int = UpdateConfig.defaultIntervalMinutes,
        snoozeHours: Int = UpdateConfig.defaultSnoozeHours
    ) {
        self.enabled = enabled
        self.manifestURL = manifestURL
        self.publicKey = publicKey
        self.packageHosts = packageHosts
        self.intervalMinutes = intervalMinutes
        self.snoozeHours = snoozeHours
    }

    public static let disabled = UpdateConfig()

    public var checkInterval: TimeInterval {
        TimeInterval(max(Self.minimumIntervalMinutes, min(Self.maximumIntervalMinutes, intervalMinutes)) * 60)
    }

    public var snoozeInterval: TimeInterval {
        TimeInterval(max(Self.minimumSnoozeHours, min(Self.maximumSnoozeHours, snoozeHours)) * 3600)
    }

    public var manifestHost: String? {
        UpdateURLPolicy.host(of: manifestURL)
    }

    public var pinnedHosts: Set<String> {
        var hosts = Set(packageHosts.map { UpdateURLPolicy.normalisedHost($0) }.filter { !$0.isEmpty })
        if let manifestHost { hosts.insert(manifestHost) }
        return hosts
    }

    /// True when the two values the signature depends on are structurally usable.
    /// It says nothing about whether the URL answers — that is a network fact,
    /// not a configuration fact.
    public var usable: Bool {
        guard !manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = TextKit.base64URLDecode(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 32,
              let host = manifestHost, !host.isEmpty,
              (try? UpdateURLPolicy.validate(manifestURL, pinnedHosts: [host])) != nil
        else { return false }
        return true
    }

    public var keyFingerprint: String {
        guard let raw = TextKit.base64URLDecode(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return Digest.short(raw, length: 10)
    }

    /// Trims and clamps. An unusable URL/key turns the switch off rather than
    /// leaving a card that says "on" while every check is refused.
    public var normalised: UpdateConfig {
        var copy = self
        copy.manifestURL = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.packageHosts = Array(
            Set(packageHosts
                .map { UpdateURLPolicy.normalisedHost($0) }
                .filter { !$0.isEmpty })
        ).sorted().prefix(Self.maximumPackageHosts).map { $0 }
        copy.intervalMinutes = max(
            Self.minimumIntervalMinutes,
            min(Self.maximumIntervalMinutes, intervalMinutes)
        )
        copy.snoozeHours = max(Self.minimumSnoozeHours, min(Self.maximumSnoozeHours, snoozeHours))
        if !copy.usable { copy.enabled = false }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, manifestURL, publicKey, packageHosts, intervalMinutes, snoozeHours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.manifestURL = try container.decodeIfPresent(String.self, forKey: .manifestURL) ?? ""
        self.publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        self.packageHosts = try container.decodeIfPresent([String].self, forKey: .packageHosts) ?? []
        self.intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
            ?? Self.defaultIntervalMinutes
        self.snoozeHours = try container.decodeIfPresent(Int.self, forKey: .snoozeHours)
            ?? Self.defaultSnoozeHours
    }
}

// MARK: - Egress policy

/// The one narrow exception to the loopback/LAN allow-list.
///
/// `EdgeBoundary` refuses every public host by design. An update manifest is the
/// one document the owner explicitly names on the public internet, so it gets its
/// own validator rather than widening `EdgeBoundary` for the MQTT or CalDAV
/// bridges. The validator is still positive: HTTPS, no credentials, default port,
/// and the host must equal one the owner pinned in the settings document.
public enum UpdateURLPolicy {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missingURL
        case unsupportedScheme(String)
        case credentialsInURL
        case missingHost
        case nonDefaultPort(Int)
        case hostNotPinned(String)

        public var description: String {
            switch self {
            case .missingURL:
                return "未配置更新地址 / no update URL configured"
            case let .unsupportedScheme(scheme):
                return "更新地址必须为 https / the update URL must be https: \(scheme)"
            case .credentialsInURL:
                return "更新地址内不得携带凭据 / credentials do not belong in the update URL"
            case .missingHost:
                return "更新地址缺少主机名 / the update URL has no host"
            case let .nonDefaultPort(port):
                return "更新地址仅允许默认端口 / only the default HTTPS port is admitted: \(port)"
            case let .hostNotPinned(host):
                return "主机不在机主固定名单内 / host is not pinned by the owner: \(host)"
            }
        }
    }

    public static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://"), let components = URLComponents(string: trimmed) else { return nil }
        guard let raw = components.host, !raw.isEmpty else { return nil }
        return normalisedHost(raw)
    }

    public static func normalisedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let marker = host.range(of: "://") {
            host = String(host[marker.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.firstIndex(of: ":"), !host.hasPrefix("[") { host = String(host[..<colon]) }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        return host
    }

    /// Returns the URL to hand to the transport, or the reason it is refused.
    /// `pinnedHosts` must already be normalised.
    public static func validate(_ text: String, pinnedHosts: Set<String>) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.missingURL }
        guard trimmed.contains("://") else { throw Failure.unsupportedScheme(String(trimmed.prefix(16))) }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw Failure.missingURL
        }
        guard scheme == "https" else { throw Failure.unsupportedScheme(scheme) }
        guard components.user == nil, components.password == nil else { throw Failure.credentialsInURL }
        guard let rawHost = components.host, !rawHost.isEmpty else { throw Failure.missingHost }
        if let port = components.port, port != 443 { throw Failure.nonDefaultPort(port) }
        let host = normalisedHost(rawHost)
        guard pinnedHosts.map(normalisedHost).contains(host) else { throw Failure.hostNotPinned(host) }
        guard let url = components.url else { throw Failure.missingURL }
        return url
    }
}

// MARK: - Version

public struct UpdateVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), part.count <= 6,
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]
    }

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

extension UpdateVersion {
    /// Strictly newer than the running build. Equality is *not* an update.
    public func isNewer(than current: NodeVersion) -> Bool {
        self > UpdateVersion(major: current.major, minor: current.minor, patch: current.patch)
    }
}

// MARK: - Manifest

public struct UpdatePackage: Codable, Sendable, Equatable {
    public var url: String
    public var sha256: String
    public var size: Int
    /// `dmg`, `pkg` or `zip`. Anything else is refused before a download.
    public var format: String

    public init(url: String, sha256: String, size: Int, format: String = "dmg") {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.format = format
    }
}

public struct UpdateRelease: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    public var releasedAt: String
    public var summary: [String]
    public var package: UpdatePackage

    public init(
        version: String,
        build: Int = 0,
        releasedAt: String = "",
        summary: [String] = [],
        package: UpdatePackage
    ) {
        self.version = version
        self.build = build
        self.releasedAt = releasedAt
        self.summary = summary
        self.package = package
    }

    public var parsedVersion: UpdateVersion? { UpdateVersion(version) }

    /// What the card shows, one line per feature and capped so a hostile
    /// manifest cannot turn the chat into a wall of text.
    public var summaryLines: [String] {
        summary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(UpdateConfig.maximumSummaryItems)
            .map { TextKit.truncate($0, to: 160) }
    }
}

/// `popopx.update.manifest.v1`.
///
/// The signature covers the canonical JSON of `{ schema, release }` — sorted
/// keys, compact separators, slashes not escaped. The bytes are rebuilt from the
/// typed fields rather than re-read from the document, so whitespace or key order
/// in the file cannot change what is verified.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public static let schemaIdentifier = "popopx.update.manifest.v1"
    public static let acceptedFormats: Set<String> = ["dmg", "pkg", "zip"]

    public var schema: String
    public var release: UpdateRelease
    /// base64url Ed25519 signature over `signingBody(schema:release:)`.
    public var signature: String

    public init(schema: String = UpdateManifest.schemaIdentifier, release: UpdateRelease, signature: String) {
        self.schema = schema
        self.release = release
        self.signature = signature
    }

    public static func signingBody(schema: String = UpdateManifest.schemaIdentifier, release: UpdateRelease) -> Data? {
        let body: [String: Any] = [
            "schema": schema,
            "release": [
                "version": release.version,
                "build": release.build,
                "releasedAt": release.releasedAt,
                "summary": release.summary,
                "package": [
                    "url": release.package.url,
                    "sha256": release.package.sha256,
                    "size": release.package.size,
                    "format": release.package.format
                ]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public var signingBody: Data? { Self.signingBody(schema: schema, release: release) }

    /// Structure that must hold *before* the signature is even considered. A
    /// signed-but-unusable manifest (an `http` package, a digest of the wrong
    /// length) is still refused.
    public func structuralRefusal(pinnedHosts: Set<String>) -> String? {
        guard schema == Self.schemaIdentifier else {
            return "清单版本不符 / unsupported manifest schema: \(TextKit.truncate(schema, to: 40))"
        }
        guard !signature.isEmpty else { return "缺少签名 / the manifest carries no signature" }
        guard parsedVersion != nil else { return "版本号不可解析 / release version is not major.minor.patch" }
        guard release.build >= 0 else { return "构建号越界 / release build is negative" }
        guard (1...UpdateConfig.maximumPackageBytes).contains(release.package.size) else {
            return "安装包大小越界 / package size is outside the admitted range"
        }
        guard Self.acceptedFormats.contains(release.package.format.lowercased()) else {
            return "安装包格式不受支持 / unsupported package format: \(TextKit.truncate(release.package.format, to: 16))"
        }
        guard release.package.sha256.count == 64,
              release.package.sha256.allSatisfy({ $0.isHexDigit }) else {
            return "SHA-256 格式不符 / package digest is not 64 hex characters"
        }
        guard (try? UpdateURLPolicy.validate(release.package.url, pinnedHosts: pinnedHosts)) != nil else {
            return "安装包地址未通过主机固定校验 / package URL is outside the owner's pinned hosts"
        }
        return nil
    }

    private var parsedVersion: UpdateVersion? { release.parsedVersion }
}

// MARK: - Persisted state

/// Everything that has to survive a restart: which signed release is still on
/// offer, whether its card was already sent, and when the owner asked to be
/// reminded later. The raw signed document is stored so approval re-verifies the
/// same bytes instead of trusting the decoded fields.
public struct UpdateState: Codable, Sendable, Equatable {
    public var pendingManifest: String?
    public var pendingVersion: String
    public var lastNotifiedVersion: String
    public var snoozedUntil: Date?
    public var lastCheckAt: Date?
    public var lastError: String
    public var lastIgnored: String
    public var installedVersion: String
    public var stagedPath: String

    public init(
        pendingManifest: String? = nil,
        pendingVersion: String = "",
        lastNotifiedVersion: String = "",
        snoozedUntil: Date? = nil,
        lastCheckAt: Date? = nil,
        lastError: String = "",
        lastIgnored: String = "",
        installedVersion: String = "",
        stagedPath: String = ""
    ) {
        self.pendingManifest = pendingManifest
        self.pendingVersion = pendingVersion
        self.lastNotifiedVersion = lastNotifiedVersion
        self.snoozedUntil = snoozedUntil
        self.lastCheckAt = lastCheckAt
        self.lastError = lastError
        self.lastIgnored = lastIgnored
        self.installedVersion = installedVersion
        self.stagedPath = stagedPath
    }

    private enum CodingKeys: String, CodingKey {
        case pendingManifest, pendingVersion, lastNotifiedVersion, snoozedUntil
        case lastCheckAt, lastError, lastIgnored, installedVersion, stagedPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pendingManifest = try container.decodeIfPresent(String.self, forKey: .pendingManifest)
        self.pendingVersion = try container.decodeIfPresent(String.self, forKey: .pendingVersion) ?? ""
        self.lastNotifiedVersion = try container.decodeIfPresent(String.self, forKey: .lastNotifiedVersion) ?? ""
        self.snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        self.lastCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        self.lastIgnored = try container.decodeIfPresent(String.self, forKey: .lastIgnored) ?? ""
        self.installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion) ?? ""
        self.stagedPath = try container.decodeIfPresent(String.self, forKey: .stagedPath) ?? ""
    }
}

/// Reads and writes `updates/state.json`. Injectable so a test never touches the
/// running node's real application-support tree.
public struct UpdateStateStore: Sendable {
    public let url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func load() -> UpdateState {
        guard let url, let data = try? Data(contentsOf: url),
              let state = NodeJSON.decode(UpdateState.self, from: data) else {
            return UpdateState()
        }
        return state
    }

    public func save(_ state: UpdateState) {
        guard let url, let data = NodeJSON.encodeLine(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Card

/// The `::POPOPX_UPD::` card. Same grammar as `PrivacyCard` — one marker line,
/// `key=value` fields split on `|` — because a receiver that has never seen this
/// kind still renders a readable line, and the two commands are the only `|`
/// content that matters.
public struct UpdateCard: Sendable, Equatable {
    public static let marker = "::POPOPX_UPD::"
    public static let version = "v1"

    public var release: UpdateRelease
    public var approveCommand: String
    public var snoozeCommand: String

    public init(release: UpdateRelease, approveCommand: String, snoozeCommand: String) {
        self.release = release
        self.approveCommand = approveCommand
        self.snoozeCommand = snoozeCommand
    }

    public var text: String {
        let fields: [(String, String)] = [
            ("v", release.version),
            ("b", String(release.build)),
            ("d", TextKit.truncate(release.releasedAt, to: 32)),
            ("s", String(release.package.sha256.prefix(12))),
            ("n", String(release.summaryLines.count))
        ]
        func build(_ pairs: [(String, String)]) -> String {
            let head = Self.marker + Self.version + "|"
                + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
            return head + "|approve=\(approveCommand)|snooze=\(snoozeCommand)"
        }
        let full = build(fields)
        if full.count <= NodeWire.maxSignalPayloadCharacters { return full }
        // Truncating would cut a command off the end, which makes the card
        // unanswerable. Drop the display-only fields instead; the two commands and
        // the version identity always survive.
        return build(Array(fields.prefix(2)))
    }
}

// MARK: - Snapshot

public struct UpdateSnapshot: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Enabled *and* every field the checker needs is present. The console shows
    /// "on" separately from "ready to check" so an incomplete URL or key is visible.
    public var usable: Bool
    public var currentVersion: String
    public var manifestHost: String
    public var pinnedHosts: [String]
    public var keyFingerprint: String
    public var available: UpdateRelease?
    public var lastCheckAt: Date?
    public var lastError: String
    public var lastIgnored: String
    public var snoozedUntil: Date?
    public var notified: Bool
    public var installedVersion: String
    public var boundary: String

    public init(
        enabled: Bool = false,
        usable: Bool = false,
        currentVersion: String = NodeVersion.current.semanticString,
        manifestHost: String = "",
        pinnedHosts: [String] = [],
        keyFingerprint: String = "",
        available: UpdateRelease? = nil,
        lastCheckAt: Date? = nil,
        lastError: String = "",
        lastIgnored: String = "",
        snoozedUntil: Date? = nil,
        notified: Bool = false,
        installedVersion: String = "",
        boundary: String = ""
    ) {
        self.enabled = enabled
        self.usable = usable
        self.currentVersion = currentVersion
        self.manifestHost = manifestHost
        self.pinnedHosts = pinnedHosts
        self.keyFingerprint = keyFingerprint
        self.available = available
        self.lastCheckAt = lastCheckAt
        self.lastError = lastError
        self.lastIgnored = lastIgnored
        self.snoozedUntil = snoozedUntil
        self.notified = notified
        self.installedVersion = installedVersion
        self.boundary = boundary
    }

    public static let disabled = UpdateSnapshot()
}

// MARK: - Outcomes

public enum UpdateCheckOutcome: Sendable, Equatable {
    case disabled
    /// Signature, schema or version refused it. Nothing is shown to the owner.
    case ignored(String)
    case upToDate(String)
    case available(UpdateRelease)
    case failed(String)
}

public enum UpdateDecisionOutcome: Sendable, Equatable {
    case refused(String)
    case snoozed(until: Date)
    case installed(version: String, message: String)
    case failed(String)
}

/// What `POST /api/update/check` answers. The outcome names are stable strings so
/// the console's JavaScript can branch without decoding a Swift enum.
public struct UpdateCheckReport: Codable, Sendable, Equatable {
    public var outcome: String
    public var detail: String
    public var update: UpdateSnapshot

    public init(outcome: String, detail: String = "", update: UpdateSnapshot) {
        self.outcome = outcome
        self.detail = detail
        self.update = update
    }

    public static func make(_ outcome: UpdateCheckOutcome, snapshot: UpdateSnapshot) -> UpdateCheckReport {
        switch outcome {
        case .disabled:
            return UpdateCheckReport(outcome: "disabled", detail: "更新检查未启用 / the update feed is off", update: snapshot)
        case let .ignored(detail):
            return UpdateCheckReport(outcome: "ignored", detail: detail, update: snapshot)
        case let .upToDate(detail):
            return UpdateCheckReport(outcome: "up_to_date", detail: detail, update: snapshot)
        case let .available(release):
            return UpdateCheckReport(outcome: "available", detail: "v\(release.version)", update: snapshot)
        case let .failed(detail):
            return UpdateCheckReport(outcome: "failed", detail: detail, update: snapshot)
        }
    }
}

public struct UpdateDecisionReport: Codable, Sendable, Equatable {
    /// `installed`, `snoozed`, `refused` or `failed`.
    public var outcome: String
    public var ok: Bool
    public var detail: String
    public var update: UpdateSnapshot

    public init(outcome: String, ok: Bool, detail: String = "", update: UpdateSnapshot) {
        self.outcome = outcome
        self.ok = ok
        self.detail = detail
        self.update = update
    }

    public static func make(
        _ outcome: UpdateDecisionOutcome, snapshot: UpdateSnapshot, timeZone: TimeZone = .current
    ) -> UpdateDecisionReport {
        switch outcome {
        case let .refused(detail):
            return UpdateDecisionReport(outcome: "refused", ok: false, detail: detail, update: snapshot)
        case let .snoozed(until):
            let when = PrivacyStamp.display(until, timeZone: timeZone)
            return UpdateDecisionReport(
                outcome: "snoozed", ok: true,
                detail: "已推迟 / snoozed until \(when)", update: snapshot
            )
        case let .installed(version, message):
            return UpdateDecisionReport(
                outcome: "installed", ok: true, detail: "\(version) · \(message)", update: snapshot
            )
        case let .failed(detail):
            return UpdateDecisionReport(outcome: "failed", ok: false, detail: detail, update: snapshot)
        }
    }
}

public struct UpdateAuditEntry: Codable, Sendable, Equatable {
    public var action: String
    public var outcome: String
    public var detail: String
    public var at: Date

    public init(action: String, outcome: String, detail: String = "", at: Date = Date()) {
        self.action = action
        self.outcome = outcome
        self.detail = detail
        self.at = at
    }
}

// MARK: - Collaborators

/// Fetching is injected so the whole gate — signature, version comparison,
/// "nothing before approval" — is testable without a network.
public protocol UpdateTransport: Sendable {
    func fetch(_ url: URL, limit: Int) async throws -> Data
    func download(_ url: URL, limit: Int, to destination: URL) async throws
}

public enum UpdateTransportError: Error, Equatable, CustomStringConvertible {
    case notHTTPS(String)
    case hostNotPinned(String)
    case httpStatus(Int)
    case tooManyBytes(limit: Int)
    case malformedResponse

    public var description: String {
        switch self {
        case let .notHTTPS(url):
            return "更新传输必须为 https / update transport refused a non-https URL: \(url)"
        case let .hostNotPinned(host):
            return "跳转到了未固定主机 / redirect left the pinned hosts: \(host)"
        case let .httpStatus(status):
            return "更新服务器返回 \(status) / update server answered \(status)"
        case let .tooManyBytes(limit):
            return "响应超过上限 / response exceeded \(limit) bytes"
        case .malformedResponse:
            return "更新服务器响应无法解析 / malformed update response"
        }
    }
}

public struct UpdateInstallOutcome: Sendable, Equatable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

public protocol UpdateInstaller: Sendable {
    /// Receives an already verified package. It must never be called on a path
    /// that lacks an owner receipt; `UpdateCenter` is the only caller.
    func install(package: URL, release: UpdateRelease) async -> UpdateInstallOutcome
}

/// Streams a file through SHA-256 so a large package is never held in memory.
public enum UpdateDigest {
    public static func sha256Hex(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
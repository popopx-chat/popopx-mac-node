//
//  GodsEyeViewConfig.swift
//  PopopxMacNode — the document behind the 「全球情报地图 / God's Eye View」 card.
//
//  Everything here is a *description* of a local program the owner installed. The
//  repository ships no JavaScript, no map tiles and no data: this document only
//  points at a directory on this Mac, pins the version that directory is allowed to
//  report, and names the Keychain references from which a launch may read optional
//  third-party data-source keys.
//
//  Three rules shaped the fields:
//
//  * **The bind address is not here.** A configurable host is how a loopback-only
//    service becomes a LAN service after one hand edit, so the only host this node
//    can pass is the constant in `GodsEyeViewPolicy`.
//  * **Keys are references, never values.** `GodsEyeCredentialSlot` is a switch and a
//    name. A value that reached this document would be in `settings.json`, and the
//    console serves that document to a browser over TCP.
//  * **Absent means off.** Every switch defaults to false and every source is
//    optional; decoding a document written by an older build must not turn anything
//    on by surprise.
//

import Foundation

// MARK: - Install mode

/// Where a verified copy comes from.
public enum GodsEyeInstallMode: String, Codable, Sendable, CaseIterable {
    /// The owner installed the program themselves and this node only verifies and
    /// launches the directory.
    case existing
    /// The node clones one pinned commit into `installPath` on an explicit click.
    /// Requires `allowSourcePull`; the node never fetches on a timer.
    case pinnedSource
}

// MARK: - Data sources

/// The optional third-party feeds the program may be given keys for.
///
/// The node does not speak any of these protocols. It only hands a key to the local
/// process at launch, so the traffic — and the provider's terms that govern it — belong
/// to the owner's machine and to that program, not to this repository.
public enum GodsEyeDataSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case aisStream = "aisstream"
    case openSkyClientID = "opensky-client-id"
    case openSkyClientSecret = "opensky-client-secret"

    public var id: String { rawValue }

    /// The environment variable the local process reads at launch. These names are
    /// part of the integration contract; changing one without the other would look
    /// like an empty key rather than a broken mapping.
    public var environmentName: String {
        switch self {
        case .aisStream: return "AISSTREAM_API_KEY"
        case .openSkyClientID: return "OPENSKY_CLIENT_ID"
        case .openSkyClientSecret: return "OPENSKY_CLIENT_SECRET"
        }
    }

    /// The Keychain reference suffix. The full reference is `godseye/<rawValue>`.
    public var referenceName: String { "godseye/\(rawValue)" }

    public var isSecret: Bool {
        switch self {
        case .openSkyClientID: return false
        case .aisStream, .openSkyClientSecret: return true
        }
    }
}

// MARK: - Credential slot

/// One optional feed: whether the owner switched it on, and where the value lives.
public struct GodsEyeCredentialSlot: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// A Keychain reference, not a secret. Empty means "no value stored".
    public var reference: String

    public init(enabled: Bool = false, reference: String = "") {
        self.enabled = enabled
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case enabled, reference }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.reference = try container.decodeIfPresent(String.self, forKey: .reference) ?? ""
    }

    public var normalised: GodsEyeCredentialSlot {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HubSecrets.isSafeReference(ref) else {
            return GodsEyeCredentialSlot(enabled: false, reference: "")
        }
        return GodsEyeCredentialSlot(enabled: enabled && !ref.isEmpty, reference: ref)
    }
}

// MARK: - Config

public struct GodsEyeViewConfig: Codable, Sendable, Equatable {
    /// The owner's switch. Off means the process is not launched, no registration
    /// is added and the card says so; it never means "start quietly on next boot".
    public var enabled: Bool
    public var mode: GodsEyeInstallMode
    /// `~`-relative or absolute. Resolved at use time; never a file descriptor.
    public var installPath: String
    /// The version `package.json` must report. A directory that reports anything
    /// else is refused rather than run, because "fixed version" is the review claim.
    public var pinnedVersion: String
    /// Loopback port for the local web instance. The host is not configurable.
    public var port: Int
    /// Explicit Node.js binary. Empty means "detect with `which node`".
    public var nodePath: String
    /// Whether the one-click clone may reach the network. Default off: an installer
    /// that dials on its own is the opposite of the boundary this node advertises.
    public var allowSourcePull: Bool
    /// HTTPS repository for `pinnedSource`. Rejected when it carries credentials.
    public var repositoryURL: String
    /// Tag or branch to clone. Both this and `pinnedCommit` are required to install.
    public var pinnedRef: String
    /// Full 40-hex commit. The clone's HEAD must equal it, so a moved tag cannot
    /// change what runs here.
    public var pinnedCommit: String
    public var credentials: [String: GodsEyeCredentialSlot]

    public init(
        enabled: Bool = false,
        mode: GodsEyeInstallMode = .existing,
        installPath: String = "",
        pinnedVersion: String = GodsEyeViewPolicy.defaultPinnedVersion,
        port: Int = GodsEyeViewPolicy.defaultPort,
        nodePath: String = "",
        allowSourcePull: Bool = false,
        repositoryURL: String = "",
        pinnedRef: String = "",
        pinnedCommit: String = "",
        credentials: [String: GodsEyeCredentialSlot] = [:]
    ) {
        self.enabled = enabled
        self.mode = mode
        self.installPath = installPath
        self.pinnedVersion = pinnedVersion
        self.port = port
        self.nodePath = nodePath
        self.allowSourcePull = allowSourcePull
        self.repositoryURL = repositoryURL
        self.pinnedRef = pinnedRef
        self.pinnedCommit = pinnedCommit
        self.credentials = credentials
    }

    public static let disabled = GodsEyeViewConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, installPath, pinnedVersion, port, nodePath
        case allowSourcePull, repositoryURL, pinnedRef, pinnedCommit, credentials
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.mode = try container.decodeIfPresent(GodsEyeInstallMode.self, forKey: .mode) ?? .existing
        self.installPath = try container.decodeIfPresent(String.self, forKey: .installPath) ?? ""
        self.pinnedVersion = try container.decodeIfPresent(String.self, forKey: .pinnedVersion)
            ?? GodsEyeViewPolicy.defaultPinnedVersion
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? GodsEyeViewPolicy.defaultPort
        self.nodePath = try container.decodeIfPresent(String.self, forKey: .nodePath) ?? ""
        self.allowSourcePull = try container.decodeIfPresent(Bool.self, forKey: .allowSourcePull) ?? false
        self.repositoryURL = try container.decodeIfPresent(String.self, forKey: .repositoryURL) ?? ""
        self.pinnedRef = try container.decodeIfPresent(String.self, forKey: .pinnedRef) ?? ""
        self.pinnedCommit = try container.decodeIfPresent(String.self, forKey: .pinnedCommit) ?? ""
        self.credentials = try container.decodeIfPresent([String: GodsEyeCredentialSlot].self, forKey: .credentials) ?? [:]
    }

    /// Every field clamped, trimmed and filtered once, on the way in.
    public var normalised: GodsEyeViewConfig {
        var copy = self
        copy.installPath = copy.installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pinnedVersion = copy.pinnedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.pinnedVersion.hasPrefix("v") { copy.pinnedVersion = String(copy.pinnedVersion.dropFirst()) }
        copy.nodePath = copy.nodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !GodsEyeViewPolicy.isValidPort(copy.port) { copy.port = GodsEyeViewPolicy.defaultPort }
        copy.repositoryURL = copy.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pinnedRef = copy.pinnedRef.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pinnedCommit = copy.pinnedCommit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !GodsEyeViewPolicy.isCommit(copy.pinnedCommit) { copy.pinnedCommit = "" }
        var slots: [String: GodsEyeCredentialSlot] = [:]
        for source in GodsEyeDataSource.allCases {
            guard let slot = copy.credentials[source.rawValue]?.normalised, slot.enabled else { continue }
            slots[source.rawValue] = slot
        }
        copy.credentials = slots
        return copy
    }

    public func slot(_ source: GodsEyeDataSource) -> GodsEyeCredentialSlot {
        credentials[source.rawValue] ?? GodsEyeCredentialSlot()
    }

    public var enabledSources: [GodsEyeDataSource] {
        GodsEyeDataSource.allCases.filter { slot($0).enabled }
    }

    public var hasInstallPath: Bool { !installPath.isEmpty }
    public var isPinnedVersionValid: Bool { GodsEyeViewPolicy.isVersion(pinnedVersion) }
    public var sourcePullReady: Bool {
        mode == .pinnedSource && allowSourcePull && GodsEyeViewPolicy.isHTTPSource(repositoryURL)
            && !pinnedRef.isEmpty && GodsEyeViewPolicy.isCommit(pinnedCommit)
    }
}

// MARK: - Install verification

/// What a directory was proven to contain. Digests cover the two entry files, not the
/// whole tree: they are the two files this node hands to `Process`, and hashing a
/// multi-gigabyte asset directory would make the verify button look broken.
public struct GodsEyeInstallVerification: Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public var path: String
    public var packageName: String
    public var version: String
    public var entryPath: String
    public var mcpEntryPath: String
    public var entryDigest: String
    public var mcpEntryDigest: String
    public var verifiedAt: Date

    public init(
        ok: Bool,
        detail: String,
        path: String = "",
        packageName: String = "",
        version: String = "",
        entryPath: String = "",
        mcpEntryPath: String = "",
        entryDigest: String = "",
        mcpEntryDigest: String = "",
        verifiedAt: Date = Date()
    ) {
        self.ok = ok
        self.detail = detail
        self.path = path
        self.packageName = packageName
        self.version = version
        self.entryPath = entryPath
        self.mcpEntryPath = mcpEntryPath
        self.entryDigest = entryDigest
        self.mcpEntryDigest = mcpEntryDigest
        self.verifiedAt = verifiedAt
    }

    public static func refused(_ detail: String) -> GodsEyeInstallVerification {
        GodsEyeInstallVerification(ok: false, detail: detail)
    }
}

// MARK: - Node probe

public struct GodsEyeNodeProbe: Sendable, Equatable {
    public var ok: Bool
    public var path: String
    public var version: String
    public var major: Int
    public var detail: String

    public init(ok: Bool = false, path: String = "", version: String = "", major: Int = 0, detail: String = "") {
        self.ok = ok
        self.path = path
        self.version = version
        self.major = major
        self.detail = detail
    }

    public static let missing = GodsEyeNodeProbe(detail: "未检测到 Node.js / Node.js was not found")
}

// MARK: - Console rows

public struct GodsEyeCredentialRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var environmentName: String
    public var enabled: Bool
    public var stored: Bool
    /// A redacted label, never a prefix of the value.
    public var display: String

    public init(id: String, environmentName: String, enabled: Bool, stored: Bool, display: String) {
        self.id = id
        self.environmentName = environmentName
        self.enabled = enabled
        self.stored = stored
        self.display = display
    }
}

public struct GodsEyeToolRow: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// `readOnly` or `mutating`, after the GodsEye gate. A mutating tool needs the
    /// owner's approval per call even when it is in the registry's allow-list.
    public var safety: String
    public var permitted: Bool

    public var id: String { name }

    public init(name: String, safety: String, permitted: Bool) {
        self.name = name
        self.safety = safety
        self.permitted = permitted
    }
}

// MARK: - Snapshot

public struct GodsEyeViewSnapshot: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var usable: Bool
    public var mode: String
    public var installPath: String
    public var pinnedVersion: String
    public var installedVersion: String
    public var installVerified: Bool
    public var installDetail: String
    public var verifiedAt: Date?
    public var nodePath: String
    public var nodeVersion: String
    public var nodeMajor: Int
    public var nodeOK: Bool
    public var nodeDetail: String
    public var port: Int
    public var bindHost: String
    public var running: Bool
    public var pid: Int32?
    public var startedAt: Date?
    public var healthStatus: Int?
    public var lastHealthAt: Date?
    public var lastError: String
    public var mcpRegistered: Bool
    public var mcpTools: [GodsEyeToolRow]
    public var mcpDetail: String
    public var sourcePullAllowed: Bool
    public var sourcePullReady: Bool
    public var boundary: String
    public var dataPolicy: String
    public var licence: String
    public var credentials: [GodsEyeCredentialRow]

    public init(
        enabled: Bool = false,
        usable: Bool = false,
        mode: String = GodsEyeInstallMode.existing.rawValue,
        installPath: String = "",
        pinnedVersion: String = GodsEyeViewPolicy.defaultPinnedVersion,
        installedVersion: String = "",
        installVerified: Bool = false,
        installDetail: String = "",
        verifiedAt: Date? = nil,
        nodePath: String = "",
        nodeVersion: String = "",
        nodeMajor: Int = 0,
        nodeOK: Bool = false,
        nodeDetail: String = "",
        port: Int = GodsEyeViewPolicy.defaultPort,
        bindHost: String = GodsEyeViewPolicy.bindHost,
        running: Bool = false,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        healthStatus: Int? = nil,
        lastHealthAt: Date? = nil,
        lastError: String = "",
        mcpRegistered: Bool = false,
        mcpTools: [GodsEyeToolRow] = [],
        mcpDetail: String = "",
        sourcePullAllowed: Bool = false,
        sourcePullReady: Bool = false,
        boundary: String = GodsEyeViewPolicy.boundaryStatement,
        dataPolicy: String = GodsEyeViewPolicy.dataSourceStatement,
        licence: String = GodsEyeViewPolicy.licenceStatement,
        credentials: [GodsEyeCredentialRow] = []
    ) {
        self.enabled = enabled
        self.usable = usable
        self.mode = mode
        self.installPath = installPath
        self.pinnedVersion = pinnedVersion
        self.installedVersion = installedVersion
        self.installVerified = installVerified
        self.installDetail = installDetail
        self.verifiedAt = verifiedAt
        self.nodePath = nodePath
        self.nodeVersion = nodeVersion
        self.nodeMajor = nodeMajor
        self.nodeOK = nodeOK
        self.nodeDetail = nodeDetail
        self.port = port
        self.bindHost = bindHost
        self.running = running
        self.pid = pid
        self.startedAt = startedAt
        self.healthStatus = healthStatus
        self.lastHealthAt = lastHealthAt
        self.lastError = lastError
        self.mcpRegistered = mcpRegistered
        self.mcpTools = mcpTools
        self.mcpDetail = mcpDetail
        self.sourcePullAllowed = sourcePullAllowed
        self.sourcePullReady = sourcePullReady
        self.boundary = boundary
        self.dataPolicy = dataPolicy
        self.licence = licence
        self.credentials = credentials
    }

    public static let disabled = GodsEyeViewSnapshot()
}

// MARK: - Reports

/// One control click. The snapshot rides back so the card settles without a second
/// round trip; `outcome` is a stable word the page can branch on.
public struct GodsEyeControlReport: Codable, Sendable, Equatable {
    public var outcome: String
    public var ok: Bool
    public var detail: String
    public var godsEye: GodsEyeViewSnapshot

    public init(outcome: String, ok: Bool, detail: String = "", godsEye: GodsEyeViewSnapshot) {
        self.outcome = outcome
        self.ok = ok
        self.detail = detail
        self.godsEye = godsEye
    }

    public static func disabled(_ detail: String = "全球情报地图未启用 / God's Eye View is off") -> GodsEyeControlReport {
        GodsEyeControlReport(outcome: "disabled", ok: false, detail: detail, godsEye: .disabled)
    }
}

/// The manager's own verdict, kept free of the console model so it can be tested
/// without constructing a snapshot.
public struct GodsEyeActionResult: Sendable, Equatable {
    public var ok: Bool
    public var detail: String

    public init(ok: Bool, detail: String = "") {
        self.ok = ok
        self.detail = detail
    }

    public static func failure(_ detail: String) -> GodsEyeActionResult {
        GodsEyeActionResult(ok: false, detail: detail)
    }
}
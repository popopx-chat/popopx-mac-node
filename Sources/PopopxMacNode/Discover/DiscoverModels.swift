//
//  DiscoverModels.swift
//  PopopxMacNode — the `popopx.discover.feed.v1` envelope and the switches that
//  decide what may enter it.
//
//  The aggregator is local-first by construction:
//
//  * **Off by default.** A settings document that predates this feature decodes
//    to `enabled: false`.
//  * **Outbound feeds are LAN-only.** Every RSS/JSON URL is admitted through
//    `EdgeBoundary` with `.privateNetworkOnly`; a public host is refused and the
//    refusal is shown per source in the console. Folders are local reads, and MCP
//    sources go through the same read-only tier the MCP bridge enforces.
//  * **Every item is signed.** The node signs each item over its canonical body
//    and signs the envelope over the item list, so the phone can verify one item
//    without trusting the file it arrived in.
//

import Foundation

// MARK: - Configuration

public struct DiscoverFeedSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var url: String
    /// `rss` (RSS or Atom) or `json` (JSON Feed or a plain `items` array).
    public var kind: String
    public var enabled: Bool

    public init(id: String = "", label: String = "", url: String = "", kind: String = "rss", enabled: Bool = true) {
        self.id = id
        self.label = label
        self.url = url
        self.kind = kind
        self.enabled = enabled
    }

    public var normalised: DiscoverFeedSource {
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        copy.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.kind = DiscoverFeedSource.normalisedKind(kind)
        return copy
    }

    public static func normalisedKind(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "json" ? "json" : "rss"
    }
}

public struct DiscoverMCPSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var serverID: String
    public var toolName: String
    public var arguments: [String: JSONValue]
    public var enabled: Bool

    public init(
        id: String = "",
        label: String = "",
        serverID: String = "",
        toolName: String = "",
        arguments: [String: JSONValue] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.serverID = serverID
        self.toolName = toolName
        self.arguments = arguments
        self.enabled = enabled
    }

    public var normalised: DiscoverMCPSource {
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        copy.serverID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.toolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if arguments.count > 32 { copy.arguments = [:] }
        return copy
    }

    public var usable: Bool { !serverID.isEmpty && !toolName.isEmpty }
}

public struct DiscoverConfig: Codable, Sendable, Equatable {
    public static let maximumFolders = 4
    public static let maximumFeeds = 8
    public static let maximumMCPSources = 4
    public static let minimumIntervalMinutes = 15
    public static let maximumIntervalMinutes = 24 * 60
    public static let defaultIntervalMinutes = 60
    public static let defaultMaxItems = 20
    public static let maximumItems = 60
    public static let maximumFileBytes = 512 * 1024
    public static let maximumFeedBytes = 2 * 1024 * 1024
    public static let maximumFilesPerFolder = 40
    public static let maximumItemsPerSource = 20
    public static let maximumScanDepth = 3

    public var enabled: Bool
    public var intervalMinutes: Int
    public var maxItems: Int
    public var folders: [String]
    public var feeds: [DiscoverFeedSource]
    public var mcpSources: [DiscoverMCPSource]

    public init(
        enabled: Bool = false,
        intervalMinutes: Int = DiscoverConfig.defaultIntervalMinutes,
        maxItems: Int = DiscoverConfig.defaultMaxItems,
        folders: [String] = [],
        feeds: [DiscoverFeedSource] = [],
        mcpSources: [DiscoverMCPSource] = []
    ) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.maxItems = maxItems
        self.folders = folders
        self.feeds = feeds
        self.mcpSources = mcpSources
    }

    public static let disabled = DiscoverConfig()

    public var refreshInterval: TimeInterval {
        TimeInterval(max(Self.minimumIntervalMinutes, min(Self.maximumIntervalMinutes, intervalMinutes)) * 60)
    }

    public var normalised: DiscoverConfig {
        var copy = self
        copy.intervalMinutes = max(Self.minimumIntervalMinutes, min(Self.maximumIntervalMinutes, intervalMinutes))
        copy.maxItems = max(1, min(Self.maximumItems, maxItems))
        copy.folders = folders
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.maximumFolders)
            .map { $0 }
        copy.feeds = feeds.map { $0.normalised }.filter { !$0.url.isEmpty }
            .prefix(Self.maximumFeeds).map { $0 }
        copy.mcpSources = mcpSources.map { $0.normalised }.filter { $0.usable }
            .prefix(Self.maximumMCPSources).map { $0 }
        return copy
    }

    /// What the console card shows: an enabled switch with nothing behind it is
    /// still "off", so the badge never lies.
    public var hasAnySource: Bool {
        enabled && (!folders.isEmpty || feeds.contains { $0.enabled } || mcpSources.contains { $0.enabled })
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, intervalMinutes, maxItems, folders, feeds, mcpSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
            ?? Self.defaultIntervalMinutes
        self.maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? Self.defaultMaxItems
        self.folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
        self.feeds = try container.decodeIfPresent([DiscoverFeedSource].self, forKey: .feeds) ?? []
        self.mcpSources = try container.decodeIfPresent([DiscoverMCPSource].self, forKey: .mcpSources) ?? []
    }
}

// MARK: - Envelope

/// One signed entry. `link` is deliberately allowed to be empty: a local file
/// path must not travel to the phone as a tappable target.
public struct DiscoverItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    /// `folder`, `rss`, `json` or `mcp`.
    public var source: String
    public var sourceLabel: String
    public var link: String
    public var timestamp: String
    public var sha256: String
    public var signature: String

    public init(
        id: String,
        title: String,
        summary: String,
        source: String,
        sourceLabel: String,
        link: String = "",
        timestamp: String,
        sha256: String = "",
        signature: String = ""
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.source = source
        self.sourceLabel = sourceLabel
        self.link = link
        self.timestamp = timestamp
        self.sha256 = sha256
        self.signature = signature
    }

    public func signingBody() -> Data? {
        Self.signingBody(
            id: id, title: title, summary: summary, source: source,
            sourceLabel: sourceLabel, link: link, timestamp: timestamp
        )
    }

    public static func signingBody(
        id: String,
        title: String,
        summary: String,
        source: String,
        sourceLabel: String,
        link: String,
        timestamp: String
    ) -> Data? {
        let body: [String: Any] = [
            "id": id,
            "title": title,
            "summary": summary,
            "source": source,
            "sourceLabel": sourceLabel,
            "link": link,
            "timestamp": timestamp
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// `popopx.discover.feed.v1`.
///
/// Two signatures: each item carries its own over the item body, and the envelope
/// carries one over `{ schema, generatedAt, nodeId, publicKey, items }` with the
/// full item objects in order. The envelope key is the aggregator's own key,
/// stored at `vault/discover-signing.key` — deliberately not the pairing key, so
/// this feature never becomes a general-purpose signing oracle for the node.
public struct DiscoverFeed: Codable, Sendable, Equatable {
    public static let schemaIdentifier = "popopx.discover.feed.v1"

    public var schema: String
    public var generatedAt: String
    public var nodeId: String
    public var publicKey: String
    public var items: [DiscoverItem]
    public var signature: String

    public init(
        schema: String = DiscoverFeed.schemaIdentifier,
        generatedAt: String,
        nodeId: String,
        publicKey: String,
        items: [DiscoverItem],
        signature: String
    ) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.items = items
        self.signature = signature
    }

    public static func signingBody(
        schema: String = DiscoverFeed.schemaIdentifier,
        generatedAt: String,
        nodeId: String,
        publicKey: String,
        items: [DiscoverItem]
    ) -> Data? {
        let itemBodies: [[String: Any]] = items.map { item in
            [
                "id": item.id,
                "title": item.title,
                "summary": item.summary,
                "source": item.source,
                "sourceLabel": item.sourceLabel,
                "link": item.link,
                "timestamp": item.timestamp,
                "sha256": item.sha256,
                "signature": item.signature
            ]
        }
        let body: [String: Any] = [
            "schema": schema,
            "generatedAt": generatedAt,
            "nodeId": nodeId,
            "publicKey": publicKey,
            "items": itemBodies
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func signingBody() -> Data? {
        Self.signingBody(
            schema: schema, generatedAt: generatedAt, nodeId: nodeId,
            publicKey: publicKey, items: items
        )
    }

    /// Structural checks a receiver should apply before verifying. Kept here so
    /// the node's own tests and a future phone decoder state the same rules.
    public var structuralRefusal: String? {
        guard schema == Self.schemaIdentifier else { return "schema" }
        guard !publicKey.isEmpty, !signature.isEmpty else { return "signature" }
        guard items.allSatisfy({ !$0.id.isEmpty && !$0.signature.isEmpty && $0.sha256.count == 64 }) else {
            return "item"
        }
        return nil
    }
}

// MARK: - State and snapshot

public struct DiscoverSourceStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var kind: String
    /// `ok`, `refused`, `failed` or `off`.
    public var state: String
    public var detail: String
    public var itemCount: Int

    public init(id: String, label: String, kind: String, state: String, detail: String = "", itemCount: Int = 0) {
        self.id = id
        self.label = label
        self.kind = kind
        self.state = state
        self.detail = detail
        self.itemCount = itemCount
    }
}

public struct DiscoverFeedItemView: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var sourceLabel: String
    public var timestamp: String

    public init(id: String, title: String, summary: String, sourceLabel: String, timestamp: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sourceLabel = sourceLabel
        self.timestamp = timestamp
    }

    public init(_ item: DiscoverItem) {
        self.init(
            id: item.id, title: item.title, summary: item.summary,
            sourceLabel: item.sourceLabel, timestamp: item.timestamp
        )
    }
}

public struct DiscoverSnapshot: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalMinutes: Int
    public var boundary: String
    public var lastRunAt: Date?
    public var lastDeliveredAt: Date?
    public var lastError: String
    public var itemCount: Int
    public var sources: [DiscoverSourceStatus]
    public var items: [DiscoverFeedItemView]

    public init(
        enabled: Bool = false,
        intervalMinutes: Int = DiscoverConfig.defaultIntervalMinutes,
        boundary: String = "",
        lastRunAt: Date? = nil,
        lastDeliveredAt: Date? = nil,
        lastError: String = "",
        itemCount: Int = 0,
        sources: [DiscoverSourceStatus] = [],
        items: [DiscoverFeedItemView] = []
    ) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.boundary = boundary
        self.lastRunAt = lastRunAt
        self.lastDeliveredAt = lastDeliveredAt
        self.lastError = lastError
        self.itemCount = itemCount
        self.sources = sources
        self.items = items
    }

    public static let disabled = DiscoverSnapshot()
}

public struct DiscoverState: Codable, Sendable, Equatable {
    public var lastRunAt: Date?
    public var lastDeliveredAt: Date?
    public var lastError: String
    public var itemCount: Int
    public var lastDeliveredIDs: [String]
    public var lastFeedPath: String

    public init(
        lastRunAt: Date? = nil,
        lastDeliveredAt: Date? = nil,
        lastError: String = "",
        itemCount: Int = 0,
        lastDeliveredIDs: [String] = [],
        lastFeedPath: String = ""
    ) {
        self.lastRunAt = lastRunAt
        self.lastDeliveredAt = lastDeliveredAt
        self.lastError = lastError
        self.itemCount = itemCount
        self.lastDeliveredIDs = lastDeliveredIDs
        self.lastFeedPath = lastFeedPath
    }

    private enum CodingKeys: String, CodingKey {
        case lastRunAt, lastDeliveredAt, lastError, itemCount, lastDeliveredIDs, lastFeedPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastDeliveredAt = try container.decodeIfPresent(Date.self, forKey: .lastDeliveredAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        self.itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        self.lastDeliveredIDs = try container.decodeIfPresent([String].self, forKey: .lastDeliveredIDs) ?? []
        self.lastFeedPath = try container.decodeIfPresent(String.self, forKey: .lastFeedPath) ?? ""
    }
}

public struct DiscoverAuditEntry: Codable, Sendable, Equatable {
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

// MARK: - Outcome and collaborators

public enum DiscoverRefreshOutcome: Sendable, Equatable {
    case disabled
    case unchanged(DiscoverSnapshot)
    case refreshed(feed: DiscoverFeed, path: String, newItemIDs: [String])
    case failed(String)
}

/// What `POST /api/discover/refresh` answers.
public struct DiscoverRefreshReport: Codable, Sendable, Equatable {
    /// `refreshed`, `unchanged`, `disabled` or `failed`.
    public var outcome: String
    public var itemCount: Int
    public var detail: String
    public var discover: DiscoverSnapshot

    public init(outcome: String, itemCount: Int = 0, detail: String = "", discover: DiscoverSnapshot) {
        self.outcome = outcome
        self.itemCount = itemCount
        self.detail = detail
        self.discover = discover
    }

    public static func make(_ outcome: DiscoverRefreshOutcome, snapshot: DiscoverSnapshot) -> DiscoverRefreshReport {
        switch outcome {
        case .disabled:
            return DiscoverRefreshReport(
                outcome: "disabled", detail: "发现聚合未启用 / the aggregator is off", discover: snapshot
            )
        case let .unchanged(snapshot):
            return DiscoverRefreshReport(
                outcome: "unchanged", itemCount: snapshot.itemCount,
                detail: "运行中或没有变化 / already running or unchanged", discover: snapshot
            )
        case let .refreshed(feed, _, newIDs):
            return DiscoverRefreshReport(
                outcome: "refreshed", itemCount: feed.items.count,
                detail: "items=\(feed.items.count) new=\(newIDs.count)", discover: snapshot
            )
        case let .failed(detail):
            return DiscoverRefreshReport(outcome: "failed", detail: detail, discover: snapshot)
        }
    }
}

/// Injected so feed parsing and the egress gate are testable without a socket.
public protocol DiscoverTransport: Sendable {
    func fetch(_ url: URL, limit: Int) async throws -> Data
}

public struct DiscoverMCPFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public typealias DiscoverMCPCall = @Sendable (DiscoverMCPSource) async -> Result<String, DiscoverMCPFailure>

// MARK: - Text helpers

public enum DiscoverText {
    /// Strips tags and the handful of entities that actually appear in feeds,
    /// then collapses whitespace. A summary is a preview, not a rendering.
    public static func plain(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; output.append(" "); continue }
            if !insideTag { output.append(character) }
        }
        let decoded = output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func title(_ text: String, fallback: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = plain(firstLine)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*> -_"))
        let candidate = cleaned.isEmpty ? fallback : cleaned
        return TextKit.truncate(candidate, to: 90)
    }

    public static func date(_ raw: String, fallback: Date) -> Date {
        if let parsed = PrivacyStamp.parse(raw) { return parsed }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd HH:mm:ss"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return fallback
    }
}
//
//  DiscoverCenter.swift
//  PopopxMacNode — the local Discover feed aggregator.
//
//  Flow: collect from local folders, LAN RSS/JSON feeds and read-only MCP tool
//  output, turn each entry into one signed item, sign the `popopx.discover.feed.v1`
//  envelope, write `discover/feed.json`, and leave delivery to the console layer.
//  The aggregator itself never opens a socket to a public host: feed URLs go
//  through `EdgeBoundary.privateNetworkOnly`, and a refusal is a visible source
//  status, not a silent skip.
//

import Foundation

public actor DiscoverCenter {
    public static let auditAction = "discover"
    public static let boundaryText = "仅局域网 / LAN-only · 本机文件夹 / local · Ed25519"
    /// A manual refresh (console button or phone command) is safe but not free:
    /// it touches the LAN and the disk. Sixty seconds keeps a double-click from
    /// becoming two scans, without hiding the button.
    public static let minimumRefreshGap: TimeInterval = 60

    private let transport: any DiscoverTransport
    private let mcpCall: DiscoverMCPCall
    private let keyURL: URL?
    private let feedFile: URL?
    private let stateFile: URL?
    private let scopeRoots: [URL]
    private let nodeID: @Sendable () async -> String
    private let clock: @Sendable () -> Date
    private let audit: @Sendable (DiscoverAuditEntry) async -> Void

    private var config: DiscoverConfig
    private var state: DiscoverState
    private var sources: [DiscoverSourceStatus] = []
    private var feed: DiscoverFeed?
    private var identity: SBSigning.Identity?
    private var busy = false

    public init(
        config: DiscoverConfig,
        transport: any DiscoverTransport,
        mcpCall: @escaping DiscoverMCPCall,
        keyURL: URL?,
        feedFile: URL?,
        stateFile: URL?,
        scopeRoots: [URL],
        nodeID: @escaping @Sendable () async -> String,
        now: @escaping @Sendable () -> Date = { Date() },
        audit: @escaping @Sendable (DiscoverAuditEntry) async -> Void = { _ in }
    ) {
        self.config = config.normalised
        self.transport = transport
        self.mcpCall = mcpCall
        self.keyURL = keyURL
        self.feedFile = feedFile
        self.stateFile = stateFile
        self.scopeRoots = scopeRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.nodeID = nodeID
        self.clock = now
        self.audit = audit
        if let stateFile, let data = try? Data(contentsOf: stateFile),
           let decoded = NodeJSON.decode(DiscoverState.self, from: data) {
            self.state = decoded
        } else {
            self.state = DiscoverState()
        }
        if let feedFile, let data = try? Data(contentsOf: feedFile),
           let decoded = NodeJSON.decode(DiscoverFeed.self, from: data) {
            self.feed = decoded
        }
    }

    // MARK: - Configuration and status

    public func update(config newConfig: DiscoverConfig) {
        config = newConfig.normalised
    }

    public func lastFeed() -> DiscoverFeed? { feed }

    public func snapshot() -> DiscoverSnapshot {
        makeSnapshot()
    }

    private func makeSnapshot() -> DiscoverSnapshot {
        DiscoverSnapshot(
            enabled: config.hasAnySource,
            intervalMinutes: config.intervalMinutes,
            boundary: Self.boundaryText,
            lastRunAt: state.lastRunAt,
            lastDeliveredAt: state.lastDeliveredAt,
            lastError: state.lastError,
            itemCount: state.itemCount,
            sources: sources,
            items: (feed?.items ?? []).map(DiscoverFeedItemView.init)
        )
    }

    // MARK: - Schedule

    /// The app calls this every tick. Returns a refresh outcome only when it
    /// actually ran, so the caller can decide whether to push.
    public func tick() async -> DiscoverRefreshOutcome? {
        guard config.hasAnySource else { return nil }
        guard !busy else { return nil }
        let current = clock()
        if let last = state.lastRunAt, current < last.addingTimeInterval(config.refreshInterval) {
            return nil
        }
        return await refresh()
    }

    @discardableResult
    public func refresh() async -> DiscoverRefreshOutcome {
        guard config.hasAnySource else {
            await audit(DiscoverAuditEntry(action: Self.auditAction, outcome: "disabled", at: clock()))
            return .disabled
        }
        guard !busy else { return .unchanged(makeSnapshot()) }
        busy = true
        defer { busy = false }

        let started = clock()
        if let last = state.lastRunAt, started.timeIntervalSince(last) < Self.minimumRefreshGap {
            return .unchanged(makeSnapshot())
        }

        var collected: [DiscoverItem] = []
        var statuses: [DiscoverSourceStatus] = []
        var attempted = 0
        var succeeded = 0
        var failures: [String] = []

        for folder in config.folders {
            attempted += 1
            let result = collect(folder: folder)
            statuses.append(result.status)
            if result.status.state == "ok" {
                succeeded += 1
                collected.append(contentsOf: result.items)
            } else {
                failures.append("\(result.status.label): \(result.status.detail)")
            }
        }

        for source in config.feeds where source.enabled {
            attempted += 1
            let result = await collectFeed(source)
            statuses.append(result.status)
            if result.status.state == "ok" {
                succeeded += 1
                collected.append(contentsOf: result.items)
            } else {
                failures.append("\(result.status.label): \(result.status.detail)")
            }
        }

        for source in config.mcpSources where source.enabled {
            attempted += 1
            let result = await collectMCP(source)
            statuses.append(result.status)
            if result.status.state == "ok" {
                succeeded += 1
                collected.append(contentsOf: result.items)
            } else {
                failures.append("\(result.status.label): \(result.status.detail)")
            }
        }

        sources = statuses
        let now = clock()

        if attempted > 0, succeeded == 0 {
            let detail = failures.joined(separator: " · ")
            state.lastRunAt = now
            state.lastError = detail.isEmpty ? "没有可用的来源 / no usable source" : detail
            persistState()
            await audit(DiscoverAuditEntry(
                action: Self.auditAction, outcome: "failed", detail: TextKit.truncate(state.lastError, to: 300), at: now
            ))
            return .failed(state.lastError)
        }

        let ordered = sortAndCap(collected, limit: config.maxItems)
        guard let identity = signingIdentity() else {
            let detail = "签名密钥不可用 / signing key unavailable"
            state.lastRunAt = now
            state.lastError = detail
            persistState()
            await audit(DiscoverAuditEntry(action: Self.auditAction, outcome: "failed", detail: detail, at: now))
            return .failed(detail)
        }

        let signed = ordered.compactMap { sign($0, identity: identity) }
        guard signed.count == ordered.count else {
            let detail = "条目签名失败 / item signing failed"
            state.lastRunAt = now
            state.lastError = detail
            persistState()
            await audit(DiscoverAuditEntry(action: Self.auditAction, outcome: "failed", detail: detail, at: now))
            return .failed(detail)
        }

        let built = DiscoverFeed(
            generatedAt: PrivacyStamp.iso(now),
            nodeId: await nodeID(),
            publicKey: identity.publicKeyBase64URL,
            items: signed,
            signature: ""
        )
        guard let envelopeBody = built.signingBody(),
              let envelopeSignature = identity.signature(for: envelopeBody) else {
            let detail = "载荷签名失败 / envelope signing failed"
            state.lastRunAt = now
            state.lastError = detail
            persistState()
            await audit(DiscoverAuditEntry(action: Self.auditAction, outcome: "failed", detail: detail, at: now))
            return .failed(detail)
        }
        var envelope = built
        envelope.signature = TextKit.base64URL(envelopeSignature)

        var path = state.lastFeedPath
        if let feedFile {
            do {
                try FileManager.default.createDirectory(
                    at: feedFile.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let data = try NodeJSON.encoder(prettyPrinted: true).encode(envelope)
                try data.write(to: feedFile, options: [.atomic])
                path = feedFile.path
            } catch {
                let detail = "写入 feed.json 失败 / write failed: \(error.localizedDescription)"
                state.lastRunAt = now
                state.lastError = detail
                persistState()
                await audit(DiscoverAuditEntry(action: Self.auditAction, outcome: "failed", detail: detail, at: now))
                return .failed(detail)
            }
        }

        let known = Set(state.lastDeliveredIDs)
        let newIDs = envelope.items.map(\.id).filter { !known.contains($0) }
        feed = envelope
        state.lastRunAt = now
        state.itemCount = envelope.items.count
        state.lastFeedPath = path
        state.lastError = failures.isEmpty ? "" : TextKit.truncate(failures.joined(separator: " · "), to: 300)
        persistState()
        await audit(DiscoverAuditEntry(
            action: Self.auditAction, outcome: "refreshed",
            detail: "items=\(envelope.items.count) new=\(newIDs.count) sources=\(succeeded)/\(attempted)",
            at: now
        ))
        return .refreshed(feed: envelope, path: path, newItemIDs: newIDs)
    }

    /// Records what was actually handed to the phone, so the next refresh knows
    /// which ids are new. The console calls this only after a successful delivery.
    public func markDelivered(ids: [String]) {
        guard !ids.isEmpty else { return }
        state.lastDeliveredIDs = Array(ids.prefix(DiscoverConfig.maximumItems * 2))
        state.lastDeliveredAt = clock()
        persistState()
    }

    // MARK: - Ordering and signing

    private func sortAndCap(_ items: [DiscoverItem], limit: Int) -> [DiscoverItem] {
        let indexed = items.enumerated().map { (offset: $0.offset, item: $0.element) }
        let sorted = indexed.sorted { left, right in
            let leftDate = PrivacyStamp.parse(left.item.timestamp) ?? .distantPast
            let rightDate = PrivacyStamp.parse(right.item.timestamp) ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.offset < right.offset
        }
        var seen = Set<String>()
        var out: [DiscoverItem] = []
        for entry in sorted where !seen.contains(entry.item.id) {
            seen.insert(entry.item.id)
            out.append(entry.item)
            if out.count >= limit { break }
        }
        return out
    }

    private func sign(_ item: DiscoverItem, identity: SBSigning.Identity) -> DiscoverItem? {
        var copy = item
        guard let body = copy.signingBody(), let signature = identity.signature(for: body) else { return nil }
        copy.sha256 = Digest.sha256Hex(body)
        copy.signature = TextKit.base64URL(signature)
        return copy
    }

    private func signingIdentity() -> SBSigning.Identity? {
        if let identity { return identity }
        if let keyURL, let data = try? Data(contentsOf: keyURL), let restored = SBSigning.restore(seed: data) {
            identity = restored
            return restored
        }
        guard let generated = SBSigning.generate() else { return nil }
        if let keyURL {
            do {
                try FileManager.default.createDirectory(
                    at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if let seed = generated.seed {
                    try seed.write(to: keyURL, options: [.atomic])
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: keyURL.path
                    )
                }
            } catch {
                return nil
            }
        }
        identity = generated
        return generated
    }

    private func persistState() {
        guard let stateFile else { return }
        do {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try NodeJSON.encoder(prettyPrinted: true).encode(state)
            try data.write(to: stateFile, options: [.atomic])
        } catch {
            // State is an optimisation; a stale file must not fail a refresh that
            // already wrote a correctly signed feed.
        }
    }

    // MARK: - Local folders

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "csv", "html", "htm", "log"
    ]

    private func collect(folder rawPath: String) -> (status: DiscoverSourceStatus, items: [DiscoverItem]) {
        let label = (rawPath as NSString).lastPathComponent
        let display = label.isEmpty ? rawPath : label
        do {
            let directory = try resolveFolder(rawPath)
            let files = try scanFolder(directory)
            var items: [DiscoverItem] = []
            for file in files {
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                items.append(makeDocumentItem(file: file, text: text, label: display))
            }
            return (
                DiscoverSourceStatus(
                    id: "folder:" + TextKit.fingerprint(rawPath, length: 10),
                    label: display, kind: "folder", state: "ok",
                    detail: "files=\(items.count)", itemCount: items.count
                ),
                items
            )
        } catch {
            return (
                DiscoverSourceStatus(
                    id: "folder:" + TextKit.fingerprint(rawPath, length: 10),
                    label: display, kind: "folder", state: "refused",
                    detail: describe(error)
                ),
                []
            )
        }
    }

    private func resolveFolder(_ rawPath: String) throws -> URL {
        guard let resolved = AppPaths.resolve(userPath: rawPath) else { throw FolderError.notAFolder }
        let candidate = resolved.resolvingSymlinksInPath().standardizedFileURL
        let admitted = scopeRoots.contains { root in
            candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        }
        guard admitted else { throw FolderError.outsideScope }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FolderError.notAFolder
        }
        return candidate
    }

    private struct ScannedFile {
        let url: URL
        let modified: Date
        let size: Int
    }

    private func scanFolder(_ directory: URL) throws -> [ScannedFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw FolderError.notAFolder
        }
        var found: [ScannedFile] = []
        for case let url as URL in enumerator {
            if enumerator.level > DiscoverConfig.maximumScanDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true || values.isRegularFile != true { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.textExtensions.contains(ext) else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= DiscoverConfig.maximumFileBytes else { continue }
            found.append(ScannedFile(
                url: url,
                modified: values.contentModificationDate ?? .distantPast,
                size: size
            ))
        }
        found.sort { $0.modified > $1.modified }
        return Array(found.prefix(DiscoverConfig.maximumFilesPerFolder))
    }

    private func makeDocumentItem(file: ScannedFile, text: String, label: String) -> DiscoverItem {
        let name = file.url.deletingPathExtension().lastPathComponent
        let body = DiscoverText.plain(text)
        return DiscoverItem(
            id: "doc-" + TextKit.fingerprint(file.url.resolvingSymlinksInPath().path + "\u{0}" + text, length: 20),
            title: DiscoverText.title(text, fallback: name),
            summary: TextKit.truncate(body, to: 280),
            source: "folder",
            sourceLabel: label,
            link: "",
            timestamp: PrivacyStamp.iso(file.modified)
        )
    }

    // MARK: - RSS / JSON feeds

    private func collectFeed(_ source: DiscoverFeedSource) async -> (status: DiscoverSourceStatus, items: [DiscoverItem]) {
        let label = source.label.isEmpty ? source.url : source.label
        let sourceID = source.id.isEmpty ? TextKit.fingerprint(source.url, length: 10) : source.id
        let statusID = "feed:" + sourceID
        let endpoint: EdgeEndpoint
        do {
            endpoint = try EdgeBoundary.resolve(url: source.url, policy: .privateNetworkOnly)
        } catch {
            return (
                DiscoverSourceStatus(
                    id: statusID, label: label, kind: source.kind, state: "refused",
                    detail: describe(error)
                ),
                []
            )
        }
        let components = URLComponents(string: source.url)
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let query = components?.percentEncodedQuery ?? ""
        guard let url = endpoint.url(path: path, query: query) else {
            return (
                DiscoverSourceStatus(id: statusID, label: label, kind: source.kind, state: "failed", detail: "URL"),
                []
            )
        }
        do {
            let data = try await transport.fetch(url, limit: DiscoverConfig.maximumFeedBytes)
            guard let text = String(data: data, encoding: .utf8) else {
                return (
                    DiscoverSourceStatus(id: statusID, label: label, kind: source.kind, state: "failed", detail: "encoding"),
                    []
                )
            }
            let raw: [DiscoverRawEntry]
            if source.kind == "json" || looksLikeJSON(text) {
                raw = try parseJSONFeed(text)
            } else {
                raw = try parseRSS(text)
            }
            let now = clock()
            let items = raw.prefix(DiscoverConfig.maximumItemsPerSource).map { entry in
                makeFeedItem(entry, source: source, sourceID: sourceID, label: label, now: now)
            }
            return (
                DiscoverSourceStatus(
                    id: statusID, label: label, kind: source.kind, state: "ok",
                    detail: "items=\(items.count)", itemCount: items.count
                ),
                items
            )
        } catch {
            return (
                DiscoverSourceStatus(id: statusID, label: label, kind: source.kind, state: "failed", detail: describe(error)),
                []
            )
        }
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private func makeFeedItem(
        _ entry: DiscoverRawEntry, source: DiscoverFeedSource, sourceID: String, label: String, now: Date
    ) -> DiscoverItem {
        let seed = sourceID + "|" + (entry.identifier.isEmpty ? entry.link + "|" + entry.title : entry.identifier)
        return DiscoverItem(
            id: "feed-" + TextKit.fingerprint(seed, length: 20),
            title: TextKit.truncate(DiscoverText.plain(entry.title), to: 90),
            summary: TextKit.truncate(DiscoverText.plain(entry.summary), to: 280),
            source: source.kind,
            sourceLabel: label,
            link: entry.link.hasPrefix("http") ? entry.link : "",
            timestamp: PrivacyStamp.iso(entry.date ?? now)
        )
    }

    private func parseRSS(_ text: String) throws -> [DiscoverRawEntry] {
        let delegate = RSSDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        let complete = parser.parse()
        guard complete || !delegate.entries.isEmpty else {
            throw FeedError.malformed("XML")
        }
        return delegate.entries
    }

    private func parseJSONFeed(_ text: String) throws -> [DiscoverRawEntry] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw FeedError.malformed("JSON")
        }
        let rawItems: [Any]
        if let array = object as? [Any] {
            rawItems = array
        } else if let dictionary = object as? [String: Any], let array = dictionary["items"] as? [Any] {
            rawItems = array
        } else {
            throw FeedError.malformed("JSON items")
        }
        return rawItems.compactMap { element in
            guard let dictionary = element as? [String: Any] else { return nil }
            let title = firstString(dictionary, ["title", "name"]) ?? ""
            let link = firstString(dictionary, ["url", "link", "external_url", "permalink"]) ?? ""
            let summary = firstString(
                dictionary, ["summary", "content_text", "description", "content_html", "content"]
            ) ?? ""
            let identifier = firstString(dictionary, ["id", "guid", "uuid"]) ?? link
            let dateText = firstString(
                dictionary, ["date_published", "date_modified", "pubDate", "published", "published_at", "updated"]
            )
            guard !title.isEmpty || !summary.isEmpty else { return nil }
            return DiscoverRawEntry(
                title: title,
                link: link,
                summary: summary,
                identifier: identifier,
                date: dateText.map { DiscoverText.date($0, fallback: clock()) }
            )
        }
    }

    private func firstString(_ dictionary: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - MCP sources

    private func collectMCP(_ source: DiscoverMCPSource) async -> (status: DiscoverSourceStatus, items: [DiscoverItem]) {
        let label = source.label.isEmpty ? "\(source.serverID)/\(source.toolName)" : source.label
        let statusID = "mcp:" + (source.id.isEmpty ? TextKit.fingerprint(label, length: 10) : source.id)
        let result = await mcpCall(source)
        switch result {
        case let .failure(error):
            return (
                DiscoverSourceStatus(id: statusID, label: label, kind: "mcp", state: "failed", detail: error.message),
                []
            )
        case let .success(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return (
                    DiscoverSourceStatus(id: statusID, label: label, kind: "mcp", state: "ok", detail: "items=0"),
                    []
                )
            }
            var entries: [DiscoverRawEntry] = []
            if looksLikeJSON(trimmed), let parsed = try? parseJSONFeed(trimmed) {
                entries = parsed
            }
            if entries.isEmpty {
                entries = [DiscoverRawEntry(
                    title: label, link: "", summary: trimmed,
                    identifier: source.serverID + "|" + source.toolName, date: clock()
                )]
            }
            let items = entries.prefix(DiscoverConfig.maximumItemsPerSource).map { entry in
                makeFeedItem(entry, source: DiscoverFeedSource(url: "mcp://" + source.serverID, kind: "mcp"), sourceID: statusID, label: label, now: clock())
            }
            return (
                DiscoverSourceStatus(
                    id: statusID, label: label, kind: "mcp", state: "ok",
                    detail: "items=\(items.count)", itemCount: items.count
                ),
                items
            )
        }
    }

    // MARK: - Errors

    private enum FolderError: Error, CustomStringConvertible {
        case outsideScope
        case notAFolder

        var description: String {
            switch self {
            case .outsideScope:
                return "文件夹不在允许范围内 / folder outside the allowed roots"
            case .notAFolder:
                return "不是可读取的文件夹 / not a readable folder"
            }
        }
    }

    private enum FeedError: Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(kind):
                return "无法解析 \(kind) / malformed \(kind)"
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if let boundary = error as? EdgeBoundaryError { return boundary.description }
        if let feed = error as? FeedError { return feed.description }
        if let folder = error as? FolderError { return folder.description }
        return TextKit.truncate(error.localizedDescription, to: 200)
    }
}

// MARK: - RSS / Atom delegate

private struct DiscoverRawEntry {
    var title: String
    var link: String
    var summary: String
    var identifier: String
    var date: Date?
}

/// Minimal RSS 2.0 / Atom reader. It deliberately ignores namespaces beyond
/// matching the local tag name, because a feed that needs more than title, link,
/// summary and date is beyond what a "lightweight aggregator" promises.
private final class RSSDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [DiscoverRawEntry] = []
    private var inItem = false
    private var current = DiscoverRawEntry(
        title: "", link: "", summary: "", identifier: "", date: nil
    )
    private var field: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            inItem = true
            current = DiscoverRawEntry(title: "", link: "", summary: "", identifier: "", date: nil)
            field = nil
            buffer = ""
            return
        }
        guard inItem else { return }
        if name == "link", let href = attributeDict["href"], !href.isEmpty {
            current.link = href
        }
        switch name {
        case "title", "link", "description", "summary", "content", "encoded",
             "guid", "id", "pubdate", "published", "updated", "date":
            field = name
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard field != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            appendEntry()
            inItem = false
            field = nil
            buffer = ""
            return
        }
        guard inItem, let active = field, active == name else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current.title = value
        case "link": if !value.isEmpty { current.link = value }
        case "description", "summary", "content", "encoded":
            if current.summary.isEmpty { current.summary = value }
        case "guid", "id": current.identifier = value
        case "pubdate", "published", "updated", "date":
            if !value.isEmpty, current.date == nil {
                current.date = DiscoverText.date(value, fallback: Date())
            }
        default: break
        }
        field = nil
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // A truncated feed is common in the wild; keep the entries already read.
    }

    private func appendEntry() {
        guard !current.title.isEmpty || !current.summary.isEmpty || !current.link.isEmpty else { return }
        entries.append(current)
    }
}
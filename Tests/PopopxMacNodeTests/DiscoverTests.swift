//
//  DiscoverTests.swift
//  PopopxMacNode — the `popopx.discover.feed.v1` contract.
//
//  Two promises are tested here. Packaging: every item and the envelope carry an
//  Ed25519 signature a receiver can check without trusting the file, so tampering
//  with one summary breaks the envelope. Containment: a public feed host is
//  refused before any transport call, a folder outside the injected scope roots
//  is never read, and the scan skips symlinks, hidden files and oversized files.
//

import Foundation
import XCTest
@testable import PopopxMacNode

private final class DiscoverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.lock(); defer { lock.unlock() }; return value }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

private final class DiscoverAuditBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DiscoverAuditEntry] = []

    func add(_ entry: DiscoverAuditEntry) {
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [DiscoverAuditEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}

private actor FeedFixtureTransport: DiscoverTransport {
    private var payloads: [String: Data] = [:]
    private(set) var calls: [URL] = []

    func set(_ path: String, data: Data) { payloads[path] = data }
    func set(_ path: String, text: String) { payloads[path] = Data(text.utf8) }

    func fetch(_ url: URL, limit: Int) async throws -> Data {
        calls.append(url)
        guard let data = payloads[url.path] else { throw URLError(.badServerResponse) }
        return data
    }
}

final class DiscoverTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func makeDirectory(_ name: String = "ppx-discover") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCenter(
        config: DiscoverConfig,
        transport: FeedFixtureTransport,
        mcpCall: @escaping DiscoverMCPCall = { _ in .success("") },
        directory: URL,
        root: URL,
        clock: DiscoverClock,
        audit: DiscoverAuditBox? = nil
    ) -> DiscoverCenter {
        DiscoverCenter(
            config: config,
            transport: transport,
            mcpCall: mcpCall,
            keyURL: directory.appendingPathComponent("discover-signing.key"),
            feedFile: directory.appendingPathComponent("feed.json"),
            stateFile: directory.appendingPathComponent("state.json"),
            scopeRoots: [root],
            nodeID: { "PPXNODE1-TEST" },
            now: { clock.now },
            audit: { entry in audit?.add(entry) }
        )
    }

    @discardableResult
    private func writeFile(_ directory: URL, _ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let jsonFeed = """
    {"items":[
      {"id":"j1","title":"JSON 条目","summary":"JSON 摘要","url":"https://example.com/a",
       "date_published":"2026-11-26T10:00:00Z"}
    ]}
    """

    private static let rssFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>RSS</title><item>
      <title>RSS 条目</title>
      <link>http://127.0.0.1/item</link>
      <description>RSS 摘要</description>
      <pubDate>2026-11-26T09:00:00Z</pubDate>
      <guid>r1</guid>
    </item></channel></rss>
    """

    private static let mdnsFeed = """
    {"items":[
      {"id":"m1","title":"mDNS 条目","summary":"局域网页摘要","url":"https://popopx.chat/blog",
       "date_published":"2026-11-26T11:00:00Z"}
    ]}
    """

    // MARK: - Packaging

    func testRefreshSignsEveryItemAndTheEnvelopeOnDisk() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        try writeFile(root, "note.md", "# 小笔记\n正文内容在这里")
        let transport = FeedFixtureTransport()
        let clock = DiscoverClock(fixedNow)
        let center = makeCenter(
            config: DiscoverConfig(enabled: true, folders: [root.path]),
            transport: transport, directory: directory, root: root, clock: clock
        )

        let outcome = await center.refresh()
        guard case let .refreshed(feed, path, newIDs) = outcome else {
            return XCTFail("a local folder must produce a feed, got \(outcome)")
        }
        XCTAssertEqual(feed.schema, "popopx.discover.feed.v1")
        XCTAssertEqual(feed.nodeId, "PPXNODE1-TEST")
        XCTAssertNil(feed.structuralRefusal)
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(newIDs, feed.items.map(\.id))
        XCTAssertEqual(path, directory.appendingPathComponent("feed.json").path)

        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.title, "小笔记")
        XCTAssertEqual(item.source, "folder")
        XCTAssertEqual(item.link, "", "a local file path must never travel to the phone as a tappable link")
        XCTAssertEqual(item.sha256.count, 64)
        let itemBody = try XCTUnwrap(item.signingBody())
        XCTAssertEqual(item.sha256, Digest.sha256Hex(itemBody))
        XCTAssertTrue(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: item.signature,
            body: itemBody
        ), "the item signature must verify against the envelope's own key")

        let envelopeBody = try XCTUnwrap(feed.signingBody())
        XCTAssertTrue(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: feed.signature,
            body: envelopeBody
        ), "the envelope signature must verify")

        // The file — not just the in-memory value — is what carries the signatures.
        let diskData = try Data(contentsOf: directory.appendingPathComponent("feed.json"))
        let diskFeed = try XCTUnwrap(NodeJSON.decode(DiscoverFeed.self, from: diskData))
        XCTAssertEqual(diskFeed, feed)
        let diskBody = try XCTUnwrap(diskFeed.signingBody())
        XCTAssertTrue(SBSigning.verify(
            publicKeyBase64URL: diskFeed.publicKey,
            signatureBase64URL: diskFeed.signature,
            body: diskBody
        ))

        // The signing key is the one on disk, and only the node can read it.
        let keyURL = directory.appendingPathComponent("discover-signing.key")
        let seed = try Data(contentsOf: keyURL)
        let restored = try XCTUnwrap(SBSigning.restore(seed: seed))
        XCTAssertEqual(restored.publicKeyBase64URL, feed.publicKey)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600, "the signing seed must stay owner-only")

        let stateData = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let state = try XCTUnwrap(NodeJSON.decode(DiscoverState.self, from: stateData))
        XCTAssertEqual(state.itemCount, 1)
        XCTAssertEqual(state.lastFeedPath, path)

        // Delivered ids make the next refresh's "new" list honest, and ids are stable.
        await center.markDelivered(ids: feed.items.map(\.id))
        clock.advance(61)
        let second = await center.refresh()
        guard case let .refreshed(secondFeed, _, secondNew) = second else {
            return XCTFail("a second refresh after the gap must run, got \(second)")
        }
        XCTAssertTrue(secondNew.isEmpty, "an already delivered item is not new again")
        XCTAssertEqual(secondFeed.items.map(\.id), feed.items.map(\.id), "ids are derived, not random")
    }

    func testTamperingWithAnItemBreaksTheEnvelopeSignature() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        try writeFile(root, "note.md", "标题\n正文")
        let transport = FeedFixtureTransport()
        let center = makeCenter(
            config: DiscoverConfig(enabled: true, folders: [root.path]),
            transport: transport, directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case let .refreshed(feed, _, _) = outcome else {
            return XCTFail("expected a feed, got \(outcome)")
        }

        let honestItem = try XCTUnwrap(feed.items.first)
        var tamperedItem = honestItem
        tamperedItem.summary = "被篡改的摘要 / tampered summary"

        let honestBody = try XCTUnwrap(honestItem.signingBody())
        let tamperedBody = try XCTUnwrap(tamperedItem.signingBody())
        XCTAssertTrue(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: honestItem.signature,
            body: honestBody
        ), "control: the untouched item verifies")
        XCTAssertFalse(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: honestItem.signature,
            body: tamperedBody
        ), "the item signature must cover its own text")

        let honestEnvelope = try XCTUnwrap(feed.signingBody())
        let tamperedEnvelope = try XCTUnwrap(DiscoverFeed.signingBody(
            generatedAt: feed.generatedAt, nodeId: feed.nodeId,
            publicKey: feed.publicKey, items: [tamperedItem]
        ))
        XCTAssertTrue(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: feed.signature,
            body: honestEnvelope
        ), "control: the untouched envelope verifies")
        XCTAssertFalse(SBSigning.verify(
            publicKeyBase64URL: feed.publicKey,
            signatureBase64URL: feed.signature,
            body: tamperedEnvelope
        ), "the envelope must bind item content, not just item ids")
    }

    // MARK: - Containment

    func testPublicFeedHostsAreRefusedAndNeverFetched() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        try writeFile(root, "note.md", "本机文件")
        let transport = FeedFixtureTransport()
        await transport.set("/public.json", text: Self.jsonFeed)
        await transport.set("/resolved.json", text: Self.jsonFeed)
        let config = DiscoverConfig(
            enabled: true,
            folders: [root.path],
            feeds: [
                DiscoverFeedSource(id: "public-domain", label: "公网域名", url: "https://example.com/public.json", kind: "json"),
                DiscoverFeedSource(id: "public-ip", label: "公网地址", url: "http://93.184.216.34/resolved.json", kind: "json")
            ]
        )
        let center = makeCenter(
            config: config, transport: transport,
            directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case let .refreshed(feed, _, _) = outcome else {
            return XCTFail("the folder still yields a feed beside refused feeds, got \(outcome)")
        }
        XCTAssertEqual(feed.items.count, 1, "only the local folder contributes")
        XCTAssertEqual(feed.items.first?.source, "folder")

        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty, "a refused feed URL must never reach the transport: \(calls)")

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.sources.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        XCTAssertEqual(byID["feed:public-domain"]?.state, "refused")
        XCTAssertTrue(byID["feed:public-domain"]?.detail.contains("域名") == true,
                      byID["feed:public-domain"]?.detail ?? "")
        XCTAssertEqual(byID["feed:public-ip"]?.state, "refused")
        XCTAssertTrue(byID["feed:public-ip"]?.detail.contains("公网") == true,
                      byID["feed:public-ip"]?.detail ?? "")
        XCTAssertEqual(byID["folder:\(TextKit.fingerprint(root.path, length: 10))"]?.state, "ok")
    }

    func testLoopbackAndMdnsFeedsAreParsedNewestFirst() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()
        await transport.set("/feed.json", text: Self.jsonFeed)
        await transport.set("/rss.xml", text: Self.rssFeed)
        await transport.set("/mdns.json", text: Self.mdnsFeed)
        let config = DiscoverConfig(
            enabled: true,
            feeds: [
                DiscoverFeedSource(id: "rss", label: "RSS 派", url: "http://127.0.0.1:8099/rss.xml", kind: "rss"),
                DiscoverFeedSource(id: "json", label: "JSON 派", url: "http://127.0.0.1:8099/feed.json", kind: "json"),
                DiscoverFeedSource(id: "mdns", label: "mDNS 派", url: "http://mac-mini.local/mdns.json", kind: "json")
            ]
        )
        let center = makeCenter(
            config: config, transport: transport,
            directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case let .refreshed(feed, _, _) = outcome else {
            return XCTFail("LAN feeds must produce a feed, got \(outcome)")
        }

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(Set(calls.map(\.path)), ["/feed.json", "/rss.xml", "/mdns.json"])
        XCTAssertTrue(calls.allSatisfy { $0.host == "127.0.0.1" || $0.host == "mac-mini.local" })

        XCTAssertEqual(feed.items.map(\.title), ["mDNS 条目", "JSON 条目", "RSS 条目"],
                       "items are ordered newest first by their own timestamp")
        XCTAssertEqual(feed.items.map(\.source), ["json", "json", "rss"])
        XCTAssertEqual(feed.items.first?.link, "https://popopx.chat/blog")

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.sources.map(\.state), ["ok", "ok", "ok"])
        XCTAssertEqual(snapshot.itemCount, 3)
        XCTAssertEqual(snapshot.items.count, 3)
    }

    func testMCPFailureIsVisibleAndSuccessBecomesAnItem() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()
        let mcpCall: DiscoverMCPCall = { source in
            if source.toolName == "noise" {
                return .success("来自 MCP 的纯文本输出")
            }
            return .failure(DiscoverMCPFailure("工具失败 / tool failed"))
        }
        let config = DiscoverConfig(
            enabled: true,
            mcpSources: [
                DiscoverMCPSource(id: "good", serverID: "local", toolName: "noise"),
                DiscoverMCPSource(id: "bad", serverID: "local", toolName: "crash")
            ]
        )
        let center = makeCenter(
            config: config, transport: transport, mcpCall: mcpCall,
            directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case let .refreshed(feed, _, _) = outcome else {
            return XCTFail("one working MCP source is enough for a feed, got \(outcome)")
        }
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.source, "mcp")
        XCTAssertEqual(item.sourceLabel, "local/noise")
        XCTAssertEqual(item.link, "")
        XCTAssertTrue(item.summary.contains("MCP"))

        let snapshot = await center.snapshot()
        let failed = snapshot.sources.first { $0.id == "mcp:bad" }
        XCTAssertEqual(failed?.state, "failed")
        XCTAssertEqual(failed?.detail, "工具失败 / tool failed")
        XCTAssertEqual(snapshot.sources.first { $0.id == "mcp:good" }?.state, "ok")
    }

    func testOnlyFailingSourcesProduceAFailedRefreshAndNoFeedFile() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()
        let mcpCall: DiscoverMCPCall = { _ in .failure(DiscoverMCPFailure("工具失败 / tool failed")) }
        let config = DiscoverConfig(
            enabled: true,
            mcpSources: [DiscoverMCPSource(id: "bad", serverID: "local", toolName: "crash")]
        )
        let audit = DiscoverAuditBox()
        let center = makeCenter(
            config: config, transport: transport, mcpCall: mcpCall,
            directory: directory, root: root, clock: DiscoverClock(fixedNow), audit: audit
        )
        let outcome = await center.refresh()
        guard case let .failed(detail) = outcome else {
            return XCTFail("zero working sources is a failed refresh, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("工具失败"), detail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("feed.json").path),
                       "a failed refresh must not publish a feed")
        XCTAssertTrue(audit.all.contains { $0.outcome == "failed" })
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.sources.first?.state, "failed")
        XCTAssertTrue(snapshot.lastError.contains("工具失败"))
    }

    func testFolderOutsideScopeIsRefusedAndTheSameFolderInsideScopeIsRead() async throws {
        let inside = try makeDirectory("ppx-discover-inside")
        let outside = try makeDirectory("ppx-discover-outside")
        try writeFile(outside, "note.md", "范围之外的文件")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()

        let refusedCenter = makeCenter(
            config: DiscoverConfig(enabled: true, folders: [outside.path]),
            transport: transport, directory: directory, root: inside, clock: DiscoverClock(fixedNow)
        )
        let refused = await refusedCenter.refresh()
        guard case let .failed(detail) = refused else {
            return XCTFail("a folder outside the scope roots is a failed refresh, got \(refused)")
        }
        XCTAssertTrue(detail.contains("允许范围"), detail)
        let refusedSnapshot = await refusedCenter.snapshot()
        XCTAssertEqual(refusedSnapshot.sources.first?.state, "refused")

        let admittedCenter = makeCenter(
            config: DiscoverConfig(enabled: true, folders: [outside.path]),
            transport: transport, directory: try makeDirectory("ppx-discover-store2"),
            root: outside, clock: DiscoverClock(fixedNow)
        )
        let admitted = await admittedCenter.refresh()
        guard case let .refreshed(feed, _, _) = admitted else {
            return XCTFail("control: the same folder inside the scope roots is readable, got \(admitted)")
        }
        XCTAssertEqual(feed.items.count, 1)
    }

    func testFolderScanSkipsSymlinksOversizeHiddenAndNonText() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        try writeFile(root, "small.md", "# 小笔记\n正文")
        let big = Data(repeating: 0x61, count: 600 * 1024)
        try big.write(to: root.appendingPathComponent("big.txt"))
        try writeFile(root, "non-text.pdf", "PDF 内容")
        try writeFile(root, ".hidden.md", "隐藏文件")
        try writeFile(root, "empty.txt", "")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.md"),
            withDestinationURL: root.appendingPathComponent("small.md")
        )

        let transport = FeedFixtureTransport()
        let center = makeCenter(
            config: DiscoverConfig(enabled: true, folders: [root.path]),
            transport: transport, directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case let .refreshed(feed, _, _) = outcome else {
            return XCTFail("expected a feed from the one small text file, got \(outcome)")
        }
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.items.first?.title, "小笔记")
    }

    // MARK: - Schedule

    func testTicksAreIntervalGatedAndManualRefreshIsThrottled() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()
        await transport.set("/feed.json", text: Self.jsonFeed)
        let config = DiscoverConfig(
            enabled: true,
            intervalMinutes: 15,
            feeds: [DiscoverFeedSource(id: "j", label: "JSON", url: "http://127.0.0.1:8100/feed.json", kind: "json")]
        )
        let clock = DiscoverClock(fixedNow)
        let center = makeCenter(
            config: config, transport: transport,
            directory: directory, root: root, clock: clock
        )

        let firstTick = await center.tick()
        guard case .refreshed? = firstTick else {
            return XCTFail("the first tick runs, got \(String(describing: firstTick))")
        }
        let afterFirst = await transport.calls.count
        XCTAssertEqual(afterFirst, 1)

        let gatedTick = await center.tick()
        XCTAssertNil(gatedTick, "a tick inside the refresh interval does not run")

        let throttled = await center.refresh()
        guard case .unchanged = throttled else {
            return XCTFail("a manual refresh within 60 s is a no-op, got \(throttled)")
        }
        let afterThrottle = await transport.calls.count
        XCTAssertEqual(afterThrottle, 1, "the throttle must not hit the network")

        clock.advance(60)
        let allowed = await center.refresh()
        guard case .refreshed = allowed else {
            return XCTFail("after 60 s the manual refresh runs, got \(allowed)")
        }
        let afterAllowed = await transport.calls.count
        XCTAssertEqual(afterAllowed, 2)

        clock.advance(61)
        let stillGated = await center.tick()
        XCTAssertNil(stillGated)

        clock.advance(15 * 60)
        let due = await center.tick()
        guard case .refreshed? = due else {
            return XCTFail("after the interval the tick runs again, got \(String(describing: due))")
        }
        let afterDue = await transport.calls.count
        XCTAssertEqual(afterDue, 3)
    }

    func testDisabledOrSourcelessConfigDoesNothing() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        try writeFile(root, "note.md", "内容")
        let transport = FeedFixtureTransport()
        let audit = DiscoverAuditBox()

        let disabled = makeCenter(
            config: DiscoverConfig(enabled: false, folders: [root.path]),
            transport: transport, directory: directory, root: root,
            clock: DiscoverClock(fixedNow), audit: audit
        )
        let offOutcome = await disabled.refresh()
        guard case .disabled = offOutcome else {
            return XCTFail("a disabled aggregator does nothing, got \(offOutcome)")
        }
        let tickOnDisabled = await disabled.tick()
        XCTAssertNil(tickOnDisabled)
        let offSnapshot = await disabled.snapshot()
        XCTAssertFalse(offSnapshot.enabled)

        let sourceless = makeCenter(
            config: DiscoverConfig(enabled: true),
            transport: transport, directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let emptyOutcome = await sourceless.refresh()
        guard case .disabled = emptyOutcome else {
            return XCTFail("an enabled switch with no sources is still off, got \(emptyOutcome)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("feed.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("discover-signing.key").path),
                       "no source means no key is minted")
        XCTAssertTrue(audit.all.contains { $0.outcome == "disabled" })
    }

    func testDisabledFeedSourceIsSkipped() async throws {
        let root = try makeDirectory("ppx-discover-root")
        let directory = try makeDirectory("ppx-discover-store")
        let transport = FeedFixtureTransport()
        await transport.set("/on.json", text: Self.jsonFeed)
        await transport.set("/off.json", text: Self.jsonFeed)
        let config = DiscoverConfig(
            enabled: true,
            feeds: [
                DiscoverFeedSource(id: "on", label: "开", url: "http://127.0.0.1:8101/on.json", kind: "json"),
                DiscoverFeedSource(id: "off", label: "关", url: "http://127.0.0.1:8101/off.json", kind: "json", enabled: false)
            ]
        )
        let center = makeCenter(
            config: config, transport: transport,
            directory: directory, root: root, clock: DiscoverClock(fixedNow)
        )
        let outcome = await center.refresh()
        guard case .refreshed = outcome else {
            return XCTFail("the enabled source still runs, got \(outcome)")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.path), ["/on.json"])
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources.first?.id, "feed:on")
    }
}
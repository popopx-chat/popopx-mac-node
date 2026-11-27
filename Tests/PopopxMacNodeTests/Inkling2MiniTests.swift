//
//  Inkling2MiniTests.swift
//  PopopxMacNode — the local model's boundary, on a fake loopback runtime.
//
//  What is being proved is not that a model is clever. It is that:
//  * an endpoint the EdgeBoundary did not classify as loopback is never contacted;
//  * a malformed or shape-wrong answer gets exactly one repair, and a transport
//    failure gets none;
//  * media is read only inside the owner's authorized roots, and neither the
//    Base64 payload nor the extracted private text reaches the audit log;
//  * a proposal that the model produced is still inert until the owner's receipt
//    is validated at the executor.
//

import CoreGraphics
import Foundation
import XCTest
@testable import PopopxMacNode

// MARK: - Fakes

/// A queue-per-path transport. Every request it records names an `EdgeEndpoint`,
/// so the request log is also proof that the loopback guard ran before I/O.
private final class InklingFakeTransport: InklingTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [InklingHTTPResponse]] = [:]
    private var fallbacks: [String: InklingHTTPResponse] = [:]
    private var failing: Set<String> = []
    private var failEverything = false
    private var log: [InklingHTTPRequest] = []
    private var sentBodies: [(path: String, text: String)] = []

    func queue(_ path: String, _ responses: [InklingHTTPResponse]) {
        lock.lock(); defer { lock.unlock() }
        queues[path, default: []].append(contentsOf: responses)
    }

    func fallback(_ path: String, _ response: InklingHTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        fallbacks[path] = response
    }

    func fail(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(path)
    }

    func setFailEverything(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        failEverything = value
    }

    var requests: [InklingHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func count(_ path: String) -> Int {
        requests.filter { $0.path == path }.count
    }

    func bodies(for path: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sentBodies.filter { $0.path == path }.map(\.text)
    }

    func send(_ request: InklingHTTPRequest) async throws -> InklingHTTPResponse {
        let outcome = record(request)
        if outcome.shouldFail { throw InklingTransportError.notHTTP }
        guard let reply = outcome.reply else { throw InklingTransportError.notHTTP }
        return reply
    }

    /// The lock is taken in a synchronous section: `NSLock` inside an async
    /// function is a Swift 6 error, and the fake has to stay warning-free too.
    private func record(_ request: InklingHTTPRequest) -> (shouldFail: Bool, reply: InklingHTTPResponse?) {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
        if let body = request.body {
            sentBodies.append((request.path, String(decoding: body, as: UTF8.self)))
        }
        let shouldFail = failEverything || failing.contains(request.path)
        guard !shouldFail else { return (true, nil) }
        if var queue = queues[request.path], !queue.isEmpty {
            let reply = queue.removeFirst()
            queues[request.path] = queue
            return (false, reply)
        }
        return (false, fallbacks[request.path])
    }
}

private final class InklingFakeMailTransport: MailTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [MailFetchedMessage] = []
    private var outbox: [MailOutgoingDraft] = []

    func setInbox(_ messages: [MailFetchedMessage]) {
        lock.lock(); defer { lock.unlock() }
        inbox = messages
    }

    var sent: [MailOutgoingDraft] {
        lock.lock(); defer { lock.unlock() }
        return outbox
    }

    func fetchRecent(
        account: MailAssistantConfig,
        password: String,
        since: Date,
        limit: Int
    ) async throws -> [MailFetchedMessage] {
        takeInbox(limit)
    }

    func send(draft: MailOutgoingDraft, account: MailAssistantConfig, password: String) async throws {
        appendSent(draft)
    }

    private func takeInbox(_ limit: Int) -> [MailFetchedMessage] {
        lock.lock(); defer { lock.unlock() }
        return Array(inbox.prefix(limit))
    }

    private func appendSent(_ draft: MailOutgoingDraft) {
        lock.lock(); defer { lock.unlock() }
        outbox.append(draft)
    }
}

private actor InklingFakeSentinelProvider: HomeSentinelEntityProviding {
    func sentinelEntities() async -> [SmartHomeEntityCard] { [] }
    func sentinelReadOnly() async -> Bool { false }
    func performSentinelRepair(_ payload: HubCallPayload) async -> HomeRepairOutcome {
        .refused("sentinel not exercised")
    }
}

private actor InklingDeliveryRecorder {
    private var results: [CommandResult] = []

    func deliver(_ result: CommandResult) async -> Bool {
        results.append(result)
        return true
    }

    func all() -> [CommandResult] { results }
}

// MARK: - Fixtures

private let inklingNow = localInklingMorning()
private let inklingOllamaTags = "/api/tags"
private let inklingGenerate = "/api/generate"
private let inklingMLXModels = "/v1/models"
private let inklingMLXChat = "/v1/chat/completions"

private func localInklingMorning() -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 27
    components.hour = 8
    components.minute = 0
    return Calendar.current.date(from: components)!
}

private func inklingHTTP(_ object: Any, status: Int = 200) -> InklingHTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return InklingHTTPResponse(status: status, body: data)
}

private func inklingInnerJSON(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func inklingOllamaAnswer(_ text: String) -> InklingHTTPResponse {
    inklingHTTP(["response": text])
}

private func inklingTags(_ names: [String]) -> InklingHTTPResponse {
    inklingHTTP(["models": names.map { ["name": $0] }])
}

private func inklingMLXList(_ names: [String]) -> InklingHTTPResponse {
    inklingHTTP(["data": names.map { ["id": $0] }])
}

private func inklingMLXAnswer(_ text: String) -> InklingHTTPResponse {
    inklingHTTP(["choices": [["message": ["content": text]]]])
}

private let inklingBriefingJSON = inklingInnerJSON([
    "headline": "Local headline",
    "summary": "Two quiet sentences from the local model.",
    "priorities": ["pay the bill", "check the gateway"],
    "anomaly_notes": "the gateway lost its lease"
])

private let inklingMediaJSON = inklingInnerJSON([
    "document_kind": "bill",
    "merchant": "Grid & Gas",
    "amount": "128.00",
    "due_date": "2026-12-05",
    "summary": "Electricity bill for November"
])

/// A real 1×1 PNG. The loader checks magic bytes rather than decoding, so a
/// constant is a smaller and more stable fixture than drawing an image.
private let inklingPNGBytes = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!

private func inklingTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ppx-inkling-\(UUID().uuidString)", isDirectory: true)
}

private func inklingWritePNG(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try inklingPNGBytes.write(to: url)
}

private func inklingMakePDF() -> Data? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(x: 0, y: 0, width: 144, height: 144)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(box)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 16, y: 16, width: 72, height: 24))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

private func inklingLoopbackOnly(_ requests: [InklingHTTPRequest]) -> Bool {
    requests.allSatisfy { $0.endpoint.host == "127.0.0.1" }
}

// MARK: - Adapter tests

final class Inkling2MiniTests: XCTestCase {
    private func makeAdapter(
        config: InklingConfig = InklingConfig(),
        roots: [String] = [],
        transport: InklingFakeTransport,
        store: AssistantAuditStore? = nil
    ) -> Inkling2MiniAdapter {
        Inkling2MiniAdapter(
            config: config,
            scopeRoots: roots,
            transport: transport,
            store: store,
            clock: ManualAssistantClock(inklingNow)
        )
    }

    func testProbeContactsOnlyTheLoopbackOllamaRuntime() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini:latest"]))
        let adapter = makeAdapter(transport: transport)

        let card = await adapter.probe(now: inklingNow)

        XCTAssertEqual(card.state, .ready)
        XCTAssertEqual(card.runtime, "ollama")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.path, inklingOllamaTags)
        XCTAssertTrue(inklingLoopbackOnly(transport.requests))
    }

    func testPublicDomainAndCredentialedEndpointsAreRefusedWithZeroRequests() async {
        let transport = InklingFakeTransport()
        let adapter = makeAdapter(
            config: InklingConfig(
                ollamaEndpoint: "http://203.0.113.9:11434",
                mlxEndpoint: "https://example.com:8443"
            ),
            transport: transport
        )

        let card = await adapter.probe(now: inklingNow)
        XCTAssertEqual(card.state, .refused)
        XCTAssertTrue(transport.requests.isEmpty, "a refused endpoint must not produce a request")

        let generation = await adapter.generateStructuredJSON(
            prompt: "answer",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )
        XCTAssertFalse(generation.ok)
        XCTAssertEqual(generation.attempts, 0)
        XCTAssertTrue(transport.requests.isEmpty)

        let credentialed = InklingFakeTransport()
        let second = makeAdapter(
            config: InklingConfig(
                ollamaEndpoint: "http://user:pass@127.0.0.1:11434",
                mlxEndpoint: "https://example.org:8443"
            ),
            transport: credentialed
        )
        let refused = await second.probe(now: inklingNow)
        XCTAssertEqual(refused.state, .refused)
        XCTAssertTrue(credentialed.requests.isEmpty)
    }

    func testValidStructuredJSONIsReturnedAndMalformedJSONIsRepairedOnce() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.queue(inklingGenerate, [
            inklingOllamaAnswer("this is not json"),
            inklingOllamaAnswer(inklingBriefingJSON)
        ])
        let adapter = makeAdapter(transport: transport)

        let generation = await adapter.generateStructuredJSON(
            prompt: "summarize",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )

        XCTAssertTrue(generation.ok)
        XCTAssertEqual(generation.attempts, 2)
        XCTAssertEqual(generation.value?.objectValue?["headline"]?.stringValue, "Local headline")
        XCTAssertEqual(transport.count(inklingGenerate), 2)
        let prompts = transport.bodies(for: inklingGenerate)
        XCTAssertTrue(prompts.first?.contains("REJECTED") == false)
        XCTAssertTrue(prompts.last?.contains("YOUR PREVIOUS ANSWER WAS REJECTED") == true,
                      "the second attempt must carry the repair instruction")
    }

    func testWrongTypedJSONIsRepairedOnceThenSucceeds() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.queue(inklingGenerate, [
            inklingOllamaAnswer(inklingInnerJSON([
                "headline": 7,
                "summary": "typed wrongly",
                "priorities": []
            ])),
            inklingOllamaAnswer(inklingBriefingJSON)
        ])
        let adapter = makeAdapter(transport: transport)

        let generation = await adapter.generateStructuredJSON(
            prompt: "summarize",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )

        XCTAssertTrue(generation.ok)
        XCTAssertEqual(generation.attempts, 2)
        XCTAssertEqual(transport.count(inklingGenerate), 2)
    }

    func testTwoMalformedAnswersDegradeAfterTwoAttempts() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.queue(inklingGenerate, [
            inklingOllamaAnswer("not json"),
            inklingOllamaAnswer("still not json")
        ])
        let adapter = makeAdapter(transport: transport)

        let generation = await adapter.generateStructuredJSON(
            prompt: "summarize",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )

        XCTAssertFalse(generation.ok)
        XCTAssertEqual(generation.attempts, 2)
        XCTAssertFalse(generation.degradedReason.isEmpty)
        let card = await adapter.card(now: inklingNow)
        XCTAssertEqual(card.degradedRuns, 1)
        XCTAssertEqual(card.jsonRuns, 0)
    }

    func testTransportFailureIsNotRetried() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.fail(inklingGenerate)
        let adapter = makeAdapter(transport: transport)

        let generation = await adapter.generateStructuredJSON(
            prompt: "summarize",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )

        XCTAssertFalse(generation.ok)
        XCTAssertEqual(generation.attempts, 1)
        XCTAssertEqual(transport.count(inklingGenerate), 1, "an unreachable runtime is not retried in the same tick")
    }

    func testMLXRuntimeIsUsedWhenOnlyItsLoopbackEndpointIsValid() async {
        let transport = InklingFakeTransport()
        transport.fallback(inklingMLXModels, inklingMLXList(["inkling-2-mini"]))
        transport.fallback(inklingMLXChat, inklingMLXAnswer(inklingBriefingJSON))
        let adapter = makeAdapter(
            config: InklingConfig(
                ollamaEndpoint: "http://198.51.100.7:11434",
                mlxEndpoint: "http://127.0.0.1:8080"
            ),
            transport: transport
        )

        let card = await adapter.probe(now: inklingNow)
        XCTAssertEqual(card.state, .ready)
        XCTAssertEqual(card.runtime, "mlx")

        let generation = await adapter.generateStructuredJSON(
            prompt: "summarize",
            schema: Inkling2MiniAdapter.briefingSchema,
            now: inklingNow
        )
        XCTAssertTrue(generation.ok)
        XCTAssertEqual(generation.runtime, "mlx")
        XCTAssertEqual(transport.count(inklingGenerate), 0)
        XCTAssertEqual(transport.count(inklingOllamaTags), 0)
        XCTAssertTrue(inklingLoopbackOnly(transport.requests))
    }

    func testMediaExtractionStaysOnLoopbackAndTheAuditCarriesOnlyTheDigest() async throws {
        let root = inklingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bill = root.appendingPathComponent("november-bill.png")
        try inklingWritePNG(bill)

        let store = AssistantAuditStore(path: root.appendingPathComponent("ledger/assistant.sqlite3").path)
        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.queue(inklingGenerate, [inklingOllamaAnswer(inklingMediaJSON)])
        let adapter = makeAdapter(
            config: InklingConfig(ticketPaths: [bill.path]),
            roots: [root.path],
            transport: transport,
            store: store
        )

        let analysis = await adapter.analyzeLocalMedia(path: bill.path, now: inklingNow)

        XCTAssertTrue(analysis.ok)
        XCTAssertEqual(analysis.extraction?.merchant, "Grid & Gas")
        XCTAssertEqual(analysis.extraction?.amount, "128.00")
        XCTAssertEqual(analysis.extraction?.dueDate, "2026-12-05")
        XCTAssertEqual(analysis.mimeType, "image/png")
        XCTAssertEqual(transport.count(inklingGenerate), 1)
        XCTAssertTrue(inklingLoopbackOnly(transport.requests))

        let body = try XCTUnwrap(transport.bodies(for: inklingGenerate).last)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let images = try XCTUnwrap(document["images"] as? [String])
        XCTAssertEqual(images, [inklingPNGBytes.base64EncodedString()],
                       "the model receives the image, and only over the validated endpoint")
        XCTAssertNotNil(document["format"], "structured output must ask the runtime for a schema")

        let rows = await store.recent(limit: 100).filter { $0.channel == "inkling" }
        XCTAssertTrue(rows.contains { $0.event == "media_ok" })
        let encoded = inklingPNGBytes.base64EncodedString()
        for row in rows {
            XCTAssertFalse(row.detail.contains(encoded), "the audit must never carry the image payload")
            XCTAssertFalse(row.detail.contains("Grid & Gas"), "the audit must never carry extracted private text")
            XCTAssertFalse(row.detail.contains("Electricity bill"), "the audit must never carry extracted private text")
        }
        let mediaRow = try XCTUnwrap(rows.first { $0.event == "media_ok" })
        XCTAssertTrue(mediaRow.detail.contains("sha256"))
        XCTAssertTrue(mediaRow.detail.contains(String(analysis.digest.prefix(12))))
    }

    func testMediaRefusesOutsideTraversalSymlinkOversizeAndUnsupportedFiles() async throws {
        let root = inklingTemporaryDirectory()
        let outsideRoot = inklingTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let inside = root.appendingPathComponent("inside.png")
        let outside = outsideRoot.appendingPathComponent("outside.png")
        try inklingWritePNG(inside)
        try inklingWritePNG(outside)
        let symlink = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let traversal = URL(fileURLWithPath: root.path + "/../outside-\(UUID().uuidString).png")
        try inklingPNGBytes.write(to: traversal)
        let oversize = root.appendingPathComponent("huge.png")
        var huge = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        huge.append(Data(count: InklingMediaScope.maximumSourceBytes))
        try huge.write(to: oversize)
        let plain = root.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: plain)

        let transport = InklingFakeTransport()
        let adapter = makeAdapter(roots: [root.path], transport: transport)

        let cases: [(path: String, label: String)] = [
            (outside.path, "outside the authorized root"),
            (traversal.path, "a traversal component"),
            (symlink.path, "a symlink escape"),
            (oversize.path, "an oversize file"),
            (plain.path, "an unsupported file")
        ]
        for item in cases {
            let analysis = await adapter.analyzeLocalMedia(path: item.path, now: inklingNow)
            XCTAssertFalse(analysis.ok, "\(item.label) must be refused")
            XCTAssertNil(analysis.extraction)
            XCTAssertTrue(transport.requests.isEmpty, "\(item.label) must be refused before any request")
        }

        let unrooted = makeAdapter(roots: [], transport: transport)
        let noRoot = await unrooted.analyzeLocalMedia(path: inside.path, now: inklingNow)
        XCTAssertFalse(noRoot.ok)
        XCTAssertTrue(transport.requests.isEmpty)

        let switchedOff = makeAdapter(
            config: InklingConfig(allowMultimodal: false),
            roots: [root.path],
            transport: transport
        )
        let disabled = await switchedOff.analyzeLocalMedia(path: inside.path, now: inklingNow)
        XCTAssertFalse(disabled.ok)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPDFIsRasterisedToAPNGPageBeforeTheLoopbackCall() async throws {
        let root = inklingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = try XCTUnwrap(inklingMakePDF())
        let pdfURL = root.appendingPathComponent("statement.pdf")
        try pdf.write(to: pdfURL)

        let loaded = InklingMediaScope(directoryPaths: [root.path]).load(pdfURL.path)
        let file: InklingMediaFile
        switch loaded {
        case .success(let value): file = value
        case .failure(let refusal): return XCTFail("PDF was refused: \(refusal.rawValue)")
        }
        XCTAssertEqual(file.mimeType, "image/png")
        XCTAssertEqual(file.bytes, pdf.count)
        XCTAssertEqual(Array(file.payload.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let transport = InklingFakeTransport()
        transport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        transport.queue(inklingGenerate, [inklingOllamaAnswer(inklingMediaJSON)])
        let adapter = makeAdapter(roots: [root.path], transport: transport)

        let analysis = await adapter.analyzeLocalMedia(path: pdfURL.path, now: inklingNow)
        XCTAssertTrue(analysis.ok)
        XCTAssertEqual(analysis.mimeType, "image/png")
        XCTAssertEqual(analysis.bytes, pdf.count)

        let body = try XCTUnwrap(transport.bodies(for: inklingGenerate).last)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let images = try XCTUnwrap(document["images"] as? [String])
        XCTAssertEqual(images, [file.payload.base64EncodedString()],
                       "the PDF bytes must never leave the Mac; the rasterised page does")
    }

    func testConfigNormalisationAndLegacyDecodeKeepTheLocalDefaults() throws {
        let wild = InklingConfig(
            ollamaEndpoint: "   ",
            mlxEndpoint: "",
            model: "gpt 4",
            ticketPaths: ["a", "b", "c", "d", "e"]
        ).normalised
        XCTAssertEqual(wild.ollamaEndpoint, InklingConfig.defaultOllamaEndpoint)
        XCTAssertEqual(wild.mlxEndpoint, InklingConfig.defaultMlxEndpoint)
        XCTAssertEqual(wild.model, InklingConfig.defaultModel)
        XCTAssertEqual(wild.ticketPaths.count, InklingConfig.maximumTicketPaths)

        let legacy = Data(#"{"enabled":true,"briefing":{"enabled":true}}"#.utf8)
        let config = try XCTUnwrap(NodeJSON.decode(AssistantConfig.self, from: legacy))
        XCTAssertTrue(config.inkling.enabled)
        XCTAssertEqual(config.inkling.model, InklingConfig.defaultModel)
        XCTAssertEqual(config.inkling.ollamaEndpoint, InklingConfig.defaultOllamaEndpoint)
        XCTAssertFalse(config.mail.enabled)
    }
}

// MARK: - Manager integration

private struct InklingManagerHarness {
    let root: URL
    let clock: ManualAssistantClock
    let store: AssistantAuditStore
    let mailTransport: InklingFakeMailTransport
    let modelTransport: InklingFakeTransport
    let recorder: InklingDeliveryRecorder
    let manager: PersonalAssistantManager
}

private func inklingMailConfig() -> MailAssistantConfig {
    MailAssistantConfig(
        enabled: true,
        imapHost: "imap.example.com",
        imapPort: 993,
        smtpHost: "smtp.example.com",
        smtpPort: 465,
        username: "owner@example.com",
        fromAddress: "owner@example.com"
    )
}

private func makeInklingManagerHarness(
    config: AssistantConfig,
    inbox: [MailFetchedMessage] = []
) async -> InklingManagerHarness {
    let root = inklingTemporaryDirectory()
    let clock = ManualAssistantClock(inklingNow)
    let store = AssistantAuditStore(path: root.appendingPathComponent("ledger/assistant.sqlite3").path)
    let gate = AssistantApprovalGate(
        signer: AssistantApprovalSigner(key: Data((0..<32).map { UInt8($0) })),
        clock: clock,
        audit: store
    )
    let secrets = VolatileSecretStore(secrets: [
        "assistant/mail/imap-password": "imap-secret",
        "assistant/mail/smtp-password": "smtp-secret"
    ])
    let mailTransport = InklingFakeMailTransport()
    mailTransport.setInbox(inbox)
    let scheduler = LocalTaskScheduler(config: config, clock: clock, store: store)
    let mail = MailAssistantBridge(
        config: config.mail,
        secrets: secrets,
        transport: mailTransport,
        gate: gate,
        store: store,
        clock: clock
    )
    let sentinel = HomeSentinelLoop(
        config: config,
        provider: InklingFakeSentinelProvider(),
        gate: gate,
        store: store,
        clock: clock
    )
    let modelTransport = InklingFakeTransport()
    let inkling = Inkling2MiniAdapter(
        config: config.inkling,
        scopeRoots: [],
        transport: modelTransport,
        store: store,
        clock: clock
    )
    let recorder = InklingDeliveryRecorder()
    let manager = PersonalAssistantManager(
        config: config,
        privacy: PrivacyBridgeConfig.disabled,
        hub: HubConfig.disabled,
        godsEyeEnabled: false,
        secrets: secrets,
        gate: gate,
        store: store,
        scheduler: scheduler,
        mail: mail,
        sentinel: sentinel,
        inkling: inkling,
        clock: clock
    ) { result in
        await recorder.deliver(result)
    }
    return InklingManagerHarness(
        root: root,
        clock: clock,
        store: store,
        mailTransport: mailTransport,
        modelTransport: modelTransport,
        recorder: recorder,
        manager: manager
    )
}

private func inklingRuleNotificationMessage() -> MailFetchedMessage {
    MailFetchedMessage(
        id: "m1",
        subject: "Team lunch",
        from: "Sender <sender@example.com>",
        receivedAt: inklingNow.addingTimeInterval(-300),
        body: "Thursday works for me. The usual place is fine."
    )
}

final class InklingManagerIntegrationTests: XCTestCase {
    func testInklingProposalStaysInertUntilTheConsoleMintsAReceipt() async throws {
        let config = AssistantConfig(
            enabled: true,
            mail: inklingMailConfig(),
            inkling: InklingConfig()
        )
        let harness = await makeInklingManagerHarness(
            config: config,
            inbox: [inklingRuleNotificationMessage()]
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.modelTransport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        harness.modelTransport.queue(inklingGenerate, [
            inklingOllamaAnswer(inklingInnerJSON([
                "messages": [["id": "m1", "category": "needs_reply", "amount": "", "deadline": "2026-12-01"]]
            ]))
        ])

        let report = await harness.manager.refreshMail(now: inklingNow)
        XCTAssertTrue(report.contains("草稿提案 1"), "the model's hint must produce a draft: \(report)")

        let pending = await harness.manager.pending(now: inklingNow)
        XCTAssertEqual(pending.count, 1)
        let proposal = try XCTUnwrap(pending.first)
        XCTAssertEqual(proposal.kind, .mailSend)
        XCTAssertEqual(proposal.target, "sender@example.com")
        XCTAssertTrue(harness.mailTransport.sent.isEmpty, "a proposal is not a send")

        let forged = await harness.manager.decide(
            proposalID: proposal.id,
            verb: "approve",
            receipt: "forged-receipt",
            now: inklingNow
        )
        XCTAssertFalse(forged.ok)
        XCTAssertTrue(harness.mailTransport.sent.isEmpty, "an invalid receipt must not execute a write")

        let approved = await harness.manager.consoleDecide(
            proposalID: proposal.id,
            verb: "approve",
            now: inklingNow
        )
        XCTAssertTrue(approved.ok)
        XCTAssertEqual(harness.mailTransport.sent.count, 1)
        XCTAssertEqual(harness.mailTransport.sent.first?.to, "sender@example.com")

        let replay = await harness.manager.consoleDecide(
            proposalID: proposal.id,
            verb: "approve",
            now: inklingNow
        )
        XCTAssertFalse(replay.ok)
        XCTAssertEqual(harness.mailTransport.sent.count, 1, "the receipt is single-use")
    }

    func testBriefingUsesTheLocalModelAndFallsBackToFactsWithoutIt() async throws {
        let readyConfig = AssistantConfig(
            enabled: true,
            briefing: AssistantBriefingConfig(enabled: true),
            inkling: InklingConfig()
        )
        let ready = await makeInklingManagerHarness(config: readyConfig)
        defer { try? FileManager.default.removeItem(at: ready.root) }
        ready.modelTransport.fallback(inklingOllamaTags, inklingTags(["inkling-2-mini"]))
        ready.modelTransport.queue(inklingGenerate, [inklingOllamaAnswer(inklingBriefingJSON)])

        _ = await ready.manager.runBriefing(now: inklingNow)
        let readyResults = await ready.recorder.all()
        let synthesized = try XCTUnwrap(readyResults.last)
        XCTAssertTrue(synthesized.body.contains("【Local headline】"))
        XCTAssertTrue(synthesized.body.contains("————"))
        XCTAssertEqual(synthesized.metrics["inkling"], .bool(true))
        XCTAssertEqual(synthesized.metrics["inkling_runtime"], .string("ollama"))

        let degradedConfig = AssistantConfig(
            enabled: true,
            briefing: AssistantBriefingConfig(enabled: true),
            inkling: InklingConfig()
        )
        let degraded = await makeInklingManagerHarness(config: degradedConfig)
        defer { try? FileManager.default.removeItem(at: degraded.root) }
        degraded.modelTransport.setFailEverything(true)

        _ = await degraded.manager.runBriefing(now: inklingNow)
        let degradedResults = await degraded.recorder.all()
        let fallback = try XCTUnwrap(degradedResults.last)
        XCTAssertTrue(fallback.body.contains("邮件：未启用"))
        XCTAssertTrue(fallback.body.contains("设备巡检：未启用"))
        XCTAssertFalse(fallback.body.contains("————"), "a missing runtime must change nothing about the briefing")
        XCTAssertEqual(fallback.metrics["inkling"], .bool(false))
        let snapshot = await degraded.manager.snapshot(now: inklingNow)
        XCTAssertEqual(snapshot.inkling.state, .runtimeMissing)
    }

    func testWithoutAnAdapterTheAssistantKeepsItsOldBehaviour() async throws {
        let config = AssistantConfig(
            enabled: true,
            briefing: AssistantBriefingConfig(enabled: true)
        )
        let root = inklingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualAssistantClock(inklingNow)
        let store = AssistantAuditStore(path: root.appendingPathComponent("ledger/assistant.sqlite3").path)
        let gate = AssistantApprovalGate(
            signer: AssistantApprovalSigner(key: Data((0..<32).map { UInt8($0) })),
            clock: clock,
            audit: store
        )
        let mail = MailAssistantBridge(
            config: config.mail,
            secrets: VolatileSecretStore(),
            transport: InklingFakeMailTransport(),
            gate: gate,
            store: store,
            clock: clock
        )
        let sentinel = HomeSentinelLoop(
            config: config,
            provider: InklingFakeSentinelProvider(),
            gate: gate,
            store: store,
            clock: clock
        )
        let recorder = InklingDeliveryRecorder()
        let manager = PersonalAssistantManager(
            config: config,
            privacy: PrivacyBridgeConfig.disabled,
            hub: HubConfig.disabled,
            godsEyeEnabled: false,
            secrets: VolatileSecretStore(),
            gate: gate,
            store: store,
            scheduler: LocalTaskScheduler(config: config, clock: clock, store: store),
            mail: mail,
            sentinel: sentinel,
            clock: clock
        ) { result in
            await recorder.deliver(result)
        }

        _ = await manager.runBriefing(now: inklingNow)
        let results = await recorder.all()
        let result = try XCTUnwrap(results.last)
        XCTAssertFalse(result.body.contains("————"))
        XCTAssertEqual(result.metrics["inkling"], .bool(false))
        let snapshot = await manager.snapshot(now: inklingNow)
        XCTAssertEqual(snapshot.inkling.state, .unknown)
        XCTAssertTrue(snapshot.inkling.enabled, "the preference is on, but no adapter exists to probe")
    }

    func testConsoleRendersTheModelCardAndItsProbeVerb() {
        let page = WEBConsoleHTML.document
        XCTAssertTrue(page.contains("data-i18n=\"asInklingTitle\""))
        XCTAssertTrue(page.contains("PPX.asRun('inklingProbe')"))
        XCTAssertTrue(page.contains("renderAssistantInkling"))
        XCTAssertTrue(page.contains("asInklingMultimodal"))
        XCTAssertTrue(page.contains("asInklingJSON"))
        XCTAssertTrue(page.contains("asInklingPull"))
    }
}
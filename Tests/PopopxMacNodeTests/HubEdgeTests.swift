//
//  HubEdgeTests.swift
//  The hub layer's two iron rules.
//
//  Four groups, in the order they are dangerous:
//
//  * A — `EdgeBoundary`. The private-network gate is the only thing standing
//    between this node and somebody else's server, so it is tested as a
//    decision made on the operator's literal: no DNS, no config, no convention.
//    A public address, a shorthand `127.8`, a trailing-dot FQDN or a userinfo
//    smuggling trick has to be refused *and named*, because an audit row that
//    says "denied" without saying what is a denial nobody can check.
//  * B — the MQTT v3.1.1 codec. Bytes go on the wire to a broker on the LAN.
//    A wrong flag nibble or a length prefix counted in characters instead of
//    bytes is a broker that silently misroutes another device's topic, and a
//    decoder that trusts a hostile frame is a crash inside the node.
//  * C — the smart-home gate. An allow-listed entity is still a door lock: the
//    proposal, not the bridge, is the execution boundary, so every write must
//    stop at a receipt the owner signed, and a switch flipped off must refuse
//    the same call it accepted three times before.
//  * D — CalDAV. The only place this node reads text it will never show. After
//    `DTSTART`/`DTEND` are read, `SUMMARY`, `DESCRIPTION`, `LOCATION` and
//    `ATTENDEE` are dropped in memory, so the assertions here are leak
//    assertions: the canary must be absent from the encoder, from the cards,
//    from the tool response and from the type that crosses the boundary.
//
//  Nothing here opens a socket, spawns a process, touches EventKit or the
//  Keychain, or writes outside a private temporary directory. `HubByteStream`
//  and `CalDavTransport` are the seams the production code already offers; the
//  scripted fakes below are the only "peers" these tests talk to.
//

import XCTest
@testable import PopopxMacNode

// MARK: - Canaries

/// Every one of these must be absent from anything the node returns.
private let hubCanarySummary = "项目代号 Aurora 融资评审"
private let hubCanaryNote = "预算见附件，联系 13800138000"
private let hubCanaryPlace = "某某咖啡厅"
private let hubCanaryAttendee = "mailto:boss@example.com"
private let hubCanaryOrganizer = "mailto:ceo@example.com"
private let hubCanaryUID = "aurora-42@popopx.example"

private let hubCalendarCanaries = [
    hubCanarySummary, "Aurora", hubCanaryNote, "13800138000", hubCanaryPlace,
    hubCanaryAttendee, hubCanaryOrganizer, "boss@example.com", "mailto:", hubCanaryUID,
    // The attendee's display name, which lives in a `CN` *parameter* rather than the
    // value. A redactor that keeps the property name and throws away only the value
    // would still hand back who was invited.
    "Team Lead"
]

/// The iCalendar property names, for the types that must not even *have* a field
/// for them. `PrivacyToolEngine`'s prose does name these properties on purpose,
/// so this list is only applied to encoded values, never to a human sentence.
private let hubCalendarPropertyNames = ["SUMMARY", "DESCRIPTION", "LOCATION", "ATTENDEE", "ORGANIZER", "UID", "CATEGORIES"]

private let hubUTCZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
private let hubShanghaiZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

// MARK: - Small pure helpers

private func hubDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, in zone: TimeZone) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard let date = calendar.date(from: components) else {
        XCTFail("the fixture instant \(year)-\(month)-\(day) \(hour):\(minute) is not buildable in \(zone.identifier)")
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

private func hubUTC(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    hubDate(year, month, day, hour, minute, second, in: hubUTCZone)
}

private func hubLocal(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    hubDate(year, month, day, hour, minute, 0, in: .autoupdatingCurrent)
}

/// §2.2.3 again, independently of the codec under test.
private func hubRemainingLengthBytes(_ length: Int) -> [UInt8] {
    var value = length
    var out: [UInt8] = []
    repeat {
        var byte = UInt8(value % 128)
        value /= 128
        if value > 0 { byte |= 0x80 }
        out.append(byte)
    } while value > 0
    return out
}

private func hubStringField(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
}

private func hubU16(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func hubHex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Asserts that a blob carries none of the calendar canaries.
private func hubAssertNoCalendarText(_ text: String, _ surface: String, file: StaticString = #filePath, line: UInt = #line) {
    for canary in hubCalendarCanaries {
        XCTAssertFalse(text.contains(canary), "\(surface) contains calendar content (\(canary))", file: file, line: line)
    }
}

/// Asserts an XML string is a document, not just a string that looks like one.
private func hubAssertWellFormedXML(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    let parser = XMLParser(data: Data(text.utf8))
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    XCTAssertTrue(parser.parse(), "\(what) is not well-formed XML: \(parser.parserError.map { String(describing: $0) } ?? "no error")", file: file, line: line)
}

// MARK: - Scripted byte stream (the MQTT peer, without a socket)

/// Answers from a script. `nil` means "the broker hung up", so an idle script
/// returns an empty chunk instead and lets the session's own deadline end the read.
private final class HubScriptedStream: HubByteStream, @unchecked Sendable {
    let endpoint: EdgeEndpoint
    private let lock = NSLock()
    private var inbound: [Data]
    private var cursor = 0
    private var writes: [Data] = []
    private var starts = 0
    private var finishes = 0

    init(endpoint: EdgeEndpoint, inbound: [Data] = []) {
        self.endpoint = endpoint
        self.inbound = inbound
    }

    // `NSLock` is not usable from an async context, so every mutation happens in a
    // plain synchronous helper and the protocol methods just call them.
    private func noteStart() {
        lock.lock(); starts += 1; lock.unlock()
    }
    private func noteFinish() {
        lock.lock(); finishes += 1; lock.unlock()
    }
    private func noteSend(_ data: Data) {
        lock.lock(); writes.append(data); lock.unlock()
    }
    private func takeNext() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard cursor < inbound.count else { return nil }
        defer { cursor += 1 }
        return inbound[cursor]
    }

    func start(timeout: TimeInterval) async throws { noteStart() }

    func receiveChunk(timeout: TimeInterval) async throws -> Data? {
        guard let next = takeNext() else {
            // Out of script. An empty chunk means "nothing yet"; `nil` would mean
            // "the broker hung up", which is a different test.
            try? await Task.sleep(nanoseconds: 2_000_000)
            return Data()
        }
        return next
    }

    func send(_ data: Data) async throws { noteSend(data) }
    func finish() async { noteFinish() }

    var framesSent: [Data] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }
    var finishCount: Int {
        lock.lock(); defer { lock.unlock() }
        return finishes
    }
}

private func hubConnAck(code: UInt8 = 0, sessionPresent: Bool = false) -> Data {
    Data([0x20, 0x02, sessionPresent ? 0x01 : 0x00, code])
}

private func hubPubAck(packetId: Int) -> Data {
    Data([0x40, 0x02] + hubU16(packetId))
}

private func hubSubAck(packetId: Int, code: UInt8 = 1) -> Data {
    Data([0x90, 0x03] + hubU16(packetId) + [code])
}

// MARK: - Ledger fixtures

/// Records what the approval gate let through. A second `PrivacyExecutorHub`
/// would have reached Home Assistant over the network, which is exactly what a
/// test may not do.
private final class HubRecordingExecutor: ProposalExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PrivacyProposal] = []

    private func record(_ proposal: PrivacyProposal) {
        lock.lock(); recorded.append(proposal); lock.unlock()
    }

    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        record(proposal)
        return PrivacyExecution(ok: true, identifier: proposal.id, message: "recorded by the test executor")
    }

    var runs: [PrivacyProposal] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

/// Stands in for the EventKit gateway. Nothing in these four groups may reach a
/// real event store, and a test host cannot grant one anyway.
private final class HubFakeGateway: CalendarGateway, @unchecked Sendable {
    func authorizationState() async -> String { "notDetermined" }
    func requestFullAccess() async -> String { "notDetermined" }
    func availability(_ probe: CalendarProbe) async -> AvailabilityOutcome { AvailabilityOutcome() }
    func commit(_ draft: CalendarEventDraft) async -> CalendarCommitOutcome { .refused("not this test") }
    func reschedule(identifier: String, start: Date, end: Date) async -> CalendarCommitOutcome { .refused("not this test") }
    func remove(identifier: String) async -> CalendarCommitOutcome { .refused("not this test") }
    func exists(identifier: String) async -> Bool { false }
}

/// A broker factory that never opens a socket: every stream the bridge asks for is
/// scripted, and the count is the evidence that a receipt — not a config — is what
/// makes the node reach for a connection.
private final class HubBrokerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [HubScriptedStream] = []
    private let inbound: [Data]

    init(inbound: [Data] = []) {
        self.inbound = inbound
    }

    func make(endpoint: EdgeEndpoint, options: MQTTConnectOptions) -> HubByteStream? {
        // The allow-list, not "not public": an unresolved or ambiguous name is as
        // undialable as a public address, and `MQTTByteStream` refuses it the same way.
        precondition(endpoint.hostClass == .loopback || endpoint.hostClass == .privateNetwork,
                     "a scripted broker was asked for a target outside the boundary: \(endpoint.host) (\(endpoint.hostClass.rawValue))")
        let stream = HubScriptedStream(endpoint: endpoint, inbound: inbound)
        lock.lock(); created.append(stream); lock.unlock()
        return stream
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return created.count
    }
    var streams: [HubScriptedStream] {
        lock.lock(); defer { lock.unlock() }
        return created
    }
}

/// A credential store that always says no, so the "the Keychain refused" branch is a
/// tested path rather than a comment.
private struct HubRefusingSecrets: HubSecretStoring {
    func store(_ value: String, for reference: String) -> Bool { false }
    func secret(for reference: String) -> String? { nil }
    func delete(reference: String) -> Bool { false }
    var isPersistent: Bool { false }
    var backingName: String { "refusing-test-store" }
}

/// One wired-up node, as the smart-home group needs it.
private struct HubHomeRig {
    let engine: PrivacyToolEngine
    let bridge: SmartHomeBridge
    let ledger: PrivacyProposalLedger
    let secrets: HubSecretStoring
    let factory: HubBrokerFactory
    let recorder: HubRecordingExecutor?
}

/// A Long-Lived Token lookalike. If this string appears anywhere in a response, an
/// audit row or a card, the credential has left the vault.
private let hubTokenCanary = "ppx-token-DO-NOT-LEAK-0f4e9c2b7a"

// MARK: - CalDAV fixtures

/// A peer that answers from a script and records the requests it was given.
private final class HubCalDavStub: CalDavTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CalDavRequest] = []
    private var replies: [CalDavResponse]
    var forcedError: Error?

    init(replies: [CalDavResponse] = []) {
        self.replies = replies
    }

    private func answer(for request: CalDavRequest) -> (reply: CalDavResponse, failure: Error?) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        let reply: CalDavResponse
        if replies.count > 1 {
            reply = replies.removeFirst()
        } else if let first = replies.first {
            reply = first
        } else {
            reply = CalDavResponse(statusCode: 207, headers: ["Content-Type": "application/xml"])
        }
        return (reply, forcedError)
    }

    func perform(_ request: CalDavRequest) async throws -> CalDavResponse {
        let outcome = answer(for: request)
        if let failure = outcome.failure { throw failure }
        return outcome.reply
    }

    var requests: [CalDavRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

/// The `.ics` inside a `calendar-data` element is character data, so the only
/// things needing a rewrite are the XML metacharacters.
private func hubEscapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func hubMultistatus(bodies: [String], root: String = "multistatus") -> String {
    var xml = """
    <?xml version="1.0" encoding="utf-8"?>\
    <d:\(root) xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:i="http://apple.com/ns/ical/">
    """
    for body in bodies { xml += body }
    xml += "</d:\(root)>"
    return xml
}

private func hubDataResponse(href: String, document: String, etag: String = "\"v1\"") -> String {
    """
    <d:response><d:href>\(href)</d:href><d:propstat><d:prop>\
    <d:getetag>\(etag)</d:getetag>\
    <c:calendar-data>\(hubEscapeXML(document))</c:calendar-data>\
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    """
}

private func hubXMLResponse(statusCode: Int, bodies: [String], root: String = "multistatus") -> CalDavResponse {
    CalDavResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "text/xml; charset=utf-8"],
        body: Data(hubMultistatus(bodies: bodies, root: root).utf8)
    )
}

private func hubCalendarResponse(document: String) -> CalDavResponse {
    hubXMLResponse(statusCode: 207, bodies: [hubDataResponse(href: "/calendars/ada/home/", document: document)])
}

// MARK: - iCalendar fixtures

private func hubEvent(_ body: String) -> String {
    """
    BEGIN:VEVENT
    UID:\(hubCanaryUID)
    DTSTAMP:20260101T000000Z
    SUMMARY:\(hubCanarySummary)
    DESCRIPTION:\(hubCanaryNote)
    LOCATION:\(hubCanaryPlace)
    ORGANIZER:\(hubCanaryOrganizer)
    ATTENDEE;CN="Ada: Team Lead";ROLE=REQ-PARTICIPANT:\(hubCanaryAttendee)
    CATEGORIES:work,confidential
    \(body)
    END:VEVENT
    """
}

/// A document that is as full of other people's business as a real one is.
private func hubCalendar(_ events: [String]) -> String {
    var text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//popopx//hub-edge-test//EN\r\n"
    text += "BEGIN:VTIMEZONE\r\nTZID:Asia/Shanghai\r\nBEGIN:STANDARD\r\n"
    text += "DTSTART:19700101T000000\r\nTZOFFSETFROM:+0800\r\nTZOFFSETTO:+0800\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
    for event in events {
        text += event.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }
    text += "END:VCALENDAR\r\n"
    return text
}

// MARK: - Scripted CalDAV peer

/// A `CalDavTransport` that answers from a queue and remembers what it was asked.
///
/// The production transport is `URLSession`; this is the seam `CalDavClient` already
/// exposes, and `exchange` re-checks its own bounds precisely because the seam is open —
/// a fake is allowed to hand this node a two-megabyte body on purpose.
private final class HubScriptedTransport: CalDavTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [CalDavResponse]
    private let fallback: CalDavResponse
    private var asked: [CalDavRequest] = []

    init(responses: [CalDavResponse], fallback: CalDavResponse = CalDavResponse(statusCode: 404)) {
        self.queue = responses
        self.fallback = fallback
    }

    var requests: [CalDavRequest] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    /// `NSLock` is not usable from an async context, so the whole exchange happens in a
    /// plain synchronous helper and `perform` only calls it.
    private func next(_ request: CalDavRequest) -> CalDavResponse {
        lock.lock(); defer { lock.unlock() }
        asked.append(request)
        return queue.isEmpty ? fallback : queue.removeFirst()
    }

    func perform(_ request: CalDavRequest) async throws -> CalDavResponse {
        next(request)
    }
}

// MARK: - Tests

final class HubEdgeTests: XCTestCase {

    // MARK: Fixtures

    /// Every file these tests write lives here, and nowhere else.
    private func hubScratch(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ppx-hub-edge-\(UUID().uuidString)-\(name)", isDirectory: true)
        XCTAssertFalse(root.path.contains("Application Support"), "a test scratch directory must not sit in the app's config dir: \(root.path)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A ledger bound to a temp file, with a test key and a recording executor.
    private func hubLedger(name: String, executor: ProposalExecutor) throws -> (PrivacyProposalLedger, PrivacyApprovalSigner, URL) {
        let folder = try hubScratch(name)
        let signer = PrivacyApprovalSigner(key: Data("hub-edge-signing-key-0123456789".utf8))
        let ledger = PrivacyProposalLedger(
            signer: signer,
            executor: executor,
            fileURL: folder.appendingPathComponent("ledger.jsonl"),
            loadFromDisk: false
        )
        return (ledger, signer, folder)
    }

    // MARK: A — EdgeBoundary, the private-network gate

    private func expectRefusal(
        url text: String,
        expected: EdgeBoundaryError,
        names value: String = "",
        policy: EdgeHostPolicy = .privateNetworkOnly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try EdgeBoundary.resolve(url: text, policy: policy),
            "\(text) must be refused under the \(policy.rawValue) policy"
        ) { error in
            XCTAssertEqual(error as? EdgeBoundaryError, expected, "wrong refusal reason for \(text): \(error)", file: file, line: line)
            guard !value.isEmpty else { return }
            XCTAssertTrue(
                String(describing: error).contains(value),
                "the refusal for \(text) must name the rejected value \(value), got: \(error)",
                file: file, line: line
            )
        }
        XCTAssertFalse(EdgeBoundary.isAllowed(text, policy: policy), "isAllowed must not admit \(text)", file: file, line: line)
    }

    private func expectHostRefusal(
        _ host: String,
        port: Int = 1883,
        expected: EdgeBoundaryError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try EdgeBoundary.resolve(host: host, port: port),
            "the bare host \(host) must be refused by resolve(host:port:)"
        ) { error in
            XCTAssertEqual(error as? EdgeBoundaryError, expected, "wrong refusal reason for \(host): \(error)", file: file, line: line)
            XCTAssertTrue(
                String(describing: error).contains(host),
                "the refusal for \(host) must name it, got: \(error)",
                file: file, line: line
            )
        }
    }

    func testPrivateNetworkPolicyAdmitsLoopbackLANAndMDNS() throws {
        let accepted: [(String, String, Int, EdgeHostClass, String)] = [
            ("http://127.0.0.1:8123", "127.0.0.1", 8123, .loopback, "http"),
            ("http://localhost:1883", "localhost", 1883, .loopback, "http"),
            ("http://homeassistant.local:8123", "homeassistant.local", 8123, .privateNetwork, "http"),
            ("https://homeassistant.local", "homeassistant.local", 443, .privateNetwork, "https"),
            ("http://nas.local", "nas.local", 80, .privateNetwork, "http")
        ]
        for (text, host, port, hostClass, scheme) in accepted {
            let endpoint = try EdgeBoundary.resolve(url: text, policy: .privateNetworkOnly)
            XCTAssertEqual(endpoint.host, host, "\(text) should keep the host it was given")
            XCTAssertEqual(endpoint.port, port, "\(text) should resolve the port it was given (or the scheme default)")
            XCTAssertEqual(endpoint.hostClass, hostClass, "\(text) is classified as \(endpoint.hostClass), not \(hostClass)")
            XCTAssertEqual(endpoint.scheme, scheme, "\(text) must keep its own scheme")
            XCTAssertEqual(
                EdgeBoundary.classification(of: host), endpoint.hostClass,
                "classification(of:) and resolve(url:) must not disagree about \(host)"
            )
        }

        // The RFC 1918 corners, as a bare host:port pair — the way an MQTT broker is configured.
        let literals: [(String, EdgeHostClass)] = [
            ("10.0.0.7", .privateNetwork),
            ("10.255.255.255", .privateNetwork),   // top of 10/8
            ("172.16.0.1", .privateNetwork),       // bottom of 172.16/12
            ("172.31.255.255", .privateNetwork),   // top of 172.16/12
            ("192.168.1.1", .privateNetwork),
            ("192.168.255.255", .privateNetwork),
            ("nas.local", .privateNetwork)
        ]
        for (host, hostClass) in literals {
            let endpoint = try EdgeBoundary.resolve(host: host, port: 1883)
            XCTAssertEqual(endpoint.hostClass, hostClass, "\(host) must classify as \(hostClass)")
            XCTAssertEqual(endpoint.scheme, "tcp", "a bare host is a socket target, not an http one")
            XCTAssertEqual(endpoint.origin, "tcp://\(host):1883", "\(host) must keep the port it was handed")
        }

        // Loopback beyond 127.0.0.1: the whole /8 is this Mac.
        XCTAssertEqual(EdgeBoundary.classification(of: "127.5.6.7"), .loopback, "127/8 is loopback, not just 127.0.0.1")
    }

    func testPublicAddressesAreRefusedAndNamed() throws {
        let publicAddresses = [
            "8.8.8.8", "1.1.1.1", "172.32.0.1", "192.167.99.1", "100.64.0.1", "255.255.255.255", "203.0.113.9"
        ]
        for host in publicAddresses {
            expectHostRefusal(host, expected: .publicAddress(host: host))
            expectRefusal(
                url: "https://\(host)/dav",
                expected: .publicAddress(host: host),
                names: host,
                file: #filePath, line: #line
            )
        }

        // 172.16/12 has exactly one edge to get wrong: 172.32 is not private.
        XCTAssertEqual(EdgeBoundary.classification(of: "172.31.255.255"), .privateNetwork, "172.31 is still inside 172.16/12")
        XCTAssertEqual(EdgeBoundary.classification(of: "172.32.0.1"), .publicAddress, "172.32 is outside 172.16/12")
        XCTAssertEqual(EdgeBoundary.classification(of: "172.15.255.255"), .publicAddress, "172.15 is outside 172.16/12")
        XCTAssertFalse(EdgeBoundary.isAllowed("http://172.32.0.1:8123", policy: .privateNetworkOnly), "the off-by-one edge must not be admitted")
    }

    func testNonCanonicalAndExternalNamesAreRefusedAsPublic() throws {
        // Shorthand forms `inet_aton` would happily expand into a public address.
        for shorthand in ["127.8", "2130706433", "0x7F000001", "017700000001", "192.168.010.001", "0x7f.1"] {
            XCTAssertEqual(
                EdgeBoundary.classification(of: shorthand), .unresolvedName,
                "\(shorthand) is not four plain decimal octets, so it must not be read as one"
            )
            expectHostRefusal(shorthand, expected: .hostOutsideMdns(shorthand))
        }

        // Anything the guard cannot place is denied as public, link-local included:
        // that is also what a captive portal answers from.
        expectHostRefusal("169.254.1.1", expected: .nonCanonicalHost("169.254.1.1"))
        expectHostRefusal("fe80::1", expected: .nonCanonicalHost("fe80::1"))
        expectHostRefusal("fe80::1%en0", expected: .nonCanonicalHost("fe80::1%en0"))
        expectHostRefusal("0.0.0.0", expected: .nonCanonicalHost("0.0.0.0"))
        expectHostRefusal("::", expected: .nonCanonicalHost("::"))

        // A name that needs DNS is outside the guarantee, dotless single label included.
        for name in ["cloud.example.com", "mqtt.cloud.net", "broker.hivemq.com", "nas", "localhost.evil"] {
            XCTAssertEqual(EdgeBoundary.classification(of: name), .unresolvedName, "\(name) needs a resolver, so it is not an address")
            expectHostRefusal(name, expected: .hostOutsideMdns(name))
        }

        // A trailing dot is the FQDN spelling of the same name; it must not slip past
        // the `.local` suffix test.
        expectHostRefusal("evil.com.", expected: .hostOutsideMdns("evil.com."))
        expectRefusal(url: "http://homeassistant.local.evil.com:8123", expected: .hostOutsideMdns("homeassistant.local.evil.com"), names: "evil.com")
        // An external domain in a URL is the same decision as the bare name above: it
        // needs a resolver, and the node does not resolve, so it is refused as an
        // out-of-scope name rather than classified as an address. Asserting
        // `.publicAddress` here would be asserting a DNS lookup this node never does.
        expectRefusal(url: "https://nextcloud.com/remote.php/dav", expected: .hostOutsideMdns("nextcloud.com"), names: "nextcloud.com")
    }

    func testCredentialsInURLNeverBecomeAnEndpoint() throws {
        // `http://127.0.0.1@relay.example.com` connects to relay.example.com. Admitting
        // userinfo at all would make the host check decorative.
        expectRefusal(url: "http://127.0.0.1@relay.example.com", expected: .credentialsInURL)
        expectRefusal(url: "http://user:pass@192.168.1.9:8123", expected: .credentialsInURL)
        expectRefusal(url: "https://ada:secret@homeassistant.local", expected: .credentialsInURL)

        // And the decision really is a refusal, not an endpoint aimed somewhere else.
        let smuggled = try? EdgeBoundary.resolve(url: "http://127.0.0.1@relay.example.com", policy: .privateNetworkOnly)
        XCTAssertNil(smuggled, "a userinfo URL must never produce an endpoint at all")
        if let endpoint = smuggled {
            XCTAssertNotEqual(endpoint.host, "relay.example.com", "the userinfo trick must not retarget the connection")
        }
        for text in ["http://127.0.0.1@relay.example.com", "https://ada:secret@homeassistant.local"] {
            XCTAssertFalse(EdgeBoundary.isAllowed(text, policy: .privateNetworkOnly), "\(text) must not be admitted from a saved document")
        }
    }

    func testSchemelessAndUnsupportedSchemeTargetsAreRefused() throws {
        // `URLComponents("127.0.0.1:1883")` parses the host as a scheme on some
        // Foundation builds, which is why the "://" is required by hand.
        expectRefusal(url: "127.0.0.1:1883", expected: .unsupportedScheme("127.0.0.1:1883"), names: "127.0.0.1:1883")
        expectRefusal(url: "ftp://192.168.1.9:21", expected: .unsupportedScheme("ftp"), names: "ftp")
        expectRefusal(url: "ws://localhost:1883", expected: .unsupportedScheme("ws"), names: "ws")
        expectRefusal(url: "mqtt://10.0.0.7:1883", expected: .unsupportedScheme("mqtt"), names: "mqtt")
        expectRefusal(url: "file://192.168.1.9/etc/passwd", expected: .unsupportedScheme("file"), names: "file")
        expectRefusal(url: "", expected: .missingHost)
        expectRefusal(url: "   ", expected: .missingHost)
        expectRefusal(url: "http://", expected: .missingHost)

        // The bare-host form is the one an MQTT broker uses, so it must reject an empty one.
        XCTAssertThrowsError(try EdgeBoundary.resolve(host: "  ", port: 1883), "a blank broker host must not become an endpoint") { error in
            XCTAssertEqual(error as? EdgeBoundaryError, .missingHost, "expected missingHost, got \(error)")
        }
    }

    func testPortEdgesAndDefaultPorts() throws {
        for port in [0, -1, 65_536, 100_000] {
            XCTAssertThrowsError(try EdgeBoundary.resolve(host: "127.0.0.1", port: port), "port \(port) is not a socket address") { error in
                XCTAssertEqual(error as? EdgeBoundaryError, .portOutOfRange(port), "expected portOutOfRange(\(port)), got \(error)")
                XCTAssertTrue(String(describing: error).contains(String(port)), "the refusal must name the port, got \(error)")
            }
            XCTAssertThrowsError(
                try EdgeBoundary.resolve(url: "http://192.168.1.9:\(max(port, 0))", policy: .privateNetworkOnly),
                "the URL form must refuse \(port) too"
            )
        }
        let top = try EdgeBoundary.resolve(host: "192.168.1.9", port: 65_535)
        XCTAssertEqual(top.port, 65_535, "65535 is the last legal port")

        // No port written at all means the scheme's default, never an assumed 1883.
        XCTAssertEqual(try EdgeBoundary.resolve(url: "https://homeassistant.local", policy: .privateNetworkOnly).port, 443, "https with no port is 443")
        XCTAssertEqual(try EdgeBoundary.resolve(url: "http://homeassistant.local", policy: .privateNetworkOnly).port, 80, "http with no port is 80")
        XCTAssertEqual(try EdgeBoundary.resolve(url: "http://127.0.0.1:8123/api", policy: .privateNetworkOnly).port, 8123, "an explicit port wins over the default")
    }

    func testLoopbackOnlyPolicyRefusesTheLan() throws {
        // The MCP bridge uses this policy: a stdio child is this machine, and an
        // http MCP server has to answer on loopback.
        let loopback = try EdgeBoundary.resolve(url: "http://127.0.0.1:11434", policy: .loopbackOnly)
        XCTAssertEqual(loopback.hostClass, .loopback, "loopback is admissible under loopbackOnly")
        XCTAssertEqual(try EdgeBoundary.resolve(url: "http://localhost:1883", policy: .loopbackOnly).host, "localhost", "localhost is loopback by name")

        expectRefusal(
            url: "http://192.168.1.20:11434",
            expected: .loopbackOnly(host: "192.168.1.20", classification: .privateNetwork),
            names: "192.168.1.20",
            policy: .loopbackOnly
        )
        expectRefusal(
            url: "http://homeassistant.local:8123",
            expected: .loopbackOnly(host: "homeassistant.local", classification: .privateNetwork),
            names: "homeassistant.local",
            policy: .loopbackOnly
        )
        expectRefusal(
            url: "http://8.8.8.8:8123",
            expected: .loopbackOnly(host: "8.8.8.8", classification: .publicAddress),
            names: "8.8.8.8",
            policy: .loopbackOnly
        )

        // Wired up, not just available: the http MCP entry refuses a LAN URL and
        // accepts the loopback one.
        let lanServer = MCPServerConfig(id: "lan", transport: .http, url: "http://192.168.1.20:8123")
        XCTAssertNotNil(lanServer.acceptance(inside: []), "an http MCP server on the LAN must be rejected by the loopback-only rule")
        let localServer = MCPServerConfig(id: "local", transport: .http, url: "http://127.0.0.1:8123")
        XCTAssertNil(localServer.acceptance(inside: []), "the same server on loopback is admissible")
    }

    func testClassificationTableIsExact() throws {
        let table: [(String, EdgeHostClass)] = [
            ("", .ambiguous),
            ("   ", .ambiguous),
            ("LOCALHOST", .loopback),
            ("localhost.", .loopback),
            ("127.1.2.3", .loopback),
            ("::1", .loopback),
            ("[::1]", .loopback),
            ("10.0.0.1 ", .privateNetwork),
            ("homeassistant.local.", .privateNetwork),
            ("fd12::1", .privateNetwork),
            ("fc00::1", .privateNetwork),
            ("::ffff:192.168.1.1", .privateNetwork),
            ("::ffff:8.8.8.8", .publicAddress),
            ("fe80::1", .linkLocal),
            ("ff02::2", .linkLocal),
            ("255.255.255.255", .publicAddress),
            ("1.1.1.1", .publicAddress),
            ("192.168.010.001", .unresolvedName),
            ("0.0.0.0", .ambiguous),
            ("::", .ambiguous),
            ("garbage:::x", .ambiguous),
            ("cloud.example.com", .unresolvedName)
        ]
        for (host, expected) in table {
            XCTAssertEqual(EdgeBoundary.classification(of: host), expected, "classification of \(String(describing: host)) is wrong")
        }

        // A v6 literal that needs an interface to mean anything is not a decision
        // this guard makes from a string.
        XCTAssertNil(EdgeBoundary.ipv6Bytes("fe80::1%en0"), "a zone id must not parse as an address")
        XCTAssertNotNil(EdgeBoundary.ipv6Bytes("::ffff:192.168.1.1"), "an IPv4-mapped literal does parse, and is then read as v4")
        XCTAssertNil(EdgeBoundary.ipv4Octets("192.168.010.001"), "a leading zero is octal to inet_aton, so it is not a decimal octet")
        XCTAssertNil(EdgeBoundary.ipv4Octets("300.1.1.1"), "an octet has to fit in a byte")
    }

    func testEndpointCarriesHostAndPortOnly() throws {
        let endpoint = try EdgeBoundary.resolve(url: "http://192.168.1.9:8123/some/path?token=abc#frag", policy: .privateNetworkOnly)
        XCTAssertEqual(endpoint.origin, "http://192.168.1.9:8123", "an origin is scheme+host+port; a path, query or fragment must not ride along")
        XCTAssertFalse(endpoint.origin.contains("token"), "a query string must not survive into the audit-visible origin")
        XCTAssertEqual(endpoint.literal, "192.168.1.9", "the operator's own spelling is kept for the audit row")

        let v6 = try EdgeBoundary.resolve(host: "::1", port: 1883)
        XCTAssertEqual(v6.host, "::1", "the brackets are stripped for classification and kept for the URL")
        XCTAssertEqual(v6.hostHeader, "[::1]", "a bare colon host has to be bracketed inside a URL")
        XCTAssertEqual(v6.origin, "tcp://[::1]:1883", "the origin must be a parseable socket address")

        // `::1` and `[::1]` are loopback: admitting them is required by the same rule
        // that admits 127.0.0.1, and refusing them would break a localhost broker. The
        // public v6 case is `::ffff:8.8.8.8`, and that one is refused (above).
        XCTAssertEqual(try EdgeBoundary.resolve(host: "::1", port: 1883).hostClass, .loopback, "IPv6 loopback is loopback")
    }

    func testSocketLayerReAssertsTheDecisionBeforeAnyConnection() throws {
        let loopback = try EdgeBoundary.resolve(host: "127.0.0.1", port: 1883)
        XCTAssertNil(MQTTByteStream.refusal(for: loopback), "a loopback broker is dialable")

        let publicHand = EdgeEndpoint(scheme: "tcp", host: "8.8.8.8", port: 1883, hostClass: .publicAddress, literal: "8.8.8.8")
        let linkLocal = EdgeEndpoint(scheme: "tcp", host: "fe80::1", port: 1883, hostClass: .linkLocal, literal: "fe80::1")
        let named = EdgeEndpoint(scheme: "tcp", host: "broker.hivemq.com", port: 1883, hostClass: .unresolvedName, literal: "broker.hivemq.com")
        let ambiguous = EdgeEndpoint(scheme: "tcp", host: "0.0.0.0", port: 1883, hostClass: .ambiguous, literal: "0.0.0.0")
        let httpScheme = EdgeEndpoint(scheme: "http", host: "127.0.0.1", port: 1883, hostClass: .loopback, literal: "127.0.0.1")
        let badPort = EdgeEndpoint(scheme: "tcp", host: "127.0.0.1", port: 0, hostClass: .loopback, literal: "127.0.0.1")
        for endpoint in [publicHand, linkLocal, named, ambiguous, httpScheme, badPort] {
            let refusal = MQTTByteStream.refusal(for: endpoint)
            XCTAssertNotNil(refusal, "the transport must refuse \(endpoint.origin) on its own, not only the config layer")
            // Constructing the stream is where an `NWConnection` would be built. The
            // guard runs first, so "no socket" is a fact about this call, not a hope.
            XCTAssertThrowsError(try MQTTByteStream(endpoint: endpoint), "no socket may be opened for \(endpoint.origin)") { error in
                XCTAssertTrue(error is HubLinkError, "expected a HubLinkError, got \(error)")
                XCTAssertTrue(String(describing: error).contains(endpoint.host) || String(describing: error).contains(endpoint.origin), "the refusal should say which target: \(error)")
            }
        }

        // The Home Assistant client repeats the decision at the request builder, so a
        // hand-built endpoint cannot reach it either — and the token is a header, never
        // part of the URL.
        XCTAssertThrowsError(
            try HomeAssistantClient.statesRequest(endpoint: publicHand, token: "long-lived-secret"),
            "an endpoint aimed at a public address must not produce a request"
        )
        let haEndpoint = try EdgeBoundary.resolve(url: "https://192.168.1.20:8123", policy: .privateNetworkOnly)
        let request = try HomeAssistantClient.serviceRequest(
            endpoint: haEndpoint, token: "long-lived-secret", domain: "lock", service: "unlock", data: ["entity_id": .string("lock.front_door")]
        )
        XCTAssertEqual(request.url?.query, nil, "the token must not travel in a query string where proxies and logs keep it")
        XCTAssertEqual(request.url?.user, nil, "no userinfo in a request URL")
        XCTAssertFalse((request.url?.absoluteString ?? "").contains("long-lived-secret"), "the token must not appear in the URL: \(request.url?.absoluteString ?? "")")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer long-lived-secret", "HA takes a bearer header, on the LAN only")
        XCTAssertEqual(request.url?.host, "192.168.1.20", "the request goes where the allow-list said it may")
    }

    // MARK: B — the MQTT v3.1.1 codec, byte for byte

    func testConnectBytesMatchTheSpecLayout() throws {
        let minimal = try MQTTCodec.encodeConnect(MQTTConnectOptions(clientID: "ppx-node", keepAliveSeconds: 30, cleanSession: true))
        var expected: [UInt8] = hubStringField("MQTT")
        expected += [MQTTCodec.protocolLevel, 0x02] + hubU16(30) + hubStringField("ppx-node")
        XCTAssertEqual(Array(minimal), [0x10] + hubRemainingLengthBytes(expected.count) + expected, "a bare CONNECT is name + level 4 + clean-session flag + keepalive + client id")

        let options = MQTTConnectOptions(
            clientID: "popopx-mac-node", keepAliveSeconds: 60, cleanSession: true,
            username: "u1", password: "hunter2",
            will: MQTTWill(topic: "ppx/last", payload: Data("bye".utf8), qos: 1, retain: true)
        )
        var body = hubStringField("MQTT")
        body += [4]                                   // protocol level, v3.1.1
        body += [0xEE]                                // user | password | will | will-qos-1 | will-retain | clean
        body += hubU16(60)                            // keepalive, big endian
        body += hubStringField("popopx-mac-node")     // client id first
        body += hubStringField("ppx/last")            // then the will topic
        body += hubU16(3) + Array("bye".utf8)         // then the will payload, length-prefixed
        body += hubStringField("u1")                  // then the username
        body += hubStringField("hunter2")             // then the password
        let encoded = try MQTTCodec.encodeConnect(options)
        XCTAssertEqual(Array(encoded), [0x10] + hubRemainingLengthBytes(body.count) + body, "the CONNECT payload order is fixed by §3.1; any other order reads as garbage")

        let bytes = [UInt8](encoded)
        XCTAssertEqual(bytes[0], 0x10, "the packet type nibble is 1 and the flag nibble is reserved-zero")
        XCTAssertEqual(bytes[9] & 0x01, 0, "§3.1.2.3: bit 0 of the connect flags must be zero")
        XCTAssertEqual(bytes[8], 4, "the protocol level must be 4, not 5 (that is MQTT 5, a different wire)")
        // Keepalive is u16 big-endian; a 70000-second keepalive is not a legal frame.
        XCTAssertThrowsError(try MQTTCodec.encodeConnect(MQTTConnectOptions(clientID: "x", keepAliveSeconds: 70_000))) { error in
            XCTAssertEqual(error as? MQTTCodecError, .topicTooLong(70_000), "the codec refuses an unrepresentable keepalive (reusing the length case, but refusing)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodeConnect(MQTTConnectOptions(clientID: "", keepAliveSeconds: 30))) { error in
            XCTAssertEqual(error as? MQTTCodecError, .emptyTopic, "an empty client id means the broker mints one the audit log cannot name")
        }
        XCTAssertThrowsError(try MQTTCodec.encodeConnect(MQTTConnectOptions(clientID: "x", will: MQTTWill(topic: "w", payload: Data(), qos: 3)))) { error in
            XCTAssertEqual(error as? MQTTCodecError, .invalidQoS(3), "a will at QoS 3 is not a thing")
        }
    }

    func testRemainingLengthVarintEdges() throws {
        let table: [(Int, [UInt8])] = [
            (0, [0x00]), (1, [0x01]), (127, [0x7F]),
            (128, [0x80, 0x01]), (16_383, [0xFF, 0x7F]),
            (16_384, [0x80, 0x80, 0x01]), (2_097_151, [0xFF, 0xFF, 0x7F]),
            (268_435_455, [0xFF, 0xFF, 0xFF, 0x7F])
        ]
        for (length, bytes) in table {
            XCTAssertEqual(try MQTTCodec.remainingLength(length), bytes, "§2.2.3 encodes \(length) as \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        XCTAssertThrowsError(try MQTTCodec.remainingLength(MQTTCodec.maximumPacketBytes + 1), "the varint holds four bytes, so 256 MiB is the ceiling") { error in
            XCTAssertEqual(error as? MQTTCodecError, .remainingLengthTooLong, "expected remainingLengthTooLong, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.remainingLength(-1), "a negative length is not a length") { error in
            XCTAssertEqual(error as? MQTTCodecError, .malformedRemainingLength, "expected malformedRemainingLength, got \(error)")
        }
        XCTAssertEqual(
            MQTTCodec.readRemainingLength([0x80, 0x01], from: 0), .value(128, bytes: 2),
            "the reader has to agree with the writer at the 128 boundary"
        )
        XCTAssertEqual(MQTTCodec.readRemainingLength([0x80, 0x80], from: 0), .incomplete, "a continuation bit with nothing after it is 'read more', not an error")
        XCTAssertEqual(MQTTCodec.readRemainingLength([0x80, 0x80, 0x80, 0x80, 0x01], from: 0), .malformed, "a fifth continuation byte is a broken packet, not an invitation to keep reading")
    }

    func testStringEncodingIsByteCountedAndRefusesNUL() throws {
        let topic = "temp/温度"
        let encoded = try MQTTCodec.string(topic)
        XCTAssertEqual(Array(topic.utf8).count, 11, "the fixture is 7 characters and 11 UTF-8 bytes")
        XCTAssertEqual(topic.count, 7, "…and the two counts differ, which is the point of the next assertion")
        XCTAssertEqual(encoded, [0x00, 0x0B] + Array(topic.utf8), "the prefix is the byte count, not the character count: a character count would make the broker read a short topic")
        XCTAssertThrowsError(try MQTTCodec.string(""), "an empty topic is not a topic") { error in
            XCTAssertEqual(error as? MQTTCodecError, .emptyTopic, "expected emptyTopic for \"\", got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.string("home/a\u{0}state"), "§1.5.3 forbids NUL; a broker truncates at it, which would name another device's topic") { error in
            XCTAssertEqual(error as? MQTTCodecError, .emptyTopic, "expected the refusal rather than a silent truncate, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.string(String(repeating: "a", count: 65_536)), "a length prefix is 16 bits") { error in
            XCTAssertEqual(error as? MQTTCodecError, .topicTooLong(65_536), "expected topicTooLong(65536), got \(error)")
        }
    }

    func testPublishLayoutCarriesAPacketIdOnlyAboveQoS0() throws {
        let topic = "home/a/state"
        let payload = Data([0x01, 0x02, 0x03])
        let qos0 = try MQTTCodec.encodePublish(topic: topic, payload: payload, qos: 0)
        var expected: [UInt8] = [0x30] + hubRemainingLengthBytes(2 + topic.utf8.count + payload.count) + hubStringField(topic) + [0x01, 0x02, 0x03]
        XCTAssertEqual(Array(qos0), expected, "a QoS-0 publish has no packet identifier: the two bytes after the topic are the payload")

        let qos1 = try MQTTCodec.encodePublish(topic: topic, payload: payload, qos: 1, retain: true, duplicate: true, packetId: 7)
        expected = [0x3B] + hubRemainingLengthBytes(2 + topic.utf8.count + 2 + payload.count) + hubStringField(topic) + hubU16(7) + [0x01, 0x02, 0x03]
        XCTAssertEqual(Array(qos1), expected, "flags must be dup|qos|retain = 0b00111011 in the low nibble, with the identifier between topic and payload")

        XCTAssertThrowsError(try MQTTCodec.encodePublish(topic: topic, payload: payload, qos: 1, packetId: 0), "QoS 1 without an identifier can never be acknowledged") { error in
            XCTAssertEqual(error as? MQTTCodecError, .packetIdMissing, "expected packetIdMissing, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodePublish(topic: topic, payload: payload, qos: 3), "QoS 3 is reserved") { error in
            XCTAssertEqual(error as? MQTTCodecError, .invalidQoS(3), "expected invalidQoS(3), got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodePublish(topic: "home/#", payload: payload), "§4.7: a PUBLISH names a topic, it does not select a set") { error in
            XCTAssertEqual(error as? MQTTCodecError, .malformedBody("wildcards are illegal in a publish topic: home/#"), "expected a wildcard refusal, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodePublish(topic: "", payload: payload), "an empty topic must not go on the wire") { error in
            XCTAssertEqual(error as? MQTTCodecError, .emptyTopic, "expected emptyTopic, got \(error)")
        }
    }

    func testSubscribeAndUnsubscribeFraming() throws {
        let filters = [("home/+/state", 0), ("h/#", 1)]
        let subscribe = try MQTTCodec.encodeSubscribe(packetId: 3, filters: filters)
        var body = hubU16(3)
        body += hubStringField("home/+/state") + [0x00]
        body += hubStringField("h/#") + [0x01]
        XCTAssertEqual(Array(subscribe), [0x82] + hubRemainingLengthBytes(body.count) + body, "SUBSCRIBE's flag nibble is fixed at 0b0010 (§3.8.1) and each filter is followed by its requested QoS")

        let unsubscribe = try MQTTCodec.encodeUnsubscribe(packetId: 4, filters: ["h/#"])
        body = hubU16(4) + hubStringField("h/#")
        XCTAssertEqual(Array(unsubscribe), [0xA2] + hubRemainingLengthBytes(body.count) + body, "UNSUBSCRIBE carries no QoS byte")

        XCTAssertThrowsError(try MQTTCodec.encodeSubscribe(packetId: 0, filters: filters), "a SUBSCRIBE the broker cannot answer belongs to nobody") { error in
            XCTAssertEqual(error as? MQTTCodecError, .packetIdMissing, "expected packetIdMissing, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodeSubscribe(packetId: 1, filters: []), "an empty subscription list is a request to be deaf") { error in
            XCTAssertEqual(error as? MQTTCodecError, .emptyTopic, "expected emptyTopic, got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodeSubscribe(packetId: 1, filters: [("a/b", 3)]), "a filter at QoS 3 is not a thing") { error in
            XCTAssertEqual(error as? MQTTCodecError, .invalidQoS(3), "expected invalidQoS(3), got \(error)")
        }
        XCTAssertThrowsError(try MQTTCodec.encodeUnsubscribe(packetId: 0, filters: ["a"]), "expected packetIdMissing, got an unsubscribe") { error in
            XCTAssertEqual(error as? MQTTCodecError, .packetIdMissing, "expected packetIdMissing, got \(error)")
        }
    }

    func testEveryEmittedFrameRoundTrips() throws {
        let publishQoS0 = try MQTTCodec.encodePublish(topic: "a/b", payload: Data("hi".utf8))
        XCTAssertEqual(
            MQTTCodec.decode(publishQoS0),
            .frame(.publish(MQTTPublish(topic: "a/b", payload: Data("hi".utf8), qos: 0, retain: false, duplicate: false, packetId: 0)), consumed: publishQoS0.count),
            "a QoS-0 publish must come back with no identifier and no flags"
        )
        let publishQoS1 = try MQTTCodec.encodePublish(topic: "a/b", payload: Data("hi".utf8), qos: 1, retain: true, duplicate: true, packetId: 9)
        XCTAssertEqual(
            MQTTCodec.decode(publishQoS1),
            .frame(.publish(MQTTPublish(topic: "a/b", payload: Data("hi".utf8), qos: 1, retain: true, duplicate: true, packetId: 9)), consumed: publishQoS1.count),
            "retain, dup, qos and the identifier all have to survive the round trip"
        )
        let acknowledgements: [(Data, MQTTInboundFrame)] = [
            (try MQTTCodec.encodePubAck(packetId: 5), .pubAck(packetId: 5)),
            (try MQTTCodec.encodePubRec(packetId: 6), .pubRec(packetId: 6)),
            (try MQTTCodec.encodePubRel(packetId: 7), .pubRel(packetId: 7)),
            (try MQTTCodec.encodePubComp(packetId: 8), .pubComp(packetId: 8))
        ]
        for (frame, expectedFrame) in acknowledgements {
            XCTAssertEqual(MQTTCodec.decode(frame), .frame(expectedFrame, consumed: frame.count), "\(expectedFrame) must round-trip through the decoder")
            XCTAssertLessThanOrEqual(frame.count, 6, "\(expectedFrame) is a four-byte frame; anything longer means the length prefix was written wrong")
        }
        XCTAssertEqual(MQTTCodec.decode(MQTTCodec.encodePingReq()), .frame(.pingReq, consumed: 2), "PINGREQ is a two-byte frame")
        XCTAssertEqual(MQTTCodec.decode(MQTTCodec.encodeDisconnect()), .frame(.disconnect, consumed: 2), "DISCONNECT is a two-byte frame")

        // A server does not send these, and the node must not parse them if it gets them.
        let serverForbidden: [(Data, Int)] = [
            (try MQTTCodec.encodeConnect(MQTTConnectOptions(clientID: "x")), 1),
            (try MQTTCodec.encodeSubscribe(packetId: 1, filters: [("a", 0)]), 8),
            (try MQTTCodec.encodeUnsubscribe(packetId: 1, filters: ["a"]), 10)
        ]
        for (frame, typeValue) in serverForbidden {
            XCTAssertEqual(MQTTCodec.decode(frame), .rejected(.serverInitiatedPacket(typeValue)), "type \(typeValue) inbound is a hostile frame, not a reply")
        }
    }

    func testDecodeAnswersForHostileFrames() throws {
        XCTAssertEqual(
            MQTTCodec.decode(Data([0x20, 0x02, 0x00, 0x05])),
            .frame(.connAck(sessionPresent: false, code: .notAuthorized, rawCode: 5), consumed: 4),
            "a CONNACK of 5 is 'not authorized', delivered as a frame the session reads as a refusal"
        )
        XCTAssertEqual(
            MQTTCodec.decode(Data([0x20, 0x02, 0x01, 0x09])),
            .frame(.connAck(sessionPresent: true, code: nil, rawCode: 9), consumed: 4),
            "a return code outside the table stays a number rather than becoming the nearest known refusal"
        )
        XCTAssertEqual(MQTTCodec.decode(Data([0x20, 0x01, 0x00])), .rejected(.malformedBody("CONNACK is 2 bytes")), "a short CONNACK is not an answer")

        XCTAssertEqual(
            MQTTCodec.decode(Data([0x38, 0x04, 0x00, 0x01, 0x61, 0x78])),
            .rejected(.malformedBody("DUP is set on a QoS-0 publish")),
            "§3.3.1.2: DUP means redelivery of an unacknowledged packet, which a QoS-0 publish never is"
        )
        XCTAssertEqual(MQTTCodec.decode(Data([0x32, 0x05, 0x00, 0x01, 0x61, 0x00, 0x00])), .rejected(.packetIdMissing), "a QoS-1 publish with identifier 0 cannot be acknowledged")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0x03, 0x00, 0x05, 0x61])), .rejected(.malformedBody("unreadable topic")), "a topic length past the end of the frame is not a topic")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0x05, 0x00, 0x03, 0xFF, 0xFF, 0xFF])), .rejected(.malformedBody("unreadable topic")), "invalid UTF-8 in a topic is refused, not replaced")
        XCTAssertEqual(MQTTCodec.decode(Data([0x40, 0x02, 0x00, 0x00])), .rejected(.packetIdMissing), "a PUBACK for packet 0 belongs to nothing")

        XCTAssertEqual(MQTTCodec.decode(Data([0x00, 0x00])), .rejected(.reservedPacketType(0)), "type 0 is reserved")
        XCTAssertEqual(MQTTCodec.decode(Data([0xF0, 0x00])), .rejected(.reservedPacketType(15)), "type 15 is reserved")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0x80, 0x80, 0x80, 0x80, 0x01])), .rejected(.malformedRemainingLength), "five length bytes is a broken packet")
        // A peer that announces 3 MB and sends 5 bytes must cost this node 5 bytes.
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0xC0, 0x8D, 0xB7, 0x01])), .incomplete(needed: 3_000_000), "the decoder reports the missing bytes instead of allocating for the lie")

        XCTAssertEqual(MQTTCodec.decode(Data()), .incomplete(needed: 2), "no bytes is 'read more', not an error")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30])), .incomplete(needed: 1), "a header with no length byte is 'read more'")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0x05, 0x00, 0x01, 0x61])), .incomplete(needed: 2), "exactly the missing two bytes are asked for")
        XCTAssertEqual(MQTTCodec.decode(Data([0x30, 0x80, 0x80, 0x80])), .incomplete(needed: 1), "an unfinished length field asks for one more byte")
    }

    func testFramesSurviveBeingSplitAcrossReads() throws {
        let options = MQTTConnectOptions(clientID: "popopx-mac-node", keepAliveSeconds: 60, cleanSession: true, username: "u", password: "p")
        let frame = try MQTTCodec.encodeConnect(options)
        let bytes = [UInt8](frame)
        XCTAssertGreaterThan(bytes.count, 20, "the fixture has to be long enough to split meaningfully")
        for cut in 1..<bytes.count {
            switch MQTTCodec.decode(Data(bytes[..<cut])) {
            case .incomplete:
                continue
            case let .rejected(error):
                XCTFail("the first \(cut) bytes of a legal CONNECT were rejected as \(error) instead of asking for more")
            case let .frame(parsed, consumed):
                XCTFail("a \(cut)-byte prefix of a \(bytes.count)-byte CONNECT decoded as \(parsed) after \(consumed) bytes")
            }
        }
        // The whole frame does decode — as a refusal, because a server may not send a CONNECT.
        XCTAssertEqual(MQTTCodec.decode(frame), .rejected(.serverInitiatedPacket(1)), "a complete CONNECT is recognised, not treated as noise")
    }

    func testTopicFilterMatcherIsTheAllowListMatcher() throws {
        XCTAssertTrue(MQTTTopics.matches("sport/#", topic: "sport"), "§4.7.1.2: sport/# also covers sport")
        XCTAssertTrue(MQTTTopics.matches("home/+/state", topic: "home/a/state"), "one + is exactly one level")
        XCTAssertFalse(MQTTTopics.matches("home/+/state", topic: "home/a/b/state"), "+ does not cross a level, so it cannot widen a subscription")
        XCTAssertTrue(MQTTTopics.matches("home/#", topic: "home/a/b/state"), "# is the multi-level wildcard")
        XCTAssertFalse(MQTTTopics.matches("home/a/state", topic: "home/b/state"), "an exact filter matches exactly")
        XCTAssertFalse(MQTTTopics.isValidFilter("a+b"), "a wildcard glued inside a level is malformed")
        XCTAssertFalse(MQTTTopics.isValidFilter("#/x"), "# must be the last level")
        XCTAssertFalse(MQTTTopics.isValidFilter(""), "an empty filter is not a filter")
        XCTAssertFalse(MQTTTopics.isValidTopicName("$SYS/broker/load"), "the broker's own namespace is not this node's to publish to")
        XCTAssertFalse(MQTTTopics.isValidTopicName("a/#"), "a published topic may not contain a wildcard")
        XCTAssertTrue(MQTTTopics.isValidTopicName("cmnd/light.desk"), "the command topic shape the bridge builds is legal")
    }

    func testSessionRunsTheHandshakeOverAnInjectedStream() async throws {
        let endpoint = try EdgeBoundary.resolve(host: "127.0.0.1", port: 1883)
        let inboundPublish = try MQTTCodec.encodePublish(topic: "home/a/state", payload: Data("{\"state\":\"on\"}".utf8), qos: 1, packetId: 7)
        let stream = HubScriptedStream(endpoint: endpoint, inbound: [
            hubConnAck(), hubSubAck(packetId: 1, code: 1), hubPubAck(packetId: 2), inboundPublish
        ])
        let session = MQTTSession(stream: stream, options: MQTTConnectOptions(clientID: "popopx-mac-node", keepAliveSeconds: 60), readTimeout: 2)

        let connected = await session.connect()
        let connectReason = await session.failureReason
        XCTAssertTrue(connected, "a CONNACK of 0 opens the session: \(connectReason)")
        var sent = stream.framesSent
        XCTAssertEqual(sent.count, 1, "connect sends exactly one frame")
        XCTAssertEqual([UInt8](sent[0]).first, 0x10, "that frame is a CONNECT")
        let subscribed = await session.subscribe(["home/+/state"], qos: 1)
        XCTAssertTrue(subscribed, "the SUBACK says the filter was granted")
        sent = stream.framesSent
        XCTAssertEqual(sent.count, 2, "subscribe added one frame")
        XCTAssertEqual([UInt8](sent[1]).first, 0x82, "the second frame is a SUBSCRIBE")
        let published = await session.publish(topic: "cmnd/light.desk", payload: "on", qos: 1)
        XCTAssertTrue(published, "a QoS-1 publish waits for its PUBACK")
        sent = stream.framesSent
        XCTAssertEqual(sent.count, 3, "publish added one frame")
        let decodedPublish = MQTTCodec.decode(sent[2])
        var publishedTopic = ""
        var publishedQoS = -1
        var publishedPayload = ""
        var consumedBytes = -1
        if case .frame(.publish(let message), let consumed) = decodedPublish {
            publishedTopic = message.topic
            publishedQoS = message.qos
            publishedPayload = message.text ?? ""
            consumedBytes = consumed
        }
        XCTAssertEqual(consumedBytes, sent[2].count, "the session writes whole frames: the decoder consumes exactly the bytes that were sent")
        XCTAssertEqual(publishedTopic, "cmnd/light.desk", "the topic on the wire is the one the bridge was asked for")
        XCTAssertEqual(publishedQoS, 1, "a command is published at the QoS the bridge asked for")
        XCTAssertEqual(publishedPayload, "on", "the payload survives the framing unchanged")

        let arrived = await session.poll(timeout: 0.3)
        XCTAssertEqual(arrived, 1, "the broker's push arrives through the same decoder")
        let inbox = await session.drainInbox()
        XCTAssertEqual(inbox.count, 1, "exactly one message was kept")
        XCTAssertEqual(inbox.first?.packetId, 7, "the inbound identifier survives, because that is what the PUBACK has to name")
        try? await Task.sleep(nanoseconds: 120_000_000)
        let acked = stream.framesSent.contains { [UInt8]($0).first == 0x40 }
        XCTAssertTrue(acked, "an inbound QoS-1 publish must be acknowledged with a PUBACK, or the broker redelivers forever")
        await session.disconnect()
        let disconnected = stream.framesSent.last
        XCTAssertEqual(disconnected, MQTTCodec.encodeDisconnect(), "the session says goodbye before it closes")
        XCTAssertGreaterThan(stream.finishCount, 0, "the stream is always finished, so the socket is not left dangling")
    }

    func testSessionRefusesToProceedWhenTheBrokerSaysNo() async throws {
        let endpoint = try EdgeBoundary.resolve(host: "192.168.1.5", port: 1883)
        let stream = HubScriptedStream(endpoint: endpoint, inbound: [hubConnAck(code: 5)])
        let session = MQTTSession(stream: stream, options: MQTTConnectOptions(clientID: "popopx", username: "u", password: "p"), readTimeout: 2)
        let connected = await session.connect()
        XCTAssertFalse(connected, "a CONNACK of 5 is not a connection")
        let reason = await session.failureReason
        XCTAssertTrue(reason.contains("not authorized"), "the owner is told why: \(reason)")
        let stillOpen = await session.isConnected
        XCTAssertFalse(stillOpen, "the session must not report itself open after a refusal")
        XCTAssertGreaterThan(stream.finishCount, 0, "a refused handshake still closes the stream it opened")
        let publish = await session.publish(topic: "cmnd/light.desk", payload: "on", qos: 1)
        XCTAssertFalse(publish, "nothing may be published on a session that was refused")
        XCTAssertEqual(stream.framesSent.count, 1, "and no publish reached the wire: only the CONNECT did")

        // A frame split across two reads is still one frame.
        let split = HubScriptedStream(endpoint: endpoint, inbound: [Data([0x20, 0x02]), Data([0x00, 0x00])])
        let second = MQTTSession(stream: split, options: MQTTConnectOptions(clientID: "popopx"), readTimeout: 2)
        let reopened = await second.connect()
        XCTAssertTrue(reopened, "the pump buffers a CONNACK delivered in two chunks instead of declaring the broker silent")
    }

    // MARK: C — the smart-home gate

    /// A whole node: engine, bridge, ledger, and the scripted broker behind the factory.
    /// `wireExecution` builds the production executor chain (ledger → `PrivacyExecutorHub`
    /// → bridge), which is the only way to prove that a receipt is what opens a socket.
    /// Otherwise the executor records and nothing else can reach a device.
    private func hubHome(
        _ name: String,
        smartHome: SmartHomeConfig,
        switchOn: Bool = true,
        secrets: HubSecretStoring = VolatileSecretStore(),
        wireExecution: Bool = false,
        inbound: [Data] = []
    ) async throws -> HubHomeRig {
        let folder = try hubScratch(name)
        let config = HubConfig(allowSmartHomeBridge: switchOn, smartHome: smartHome)
        let factory = HubBrokerFactory(inbound: inbound)
        let hub = PrivacyExecutorHub(gateway: HubFakeGateway(), sandbox: WorkspaceSandbox())
        let recorder = wireExecution ? nil : HubRecordingExecutor()
        let ledger: PrivacyProposalLedger
        if let recorder {
            ledger = PrivacyProposalLedger(signer: PrivacyApprovalSigner(key: Data("hub-edge-signing-key-0123456789".utf8)), executor: recorder, fileURL: folder.appendingPathComponent("ledger.jsonl"), loadFromDisk: false)
        } else {
            ledger = PrivacyProposalLedger(signer: PrivacyApprovalSigner(key: Data("hub-edge-signing-key-0123456789".utf8)), executor: hub, fileURL: folder.appendingPathComponent("ledger.jsonl"), loadFromDisk: false)
        }
        let bridge = SmartHomeBridge(config: config, secrets: secrets, ledger: ledger) { endpoint, options in
            factory.make(endpoint: endpoint, options: options)
        }
        await ledger.setNotificationsEnabled(false)
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(),
            gateway: HubFakeGateway(),
            ledger: ledger,
            hub: hub,
            sandbox: WorkspaceSandbox(),
            nodeReference: "hub-edge-test",
            smartHome: bridge
        )
        await engine.attachHubBridges()
        await engine.applyHubConfig(config)
        return HubHomeRig(engine: engine, bridge: bridge, ledger: ledger, secrets: secrets, factory: factory, recorder: recorder)
    }

    /// The two field halves of a refusal: the status the console gets and the text it shows.
    private func hubRefusal(_ reply: PrivacyToolResponse) -> (status: Int, text: String) {
        let text = reply.fields["refusal"]?.stringValue ?? reply.body
        return (reply.status, text)
    }

    private func hubHomeConfig(
        entities: [String] = ["light.desk"],
        readOnly: Bool = false,
        prefix: String = "",
        telemetry: Bool = false,
        homeAssistant: String = "http://192.168.1.20:8123",
        broker: String = ""
    ) -> SmartHomeConfig {
        SmartHomeConfig(
            homeAssistantUrl: homeAssistant,
            homeAssistantTokenRef: "smarthome/homeassistant/token",
            mqttHost: broker,
            exposedEntities: entities,
            readOnlyMode: readOnly,
            allowMqttTelemetry: telemetry,
            mqttCommandPrefix: prefix
        )
    }

    func testUnlistedEntityIsRefusedAndNamed() async throws {
        let rig = try await hubHome("unlisted", smartHome: hubHomeConfig())

        let missing = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("lock.front_door"), "service": .string("lock.lock")]
        ))
        let refusal = hubRefusal(missing)
        XCTAssertEqual(refusal.status, 403, "an entity outside the allow-list is a refusal, not a proposal: \(missing.body)")
        XCTAssertTrue(refusal.text.contains("白名单"), "the console must say which rule bit: \(refusal.text)")
        XCTAssertTrue(refusal.text.contains("lock.front_door"), "the refusal names the rejected entity: \(refusal.text)")

        let malformed = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("lightdesk"), "service": .string("light.turn_on")]
        ))
        XCTAssertEqual(hubRefusal(malformed).status, 403, "an entity id without a domain is refused: \(malformed.body)")
        XCTAssertTrue(hubRefusal(malformed).text.contains("domain.name"), "and the reason is the shape: \(hubRefusal(malformed).text)")

        let proposed = await rig.ledger.pending()
        XCTAssertTrue(proposed.isEmpty, "a refused call must not leave anything clickable: \(proposed.map { $0.id })")
        let audit = await rig.ledger.auditLog(limit: 20)
        XCTAssertTrue(
            audit.contains { $0.outcome == "refused" && $0.detail.contains("entity not exposed: lock.front_door") },
            "the denial is audited with the entity named: \(audit.map { $0.outcome + " " + $0.detail })"
        )
        XCTAssertEqual(rig.factory.calls, 0, "a refused entity must never reach the broker")
    }

    func testAdmittedControlBecomesAReceiptBeforeAnyDeviceCall() async throws {
        let rig = try await hubHome("receipt", smartHome: hubHomeConfig(entities: ["light.desk"]))
        let reply = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("light.desk"), "service": .string("light.turn_on")]
        ))
        XCTAssertEqual(reply.status, 201, "an admitted control is a proposal, never an actuation: \(reply.body)")
        XCTAssertEqual(reply.fields["executed"]?.boolValue, false, "the node says plainly that it did nothing")
        XCTAssertEqual(reply.fields["requiresUserConfirmation"]?.boolValue, true, "and says what it is waiting for")
        let offered = reply.fields["approvalReceipt"]?.stringValue ?? ""
        XCTAssertFalse(offered.isEmpty, "the response carries the code the owner types: \(reply.fields.keys.sorted())")
        let noCallYet = rig.factory.calls
        XCTAssertEqual(noCallYet, 0, "nothing is dialled before the receipt")

        let pending = await rig.ledger.pending()
        XCTAssertEqual(pending.count, 1, "exactly one proposal is clickable: \(pending.map { $0.id })")
        let proposal = try XCTUnwrap(pending.first)
        XCTAssertTrue(proposal.title.hasPrefix("控制设备 · "), "the card names the device: \(proposal.title)")
        XCTAssertEqual(proposal.hubCall?.target, "light.turn_on", "the service the owner is being asked about")
        XCTAssertEqual(proposal.hubCall?.destination, "http://192.168.1.20:8123", "and the only address it may reach")
        XCTAssertEqual(proposal.hubCall?.arguments["entity_id"]?.stringValue, "light.desk",
                       "the entity is normalised into the proposal, so a later edit cannot widen it")

        let receipt = await rig.ledger.receipt(id: proposal.id, verb: "approve")
        let decision = await rig.ledger.approve(id: proposal.id, receipt: receipt)
        XCTAssertTrue(decision.ok, "the receipt this node issued authorizes this proposal: \(decision.message)")
        let runs = rig.recorder?.runs ?? []
        XCTAssertEqual(runs.count, 1, "execution happens once, and only after the click")
        XCTAssertEqual(runs.first?.id, proposal.id, "the executed proposal is the one that was pending")
        let audit = await rig.ledger.auditLog(limit: 30)
        XCTAssertTrue(audit.contains { $0.outcome == "executed" }, "the approval and its execution are audited: \(audit.map { $0.outcome })")
    }

    func testHighRiskEntityNeedsItsOwnReceiptEveryTime() async throws {
        let rig = try await hubHome("highrisk", smartHome: hubHomeConfig(entities: ["lock.front_door"]))
        let first = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("lock.front_door"), "service": .string("lock.unlock")]
        ))
        XCTAssertEqual(first.status, 201, "a door lock is reachable only through a receipt: \(first.body)")
        let pending = await rig.ledger.pending()
        let proposal = try XCTUnwrap(pending.first)
        XCTAssertTrue(proposal.title.hasPrefix("高危设备操作 · "),
                      "the card says what kind of thing is about to move: \(proposal.title)")

        _ = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("lock.front_door"), "service": .string("lock.unlock")]
        ))
        let again = await rig.ledger.pending()
        XCTAssertEqual(again.count, 2, "a second actuation is a second decision, never an inherited yes: \(again.map { $0.title })")
        XCTAssertNotEqual(again[0].id, again[1].id, "two proposals, two ids, two receipts")
        XCTAssertEqual(rig.factory.calls, 0, "and still no socket")
    }

    /// The config is the owner's intent, so `executeApproved` re-checks it at the moment of
    /// the write: an allow-list edit or a flipped switch between the proposal and the
    /// approval has to stop the device, not be silently ignored.
    func testApprovedWriteIsReCheckedAgainstTheConfigAtExecution() async throws {
        let rig = try await hubHome("recheck", smartHome: hubHomeConfig(entities: ["light.desk"]))
        _ = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("light.desk"), "service": .string("light.turn_on")]
        ))
        let pending = await rig.ledger.pending()
        let proposal = try XCTUnwrap(pending.first)

        await rig.bridge.update(config: HubConfig(allowSmartHomeBridge: true, smartHome: hubHomeConfig(entities: [])))
        let dropped = await rig.bridge.executeApproved(proposal)
        XCTAssertFalse(dropped.ok, "an entity that left the allow-list cannot be actuated: \(dropped.message)")
        XCTAssertTrue(dropped.message.contains("白名单"), "and the reason names the rule: \(dropped.message)")

        await rig.bridge.update(config: HubConfig(allowSmartHomeBridge: false, smartHome: hubHomeConfig()))
        let off = await rig.bridge.executeApproved(proposal)
        XCTAssertFalse(off.ok, "a bridge that is off refuses even an approved proposal: \(off.message)")
        XCTAssertEqual(rig.factory.calls, 0, "both refusals happen before any connection is attempted")
    }

    /// 任务 3's second gate: the switch is not decoration. Turning it off must refuse the
    /// call it accepted moments before *and* void what was already waiting for a click.
    func testFlippingTheSwitchRefusesTheCallAndVoidsThePendingReceipt() async throws {
        let rig = try await hubHome("switchoff", smartHome: hubHomeConfig())
        let admitted = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("light.desk"), "service": .string("light.turn_on")]
        ))
        XCTAssertEqual(admitted.status, 201, "with the bridge on, the control becomes a proposal")
        let waiting = await rig.ledger.pending()
        XCTAssertEqual(waiting.count, 1)

        await rig.engine.applyHubConfig(HubConfig(allowSmartHomeBridge: false, smartHome: hubHomeConfig()))
        let after = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("light.desk"), "service": .string("light.turn_on")]
        ))
        let refusal = hubRefusal(after)
        XCTAssertEqual(refusal.status, 403, "the identical call is now refused: \(after.body)")
        XCTAssertTrue(refusal.text.contains("家居桥接未开启"), "and the console is told which switch: \(refusal.text)")
        XCTAssertEqual(after.fields["switch"]?.stringValue, "allowSmartHomeBridge", "the field name, so the card can link to it")

        let emptied = await rig.ledger.pending()
        XCTAssertTrue(emptied.isEmpty, "a receipt that was waiting must not outlive the bridge: \(emptied.map { $0.title })")
        let audit = await rig.ledger.auditLog(limit: 30)
        XCTAssertTrue(audit.contains { $0.outcome == "voided" }, "the voiding is audited: \(audit.map { $0.outcome })")
        XCTAssertEqual(rig.factory.calls, 0, "no socket was opened on the way in or on the way out")
    }

    func testReadOnlyModeRefusesControlAndSaysSo() async throws {
        let rig = try await hubHome("readonly", smartHome: hubHomeConfig(readOnly: true))
        let reply = await rig.engine.handle(PrivacyToolCall(
            namespace: .home, action: PrivacyToolAction.control,
            payload: ["entity": .string("light.desk"), "service": .string("light.turn_on")]
        ))
        let refusal = hubRefusal(reply)
        XCTAssertEqual(refusal.status, 403, "read-only means read-only: \(reply.body)")
        XCTAssertTrue(refusal.text.contains("只读"), "the owner is told the mode, not a generic denial: \(refusal.text)")
        let pending = await rig.ledger.pending()
        XCTAssertTrue(pending.isEmpty, "a refused control leaves nothing clickable: \(pending.map { $0.id })")
        let audit = await rig.ledger.auditLog(limit: 20)
        XCTAssertTrue(
            audit.contains { $0.outcome == "refused" && $0.detail.contains("read-only mode: light.desk") },
            "the refusal is audited with the entity named: \(audit.map { $0.outcome + " " + $0.detail })"
        )
    }

    // MARK: D — CalDAV: the text this node reads and must never keep

    /// 任务 4's iron rule, asserted on every surface the parsed value can become. The
    /// control at the top is the load-bearing part: without it, a fixture that quietly
    /// stopped carrying the canaries would turn every one of these assertions green.
    func testCalendarTextDiesWithTheParse() throws {
        let document = hubCalendar([hubEvent("""
        DTSTART;TZID=Asia/Shanghai:20260115T090000
        DTEND;TZID=Asia/Shanghai:20260115T093000
        """)])
        for canary in hubCalendarCanaries {
            XCTAssertTrue(document.contains(canary), "the fixture no longer carries \(canary), so the leak assertions below prove nothing")
        }

        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))
        let reading = ICalendarParse.busy(in: document, window: window, defaultZone: hubShanghaiZone)
        XCTAssertEqual(reading.busy.count, 1, "one event, one block: \(reading.busy)")
        XCTAssertEqual(reading.busy.first?.start, hubUTC(2026, 1, 15, 1, 0), "09:00 in Asia/Shanghai is 01:00Z")
        XCTAssertEqual(reading.busy.first?.end, hubUTC(2026, 1, 15, 1, 30))
        XCTAssertEqual(reading.eventCount, 1)
        XCTAssertEqual(reading.discardedCount, 0)
        XCTAssertFalse(reading.approximated)
        XCTAssertFalse(reading.unknownTimeZone, "Asia/Shanghai is declared by the VTIMEZONE block")

        let json = String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)
        hubAssertNoCalendarText(json, "the JSON encoding")
        hubAssertNoCalendarText(String(describing: reading), "the printed value")
        hubAssertNoCalendarText(reading.busy.map { "\($0.start)|\($0.end)" }.joined(separator: " "), "the interval list")
        for name in hubCalendarPropertyNames {
            XCTAssertFalse(json.contains(name), "the encoded value still has a slot for \(name): \(json)")
        }

        // A folded SUMMARY is the case a line-by-line redactor gets wrong: the title
        // continues on a space-indented line, so dropping only `SUMMARY:` leaks the rest.
        let folded = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:\(hubCanaryUID)\r
        SUMMARY:项目代号\r
         Aurora 融资评审\r
        DTSTART:20260115T020000Z\r
        DTEND:20260115T030000Z\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        XCTAssertTrue(ICalendarParse.unfold(folded).contains("SUMMARY:项目代号Aurora 融资评审"),
                      "a continuation line is one property: \(ICalendarParse.unfold(folded))")
        let fromFolded = ICalendarParse.busy(in: folded, window: window, defaultZone: hubUTCZone)
        XCTAssertEqual(fromFolded.busy.first?.start, hubUTC(2026, 1, 15, 2, 0), "the fold must not eat the timestamp either")
        hubAssertNoCalendarText(String(describing: fromFolded), "the value parsed from a folded document")
        hubAssertNoCalendarText(
            String(decoding: try JSONEncoder().encode(fromFolded), as: UTF8.self), "the JSON of a folded document"
        )
    }

    func testWindowZoneAndStatusDecideWhatCountsAsBusy() throws {
        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))

        // A stamp with neither `Z` nor `TZID` is floating: it means the owner's clock,
        // so the probe's zone is what moves it, not a guess at UTC.
        let floating = hubCalendar([hubEvent("""
        DTSTART:20260115T090000
        DURATION:PT45M
        """)])
        let asShanghai = ICalendarParse.busy(in: floating, window: window, defaultZone: hubShanghaiZone)
        XCTAssertEqual(asShanghai.busy.first?.start, hubUTC(2026, 1, 15, 1, 0), "floating 09:00 is 01:00Z in Shanghai")
        XCTAssertEqual(asShanghai.busy.first?.end, hubUTC(2026, 1, 15, 1, 45), "PT45M is the length when DTEND is absent")
        let asUTC = ICalendarParse.busy(in: floating, window: window, defaultZone: hubUTCZone)
        XCTAssertEqual(asUTC.busy.first?.start, hubUTC(2026, 1, 15, 9, 0), "the same stamp is 09:00Z for a UTC owner")

        // An undeclared TZID is read as wall time in the caller's zone, and it says so.
        let strange = hubCalendar([hubEvent("""
        DTSTART;TZID=Mars/Valley:20260115T090000
        DTEND;TZID=Mars/Valley:20260115T100000
        """)])
        let odd = ICalendarParse.busy(in: strange, window: window, defaultZone: hubShanghaiZone)
        XCTAssertTrue(odd.unknownTimeZone, "the document names a zone it never defines")
        XCTAssertEqual(odd.busy.first?.start, hubUTC(2026, 1, 15, 1, 0),
                       "an unknown zone is the owner's wall time; shifting it into UTC would move the block by hours")

        let dropped = hubCalendar([
            hubEvent("DTSTART:20260115T020000Z\nDTEND:20260115T030000Z\nSTATUS:CANCELLED"),
            hubEvent("DTSTART:20260115T040000Z\nDTEND:20260115T050000Z\nTRANSP:TRANSPARENT"),
            hubEvent("DTSTART:20260120T040000Z\nDTEND:20260120T050000Z"),
            hubEvent("DTEND:20260115T060000Z")
        ])
        let nothing = ICalendarParse.busy(in: dropped, window: window, defaultZone: hubUTCZone)
        XCTAssertTrue(nothing.busy.isEmpty, "cancelled, transparent, outside, unplaceable — none is busy: \(nothing.busy)")
        XCTAssertEqual(nothing.discardedCount, 4, "and every drop is counted, so the answer stays a floor")
        XCTAssertTrue(nothing.approximated, "an event with no start is a hole in the window, not a gap")

        let merged = ICalendarParse.merge([
            RedactedBusyInterval(start: hubUTC(2026, 1, 15, 1), end: hubUTC(2026, 1, 15, 3)),
            RedactedBusyInterval(start: hubUTC(2026, 1, 15, 2), end: hubUTC(2026, 1, 15, 4)),
            RedactedBusyInterval(start: hubUTC(2026, 1, 15, 6), end: hubUTC(2026, 1, 15, 7))
        ])
        XCTAssertEqual(merged.count, 2, "overlaps become one block: \(merged)")
        XCTAssertEqual(merged.first?.start, hubUTC(2026, 1, 15, 1))
        XCTAssertEqual(merged.first?.end, hubUTC(2026, 1, 15, 4), "the merged end is the later of the two")
    }

    func testClientSendsOnlyTheQueryAndReturnsOnlyIntervals() async throws {
        let document = hubCalendar([hubEvent("""
        DTSTART:20260115T020000Z
        DTEND:20260115T030000Z
        """)])
        let password = "pw-\(hubTokenCanary)"
        let transport = HubScriptedTransport(responses: [hubCalendarResponse(document: document)])
        let config = CalDavServerConfig(
            id: "lan", label: "Radicale", url: "https://192.168.1.30/remote.php/dav",
            username: "ada", passwordRef: "caldav/lan/password", calendarPath: "/calendars/ada/home/"
        )
        let client = try CalDavClient(config: config, password: password, transport: transport)
        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))
        let reading = try await client.freeBusy(calendarPath: "/calendars/ada/home/", window: window, zone: hubShanghaiZone)

        XCTAssertEqual(reading.busy.count, 1, "the answer is intervals and counters: \(reading.busy)")
        hubAssertNoCalendarText(String(describing: reading), "the value the client returns")

        let asked = transport.requests
        XCTAssertEqual(asked.count, 1, "one REPORT per read; this node keeps no calendar cache")
        let request = try XCTUnwrap(asked.first)
        XCTAssertEqual(request.method, CalDav.methodReport, "free/busy is a REPORT calendar-query, not a GET")
        XCTAssertTrue(request.url.absoluteString.hasSuffix("/remote.php/dav/calendars/ada/home/"),
                      "the base URL's own path is part of the request, not decoration: \(request.url)")
        XCTAssertEqual(request.headers["Depth"], "1")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("<c:comp-filter name=\"VEVENT\">"), "the filter asks for events only: \(body)")
        XCTAssertTrue(body.contains("start=\"20260115T000000Z\" end=\"20260116T000000Z\""),
                      "the window travels as the range: \(body)")
        hubAssertWellFormedXML(body, "the REPORT body")
        hubAssertNoCalendarText(body, "the REPORT body")

        let authorization = request.headers["Authorization"] ?? ""
        XCTAssertTrue(authorization.hasPrefix("Basic "), "CalDAV authenticates with Basic: \(authorization.prefix(10))…")
        XCTAssertFalse(authorization.contains(password), "the plaintext credential is never put on the wire")
        XCTAssertEqual(Data(base64Encoded: String(authorization.dropFirst(6))), Data("ada:\(password)".utf8),
                       "RFC 7617: one colon, base64, nothing else")
        XCTAssertFalse(String(describing: request).contains(password), "and it is not in the printed request")
    }

    func testPlainHttpToALanHostIsRefusedBeforeAnyByte() throws {
        let config = CalDavServerConfig(
            id: "lan", url: "http://192.168.1.30/remote.php/dav",
            username: "ada", passwordRef: "caldav/lan/password"
        )
        let transport = HubScriptedTransport(responses: [])
        XCTAssertThrowsError(try CalDavClient(config: config, password: "pw", transport: transport)) { error in
            guard let refusal = error as? CalDavError, case .insecureTransport = refusal else {
                return XCTFail("expected insecureTransport, got \(error)")
            }
            XCTAssertEqual(transport.requests.count, 0, "the refusal is made on the literal, not on the response")
        }
    }

    /// A `400` on a `calendar-query` is usually one Apple-only property. One retry, with
    /// that property dropped, and then the owner is told — never a loop.
    func testAFourHundredRetriesOnceWithoutTheAppleProperty() async throws {
        let document = hubCalendar([hubEvent("""
        DTSTART:20260115T020000Z
        DTEND:20260115T030000Z
        """)])
        let config = CalDavServerConfig(
            id: "lan", url: "https://192.168.1.30/remote.php/dav",
            username: "ada", passwordRef: "caldav/lan/password", calendarPath: "/calendars/ada/home/"
        )
        let transport = HubScriptedTransport(
            responses: [
                CalDavResponse(statusCode: 400, headers: ["Content-Type": "text/xml"]),
                hubCalendarResponse(document: document)
            ],
            fallback: CalDavResponse(statusCode: 400, headers: ["Content-Type": "text/xml"])
        )
        let client = try CalDavClient(config: config, password: "pw", transport: transport)
        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))
        let reading = try await client.freeBusy(calendarPath: "/calendars/ada/home/", window: window, zone: hubUTCZone)
        XCTAssertEqual(reading.busy.count, 1, "the retry produced the answer: \(reading.busy)")

        let asked = transport.requests
        XCTAssertEqual(asked.count, 2, "one retry, never a loop")
        let first = String(decoding: asked[0].body ?? Data(), as: UTF8.self)
        let second = String(decoding: asked[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(first.contains("getctag"), "the first attempt asks for the ctag: \(first)")
        XCTAssertFalse(second.contains("getctag"), "the retry drops the property the host has never heard of: \(second)")
    }

    func testMisshapenAnswersBecomeErrorsThatEchoNothing() async throws {
        let config = CalDavServerConfig(
            id: "lan", url: "https://192.168.1.30/remote.php/dav",
            username: "ada", passwordRef: "caldav/lan/password", calendarPath: "/calendars/ada/home/"
        )
        let password = "pw-\(hubTokenCanary)"
        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))

        func refusal(for response: CalDavResponse) async -> String {
            let client = try! CalDavClient(config: config, password: password, transport: HubScriptedTransport(responses: [response]))
            do {
                _ = try await client.freeBusy(calendarPath: "/calendars/ada/home/", window: window, zone: hubUTCZone)
                return ""
            } catch {
                return String(describing: error)
            }
        }

        let portal = await refusal(for: CalDavResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html><body>\(hubCanarySummary) sign in</body></html>".utf8)
        ))
        XCTAssertFalse(portal.isEmpty, "a captive portal answering 200 with HTML is an error")
        XCTAssertTrue(portal.contains("响应不是 XML") || portal.contains("expected an XML"), "and a named one: \(portal)")
        hubAssertNoCalendarText(portal, "the refusal of an HTML answer")
        XCTAssertFalse(portal.contains(password), "the credential is not in the message either: \(portal)")

        let notFound = await refusal(for: CalDavResponse(statusCode: 404))
        XCTAssertTrue(notFound.contains("HTTP 404"), "a missing collection is reported as its status: \(notFound)")

        let wrongRoot = await refusal(for: CalDavResponse(
            statusCode: 207, headers: ["Content-Type": "text/xml"],
            body: Data("<html xmlns:d=\"DAV:\"><body>x</body></html>".utf8)
        ))
        XCTAssertTrue(wrongRoot.contains("multistatus"), "a document that is not a multistatus is refused as one: \(wrongRoot)")
        hubAssertNoCalendarText(wrongRoot, "the refusal of a wrong root element")

        let empty = await refusal(for: hubXMLResponse(statusCode: 207, bodies: [
            "<d:response><d:href>/remote.php/dav/calendars/ada/home/</d:href></d:response>"
        ]))
        XCTAssertTrue(empty.contains("未返回日历数据") || empty.contains("no calendar data"),
                      "an answered-but-emptied collection is not the same as a free week: \(empty)")

        let huge = await refusal(for: CalDavResponse(
            statusCode: 207, headers: ["Content-Type": "text/xml"],
            body: Data(repeating: 0x20, count: CalDav.maximumResponseBytes + 1)
        ))
        XCTAssertTrue(huge.contains(String(CalDav.maximumResponseBytes)), "the ceiling is named: \(huge)")

        let overflow = await refusal(for: hubXMLResponse(
            statusCode: 207,
            bodies: (1...CalDav.maximumResponses + 1).map { "<d:response><d:href>/c/\($0)</d:href></d:response>" }
        ))
        XCTAssertTrue(overflow.contains("过多") || overflow.contains("too many"), "a flood is refused, not read: \(overflow)")
        hubAssertNoCalendarText(overflow, "the refusal of an overflowing multistatus")
    }

    func testDiscoveryKeepsOnlyCappedCollectionText() async throws {
        let long = String(repeating: "日历", count: 200)
        let listing = hubXMLResponse(statusCode: 207, bodies: ["""
        <d:response><d:href>/remote.php/dav/calendars/ada/home/</d:href><d:propstat><d:prop>\
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>\
        <d:displayname>\(hubEscapeXML(long))</d:displayname>\
        <i:calendar-description>\(hubEscapeXML(long))</i:calendar-description>\
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """])
        let transport = HubScriptedTransport(
            responses: [listing, hubXMLResponse(statusCode: 207, bodies: [])],
            fallback: hubXMLResponse(statusCode: 207, bodies: [])
        )
        let config = CalDavServerConfig(
            id: "lan", url: "https://192.168.1.30/remote.php/dav",
            username: "ada", passwordRef: "caldav/lan/password"
        )
        let client = try CalDavClient(config: config, password: "pw", transport: transport)
        let window = DateInterval(start: hubUTC(2026, 1, 15), end: hubUTC(2026, 1, 16))
        let found = try await client.discoverCalendars(window: window)

        XCTAssertEqual(found.count, 1, "one calendar collection: \(found.map { $0.path })")
        let calendar = try XCTUnwrap(found.first)
        XCTAssertEqual(calendar.path, "/remote.php/dav/calendars/ada/home/", "the href survives as the collection to query")
        XCTAssertEqual(calendar.displayName.count, CalDav.maximumDisplayNameCharacters,
                       "a displayname is brand text in a console cell, so it is capped: \(calendar.displayName)")
        XCTAssertEqual(calendar.description?.count, CalDav.maximumDescriptionCharacters,
                       "and so is the description: \((calendar.description ?? "").count)")
        XCTAssertTrue(calendar.supportsReport, "a collection that does not advertise is probed once, then believed")

        let asked = transport.requests
        XCTAssertEqual(asked.first?.method, CalDav.methodPropfind, "discovery starts with PROPFIND Depth 1")
        XCTAssertTrue(asked[0].url.absoluteString.hasSuffix("/remote.php/dav"),
                      "with no collection configured, the walk starts at the base URL, not the server root: \(asked[0].url)")
        let propfind = String(decoding: asked[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(propfind.contains("<c:calendar-home-set/>"), "the body asks for the home set: \(propfind)")
        hubAssertWellFormedXML(propfind, "the PROPFIND body")
        XCTAssertTrue(asked.contains { $0.method == CalDav.methodReport }, "the probe is a REPORT: \(asked.map { $0.method })")
    }

    func testBusySubtractsFromTheOwnersFreeSlots() throws {
        let busy = [RedactedBusyInterval(start: hubUTC(2026, 1, 15, 1), end: hubUTC(2026, 1, 15, 3))]
        let slots = [FreeSlot(start: hubUTC(2026, 1, 15, 0), end: hubUTC(2026, 1, 15, 4))]

        let free = CalDavBridge.subtract(busy: busy, from: slots)
        XCTAssertEqual(free.count, 2, "one four-hour morning and a two-hour block is two gaps: \(free.map { $0.minutes })")
        XCTAssertEqual(free.first?.minutes, 60, "00:00–01:00 stays bookable")
        XCTAssertEqual(free.last?.minutes, 60, "03:00–04:00 stays bookable")
        XCTAssertEqual(CalDavBridge.busyMinutes(busy), 120, "the answer the console shows is minutes, not events")

        let slivers = CalDavBridge.subtract(
            busy: [RedactedBusyInterval(start: hubUTC(2026, 1, 15, 0, 5), end: hubUTC(2026, 1, 15, 3, 5))],
            from: slots, minimumMinutes: CalDavBridge.minimumSlotMinutes
        )
        XCTAssertEqual(slivers.count, 1, "the five minutes before 00:05 is not a bookable gap: \(slivers.map { $0.minutes })")
        XCTAssertEqual(slivers.first?.minutes, 55, "03:05–04:00 is what is left")

        let untouched = CalDavBridge.subtract(busy: [], from: slots)
        XCTAssertEqual(untouched, slots, "no remote busy time must not quietly shave the owner's day")
    }
}


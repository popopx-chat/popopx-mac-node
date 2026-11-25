//
//  WebConsoleBindTests.swift
//  The console's own socket. Every other test in this target is deliberately
//  socket-free, which is exactly how 1.0.0 shipped a console that refused to bind:
//  `NWListener(using:on:)` answers POSIX `EINVAL` when the `on:` port duplicates a
//  port already pinned in `parameters.requiredLocalEndpoint`, and the node treats a
//  failed bind as fatal.
//
//  These tests bind a port of their own instead of `NodeWire.consolePort`, so a node
//  already running on the build machine cannot decide the result. Binding is only half
//  of it: a console that binds is not yet a console that answers, so the later cases
//  put real requests on the wire and read the replies back.
//

import Foundation
import XCTest
@testable import PopopxMacNode

/// Satisfies `NodeConsoleFacade` without a node behind it. Nothing on the bind path
/// reads the facade, so a stub that answers nothing is the honest shape here.
private struct NoTrafficFacade: NodeConsoleFacade {
    func snapshot() async -> ConsoleSnapshot { fatalError("binding does not consult the node") }
    func events() -> AsyncStream<ConsoleEvent> { AsyncStream { $0.finish() } }
    func startInstall() async {}
    func cancelInstall() async {}
    func setEngineEnabled(_ kind: EngineKind, enabled: Bool) async {}
    func rotatePairing() async -> PairingOffer? { nil }
    func pairingQR(pixelSize: Int) async -> QRAsset? { nil }
    func revokePairing(publicKey: String) async {}
    func updateSettings(_ settings: NodeSettings) async -> NodeSettings { settings }
    func submitWireCommand(_ text: String) async -> CommandResult { fatalError("binding does not consult the node") }
    func invokeEngine(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult { fatalError("binding does not consult the node") }
    func openInFinder(path: String) async {}
}

/// A facade whose event stream the test drives by hand, so a frame can be pushed
/// at a chosen moment instead of waiting on the node's own 20-second heartbeat.
private struct PushableFacade: NodeConsoleFacade {
    let stream: AsyncStream<ConsoleEvent>
    let continuation: AsyncStream<ConsoleEvent>.Continuation

    init() {
        let pipe = AsyncStream<ConsoleEvent>.makeStream()
        stream = pipe.stream
        continuation = pipe.continuation
    }

    func events() -> AsyncStream<ConsoleEvent> { stream }
    func snapshot() async -> ConsoleSnapshot { fatalError("the event route does not read the snapshot") }
    func startInstall() async {}
    func cancelInstall() async {}
    func setEngineEnabled(_ kind: EngineKind, enabled: Bool) async {}
    func rotatePairing() async -> PairingOffer? { nil }
    func pairingQR(pixelSize: Int) async -> QRAsset? { nil }
    func revokePairing(publicKey: String) async {}
    func updateSettings(_ settings: NodeSettings) async -> NodeSettings { settings }
    func submitWireCommand(_ text: String) async -> CommandResult { fatalError("the event route does not run commands") }
    func invokeEngine(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult { fatalError("the event route does not run engines") }
    func openInFinder(path: String) async {}
}

/// A raw loopback HTTP/1.1 client.
///
/// `URLSession` is the wrong instrument for these cases: it pools sockets,
/// follows the redirect and hides how a reply is framed. What is under test is
/// exactly which bytes reach the wire and when the console hangs up.
private enum WireError: Error { case setup(String) }

private struct WireResponse {
    let status: Int
    let headers: [String: String]
    var body: String = ""
}

private final class WireClient {
    private let descriptor: Int32
    private var buffer = Data()
    private var hungUp = false

    init(port: UInt16) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WireError.setup("socket errno=\(errno)") }
        var budget = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw WireError.setup("inet_pton refused 127.0.0.1")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw WireError.setup("connect to port \(port) errno=\(errno)") }
    }

    func send(_ text: String) throws {
        var pending = Data(text.utf8)
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { raw in Darwin.write(descriptor, raw.baseAddress, raw.count) }
            guard written > 0 else { throw WireError.setup("write errno=\(errno)") }
            pending.removeFirst(written)
        }
    }

    /// The next response, body bytes consumed so the read after this one starts on
    /// a status line. `nil` means the console ended the stream without a reply.
    func respond() -> WireResponse? {
        guard let head = read(until: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: head.dropLast(2), as: UTF8.self).components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/1.1 ") == true,
              let status = Int(lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "")
        else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let taken = consume(Int(headers["content-length"] ?? "0") ?? 0) else { return nil }
        return WireResponse(status: status, headers: headers, body: String(decoding: taken, as: UTF8.self))
    }

    /// The next SSE frame on this socket, or `nil` when the console ended the
    /// stream first. Frames are delimited by the blank line, and a stream has no
    /// `Content-Length`, so this is what proves the pipe is still open.
    func eventFrame() -> String? {
        guard let frame = read(until: Data("\n\n".utf8)) else { return nil }
        return String(decoding: frame.dropLast(2), as: UTF8.self)
    }

    func hangUp() {
        guard !hungUp else { return }
        hungUp = true
        Darwin.close(descriptor)
    }

    private func read(until marker: Data) -> Data? {
        while true {
            if let range = buffer.range(of: marker) {
                let head = Data(buffer[buffer.startIndex..<range.upperBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return head
            }
            guard fill() else { return nil }
        }
    }

    private func consume(_ bytes: Int) -> Data? {
        var taken = Data()
        var remaining = bytes
        while remaining > 0 {
            let chunk = min(remaining, buffer.count)
            taken.append(contentsOf: buffer.prefix(chunk))
            buffer.removeFirst(chunk)
            remaining -= chunk
            if remaining > 0, !fill() { return nil }
        }
        return taken
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8 * 1_024)
        let count = Darwin.read(descriptor, &chunk, chunk.count)
        guard count > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }
}

final class WebConsoleBindTests: XCTestCase {
    func test_consoleReachesReadyOnThePinnedLoopbackPort() async throws {
        let server = LocalWebConsoleServer(facade: NoTrafficFacade(), port: 18997)
        do {
            try await server.start()
        } catch {
            let failure = error as NSError
            XCTFail("the console refused to bind: \(failure.domain)/\(failure.code) \(error.localizedDescription)")
            return
        }
        let listening = await server.isListening
        let bound = await server.boundConsolePort
        await server.stop()

        XCTAssertTrue(listening, "start() returned without a ready listener")
        XCTAssertEqual(bound, 18997, "the listener answered on a port other than the pinned one")
    }

    func test_stopReturnsPromptlyOnAConsoleThatNeverStarted() async {
        // The menu bar's Quit awaits this on the way out. A stop that blocks on
        // teardown that never happened is a process that cannot be quit.
        let server = LocalWebConsoleServer(facade: NoTrafficFacade(), port: 18998)
        let began = Date()
        await server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "stop() stalled on a console that never bound")
    }

    func test_everyRequestOnItsOwnSocketIsAnswered() async throws {
        // Binding is not the same as replying, and replying once is not the same as
        // still being reachable. Two ways this went wrong: the reply was written and
        // the socket cancelled in the same breath, and `NWConnection.cancel`
        // discards bytes the kernel has not taken yet; and
        // `NWListener.newConnectionLimit` counts every socket it has ever handed
        // out, so a listener set to 64 stopped accepting at its 64th connection for
        // the rest of the process's life. So this asks many times, on many sockets.
        let server = LocalWebConsoleServer(facade: NoTrafficFacade(), port: 18999)
        try await server.start()
        var silent: [Int] = []
        for attempt in 1...70 {
            let client = try WireClient(port: 18999)
            try client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:18999\r\nConnection: close\r\n\r\n")
            if client.respond() == nil { silent.append(attempt) }
            client.hangUp()
        }
        await server.stop()

        XCTAssertEqual(silent, [], "these requests reached the node but never left it")
    }

    func test_oneKeepAliveSocketCarriesEveryRequest() async throws {
        // A browser keeps one socket for the page, its assets and its API calls, and
        // the writer used to allow exactly one response per socket and refuse the
        // rest, so request two onward was answered with nothing.
        let server = LocalWebConsoleServer(facade: NoTrafficFacade(), port: 19001)
        try await server.start()
        let client = try WireClient(port: 19001)
        var statuses: [Int] = []
        var framed: [Bool] = []
        for _ in 1...3 {
            try client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:19001\r\nConnection: keep-alive\r\n\r\n")
            guard let response = client.respond() else { break }
            statuses.append(response.status)
            framed.append(response.headers["content-length"] != nil)
        }
        client.hangUp()
        await server.stop()

        XCTAssertEqual(statuses, [302, 302, 302], "a keep-alive socket stopped being answered")
        XCTAssertEqual(framed, [true, true, true], "a body without Content-Length cannot be framed")
    }

    func test_eventStreamStaysOpenAndCarriesFrames() async throws {
        // A console that answers requests can still have a dead live channel. The
        // read pump used to fall into `teardown()` the moment a socket became an
        // event pipe, which cancelled the channel `openEvents` had just built: the
        // browser received the `retry:` preamble, then an end of stream, and the
        // page reported 「实时通道已中断」 while `/api/health` still answered 200.
        // So the stream is held open here and pushed two frames through it, because
        // a preamble that arrives on a socket that is then closed proves nothing.
        let facade = PushableFacade()
        let server = LocalWebConsoleServer(facade: facade, port: 19003)
        try await server.start()
        let client = try WireClient(port: 19003)
        let token = await server.token
        try client.send("GET /api/events?t=\(token) HTTP/1.1\r\nHost: 127.0.0.1:19003\r\nAccept: text/event-stream\r\n\r\n")

        guard let head = client.respond() else {
            XCTFail("the event route never answered")
            client.hangUp()
            await server.stop()
            return
        }
        XCTAssertEqual(head.status, 200, "the event route is not a redirect and not a refusal")
        XCTAssertTrue(head.headers["content-type"]?.contains("text/event-stream") == true,
                      "a stream the browser is not told about is a stream it will not follow")
        let preamble = client.eventFrame()
        facade.continuation.yield(ConsoleEvent(channel: .system, message: "the pipe is still open"))
        let first = client.eventFrame()
        facade.continuation.yield(ConsoleEvent(channel: .engine, message: "and it carries more than one frame"))
        let second = client.eventFrame()
        // `streamCount` is the number `/api/health` prints as `viewers`, and it is
        // also what the per-socket cap releases from, so a stream that opens without
        // being registered is a stream that costs a socket forever.
        let watching = await server.streamCount
        // Reclaiming the slot: the next frame written to a socket whose reader has
        // gone is what fails, and that failure is what frees the channel. A node
        // with nothing to say notices only on its 20-second heartbeat, so the loop
        // keeps pushing until it does.
        client.hangUp()
        var released = -1
        for attempt in 0..<40 {
            released = await server.streamCount
            if released == 0 { break }
            facade.continuation.yield(ConsoleEvent(channel: .system, message: "reclaim probe \(attempt)"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await server.stop()

        XCTAssertEqual(preamble, "retry: 3000", "a preamble is the whole stream once the pump tears it down")
        XCTAssertTrue(first?.hasPrefix("event: system") == true, "the pushed event never left the node")
        XCTAssertTrue(first?.contains("the pipe is still open") == true, "the frame reached the socket without its message")
        XCTAssertTrue(second?.hasPrefix("event: engine") == true,
                      "a stream that delivered one frame is not yet a stream that stays open")
        XCTAssertEqual(watching, 1, "the stream that delivered frames was not counted as a viewer")
        XCTAssertEqual(released, 0, "a viewer that hung up left its channel behind, and the socket cap counts from there")
    }
}

// MARK: - The console decision route

/// Records the `domain / id / verb` triples the console forwards, which is the whole
/// contract of `/api/privacy/decision`: the page names a proposal and the node decides
/// what that names.
private final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var status = 200
    var message = "已执行 / applied"

    func note(domain: String, id: String, verb: String) {
        lock.lock(); seen.append("\(domain)|\(id)|\(verb)"); lock.unlock()
    }

    var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

private struct PrivacyConsoleFacade: NodeConsoleFacade {
    let box: DecisionBox

    func snapshot() async -> ConsoleSnapshot { PrivacyConsoleFacade.stubSnapshot() }
    func events() -> AsyncStream<ConsoleEvent> { AsyncStream { $0.finish() } }

    func privacyDecision(domain: String, id: String, verb: String) async -> PrivacyToolResponse {
        box.note(domain: domain, id: id, verb: verb)
        return PrivacyToolResponse(ok: box.status == 200, status: box.status,
                                   fields: ["message": .string(box.message)])
    }

    func startInstall() async {}
    func cancelInstall() async {}
    func setEngineEnabled(_ kind: EngineKind, enabled: Bool) async {}
    func rotatePairing() async -> PairingOffer? { nil }
    func pairingQR(pixelSize: Int) async -> QRAsset? { nil }
    func revokePairing(publicKey: String) async {}
    func updateSettings(_ settings: NodeSettings) async -> NodeSettings { settings }
    func submitWireCommand(_ text: String) async -> CommandResult {
        fatalError("the decision route does not run commands")
    }
    func invokeEngine(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult {
        fatalError("the decision route does not run engines")
    }
    func openInFinder(path: String) async {}

    static func stubSnapshot() -> ConsoleSnapshot {
        let profile = MacHardwareProfile(
            chipName: "M4 Pro", modelIdentifier: "Mac16,7", cpuArchitecture: "arm64",
            logicalCPUCount: 14, physicalCPUCount: 14, performanceCoreCount: 10,
            efficiencyCoreCount: 4, memoryTotal: ByteCount(48 * 1024 * 1024 * 1024),
            freeDisk: ByteCount(512 * 1024 * 1024 * 1024),
            totalDisk: ByteCount(1024 * 1024 * 1024 * 1024),
            systemVolumeName: "Macintosh HD",
            operatingSystem: "macOS 26.1", kernelVersion: "27.0.0", serialMasked: "•••••••4"
        )
        return ConsoleSnapshot(
            node: NodeIdentity(nodeId: "test-node", publicKey: "test-key", displayName: "Test Node"),
            hardware: profile,
            plan: ModelPlan.recommend(for: profile),
            load: SystemLoad(cpuLoadPercent: 12, memoryUsed: ByteCount(8 * 1024 * 1024 * 1024),
                             memoryPressure: .nominal, activeProcessCount: 240),
            toolchain: [],
            install: InstallState(),
            bridge: BridgeStatus(daemon: .running),
            pairing: nil,
            pairedDevices: [],
            descriptors: [],
            engines: [],
            settings: NodeSettings(),
            mesh: MeshSummary(),
            recentResults: [],
            lockdowns: [],
            vaults: [],
            consoleURL: "http://127.0.0.1:18920/"
        )
    }
}

extension WebConsoleBindTests {
    /// One console, one request, one reply. `token: nil` sends the request without a
    /// bearer, which is the case that must never reach the ledger.
    private func post(port: UInt16, path: String, body: String, token: String?) -> WireResponse? {
        guard let client = try? WireClient(port: port) else { return nil }
        defer { client.hangUp() }
        var request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { request += "\(NodeWire.consoleTokenHeader): \(token)\r\n" }
        request += "Connection: close\r\n\r\n\(body)"
        guard (try? client.send(request)) != nil else { return nil }
        return client.respond()
    }

    private func request(port: UInt16, method: String, path: String, token: String?) -> WireResponse? {
        guard let client = try? WireClient(port: port) else { return nil }
        defer { client.hangUp() }
        var line = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        if let token { line += "\(NodeWire.consoleTokenHeader): \(token)\r\n" }
        line += "Connection: close\r\n\r\n"
        guard (try? client.send(line)) != nil else { return nil }
        return client.respond()
    }

    func test_privacyDecisionNeedsTheBearerToken() async throws {
        let box = DecisionBox()
        let server = LocalWebConsoleServer(facade: PrivacyConsoleFacade(box: box), port: 19007)
        try await server.start()
        let token = await server.token
        let anonymous = post(port: 19007, path: ConsoleRoute.privacyDecision,
                             body: "{\"domain\":\"calendar\",\"id\":\"ppx-pr-1\",\"verb\":\"approve\"}",
                             token: nil)
        let wrong = post(port: 19007, path: ConsoleRoute.privacyDecision,
                         body: "{\"domain\":\"calendar\",\"id\":\"ppx-pr-1\",\"verb\":\"approve\"}",
                         token: token + "deadbeef")
        await server.stop()

        XCTAssertEqual(anonymous?.status, 401, "an unauthenticated loopback call is not the operator")
        XCTAssertEqual(wrong?.status, 401, "a near-miss token must fail the same way")
        XCTAssertEqual(box.all, [], "a refused call must not have reached the node at all")
    }

    func test_privacyDecisionAnswersNothingToGET() async throws {
        let box = DecisionBox()
        let server = LocalWebConsoleServer(facade: PrivacyConsoleFacade(box: box), port: 19008)
        try await server.start()
        let token = await server.token
        let got = request(port: 19008, method: "GET", path: ConsoleRoute.privacyDecision, token: token)
        let preflight = request(port: 19008, method: "OPTIONS", path: ConsoleRoute.privacyDecision, token: token)
        await server.stop()

        XCTAssertEqual(got?.status, 405, "a decision is a write; a navigation must not perform one")
        XCTAssertEqual(preflight?.status, 405, "another document's preflight is not an approval")
        XCTAssertEqual(box.all, [])
    }

    func test_privacyDecisionRefusesEveryMalformedTriple() async throws {
        let box = DecisionBox()
        let server = LocalWebConsoleServer(facade: PrivacyConsoleFacade(box: box), port: 19009)
        try await server.start()
        let token = await server.token
        // Each of these is a value the page cannot produce, so a caller that sends one
        // is not the page: an id that could traverse, a verb that is not approve or
        // reject, a namespace the ledger has no table for, and a body missing a field.
        let bodies = [
            "{\"domain\":\"calendar\",\"id\":\"../../etc/passwd\",\"verb\":\"approve\"}",
            "{\"domain\":\"calendar\",\"id\":\"ppx-pr-1\",\"verb\":\"delete\"}",
            "{\"domain\":\"secrets\",\"id\":\"ppx-pr-1\",\"verb\":\"approve\"}",
            "{\"domain\":\"calendar\",\"verb\":\"approve\"}",
            "{\"domain\":\"calendar\",\"id\":\"\",\"verb\":\"approve\"}",
            "not json"
        ]
        var statuses: [Int] = []
        for body in bodies {
            statuses.append(post(port: 19009, path: ConsoleRoute.privacyDecision,
                                 body: body, token: token)?.status ?? 0)
        }
        await server.stop()

        XCTAssertEqual(statuses, [Int](repeating: 400, count: bodies.count),
                       "a malformed triple must be refused before the node is asked, got \(statuses)")
        XCTAssertEqual(box.all, [], "nothing malformed reached the ledger")
    }

    func test_privacyDecisionForwardsThePagesTripleAndRefreshesThePanel() async throws {
        let box = DecisionBox()
        let server = LocalWebConsoleServer(facade: PrivacyConsoleFacade(box: box), port: 19010)
        try await server.start()
        let token = await server.token
        let accepted = post(port: 19010, path: ConsoleRoute.privacyDecision,
                            body: "{\"domain\":\"calendar\",\"id\":\"ppx-pr-7\",\"verb\":\"approve\"}",
                            token: token)
        box.status = 409
        box.message = "提案已过期（15 分钟）/ proposal expired"
        let stale = post(port: 19010, path: ConsoleRoute.privacyDecision,
                         body: "{\"domain\":\"workspace\",\"id\":\"ppx-pr-8\",\"verb\":\"reject\"}",
                         token: token)
        await server.stop()

        // The route's job is the triple and nothing else: the receipt the ledger
        // demands is minted inside the node, so it is absent from this request body.
        XCTAssertEqual(box.all, ["calendar|ppx-pr-7|approve", "workspace|ppx-pr-8|reject"])
        XCTAssertEqual(accepted?.status, 200)
        XCTAssertTrue(accepted?.body.contains("已执行") == true,
                      "the panel paints this string, got \(accepted?.body ?? "nil")")
        XCTAssertTrue(accepted?.body.contains("\"privacy\"") == true,
                      "the reply must carry a fresh snapshot or the panel keeps a spent card on screen")
        XCTAssertEqual(stale?.status, 200, "a refused decision is still an answered request")
        XCTAssertTrue(stale?.body.contains("\"status\":409") == true,
                      "the engine's verdict travels in `status` so the panel can tell 409 from 403: \(stale?.body ?? "nil")")
    }
}

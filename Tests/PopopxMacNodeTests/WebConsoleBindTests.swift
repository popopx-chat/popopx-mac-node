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

/// A raw loopback HTTP/1.1 client.
///
/// `URLSession` is the wrong instrument for these cases: it pools sockets,
/// follows the redirect and hides how a reply is framed. What is under test is
/// exactly which bytes reach the wire and when the console hangs up.
private enum WireError: Error { case setup(String) }

private struct WireResponse {
    let status: Int
    let headers: [String: String]
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
        guard consume(Int(headers["content-length"] ?? "0") ?? 0) else { return nil }
        return WireResponse(status: status, headers: headers)
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

    private func consume(_ bytes: Int) -> Bool {
        var remaining = bytes
        while remaining > 0 {
            let taken = min(remaining, buffer.count)
            buffer.removeFirst(taken)
            remaining -= taken
            if remaining > 0, !fill() { return false }
        }
        return true
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
}

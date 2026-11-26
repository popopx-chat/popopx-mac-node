//
//  MCPLinks.swift
//  PopopxMacNode — the two transports an MCP server can arrive on.
//
//  `stdio` and loopback HTTP, both reduced to the same `MCPLink` (one JSON-RPC document
//  out, one document in) so that `MCPClient` has one protocol conversation to get right.
//  The security-relevant checks are repeated at this boundary on purpose:
//
//  * `MCPStdioLink` launches nothing that is not an absolute path inside the operator's
//    `allowedCommands`, free of shell metacharacters, and reported executable by the
//    filesystem. There is no `/bin/sh -c` in this file and there must never be — that one
//    argument shape would turn the node into a general-purpose command runner with a chat
//    interface bolted on.
//  * `MCPHTTPLink` re-runs `EdgeBoundary` on the URL at the moment the request is built,
//    and its session refuses every redirect. A loopback endpoint answering `302 →
//    203.0.113.9` would otherwise be a public connection made *by this node*, carrying its
//    own session id.
//
//  Both are `final class … @unchecked Sendable` with one `NSLock` owning the mutable state:
//  a `Process` handoff and a `URLSession` completion do not arrive on cooperative threads,
//  and `DispatchQueue.sync` cannot propagate a throw, which this API has to do. Every access
//  goes through `syncing(_:)` — `NSLock.lock()` is unavailable from an asynchronous context,
//  and routing through a synchronous helper keeps each section short and never spanning an
//  `await`.
//

import Foundation

// MARK: - stdio

public final class MCPStdioLink: MCPLink, @unchecked Sendable {
    public let serverID: String

    /// Stderr is kept for the console's diagnostic row and bounded: a server that prints a
    /// megabyte of startup noise must not grow the node's memory or an audit row.
    public static let maximumStderrCharacters = 2_000

    private let launchPath: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timerQueue = DispatchQueue(label: "im.popopx.macnode.mcp.stdio.timeout")

    private let lock = NSLock()
    private var process: Process?
    private var childInput: Pipe?
    private var childOutput: Pipe?
    private var childError: Pipe?
    private var buffered = Data()
    private var lines: [String] = []
    private var waiters: [PendingRead] = []
    private var closed = false
    private var stderrTail = ""

    /// One queued read, resumable exactly once: `settled` is what stops the deadline work
    /// item and a late-arriving line from both resuming the same continuation.
    private final class PendingRead {
        let continuation: CheckedContinuation<String?, Error>
        var work: DispatchWorkItem?
        var settled = false

        init(_ continuation: CheckedContinuation<String?, Error>) {
            self.continuation = continuation
        }

        func settle(_ body: () -> Void) {
            guard !settled else { return }
            settled = true
            work?.cancel()
            work = nil
            body()
        }
    }

    /// Builds a link from a config entry plus the operator's allow-list.
    ///
    /// The list is a parameter rather than a lookup, so this type has no opinion about where
    /// the document came from — and so a test can prove that an entry naming `/bin/sh` is
    /// refused without any file being read or process being spawned.
    public init?(spec: MCPServerConfig, allowedCommands: [String]) {
        guard spec.acceptance(inside: allowedCommands) == nil else { return nil }
        // `Shell.which` answers nil unless the filesystem reports the path executable, and
        // a resolved path that differs from the configured one would mean the allow-list
        // named a program and PATH found somebody else's copy of it.
        guard let resolved = Shell.which(spec.command), resolved == spec.command else { return nil }
        self.serverID = spec.id
        self.launchPath = resolved
        self.arguments = spec.arguments
        // Only the names the entry lists are forwarded. A child would otherwise inherit the
        // whole node environment, which carries the relay's material — handing that to a
        // third-party subprocess is not what "register an MCP server" means.
        let host = Shell.augmentedEnvironment
        var environment: [String: String] = [:]
        for name in ["PATH", "HOME", "LANG", "TMPDIR"] where host[name] != nil { environment[name] = host[name] }
        for name in spec.environmentNames where host[name] != nil { environment[name] = host[name] }
        self.environment = environment
    }

    public func start(timeout: TimeInterval) async throws {
        let state: (started: Bool, closed: Bool) = syncing { (self.process != nil, self.closed) }
        guard !state.started else { throw HubLinkError.alreadyConnected }
        guard !state.closed else { throw HubLinkError.peerClosed }
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw HubLinkError.invalidTarget(launchPath)
        }

        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        child.executableURL = URL(fileURLWithPath: launchPath)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { self.markClosed(); return }
            self.ingest(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.absorbStderr(String(decoding: data, as: UTF8.self))
        }
        child.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            self?.noteExit(finished)
        }

        do {
            try child.run()
        } catch {
            throw HubLinkError.connectFailed(String(describing: error))
        }
        syncing {
            self.process = child
            self.childInput = input
            self.childOutput = output
            self.childError = errors
        }
    }

    public func writeLine(_ line: String) async throws {
        let state: (closed: Bool, running: Bool, handle: FileHandle?) = syncing {
            (self.closed, self.process?.isRunning ?? false, self.childInput?.fileHandleForWriting)
        }
        guard !state.closed, state.running, let handle = state.handle else {
            throw state.closed ? HubLinkError.peerClosed : HubLinkError.notConnected
        }
        do {
            // Writing to a child that has already exited raises here rather than killing the
            // node with SIGPIPE, and the reader side needs to know the bridge is over.
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            markClosed()
            throw HubLinkError.writeFailed(String(describing: error))
        }
    }

    public func readLine(timeout: TimeInterval) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            let waiter = PendingRead(continuation)
            let armed: DispatchWorkItem? = syncing {
                if !self.lines.isEmpty {
                    continuation.resume(returning: self.lines.removeFirst())
                    return nil
                }
                if self.closed {
                    continuation.resume(returning: nil)
                    return nil
                }
                let work = DispatchWorkItem { [weak self, weak waiter] in
                    guard let self, let waiter else { return }
                    self.expire(waiter, after: timeout)
                }
                waiter.work = work
                self.waiters.append(waiter)
                return work
            }
            // Scheduled outside the lock: the deadline cannot be reached while it is held, and
            // a work item that fires before this returns is already recorded as settled.
            if let armed { timerQueue.asyncAfter(deadline: .now() + timeout, execute: armed) }
        }
    }

    public func finish() async {
        let torn: (process: Process?, input: Pipe?, output: Pipe?, errors: Pipe?, waiting: [PendingRead], firstClose: Bool) = syncing {
            let value = (self.process, self.childInput, self.childOutput, self.childError, self.waiters, !self.closed)
            self.closed = true
            self.process = nil
            self.childInput = nil
            self.childOutput = nil
            self.childError = nil
            self.waiters.removeAll()
            return value
        }
        // The pipes out of the child, not `torn.process.standardOutput`: that property is
        // typed `Any`, and reaching through it would silently do nothing should the assignment
        // ever change. Clearing the handlers stops the reader callbacks outliving the link.
        torn.output?.fileHandleForReading.readabilityHandler = nil
        torn.errors?.fileHandleForReading.readabilityHandler = nil
        torn.input?.fileHandleForWriting.closeFile()
        for waiter in torn.waiting {
            waiter.settle { waiter.continuation.resume(returning: nil) }
        }
        guard torn.firstClose, let running = torn.process, running.isRunning else { return }
        running.terminate()
    }

    /// The child's last stderr, for the console row. Never for a wire message.
    public var diagnostics: String { syncing { stderrTail } }

    // MARK: Stream plumbing

    private func ingest(_ data: Data) {
        syncing {
            self.buffered.append(data)
            while let newline = self.buffered.firstIndex(of: 0x0A) {
                let slice = self.buffered[self.buffered.startIndex..<newline]
                self.buffered.removeSubrange(self.buffered.startIndex...newline)
                let text = String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                // Blank lines between messages are legal framing, not documents.
                if !text.isEmpty { self.lines.append(text) }
            }
            self.drainLocked()
        }
    }

    private func markClosed() {
        syncing {
            guard !self.closed else { return }
            self.closed = true
            self.drainLocked()
        }
    }

    private func noteExit(_ running: Process) {
        let status: (code: Int32, signalled: Bool) = syncing {
            if self.process === running { self.process = nil }
            self.closed = true
            self.drainLocked()
            return (running.terminationStatus, running.terminationReason == .uncaughtSignal)
        }
        // Recorded, not surfaced: an exit code belongs on the console's status line, and a
        // signal-killed server is a fact the owner should see rather than a stack trace.
        if status.code != 0 || status.signalled {
            absorbStderr("\nexit \(status.code) (\(status.signalled ? "signal" : "exit"))")
        }
    }

    /// Satisfies queued readers from the buffer, in arrival order. A reader stays queued only
    /// while the buffer is empty and the pipe is still open. Called with the lock held.
    private func drainLocked() {
        while !waiters.isEmpty {
            let waiter = waiters[0]
            if !lines.isEmpty {
                let line = lines.removeFirst()
                waiters.removeFirst()
                waiter.settle { waiter.continuation.resume(returning: line) }
                continue
            }
            if closed {
                waiters.removeFirst()
                waiter.settle { waiter.continuation.resume(returning: nil) }
                continue
            }
            break
        }
    }

    private func expire(_ waiter: PendingRead, after timeout: TimeInterval) {
        let found: Bool = syncing {
            guard let index = self.waiters.firstIndex(where: { $0 === waiter }) else { return false }
            self.waiters.remove(at: index)
            return true
        }
        guard found else { return }
        waiter.settle { waiter.continuation.resume(throwing: HubLinkError.timedOut(timeout)) }
    }

    private func absorbStderr(_ text: String) {
        syncing {
            self.stderrTail = String((self.stderrTail + text).suffix(Self.maximumStderrCharacters))
        }
    }

    private func syncing<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Loopback HTTP

/// The MCP *streamable HTTP* transport, restricted to loopback.
///
/// One outbound document per `POST`; the answer comes back either as a JSON body or as an
/// SSE body whose `data:` lines are the messages. A server may answer a notification with
/// `202 Accepted` and no body, so a request is only sent when the client actually needs an
/// answer — which is exactly how `MCPClient.exchange` drives this link.
public final class MCPHTTPLink: MCPLink, @unchecked Sendable {
    public let serverID: String

    private let endpoint: EdgeEndpoint
    /// The path the operator configured (`/mcp` on most servers). It is held apart from the
    /// endpoint because `EdgeEndpoint` deliberately carries no path: the allow-list decision
    /// is about the host, and a path field would suggest the guard reads one.
    private let path: String
    private let timeout: TimeInterval
    private let session: URLSession

    /// The full URL this link posts to — a property, so the guard and the request cannot
    /// disagree about which address was admitted.
    public var requestURL: String { endpoint.origin + path }

    private let lock = NSLock()
    private var outbound: [String] = []
    private var inbound: [String] = []
    private var sessionID = ""
    private var lastStatus = 0
    private var closed = false

    public init?(spec: MCPServerConfig, timeout: TimeInterval = 20, delegate: URLSessionTaskDelegate? = nil) {
        guard spec.transport == .http,
              let endpoint = try? EdgeBoundary.resolve(url: spec.url, policy: .loopbackOnly),
              let components = URLComponents(string: spec.url)
        else { return nil }
        self.serverID = spec.id
        self.endpoint = endpoint
        self.path = components.path.isEmpty ? "/mcp" : components.path
        self.timeout = timeout
        // An injected delegate lets a test observe the redirect refusal itself rather than
        // trusting the comment on it.
        self.session = HubHTTP.session(timeout: timeout, delegate: delegate)
    }

    public func start(timeout: TimeInterval) async throws {
        // Re-admitted at the request boundary, the way the MQTT stream re-asserts its host
        // class: the config was allowed once, and building a request is not an exception.
        guard EdgeBoundary.isAllowed(requestURL, policy: .loopbackOnly) else {
            throw HubLinkError.invalidTarget(requestURL)
        }
        let isClosed: Bool = syncing { self.closed }
        guard !isClosed else { throw HubLinkError.peerClosed }
    }

    public func writeLine(_ line: String) async throws {
        let isClosed: Bool = syncing {
            guard !self.closed else { return true }
            self.outbound.append(line)
            return false
        }
        if isClosed { throw HubLinkError.peerClosed }
    }

    public func readLine(timeout: TimeInterval) async throws -> String? {
        let staged: (next: String?, document: String?, closed: Bool) = syncing {
            if !self.inbound.isEmpty { return (self.inbound.removeFirst(), nil, self.closed) }
            let document = self.outbound.isEmpty ? nil : self.outbound.removeFirst()
            return (nil, document, self.closed)
        }
        if let next = staged.next { return next }
        guard let document = staged.document else {
            throw staged.closed ? HubLinkError.peerClosed : HubLinkError.invalidTarget("read with nothing to send")
        }
        let reply = try await post(document)
        return syncing {
            self.inbound.append(contentsOf: reply)
            return self.inbound.isEmpty ? nil : self.inbound.removeFirst()
        }
    }

    public func finish() async {
        syncing {
            self.closed = true
            self.outbound.removeAll()
            self.inbound.removeAll()
        }
        session.finishTasksAndInvalidate()
    }

    public var diagnostics: String { syncing { "last status \(lastStatus)" } }

    private func post(_ document: String) async throws -> [String] {
        guard EdgeBoundary.isAllowed(requestURL, policy: .loopbackOnly), let target = URL(string: requestURL) else {
            throw HubLinkError.invalidTarget(requestURL)
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = Data(document.utf8)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPProtocol.clientVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let carried: String = syncing { self.sessionID }
        if !carried.isEmpty { request.setValue(carried, forHTTPHeaderField: "Mcp-Session-Id") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HubLinkError.readFailed(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw HubLinkError.readFailed("response was not HTTP")
        }
        let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? ""
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let status = http.statusCode
        syncing {
            self.lastStatus = status
            if !issued.isEmpty { self.sessionID = issued }
        }
        guard (200..<300).contains(status) else {
            throw HubLinkError.readFailed("HTTP \(status) from \(endpoint.origin)")
        }
        if status == 202 || data.isEmpty { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return type.contains("text/event-stream") ? Self.eventStreamData(text) : [text]
    }

    /// The `data:` payload of an SSE body, one JSON-RPC document per event.
    public static func eventStreamData(_ text: String) -> [String] {
        var events: [String] = []
        var current: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                if !current.isEmpty {
                    events.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
                continue
            }
            // `event:` and `id:` name the message; only `data:` carries it.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
            current.append(payload.hasPrefix(" ") ? String(payload.dropFirst()) : String(payload))
        }
        if !current.isEmpty { events.append(current.joined(separator: "\n")) }
        return events.filter { !$0.isEmpty }
    }

    private func syncing<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

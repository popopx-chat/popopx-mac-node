//
//  MCPClient.swift
//  PopopxMacNode — the JSON-RPC 2.0 conversation with one MCP server.
//
//  This is the whole MCP *protocol*: `initialize` → `notifications/initialized` →
//  `tools/list` → `tools/call`. It speaks through an `MCPLink` (HubLinks.swift) and knows
//  nothing about whether that link is a child process's stdin or a loopback HTTP endpoint.
//  That separation is what makes the three security properties of this feature testable
//  without spawning anything:
//
//  * a reply is only accepted when its `id` matches the request that is owed, so a server
//    cannot answer a call the node never made;
//  * notifications and server-initiated requests are skipped, not mistaken for answers,
//    and the skip is bounded so a chatty server cannot hang the client;
//  * the safety tier of a tool is decided by `MCPTool.safety` — default-deny — *before*
//    `call` runs, and a `.mutating` tool is refused here rather than sent, because the
//    bridge above this class is the one that knows how to open a proposal.
//

import Foundation

public actor MCPClient {
    public static let maximumTools = 128
    public static let maximumPages = 8
    /// How many non-answer messages may be skipped while an answer is owed. A well-behaved
    /// server sends none; this bounds the damage from one that sends a stream of progress
    /// notifications instead of a reply.
    public static let maximumIgnoredMessages = 64

    public let serverID: String
    private let link: MCPLink
    private let timeout: TimeInterval

    private var nextRequestID = 1
    private var serverInfo: MCPServerInfo?
    private var cachedTools: [MCPTool]?
    private var lastError: String = ""
    private var connected = false

    public init(serverID: String, link: MCPLink, timeout: TimeInterval = 20) {
        self.serverID = serverID
        self.link = link
        self.timeout = timeout
    }

    public var isConnected: Bool { connected }
    public var info: MCPServerInfo? { serverInfo }
    /// The reason the last handshake or call failed, for the console's status row. Kept as
    /// a string because it is display text, and every producer of it is already bilingual.
    public var failureReason: String { lastError }

    // MARK: - Lifecycle

    /// Handshakes and marks the session ready. Safe to call twice; the second call is a
    /// no-op, because the console polls and a poll must not re-spawn a child process.
    public func connect() async -> Bool {
        if connected { return true }
        do {
            try await link.start(timeout: timeout)
            let request = MCPRequest.initialize(id: allocateID())
            let answer = try await exchange(request)
            let info = MCPServerInfo.parse(answer)
            self.serverInfo = info
            try await link.writeLine(MCPNotification.initialized.line)
            connected = true
            lastError = ""
            return true
        } catch {
            lastError = String(describing: error)
            await link.finish()
            connected = false
            return false
        }
    }

    public func shutdown() async {
        connected = false
        cachedTools = nil
        await link.finish()
    }

    // MARK: - Tools

    /// Every tool the server lists, following `nextCursor` up to `maximumPages`.
    ///
    /// The result is cached for the life of the client: `tools/list` is the one call whose
    /// answer decides whether a later `tools/call` needs a human, and re-listing on every
    /// call would let a server answer "read-only" on the listing and mutate on the call.
    /// Caching also keeps a console poll from forking a new child process per refresh.
    public func tools(forceRefresh: Bool = false) async -> [MCPTool] {
        if let cached = cachedTools, !forceRefresh { return cached }
        if !connected, !(await connect()) { return cachedTools ?? [] }
        var collected: [MCPTool] = []
        var cursor = ""
        for _ in 0..<Self.maximumPages {
            let request = MCPRequest.toolsList(id: allocateID(), cursor: cursor)
            do {
                let answer = try await exchange(request)
                let fields = answer.objectValue ?? [:]
                let listed = (fields["tools"]?.arrayValue ?? []).compactMap { MCPTool.parse($0) }
                collected.append(contentsOf: listed)
                cursor = fields["nextCursor"]?.stringValue ?? ""
                if cursor.isEmpty || collected.count >= Self.maximumTools { break }
            } catch {
                lastError = String(describing: error)
                break
            }
        }
        cachedTools = Array(collected.prefix(Self.maximumTools))
        return cachedTools ?? []
    }

    public func tool(named name: String) async -> MCPTool? {
        await tools().first { $0.name == name }
    }

    /// The tier a call will be measured against, without listing twice.
    public func safety(for name: String) async -> MCPToolSafety {
        guard let tool = await tool(named: name) else {
            // An unknown tool is not a read-only tool. Refusing to guess is the whole
            // design of `MCPTool.safety`, and a name the server never listed is the
            // likeliest place for a forged call to arrive.
            return .mutating
        }
        return tool.safety
    }

    // MARK: - Calling

    /// Executes a tool. **Callers must check `safety(for:)` first and route a `.mutating`
    /// tool through the proposal ledger instead of calling this.** The guard below is
    /// defence in depth for the case where a caller forgets: `allowMutating` is a parameter
    /// that only the ledger's executor passes, after a 「批准」.
    public func call(
        name: String,
        arguments: [String: JSONValue],
        allowMutating: Bool = false
    ) async -> Result<MCPToolResult, MCPRpcError> {
        if !allowMutating, await safety(for: name) == .mutating {
            return .failure(.invalidResponse("tool \(name) is not read-only; it requires an approved proposal"))
        }
        return await performCall(name: name, arguments: arguments)
    }

    /// The ungated form, for the executor only.
    public func performCall(name: String, arguments: [String: JSONValue]) async -> Result<MCPToolResult, MCPRpcError> {
        if !connected, !(await connect()) {
            return .failure(.invalidResponse(lastError.isEmpty ? "link unavailable" : lastError))
        }
        let request = MCPRequest.toolsCall(id: allocateID(), name: name, arguments: arguments)
        do {
            let answer = try await exchange(request)
            return .success(MCPToolResult.parse(answer))
        } catch let error as MCPRpcError {
            lastError = error.description
            return .failure(error)
        } catch {
            lastError = String(describing: error)
            return .failure(.malformed(String(describing: error)))
        }
    }

    // MARK: - Framing

    private func allocateID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    /// Writes one request and returns its answer, skipping everything that is not it.
    private func exchange(_ request: MCPRequest) async throws -> JSONValue {
        try await link.writeLine(request.line)
        var ignored = 0
        while true {
            guard let line = try await link.readLine(timeout: timeout) else {
                throw MCPRpcError.invalidResponse("stream closed before an answer arrived")
            }
            let document = JSONValue.parse(line)
            guard case .object(let fields) = document else {
                throw MCPRpcError.malformed(String(line.prefix(120)))
            }
            guard let answered = fields["id"], let answeredID = answered.intValue else {
                // A notification, or a server→client request the node does not serve.
                ignored += 1
                if ignored > Self.maximumIgnoredMessages {
                    throw MCPRpcError.invalidResponse("server sent \(ignored) messages without answering id \(request.id)")
                }
                continue
            }
            guard answeredID == request.id else {
                ignored += 1
                if ignored > Self.maximumIgnoredMessages {
                    throw MCPRpcError.mismatchedIdentifier(expected: request.id, found: String(answeredID))
                }
                continue
            }
            return try MCPResponse.parse(document, expecting: request.id).unwrapped().get()
        }
    }
}

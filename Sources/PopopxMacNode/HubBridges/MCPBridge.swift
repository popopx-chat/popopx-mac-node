//
//  MCPBridge.swift
//  PopopxMacNode — the MCP tier that decides between "run it" and "ask the owner".
//
//  `MCPClient` speaks the protocol. This is the part that owns the *policy*, and it is the
//  only place a tool call can be turned into a `pending_user_approval` proposal:
//
//  * The bridge itself must be switched on (`allowMcpBridge`) and the server must be usable
//    (registered, enabled, in the command allow-list, loopback if it is HTTP).
//  * A tool that `MCPTool.safety` reads as `.readOnly` runs immediately, and only if the
//    entry's `allowedTools` permits it — an empty list means "read-only tools only", never
//    "everything".
//  * A `.mutating` tool is **never** executed on the strength of a request. It is turned
//    into a proposal that carries the exact `HubCallPayload` to be run, and the payload is
//    executed only by `executeApproved(_:)`, which the ledger reaches after a receipt-signed
//    「批准」 from the Mac console or the phone card. The console's double-click arming is a
//    UI nicety; this queue is the gate.
//
//  Clients are cached per server for the life of the bridge, because a cached `tools/list`
//  answer is what makes "the tier you were shown is the tier that runs" true — re-listing
//  per call would let a server answer `readOnlyHint: true` to the listing that precedes a
//  proposal and say something different afterwards.
//

import Foundation

/// A bridge-specific second opinion on a tool's tier.
///
/// The contract is one-way: the bridge takes the stricter of this answer and the
/// server's own hint, so a gate can turn a read into a write but never the reverse.
/// It exists because one integration (God's Eye View) has a canvas where `mark_route`
/// is a shared write even when a server advertises it as a harmless operation.
public protocol MCPToolGate: Sendable {
    func effectiveSafety(serverID: String, tool: MCPTool) -> MCPToolSafety
}

/// The console's row for one registered server.
public struct MCPServerCard: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var transport: String
    public var enabled: Bool
    public var connected: Bool
    public var toolCount: Int
    public var readOnlyCount: Int
    public var mutatingCount: Int
    /// Why it is not usable, when it is not. Rendered verbatim, so it must never contain a
    /// path the owner did not type into the config themselves.
    public var reason: String

    public init(
        id: String,
        label: String = "",
        transport: String = "stdio",
        enabled: Bool = false,
        connected: Bool = false,
        toolCount: Int = 0,
        readOnlyCount: Int = 0,
        mutatingCount: Int = 0,
        reason: String = ""
    ) {
        self.id = id
        self.label = label
        self.transport = transport
        self.enabled = enabled
        self.connected = connected
        self.toolCount = toolCount
        self.readOnlyCount = readOnlyCount
        self.mutatingCount = mutatingCount
        self.reason = reason
    }
}

/// The console's row for one tool of one server.
public struct MCPToolCard: Codable, Sendable, Equatable {
    public var serverID: String
    public var name: String
    public var title: String
    public var summary: String
    public var safety: String
    /// Whether calling it will open a 「批准」 card. Shown before the click, because an
    /// owner reading "requires approval" about a tool is the point of the whole feature.
    public var requiresApproval: Bool
    public var permitted: Bool

    public init(
        serverID: String,
        name: String,
        title: String = "",
        summary: String = "",
        safety: String = MCPToolSafety.mutating.rawValue,
        requiresApproval: Bool = true,
        permitted: Bool = false
    ) {
        self.serverID = serverID
        self.name = name
        self.title = title
        self.summary = summary
        self.safety = safety
        self.requiresApproval = requiresApproval
        self.permitted = permitted
    }
}

/// What an invoke request became.
public enum HubCallOutcome: Sendable {
    /// Ran as a read-only call; carries the (already capped) result text.
    case executed(text: String, truncated: Bool)
    /// Queued for the owner. The proposal is the answer, so the caller can show its id.
    case proposed(PrivacyProposal)
    /// Refused, with the reason the console displays.
    case refused(String)
}

public actor MCPBridge {
    public static let maximumArguments = 32
    public static let maximumArgumentDepth = 4

    private let registry: MCPServerRegistry
    private let ledger: PrivacyProposalLedger
    private var config: HubConfig
    /// Optional, and consulted through `effectiveSafety` only. It cannot downgrade a
    /// tool the protocol already called mutating.
    private let toolGate: MCPToolGate?
    /// How a server becomes a channel. Injectable so the whole gate — including the
    /// mutating-tool refusal — is testable without spawning a process or binding a socket.
    private let makeLink: @Sendable (MCPServerConfig, [String]) -> MCPLink?

    private var clients: [String: MCPClient] = [:]
    private var listedTools: [String: [MCPTool]] = [:]
    private var lastFailure = ""

    public init(
        registry: MCPServerRegistry,
        ledger: PrivacyProposalLedger,
        config: HubConfig = .disabled,
        toolGate: MCPToolGate? = nil,
        linkFactory: @escaping @Sendable (MCPServerConfig, [String]) -> MCPLink? = { spec, allowed in
            MCPBridge.defaultLink(spec: spec, allowedCommands: allowed)
        }
    ) {
        self.registry = registry
        self.ledger = ledger
        self.config = config
        self.toolGate = toolGate
        self.makeLink = linkFactory
    }

    /// The production factory: `stdio` for a command, loopback HTTP for a URL.
    public static func defaultLink(spec: MCPServerConfig, allowedCommands: [String]) -> MCPLink? {
        switch spec.transport {
        case .stdio: return MCPStdioLink(spec: spec, allowedCommands: allowedCommands)
        case .http: return MCPHTTPLink(spec: spec)
        }
    }

    public func update(config: HubConfig) {
        self.config = config
        // Flipping the switch away drops every session and every cached tool list: the gate
        // has to be re-decided from a fresh handshake, not from what was remembered.
        if !config.allowMcpBridge {
            for client in clients.values {
                Task { await client.shutdown() }
            }
            clients.removeAll()
            listedTools.removeAll()
        }
    }

    // MARK: - Status

    public func serverCards() async -> [MCPServerCard] {
        let document = await registry.document
        var cards: [MCPServerCard] = []
        for spec in document.servers {
            let rejection = spec.acceptance(inside: document.allowedCommands)
            let client = clients[spec.id]
            let tools = listedTools[spec.id] ?? []
            let mutating = tools.filter { safety(of: $0, serverID: spec.id) == .mutating }.count
            cards.append(MCPServerCard(
                id: spec.id,
                label: spec.displayName,
                transport: spec.transport.rawValue,
                enabled: spec.enabled && config.allowMcpBridge,
                connected: client != nil && !tools.isEmpty,
                toolCount: tools.count,
                readOnlyCount: tools.count - mutating,
                mutatingCount: mutating,
                reason: rejection ?? (spec.enabled ? "" : "已停用 / disabled")
            ))
        }
        return cards
    }

    /// Tools for one server, handshaking if the console asked for them.
    public func toolCards(serverID: String) async -> [MCPToolCard] {
        guard config.allowMcpBridge else { return [] }
        guard let tools = await loadTools(serverID: serverID) else { return [] }
        let allowed = await registry.server(id: serverID)?.allowedTools ?? []
        return tools.map { tool in
            let tier = safety(of: tool, serverID: serverID)
            return MCPToolCard(
                serverID: serverID,
                name: tool.name,
                title: tool.title.isEmpty ? tool.name : tool.title,
                summary: String(tool.description.prefix(160)),
                safety: tier.rawValue,
                requiresApproval: tier == .mutating,
                permitted: Self.permits(tool: tool, allowed: allowed, safety: tier)
            )
        }
    }

    /// What the bridge card needs beyond the per-server rows: the operator's allow-list, any
    /// entry the document rejected at load, and whether the file itself failed to parse.
    /// Returned as response fields so no actor's internals cross into the console layer.
    public func registrySummary() async -> [String: JSONValue] {
        let allowed = await registry.allowedCommands
        let rejections = await registry.rejections
        let failure = await registry.loadFailure ?? ""
        return [
            "allowedCommands": .array(allowed.map { JSONValue.string($0) }),
            "entryRejections": .array(rejections.map {
                .object(["id": .string($0.id), "reason": .string($0.reason)])
            }),
            "configFailure": .string(failure)
        ]
    }

    // MARK: - Calling

    /// The single entry point for "call this tool". Read-only runs; mutating is queued.
    public func invoke(
        serverID: String,
        toolName: String,
        arguments: [String: JSONValue] = [:],
        source: String = "console"
    ) async -> HubCallOutcome {
        guard config.allowMcpBridge else {
            return .refused("MCP 桥接未启用 / the MCP bridge is off")
        }
        guard let spec = await registry.server(id: serverID) else {
            return .refused("未注册的服务器 / server is not registered: \(serverID)")
        }
        let allowed = await registry.allowedCommands
        if let rejection = spec.acceptance(inside: allowed) {
            return .refused(rejection)
        }
        guard spec.enabled else { return .refused("该服务器已停用 / server is disabled") }
        guard arguments.count <= Self.maximumArguments else {
            return .refused("参数过多 / too many arguments")
        }
        guard let tool = await tool(named: toolName, in: serverID) else {
            // A tool the server never listed is refused rather than assumed mutating: the
            // proposal card would otherwise show a name the owner cannot verify.
            await ledger.record(PrivacyAuditEntry(
                domain: PrivacyDomain.mcp.rawValue,
                action: PrivacyProposalAction.invoke.rawValue,
                outcome: "refused",
                detail: "unknown tool \(serverID)/\(toolName)"
            ))
            return .refused("服务器未提供该工具 / the server did not list tool: \(toolName)")
        }
        let tier = safety(of: tool, serverID: serverID)
        guard Self.permits(tool: tool, allowed: spec.allowedTools, safety: tier) else {
            await ledger.record(PrivacyAuditEntry(
                domain: PrivacyDomain.mcp.rawValue,
                action: PrivacyProposalAction.invoke.rawValue,
                outcome: "refused",
                detail: "tool not permitted \(serverID)/\(tool.name)"
            ))
            return .refused("该工具未在 allowedTools 中勾选 / tool is not in this server's allow-list: \(tool.name)")
        }

        let payload = HubCallPayload(
            kind: .mcpTool,
            serverID: serverID,
            target: tool.name,
            arguments: arguments,
            destination: Self.describe(spec)
        )

        if tier == .readOnly {
            guard let result = await run(payload: payload, allowMutating: false) else {
                return .refused("调用失败 / the call failed: \(lastFailureText())")
            }
            await ledger.record(PrivacyAuditEntry(
                domain: PrivacyDomain.mcp.rawValue,
                action: PrivacyProposalAction.invoke.rawValue,
                outcome: result.isError ? "failed" : "executed",
                detail: "read \(serverID)/\(tool.name)"
            ))
            return .executed(text: result.text, truncated: result.truncated)
        }

        // Mutating: the only accepted answer is a proposal.
        let proposal = PrivacyProposal(
            domain: .mcp,
            action: .invoke,
            source: source,
            title: "运行 MCP 工具 · \(tool.title.isEmpty ? tool.name : tool.title)",
            detail: payload.preview,
            hubCall: payload
        )
        let stored = await ledger.propose(proposal)
        await ledger.record(PrivacyAuditEntry(
            domain: PrivacyDomain.mcp.rawValue,
            action: PrivacyProposalAction.invoke.rawValue,
            outcome: PrivacyProposalState.pendingUserApproval.rawValue,
            detail: "\(serverID)/\(tool.name) → \(stored.id)"
        ))
        return .proposed(stored)
    }

    /// Runs an already-approved payload. Reached only through the ledger's executor, which
    /// has verified the receipt, the expiry and the proposal identity.
    public func executeApproved(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        guard proposal.domain == .mcp, proposal.action == .invoke, let payload = proposal.hubCall else {
            return PrivacyExecution(ok: false, message: "提案不是 MCP 调用 / proposal is not an MCP call")
        }
        guard payload.kind == .mcpTool else {
            return PrivacyExecution(ok: false, message: "载荷类型不符 / payload kind is not an MCP tool")
        }
        guard config.allowMcpBridge else {
            return PrivacyExecution(ok: false, message: "MCP 桥接已关闭 / the MCP bridge was switched off")
        }
        guard let result = await run(payload: payload, allowMutating: true) else {
            return PrivacyExecution(ok: false, message: "执行失败 / execution failed: \(lastFailureText())")
        }
        await ledger.record(PrivacyAuditEntry(
            domain: PrivacyDomain.mcp.rawValue,
            action: PrivacyProposalAction.invoke.rawValue,
            outcome: result.isError ? "failed" : "approved_executed",
            detail: "\(payload.serverID)/\(payload.target) → \(proposal.id)"
        ))
        return PrivacyExecution(
            ok: !result.isError,
            identifier: proposal.id,
            message: result.text.isEmpty ? "已执行 / done" : String(result.text.prefix(240))
        )
    }

    /// Drops every session. Called when the switch goes off and on shutdown.
    public func disconnectAll() async {
        for client in clients.values { await client.shutdown() }
        clients.removeAll()
        listedTools.removeAll()
        lastFailure = ""
    }

    public func isEnabled() -> Bool { config.allowMcpBridge }

    /// Drops one server's session and cached tool list. The Gods Eye bridge calls this
    /// when its local instance stops or moves port: a cached channel to a dead base URL
    /// must not keep answering "connected" in the console.
    public func disconnect(serverID: String) async {
        if let client = clients.removeValue(forKey: serverID) {
            await client.shutdown()
        }
        listedTools.removeValue(forKey: serverID)
    }

    /// Where a call is going, in the words the owner typed in the config. `stdio` shows the
    /// allow-listed command; HTTP shows the validated origin, never the raw URL, so a
    /// userinfo or query component cannot ride onto a card.
    static func describe(_ spec: MCPServerConfig) -> String {
        switch spec.transport {
        case .stdio:
            return "stdio " + (spec.arguments.isEmpty ? spec.command : spec.command + " " + spec.arguments.joined(separator: " "))
        case .http:
            return (try? EdgeBoundary.resolve(url: spec.url, policy: .loopbackOnly))?.origin ?? spec.url
        }
    }

    // MARK: - Internals

    /// `allowedTools` is a *widen-only* list: empty means every read-only tool the server
    /// advertised, and a mutating tool is reachable only when it is named there. The tier
    /// passed in is the effective one, so a gate that tightened a read to a write cannot be
    /// dodged by an empty list.
    static func permits(tool: MCPTool, allowed: [String], safety: MCPToolSafety? = nil) -> Bool {
        let tier = safety ?? tool.safety
        guard !allowed.isEmpty else { return tier == .readOnly }
        return allowed.contains { $0.caseInsensitiveCompare(tool.name) == .orderedSame }
    }

    /// The stricter of the server's own hint and any bridge-specific gate.
    private func safety(of tool: MCPTool, serverID: String) -> MCPToolSafety {
        guard let toolGate else { return tool.safety }
        let gated = toolGate.effectiveSafety(serverID: serverID, tool: tool)
        if tool.safety == .mutating || gated == .mutating { return .mutating }
        return .readOnly
    }

    private func client(for spec: MCPServerConfig, allowed: [String]) async -> MCPClient? {
        if let existing = clients[spec.id] { return existing }
        guard let link = makeLink(spec, allowed) else { return nil }
        let client = MCPClient(serverID: spec.id, link: link)
        clients[spec.id] = client
        return client
    }

    private func loadTools(serverID: String) async -> [MCPTool]? {
        let allowed = await registry.allowedCommands
        guard let spec = await registry.server(id: serverID),
              spec.acceptance(inside: allowed) == nil,
              let client = await client(for: spec, allowed: allowed) else { return nil }
        guard await client.connect() else { return nil }
        let tools = await client.tools()
        listedTools[serverID] = tools
        return tools
    }

    private func tool(named name: String, in serverID: String) async -> MCPTool? {
        if let found = listedTools[serverID]?.first(where: { $0.name == name }) { return found }
        return await loadTools(serverID: serverID)?.first { $0.name == name }
    }

    /// Runs a payload. `allowMutating` is true only from the approved path; `MCPClient`
    /// refuses the call itself if the tier and the flag disagree, so a read-only path
    /// cannot reach a mutating tool by mislabelling it.
    private func run(payload: HubCallPayload, allowMutating: Bool) async -> MCPToolResult? {
        let allowed = await registry.allowedCommands
        guard let spec = await registry.server(id: payload.serverID),
              let client = await client(for: spec, allowed: allowed) else {
            lastFailure = "无法建立会话 / no session could be opened for \(payload.serverID)"
            return nil
        }
        switch await client.call(name: payload.target, arguments: payload.arguments, allowMutating: allowMutating) {
        case let .success(result):
            lastFailure = ""
            return result
        case let .failure(error):
            lastFailure = error.description
            return nil
        }
    }

    private func lastFailureText() -> String {
        lastFailure.isEmpty ? "未知原因 / no reason recorded" : lastFailure
    }
}

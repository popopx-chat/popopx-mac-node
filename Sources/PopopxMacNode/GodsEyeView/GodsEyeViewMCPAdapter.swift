//
//  GodsEyeViewMCPAdapter.swift
//  PopopxMacNode — the only writer of this bridge's entry in `config/mcp_servers.json`.
//
//  The adapter owns one id (`godseyeview`) and touches nothing else in the file. It
//  registers a STDIO server whose command is the *verified* Node binary and whose
//  entry is the *verified* `mcp-server.js`, with `--base-url http://127.0.0.1:<port>`
//  so the child talks to the instance this node started and cannot invent a port.
//
//  `allowedTools` starts empty on registration, which the MCP bridge reads as
//  "read-only tools only". Listing the server's tools is a separate, explicit step:
//  the bridge handshakes once, then `syncTools` records the observed names. A
//  mutating name being present is what lets it reach the proposal branch; it never
//  lets it run without a receipt.
//

import Foundation

public actor GodsEyeViewMCPAdapter {
    public static let maximumToolNameLength = 128

    private let registry: MCPServerRegistry

    public init(registry: MCPServerRegistry) {
        self.registry = registry
    }

    // MARK: Reading

    public func isRegistered() async -> Bool {
        await registry.server(id: GodsEyeViewPolicy.serverID) != nil
    }

    public func registeredSpec() async -> MCPServerConfig? {
        await registry.server(id: GodsEyeViewPolicy.serverID)
    }

    public func allowedTools() async -> [String] {
        await registry.server(id: GodsEyeViewPolicy.serverID)?.allowedTools ?? []
    }

    // MARK: Writing

    /// Adds or replaces this bridge's entry. `allowedTools` is preserved when the
    /// caller passes nil, so a re-registration after a restart does not silently
    /// forget the names the owner already synced.
    @discardableResult
    public func register(
        nodePath: String,
        mcpEntryPath: String,
        port: Int,
        enabled: Bool = true,
        allowedTools: [String]? = nil
    ) async -> GodsEyeActionResult {
        guard nodePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: nodePath) else {
            return .failure("Node.js 不是可执行绝对路径 / the Node.js binary is not an executable absolute path")
        }
        guard mcpEntryPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: mcpEntryPath) else {
            return .failure("MCP 入口不存在 / the MCP entry does not exist")
        }
        guard GodsEyeViewPolicy.isValidPort(port) else {
            return .failure("端口无效 / the port is not valid")
        }
        let document = await registry.document
        var commands = Set(document.allowedCommands)
        commands.insert(nodePath)
        guard commands.count <= MCPServersDocument.maximumAllowedCommands else {
            return .failure("MCP 命令白名单已满 / the MCP command allow-list is full")
        }
        var servers = document.servers.filter { $0.id != GodsEyeViewPolicy.serverID }
        guard servers.count + 1 <= MCPServersDocument.maximumServers else {
            return .failure("MCP 服务器数量已达上限 / the MCP server limit is reached")
        }
        let previous = document.servers.first { $0.id == GodsEyeViewPolicy.serverID }
        let tools = Self.sanitiseTools(allowedTools ?? previous?.allowedTools ?? [])
        let spec = MCPServerConfig(
            id: GodsEyeViewPolicy.serverID,
            label: GodsEyeViewPolicy.serverLabel,
            transport: .stdio,
            command: nodePath,
            arguments: GodsEyeViewPolicy.mcpArguments(mcpEntryPath: mcpEntryPath, port: port),
            environmentNames: [],
            url: "",
            allowedTools: tools,
            enabled: enabled
        )
        if let reason = spec.acceptance(inside: Array(commands)) {
            return .failure(reason)
        }
        servers.append(spec)
        let next = MCPServersDocument(allowedCommands: Array(commands), servers: servers)
        if let error = await registry.save(next) {
            return .failure(error)
        }
        return GodsEyeActionResult(
            ok: true,
            detail: "已注册 \(GodsEyeViewPolicy.serverID) → 127.0.0.1:\(port) / registered"
        )
    }

    /// Records the names the bridge observed. Only this bridge's entry changes.
    @discardableResult
    public func syncTools(_ names: [String]) async -> GodsEyeActionResult {
        let document = await registry.document
        guard let index = document.servers.firstIndex(where: { $0.id == GodsEyeViewPolicy.serverID }) else {
            return .failure("尚未注册 / God's Eye View is not registered")
        }
        let cleaned = Self.sanitiseTools(names)
        guard !cleaned.isEmpty else {
            return .failure("工具清单为空 / the tool list is empty")
        }
        var servers = document.servers
        servers[index].allowedTools = cleaned
        if let error = await registry.save(MCPServersDocument(
            allowedCommands: document.allowedCommands, servers: servers
        )) {
            return .failure(error)
        }
        return GodsEyeActionResult(
            ok: true,
            detail: "已登记 \(cleaned.count) 个工具 / recorded \(cleaned.count) tools"
        )
    }

    /// Removes this bridge's entry and leaves every other server untouched. The
    /// command allow-list is intentionally left alone: it is the operator's list of
    /// programs this Mac may run, and a removal of one registration is not consent to
    /// shorten it.
    @discardableResult
    public func unregister() async -> GodsEyeActionResult {
        let document = await registry.document
        guard document.servers.contains(where: { $0.id == GodsEyeViewPolicy.serverID }) else {
            return GodsEyeActionResult(ok: true, detail: "未注册 / not registered")
        }
        let next = MCPServersDocument(
            allowedCommands: document.allowedCommands,
            servers: document.servers.filter { $0.id != GodsEyeViewPolicy.serverID }
        )
        if let error = await registry.save(next) {
            return .failure(error)
        }
        return GodsEyeActionResult(ok: true, detail: "已移除注册 / unregistered")
    }

    // MARK: Sanitising

    static func sanitiseTools(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= maximumToolNameLength,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
//
//  GodsEyeViewBridge.swift
//  PopopxMacNode — the coordinator the console and the phone talk to.
//
//  It owns three things and nothing else:
//
//  * the manager (verification, process, health) — every start is still an owner click;
//  * the registry adapter (one `godseyeview` entry in `config/mcp_servers.json`);
//  * the association between the two: while the local instance runs, the MCP entry
//    points at this Node binary, this `mcp-server.js` and this loopback port; when it
//    stops, the entry and whatever MCP session was cached are gone.
//
//  The advisory switch (`allowMcpBridge`) belongs to the node's settings, not here.
//  A registration without that switch is inert: the card says so and the phone cannot
//  call anything. This type never flips it — it only reports what it observes.
//

import Foundation

public actor GodsEyeViewBridge {
    /// The control verbs the console route accepts. Kept as data so the route's
    /// allow-list and the browser's buttons read from one source.
    public static let supportedVerbs: [String] = [
        "verify", "install", "start", "stop", "register", "syncTools", "unregister", "health"
    ]

    private let adapter: GodsEyeViewMCPAdapter
    private let manager: GodsEyeViewManager
    private let secrets: any HubSecretStoring
    private var mcp: MCPBridge?

    public init(
        config: GodsEyeViewConfig = .disabled,
        registry: MCPServerRegistry,
        mcp: MCPBridge?,
        secrets: any HubSecretStoring,
        runtime: any GodsEyeRuntime = SystemGodsEyeRuntime(),
        auditURL: URL? = AppPaths.godsEyeAuditFile,
        logURL: URL? = AppPaths.godsEyeLogFile,
        startupProbeAttempts: Int = 8,
        startupProbeInterval: TimeInterval = 0.5
    ) {
        self.adapter = GodsEyeViewMCPAdapter(registry: registry)
        self.manager = GodsEyeViewManager(
            config: config,
            secrets: secrets,
            runtime: runtime,
            auditURL: auditURL,
            logURL: logURL,
            startupProbeAttempts: startupProbeAttempts,
            startupProbeInterval: startupProbeInterval
        )
        self.secrets = secrets
        self.mcp = mcp
    }

    // MARK: - Configuration

    /// Applies a settings save. A change that would make the running process represent
    /// a different install, port or Node binary tears it down: keeping it up while the
    /// card names the new values would make every status row a lie. Anything else —
    /// an enabled credential slot, a licence note — waits for the next start.
    public func update(config next: GodsEyeViewConfig, mcp nextMCP: MCPBridge?) async {
        let previous = await manager.currentConfig
        mcp = nextMCP
        let cleaned = next.normalised
        let processAffecting = cleaned.enabled != previous.enabled
            || cleaned.installPath != previous.installPath
            || cleaned.pinnedVersion != previous.pinnedVersion
            || cleaned.port != previous.port
            || cleaned.nodePath != previous.nodePath
            || cleaned.mode != previous.mode
        if processAffecting {
            await shutdownInstance(reason: "config")
        } else if !cleaned.enabled, await adapter.isRegistered() {
            await detach()
        }
        await manager.update(config: cleaned)
    }

    // MARK: - Status

    /// Cheap by construction: no handshake, no process spawn. The tool rows are the
    /// names the last sync recorded, classified by the same gate MCPBridge consults.
    public func snapshot() async -> GodsEyeViewSnapshot {
        var snap = await manager.snapshot()
        let registered = await adapter.isRegistered()
        let names = registered ? await adapter.allowedTools() : []
        let gate = GodsEyeViewToolGate()
        let rows = names.map { name -> GodsEyeToolRow in
            let tier = gate.effectiveSafety(
                serverID: GodsEyeViewPolicy.serverID,
                tool: MCPTool(name: name)
            )
            return GodsEyeToolRow(name: name, safety: tier.rawValue, permitted: true)
        }
        var bridgeOn = false
        if let mcp { bridgeOn = await mcp.isEnabled() }
        snap.mcpRegistered = registered
        snap.mcpTools = rows
        snap.mcpDetail = Self.mcpDetail(
            registered: registered, bridgeOn: bridgeOn, running: snap.running, rows: rows
        )
        return snap
    }

    /// The structured report for one control click: the verdict plus the settled card.
    public func control(verb: String) async -> GodsEyeControlReport {
        let name = verb.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = await manager.currentConfig.enabled
        let result: GodsEyeActionResult
        switch name {
        case "verify":
            result = await manager.verify()
        case "install":
            result = await manager.install()
        case "start":
            guard enabled else {
                return await report(name, .failure("全球情报地图未启用 / God's Eye View is off"))
            }
            let started = await manager.start()
            if started.ok {
                let attached = await attach(force: false)
                result = GodsEyeActionResult(
                    ok: true, detail: "\(started.detail) · \(attached.detail)"
                )
            } else {
                result = started
            }
        case "stop":
            await detach()
            result = await manager.stop()
        case "register":
            guard enabled else {
                return await report(name, .failure("全球情报地图未启用 / God's Eye View is off"))
            }
            result = await attach(force: true)
        case "syncTools":
            guard enabled else {
                return await report(name, .failure("全球情报地图未启用 / God's Eye View is off"))
            }
            result = await syncTools()
        case "unregister":
            result = await detach()
        case "health":
            result = await manager.checkHealth()
        default:
            result = .failure("未知控制指令 / unknown control verb: \(name.isEmpty ? "(empty)" : name)")
        }
        return await report(name, result)
    }

    // MARK: - Credentials

    /// Stores one optional feed key. The value goes into the Keychain (or, in a bare
    /// executable, the process-volatile store) and only the reference comes back.
    /// The caller persists the reference into `settings.godsEye.credentials`; the
    /// value is never returned, logged or included in any snapshot.
    public func storeCredential(sourceID: String, secret: String) async -> HubSecretOutcome {
        guard let source = GodsEyeDataSource(rawValue: sourceID) else {
            return .refused(reason: "未知数据源 / unknown data source: \(sourceID)")
        }
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .refused(reason: "凭据为空 / the credential is empty")
        }
        guard value.count <= HubSecrets.maximumSecretLength else {
            return .refused(reason: "凭据过长 / the credential is too long")
        }
        let reference = source.referenceName
        guard HubSecrets.isSafeReference(reference), secrets.store(value, for: reference) else {
            return .refused(reason: "钥匙串写入失败 / the Keychain write failed")
        }
        await manager.auditNote("credential", "ok", "\(source.rawValue) → keychain \(reference)")
        return .stored(reference: reference)
    }

    // MARK: - Shutdown

    /// App termination: the process this bridge started must not outlive the node, and
    /// the registration must not outlive the process.
    public func shutdown() async {
        await shutdownInstance(reason: "shutdown")
    }

    // MARK: - MCP association

    /// Registers the verified entry, files the observed tool names and returns the
    /// registration verdict. The registration itself is useful even when listing fails:
    /// the MCP bridge treats an empty `allowedTools` as "read-only tools only", so a
    /// phone query can still read the map while the sync is retried.
    private func attach(force: Bool) async -> GodsEyeActionResult {
        guard let mcp else {
            return .failure("MCP 桥接未初始化 / the MCP bridge is not available")
        }
        guard await mcp.isEnabled() else {
            return .failure("MCP 桥接未启用 / the MCP bridge is off")
        }
        guard await manager.isRunning() else {
            return .failure("本地实例未运行 / the local instance is not running")
        }
        let node = await manager.nodeProbe(force: force)
        guard node.ok else { return .failure(node.detail) }
        guard let verification = await manager.lastVerification(), verification.ok else {
            return .failure("安装尚未校验 / the install has not been verified")
        }
        let config = await manager.currentConfig
        let registered = await adapter.register(
            nodePath: node.path,
            mcpEntryPath: verification.mcpEntryPath,
            port: config.port
        )
        guard registered.ok else {
            await manager.auditNote("register", "failed", registered.detail)
            return registered
        }
        await manager.auditNote("register", "ok", registered.detail)
        // A session cached against an earlier launch can point at another port or a
        // dead child; dropping it makes `toolCards` handshake with this registration.
        await mcp.disconnect(serverID: GodsEyeViewPolicy.serverID)
        let cards = await mcp.toolCards(serverID: GodsEyeViewPolicy.serverID)
        guard !cards.isEmpty else {
            let detail = "已注册，但工具清单为空（实例可能尚未就绪）/ registered, but the server listed no tools yet"
            await manager.auditNote("syncTools", "failed", detail)
            return GodsEyeActionResult(ok: true, detail: "\(registered.detail) · \(detail)")
        }
        let synced = await adapter.syncTools(cards.map(\.name))
        await manager.auditNote("syncTools", synced.ok ? "ok" : "failed", synced.detail)
        guard synced.ok else {
            return GodsEyeActionResult(
                ok: true,
                detail: "\(registered.detail) · 工具同步失败 / tool sync failed: \(synced.detail)"
            )
        }
        return GodsEyeActionResult(ok: true, detail: "\(registered.detail) · \(synced.detail)")
    }

    /// Re-lists the running server and records the names again. The 「同步工具」 button.
    private func syncTools() async -> GodsEyeActionResult {
        guard let mcp else {
            return .failure("MCP 桥接未初始化 / the MCP bridge is not available")
        }
        guard await mcp.isEnabled() else {
            return .failure("MCP 桥接未启用 / the MCP bridge is off")
        }
        guard await adapter.isRegistered() else {
            return .failure("尚未注册 / God's Eye View is not registered")
        }
        await mcp.disconnect(serverID: GodsEyeViewPolicy.serverID)
        let cards = await mcp.toolCards(serverID: GodsEyeViewPolicy.serverID)
        guard !cards.isEmpty else {
            let detail = "工具清单为空 / the server listed no tools"
            await manager.auditNote("syncTools", "failed", detail)
            return .failure(detail)
        }
        let result = await adapter.syncTools(cards.map(\.name))
        await manager.auditNote("syncTools", result.ok ? "ok" : "failed", result.detail)
        return result
    }

    /// Removes the registration and drops the cached MCP session. The command
    /// allow-list is left alone: removing one entry is not consent to shorten the
    /// operator's list of programs this Mac may run.
    @discardableResult
    private func detach() async -> GodsEyeActionResult {
        if let mcp { await mcp.disconnect(serverID: GodsEyeViewPolicy.serverID) }
        let wasRegistered = await adapter.isRegistered()
        let result = await adapter.unregister()
        if wasRegistered {
            await manager.auditNote("unregister", result.ok ? "ok" : "failed", result.detail)
        }
        return result
    }

    private func shutdownInstance(reason: String) async {
        await detach()
        if await manager.isRunning() {
            let stopped = await manager.stop()
            if !stopped.ok {
                await manager.auditNote("stop", "failed", stopped.detail)
            }
        }
    }

    // MARK: - Reporting

    private func report(_ verb: String, _ result: GodsEyeActionResult) async -> GodsEyeControlReport {
        GodsEyeControlReport(
            outcome: verb.isEmpty ? "unknown" : verb,
            ok: result.ok,
            detail: result.detail,
            godsEye: await snapshot()
        )
    }

    static func mcpDetail(
        registered: Bool, bridgeOn: Bool, running: Bool, rows: [GodsEyeToolRow]
    ) -> String {
        if !registered {
            return "MCP 未注册：启动本地实例后自动注册 / not registered; starting the local instance registers it"
        }
        if !bridgeOn {
            return "已注册，但 MCP 桥接未启用 / registered, but the MCP bridge is off"
        }
        if !running {
            return "已注册；本地实例未运行 / registered; the local instance is not running"
        }
        if rows.isEmpty {
            return "已注册；尚未同步工具清单 / registered; the tool list has not been synced yet"
        }
        let writes = rows.filter { $0.safety == MCPToolSafety.mutating.rawValue }.count
        return "已注册 \(rows.count) 个工具，其中 \(writes) 个写操作逐次人工批准 / \(rows.count) tools; \(writes) mutating tools require approval per call"
    }
}
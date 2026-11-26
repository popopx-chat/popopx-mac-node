//
//  LocalCapabilityDiscovery.swift
//  PopopxMacNode — what this Mac already has, asked locally.
//
//  Borrowed from Home Assistant's discovery design, and deliberately kept at its most
//  conservative: HA broadcasts to find hardware, which is a network act. This node only
//  *answers questions about itself* plus the handful of addresses the owner typed into
//  `config.discovery.lanTargets`. There is no mDNS responder, no port sweep, no subnet walk
//  and no DNS lookup for a name that is not `.local` — an unasked-for probe of somebody
//  else's machine is exactly what an edge node must not do.
//
//  Two properties the console depends on:
//
//  * **Never blocking.** `snapshot()` returns whatever was last measured and starts a scan in
//    the background. A status card that stalls for the length of a TCP timeout is a worse
//    console than a status card that is one poll stale.
//  * **Separable.** `probe(...)` takes its facts as arguments, so every row — including the
//    "public address is refused" row — is reachable from a test without a socket.
//

import Foundation
import Network

// MARK: - Shape

public struct DiscoveryCapability: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case ollama
        case model
        case workspace
        case calendar
        case lanService
        case refusal
    }

    public var kind: Kind
    /// The name the console prints. Model rows carry the catalog's display name, not a wire
    /// reference, so a locally-tagged GGUF cannot smuggle text into the card.
    public var label: String
    /// `present` / `absent` / `installed` / `authorized` / `denied` / `off` / `reachable` /
    /// `silent` / `refused`.
    public var state: String
    public var detail: String
    /// Where the answer came from: a loopback origin or an owner-named host. Empty for facts
    /// about this process, such as the workspace grants.
    public var origin: String

    public init(kind: Kind, label: String, state: String, detail: String = "", origin: String = "") {
        self.kind = kind
        self.label = label
        self.state = state
        self.detail = detail
        self.origin = origin
    }
}

public struct DiscoverySnapshot: Codable, Sendable, Equatable {
    public var capabilities: [DiscoveryCapability]
    /// ISO-8601, or empty when nothing has been measured yet.
    public var scannedAt: String
    public var autoScanOnLaunch: Bool
    /// True while a scan is running, so the console can say "measuring" instead of showing an
    /// empty card that reads as "nothing here".
    public var scanning: Bool
    public var boundary: String

    public init(
        capabilities: [DiscoveryCapability] = [],
        scannedAt: String = "",
        autoScanOnLaunch: Bool = false,
        scanning: Bool = false,
        boundary: String = DiscoverySnapshot.boundaryText
    ) {
        self.capabilities = capabilities
        self.scannedAt = scannedAt
        self.autoScanOnLaunch = autoScanOnLaunch
        self.scanning = scanning
        self.boundary = boundary
    }

    /// Stated on every snapshot, because "we only looked locally" is the answer to the question
    /// the owner is actually asking.
    public static let boundaryText = "仅回环与机主列出的局域网地址 / loopback plus the LAN targets this owner listed"

    public func capabilities(matching kind: DiscoveryCapability.Kind) -> [DiscoveryCapability] {
        capabilities.filter { $0.kind == kind }
    }
}

// MARK: - Discovery

public actor LocalCapabilityDiscovery {
    /// How long a previous pass stays acceptable. Shorter than the console's own poll would
    /// like, longer than a human's patience for a card that flickers.
    public static let cacheSeconds: TimeInterval = 20
    public static let probeTimeout: TimeInterval = 0.35
    public static let ollamaOrigin = "http://127.0.0.1:\(NodeWire.ollamaPort)"

    private var config: HubConfig
    private var gateway: (any CalendarGateway)?
    private var sandbox: WorkspaceSandbox?
    private var cached: DiscoverySnapshot?
    private var cachedAt = Date.distantPast
    private var inFlight: Task<DiscoverySnapshot, Never>?

    public init(
        config: HubConfig = .disabled,
        gateway: (any CalendarGateway)? = nil,
        sandbox: WorkspaceSandbox? = nil
    ) {
        self.config = config
        self.gateway = gateway
        self.sandbox = sandbox
    }

    /// Settings changed. A changed target list invalidates the cache at once: a card that still
    /// shows the host the owner just removed would be a lie about the present.
    public func update(config: HubConfig, gateway: (any CalendarGateway)?, sandbox: WorkspaceSandbox?) {
        let previous = self.config.discovery.normalised
        self.config = config
        self.gateway = gateway
        self.sandbox = sandbox
        if previous != config.discovery.normalised {
            cached = nil
            cachedAt = .distantPast
        }
    }

    /// The console's read path: returns immediately, starts a background pass when stale.
    public func snapshot(force: Bool = false) -> DiscoverySnapshot {
        let fresh = Date().timeIntervalSince(cachedAt) < Self.cacheSeconds
        if fresh, !force, var cached {
            cached.scanning = inFlight != nil
            return cached
        }
        startScanIfNeeded()
        var result = cached ?? DiscoverySnapshot(autoScanOnLaunch: config.discovery.autoScanOnLaunch)
        result.autoScanOnLaunch = config.discovery.autoScanOnLaunch
        result.scanning = inFlight != nil
        return result
    }

    /// Waits for the measurement. Used by `POST /v1/discovery/scan`, where the owner clicked
    /// the button precisely because they wanted the answer now.
    public func scan() async -> DiscoverySnapshot {
        startScanIfNeeded()
        if let inFlight { return await inFlight.value }
        let result = await Self.measure(config: config, gateway: gateway, sandbox: sandbox)
        store(result)
        return result
    }

    public func invalidate() {
        cached = nil
        cachedAt = .distantPast
    }

    private func startScanIfNeeded() {
        guard inFlight == nil else { return }
        let gateway = self.gateway
        let sandbox = self.sandbox
        let config = self.config
        inFlight = Task { [weak self] in
            let result = await Self.measure(config: config, gateway: gateway, sandbox: sandbox)
            await self?.store(result)
            return result
        }
    }

    private func store(_ snapshot: DiscoverySnapshot) {
        cached = snapshot
        cachedAt = Date()
        inFlight = nil
    }

    // MARK: Measuring

    /// Live pass: gather the facts, then let the pure builder turn them into rows.
    static func measure(
        config: HubConfig,
        gateway: (any CalendarGateway)?,
        sandbox: WorkspaceSandbox?
    ) async -> DiscoverySnapshot {
        let discovery = config.discovery.normalised
        var reachable = false
        var installed: [String] = []
        if discovery.probeOllama {
            reachable = await ENGOllama.isReachable()
            if reachable { installed = await ENGOllama.installedModels() }
        }
        // Asked of the gateway, never of the calendar store: `authorizationState` reads the TCC
        // status this node already holds and does not raise a prompt. A node without a bridge
        // reports `off` rather than `notDetermined`, which would imply a question was asked.
        let calendarState = await (gateway?.authorizationState() ?? "off")
        let endpoints = discovery.admissibleTargets
        // Probed in parallel, and *refused before the socket*: a target that resolved to a
        // public address never reaches `NWConnection`, so the count of rows here is the count
        // of addresses this node was allowed to name.
        let answers: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for endpoint in endpoints {
                group.addTask { await probeLan(endpoint, timeout: Self.probeTimeout) }
            }
            var results: [Bool] = []
            for await answer in group { results.append(answer) }
            return results
        }
        let rejected = discovery.lanTargets.count - endpoints.count
        return probe(
            ollamaProbed: discovery.probeOllama,
            ollamaReachable: reachable,
            ollamaModels: installed,
            calendarState: calendarState,
            sandbox: sandbox,
            lanEndpoints: endpoints,
            lanAnswers: answers,
            lanRejected: rejected,
            autoScanOnLaunch: discovery.autoScanOnLaunch
        )
    }

    /// The rows, from facts. No I/O, which is what makes every claim below testable.
    static func probe(
        ollamaProbed: Bool,
        ollamaReachable: Bool,
        ollamaModels: [String],
        calendarState: String,
        sandbox: WorkspaceSandbox?,
        lanEndpoints: [EdgeEndpoint],
        lanAnswers: [Bool],
        lanRejected: Int,
        autoScanOnLaunch: Bool
    ) -> DiscoverySnapshot {
        var rows: [DiscoveryCapability] = []

        if ollamaProbed {
            rows.append(DiscoveryCapability(
                kind: .ollama,
                label: "Ollama",
                state: ollamaReachable ? "present" : "absent",
                detail: ollamaReachable
                    ? "本机推理服务在线 / answering on loopback"
                    : "未运行或未监听 127.0.0.1:\(NodeWire.ollamaPort) / not running on loopback",
                origin: ollamaOrigin
            ))
            rows.append(contentsOf: modelRows(installed: ollamaReachable ? ollamaModels : []))
        }

        rows.append(contentsOf: workspaceRows(from: sandbox))
        rows.append(calendarRow(state: calendarState))

        for (index, endpoint) in lanEndpoints.enumerated() {
            let alive = index < lanAnswers.count ? lanAnswers[index] : false
            rows.append(DiscoveryCapability(
                kind: .lanService,
                label: endpoint.host,
                state: alive ? "reachable" : "silent",
                detail: alive
                    ? "端口有响应 / the port answered"
                    : "无响应（不代表对方存在其它服务） / no answer, which says nothing about its other services",
                origin: endpoint.origin
            ))
        }
        if lanRejected > 0 {
            rows.append(DiscoveryCapability(
                kind: .refusal,
                label: "被拒绝的探测目标 / refused probe targets",
                state: "refused",
                detail: "\(lanRejected) 项不是回环、内网或 .local 地址，未发起任何连接 / \(lanRejected) target(s) were neither loopback, RFC 1918 nor .local; no connection was attempted"
            ))
        }

        return DiscoverySnapshot(
            capabilities: rows,
            scannedAt: PrivacyStamp.iso(Date()),
            autoScanOnLaunch: autoScanOnLaunch
        )
    }

    /// One row per model the catalog offers — the Ollama reference is matched through the
    /// catalog, so a locally re-tagged GGUF still counts as the model it is.
    static func modelRows(installed: [String]) -> [DiscoveryCapability] {
        ModelCatalog.options.map { option in
            let present = installed.contains { ref in
                ModelCatalog.option(matching: ref)?.ollamaModel == option.ollamaModel
            }
            return DiscoveryCapability(
                kind: .model,
                label: option.displayName,
                state: present ? "installed" : "absent",
                detail: present
                    ? "本机可用 / available on this machine"
                    : "未安装：\(option.ollamaRef) / not installed",
                origin: ollamaOrigin
            )
        }
    }

    static func workspaceRows(from sandbox: WorkspaceSandbox?) -> [DiscoveryCapability] {
        guard let sandbox else {
            return [DiscoveryCapability(
                kind: .workspace, label: "工作区 / Workspace", state: "off",
                detail: "本机尚未装配工作区桥接 / no workspace bridge on this node"
            )]
        }
        guard sandbox.readAllowed else {
            return [DiscoveryCapability(
                kind: .workspace, label: "工作区 / Workspace", state: "off",
                detail: "未授权读取 / file read is not authorized"
            )]
        }
        let access = sandbox.writeAllowed ? "read · write" : "read only"
        var rows = sandbox.directoryPaths.prefix(Self.maximumWorkspaceRows).map { path in
            DiscoveryCapability(
                kind: .workspace,
                label: AppPaths.anonymise(path),
                state: "authorized",
                detail: access
            )
        }
        if sandbox.directoryPaths.count > Self.maximumWorkspaceRows {
            rows.append(DiscoveryCapability(
                kind: .workspace,
                label: "其余目录 / Other directories",
                state: "authorized",
                detail: "另有 \(sandbox.directoryPaths.count - Self.maximumWorkspaceRows) 个目录已授权，此处仅列出前 \(Self.maximumWorkspaceRows) 个 / \(sandbox.directoryPaths.count - Self.maximumWorkspaceRows) more granted; the card lists the first \(Self.maximumWorkspaceRows)"
            ))
        }
        return rows
    }

    static func calendarRow(state: String) -> DiscoveryCapability {
        let label: String
        let detail: String
        switch state {
        case "fullAccess":
            label = "已授权 / authorized"; detail = "本机日历可读取空闲时段 / busy windows are readable on this Mac"
        case "writeAccess":
            label = "仅写入 / write only"; detail = "可写入但读不到日程 / writes are allowed, free/busy is not readable"
        case "denied":
            label = "系统已拒绝 / denied by macOS"; detail = "请在「系统设置 › 隐私与安全性 › 日历」中开启 / enable it in System Settings › Privacy & Security › Calendars"
        case "restricted":
            label = "受限 / restricted"; detail = "受管理设备限制 / restricted by a managed device policy"
        case "notDetermined":
            label = "尚未询问 / not asked yet"; detail = "首次使用时才会弹出系统授权 / the system prompt appears on first use"
        case "noGateway":
            label = "未装配 / not attached"; detail = "本节点没有日历桥接 / this node has no calendar bridge"
        default:
            label = "未开启 / off"; detail = "日历桥接未启用 / the calendar bridge is switched off"
        }
        return DiscoveryCapability(
            kind: .calendar, label: "系统日历 / System calendar", state: state, detail: "\(label) · \(detail)"
        )
    }

    public static let maximumWorkspaceRows = 8

    // MARK: LAN probe

    private static let probeQueue = DispatchQueue(label: "im.popopx.macnode.discovery.probe", attributes: .concurrent)

    /// One TCP attempt at an owner-named address.
    ///
    /// The allow-list is re-checked here rather than trusted from the config, because this is
    /// the line the whole feature must not cross. No name service is consulted for anything
    /// that is not a literal or `.local`, and a refused target returns `false` without ever
    /// building a connection.
    public static func probeLan(_ endpoint: EdgeEndpoint, timeout: TimeInterval) async -> Bool {
        guard endpoint.hostClass == .loopback || endpoint.hostClass == .privateNetwork,
              EdgeBoundary.isAllowed(endpoint.host, policy: .privateNetworkOnly),
              endpoint.port > 0, endpoint.port <= Int(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port))
        else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ReadinessGate(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
            let deadline = DispatchWorkItem {
                gate.settle(false)
                connection.cancel()
            }
            gate.attach(deadline)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.settle(true)
                    connection.cancel()
                case .failed, .cancelled:
                    gate.settle(false)
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }

    /// Resumes a probe's continuation exactly once, whichever of the state handler or the
    /// deadline gets there first. `NWConnection.wait(for:timeout:)` would be tidier and needs
    /// macOS 15; this node's deployment target is 14.
    private final class ReadinessGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var work: DispatchWorkItem?
        private let continuation: CheckedContinuation<Bool, Never>

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func attach(_ work: DispatchWorkItem) {
            lock.lock()
            self.work = work
            let already = resumed
            lock.unlock()
            // The deadline can win the race against the connection starting, so a gate that is
            // already closed cancels the work item it was handed instead of storing it.
            if already { work.cancel() }
        }

        func settle(_ value: Bool) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            let work = self.work
            self.work = nil
            lock.unlock()
            work?.cancel()
            continuation.resume(returning: value)
        }
    }
}

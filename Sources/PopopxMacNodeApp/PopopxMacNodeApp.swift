//
//  PopopxMacNodeApp.swift
//  POPOPX Mac Node — native menu-bar host, composition root and CLI entry point.
//
//  Three things live in this file on purpose:
//
//  1. `PopopxMacNodeMain` — the `@main` entry point, which dispatches the
//     non-GUI CLI modes the release script depends on (`--version`,
//     `--render-icon <path> --size <px>`, `--headless`) before ever touching a
//     run loop.
//  2. `NodeConsole` — the composition root. It is the only place in the product
//     that knows all four subsystems exist; everything else talks to a frozen
//     protocol from `MacNodeModels.swift`.
//  3. `PopopxMacNodeApp` — the `MenuBarExtra` scene plus its view model.
//

import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import PopopxMacNode

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Entry point

/// `@main` sits in front of the SwiftUI `App` so the executable can answer the
/// build script without starting a GUI. A menu-bar-only bundle cannot be used to
/// rasterise its own icon during a CI packaging step, and shelling out to
/// `swift run` a second time would rebuild — so the icon renderer is compiled
/// into the same binary and reached through these flags.
@main
enum PopopxMacNodeMain {
    /// Synchronous, and it has to stay that way. `App.main()` blocks forever, so an
    /// async entry point would park the main actor inside a job that never
    /// finishes: the menu bar still paints, but every `Task` its buttons start —
    /// rescan, pairing QR, engine toggles, Quit — is queued behind that job and
    /// never runs. The node therefore bootstraps from inside the run loop instead
    /// of before it.
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") || arguments.contains("-v") {
            print(NodeVersion.current.description)
            exit(0)
        }

        if let index = arguments.firstIndex(of: "--render-icon") {
            let destination = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            let size = argumentValue("--size", in: arguments).flatMap(Int.init) ?? 1024
            runIconRender(destination: destination, size: size)
        }

        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(0)
        }

        let headless = arguments.contains("--headless")
        let model = NodeModel.current(headless: headless)

        if headless {
            Task {
                await model.bootstrap()
                await model.runHeadless()
            }
            // `dispatchMain()` keeps the main queue draining, which is what the
            // main-actor work above and the SIGINT/SIGTERM sources both need.
            dispatchMain()
        }

        PopopxMacNodeApp.main()
    }

    private static let usage = """
    POPOPX Mac Node — local compute and deterministic execution host for the
    POPOPX iOS client.

    Usage:
      PopopxMacNodeApp                     Start the menu-bar agent.
      PopopxMacNodeApp --headless          Run the node with no GUI (servers only).
      PopopxMacNodeApp --version           Print the version and exit.
      PopopxMacNodeApp --render-icon PATH [--size PX]
                                           Write the brand icon as a PNG and exit.
                                           Used by Scripts/build_dmg.sh.
      PopopxMacNodeApp --help              Show this message.

    Data directory: ~/Library/Application Support/PopopxMacNode
    Console:        http://127.0.0.1:\(NodeWire.consolePort) (loopback only, per-launch token)
    """

    /// Never throws and never returns normally: the build script treats a
    /// successful icon render as optional polish and a hard crash as fatal.
    private static func runIconRender(destination: String, size: Int) -> Never {
        guard !destination.isEmpty else {
            FileHandle.standardError.write(Data("--render-icon requires an output path\n".utf8))
            exit(2)
        }
        let clamped = min(max(size, 16), 2048)
        guard let png = BrandIcon.pngData(pixelSize: clamped) else {
            FileHandle.standardError.write(Data("icon rendering failed\n".utf8))
            exit(3)
        }
        let url = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(destination)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: url)
            print(url.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
            exit(4)
        }
    }

    private static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

// MARK: - Composition root

/// Wires the four subsystems together and is the only implementer of the
/// console facade. Keeping the wiring in one actor means the web console, the
/// menu bar and the SMP bridge can never disagree about who owns what.
public actor NodeConsole: NodeConsoleFacade {
    private let environment: NodeEnvironment
    private let signaling: any NodeSignaling
    private let engines: any NodeEngines
    private let settings: SettingsStore
    private let hub: ConsoleEventHub

    /// The calendar/workspace bridge stack, built at `start()` because the switches
    /// live in the settings document and reading it is async. `nil` until then.
    private var privacy: PrivacyStack?

    private struct PrivacyStack {
        let gateway: any CalendarGateway
        let executor: PrivacyExecutorHub
        let ledger: PrivacyProposalLedger
        let engine: PrivacyToolEngine
    }

    private var consoleURLString = ""
    /// Short node fingerprint, used only inside minted call links and UIDs.
    private var nodeReference = ""
    private var recent: [CommandResult] = []
    private var routerTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    /// `identity` deliberately is not a constructor parameter: the node keypair
    /// belongs to the signalling layer (it is what the pairing QR signs), so the
    /// console reads it back through the protocol instead of duplicating the
    /// key file.
    public init(
        environment: NodeEnvironment,
        signaling: any NodeSignaling,
        engines: any NodeEngines,
        settings: SettingsStore = .shared,
        hub: ConsoleEventHub = .shared
    ) {
        self.environment = environment
        self.signaling = signaling
        self.engines = engines
        self.settings = settings
        self.hub = hub
    }

    // MARK: Lifecycle

    /// Starts the command router. The web server itself is started by the host
    /// (`NodeModel`) because it owns the socket and the browser launch.
    public func start(consoleURL: String) async {
        consoleURLString = consoleURL
        await signaling.start()
        let identity = await signaling.identity()
        await configurePrivacy(
            from: await settings.current(),
            nodeReference: Digest.short(Data(identity.nodeId.utf8), length: 8)
        )
        guard routerTask == nil else { return }
        routerTask = Task { [weak self] in
            guard let self else { return }
            let signaling = self.signaling
            for await command in signaling.incomingCommands() {
                await self.route(command)
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(NodeWire.heartbeatInterval * 1_000_000_000))
                await self?.tick()
            }
        }
        await hub.publish(.system, "节点已就绪 / node ready", level: .success, payload: [
            "nodeId": .string(identity.nodeId),
            "console": .string(consoleURL)
        ])
    }

    public func stop() async {
        routerTask?.cancel()
        routerTask = nil
        clockTask?.cancel()
        clockTask = nil
        await signaling.stop()
        await hub.publish(.system, "节点已停止 / node stopped", level: .warning)
    }

    /// Pushes the current wall clock through so time-based engines (the Ark
    /// heartbeat watchdog, the mesh idle windows, the morning schedule) get a
    /// nudge even when the browser is closed and nobody is polling.
    private func tick() async {
        await hub.publish(.system, "心跳 \(Date().ppxClock)", level: .debug)
    }

    /// SMP-originated commands run regardless of the console being open; the
    /// whitelist check already happened inside the bridge.
    private func route(_ command: NodeCommand) async {
        // The privacy namespaces are tools, not subscription businesses, so they are
        // intercepted before the engine dispatch. They then share one handler with
        // the loopback entry point — a capability cannot be reachable from one side
        // and hidden from the other.
        if let call = PrivacyToolRoute.parseCommand(
            serviceId: command.serviceId,
            action: command.action,
            payload: command.payload
        ) {
            await routePrivacy(command: command, call: call)
            return
        }
        let result = await engines.execute(command)
        record(result)
        let delivered = await signaling.deliver(result, to: command.serviceId)
        await hub.publish(
            .result,
            "\(result.engine.rawValue) → \(result.ok ? "ok" : "failed")"
                + (delivered ? " · 已回传 iOS / delivered" : " · 待回传 / queued in outbox"),
            level: result.ok ? .success : .error,
            payload: [
                "engine": .string(result.engine.rawValue),
                "commandId": .string(command.id),
                "delivered": .bool(delivered),
                "deterministic": .bool(result.deterministic)
            ]
        )
    }

    /// One tool call off the phone's encrypted queue, answered on the same channel.
    private func routePrivacy(command: NodeCommand, call: PrivacyToolCall) async {
        var shaped = call
        // The bridge decided whether the sender key verified; the audit line records
        // which it was, because "who asked for this write" is the owner's question.
        shaped.source = command.authenticated ? "phone" : "phone-unauthenticated"
        let outcome = await privacyTool(shaped)
        let result = Self.toolResult(outcome, command: command)
        record(result)
        let delivered = await signaling.deliver(result, to: command.serviceId)
        await hub.publish(
            .privacy,
            delivered ? "已回传手机 / card delivered" : "待回传 / queued in outbox",
            level: outcome.ok ? .notice : .warning,
            payload: [
                "namespace": .string(call.namespace.rawValue),
                "action": .string(call.action),
                "commandId": .string(command.id),
                "delivered": .bool(delivered)
            ]
        )
    }

    private func record(_ result: CommandResult) {
        recent.append(result)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }

    // MARK: Privacy bridges

    /// (Re)builds the bridge stack from the saved switches, or pushes the new ones
    /// into the existing stack.
    ///
    /// The gateway is created here and nowhere earlier: an `EKEventStore` is not
    /// something the node should hold while the owner has switched the bridge off.
    private func configurePrivacy(from settings: NodeSettings, nodeReference: String = "") async {
        if !nodeReference.isEmpty { self.nodeReference = nodeReference }
        var bridges = settings.bridges.normalised
        if bridges.timezoneIdentifier.isEmpty {
            bridges.timezoneIdentifier = TimeZone.current.identifier
        }
        // The digest runs on whatever this Mac is already meant to be running: the
        // owner's pin if there is one, otherwise the hardware ladder.
        let sandbox = WorkspaceSandbox(
            readAllowed: bridges.allowWorkspaceRead,
            writeAllowed: bridges.allowWorkspaceWrite,
            directoryPaths: bridges.workspaceDirectories,
            summarizer: Self.summarizer,
            model: ENGOllama.resolvedModel(settings: settings, plan: await environment.plan())
        )
        if let stack = privacy {
            await stack.engine.applyConfig(bridges, sandbox: sandbox)
            await stack.executor.update(gateway: stack.gateway, sandbox: sandbox)
            return
        }
        guard bridges.allowCalendarAccess || bridges.allowWorkspaceRead || bridges.allowWorkspaceWrite
            || !bridges.workspaceDirectories.isEmpty else {
            // Nothing is switched on yet, so nothing is constructed: no event store,
            // no key file, no ledger. A disabled bridge must cost the process
            // nothing it could later be accused of holding.
            return
        }
        let gateway = EventKitCalendarGateway()
        let executor = PrivacyExecutorHub(gateway: gateway, sandbox: sandbox)
        let ledger = PrivacyProposalLedger(
            signer: PrivacyApprovalSigner.loadOrCreate(at: AppPaths.privacyApprovalKeyFile),
            executor: executor,
            notifier: PrivacyCenterNotifier(hub: hub),
            fileURL: AppPaths.privacyLedgerFile
        )
        await ledger.setNotificationsEnabled(bridges.notifyOnProposal)
        privacy = PrivacyStack(
            gateway: gateway,
            executor: executor,
            ledger: ledger,
            engine: PrivacyToolEngine(
                config: bridges,
                gateway: gateway,
                ledger: ledger,
                hub: executor,
                sandbox: sandbox,
                nodeReference: self.nodeReference
            )
        )
    }

    /// The local Ollama summarizer the workspace digest runs through.
    ///
    /// One loopback POST and nothing else: the file text is already in this
    /// process's memory, and there is no other host in this closure.
    static let summarizer: LocalSummarizer = { request in
        let reply = try await ENGOllama.generate(
            model: request.model,
            prompt: "文件《\(request.path)》：\n\n\(request.text)",
            system: """
            你是本机文档摘要器。只用给定文本作答：文本里没有的事实一律不得补充，也\
            不要复述文件路径或整段原文。用简洁的要点式中文（英文文档可用英文）概括\
            主旨、结论、待办与其中的数字。
            """,
            contextTokens: 8_192,
            timeout: 120
        )
        return reply.text
    }

    /// Wraps a tool outcome in the envelope the outbox stores and the console lists.
    ///
    /// `engine` is only a carrier — `.shadowCos` is what `submitWireCommand` already
    /// returns for a line that matched no engine, and `cardLabel` is what the owner
    /// actually reads. The `::POPOPX_ECO::` card goes in the *headline* because
    /// `sendResult` truncates the body at 1800 characters, which would otherwise cut
    /// the approval command off the end of a proposal that also carries an `.ics`.
    static func toolResult(_ outcome: PrivacyToolResponse, command: NodeCommand) -> CommandResult {
        let card = outcome.fields["card"]?.stringValue ?? ""
        let refusal = outcome.fields["refusal"]?.stringValue ?? ""
        let headline: String
        if !card.isEmpty {
            headline = card
        } else if !outcome.ok {
            headline = refusal.isEmpty ? "工具调用被拒绝 / tool call refused" : refusal
        } else if let slots = outcome.fields["slotCount"]?.intValue {
            headline = "\(slots) 个空闲区间 / \(slots) free slots"
        } else if let count = outcome.fields["count"]?.intValue {
            headline = "\(count) 条记录 / \(count) records"
        } else if let summary = outcome.fields["summary"]?.stringValue {
            headline = TextKit.truncate(summary, to: 160)
        } else {
            headline = "已完成 / done"
        }
        var metrics: [String: JSONValue] = [
            "namespace": .string(command.serviceId),
            "action": .string(command.action),
            "status": .int(outcome.status)
        ]
        // A receipt is an authorization, so it rides only in the card the owner was
        // handed — never into a metrics blob that gets logged or queued alongside it.
        for key in ["proposalId", "bookingRefId", "state", "slotCount", "busyCount"] {
            if let value = outcome.fields[key] { metrics[key] = value }
        }
        return CommandResult(
            commandID: command.id,
            engine: .shadowCos,
            ok: outcome.ok,
            headline: headline,
            body: toolBody(outcome),
            metrics: metrics,
            cardLabel: "POPOPX 隐私桥接 / Privacy Bridge"
        )
    }

    /// The readable half of a tool reply. The structured JSON stays on the loopback
    /// API, where the assistant asked for it; a chat bubble gets lines a person can
    /// scan, and no raw calendar text is among them because the response carries none.
    static func toolBody(_ outcome: PrivacyToolResponse) -> String {
        var lines: [String] = []
        if let refusal = outcome.fields["refusal"]?.stringValue { lines.append(refusal) }
        if let detail = outcome.fields["detail"]?.stringValue { lines.append(detail) }
        if let window = outcome.fields["event"]?["startLocal"]?.stringValue,
           let until = outcome.fields["event"]?["endLocal"]?.stringValue {
            lines.append("时间 / when: \(window) → \(until)")
        }
        if let expires = outcome.fields["expiresAt"]?.stringValue {
            lines.append("有效期至 / valid until: \(expires)")
        }
        if let slots = outcome.fields["freeSlots"]?.arrayValue, !slots.isEmpty {
            lines.append("空闲 / free:")
            for slot in slots.prefix(8) {
                guard let start = slot["start"]?.stringValue, let end = slot["end"]?.stringValue else { continue }
                lines.append("· \(start) → \(end)")
            }
            if slots.count > 8 { lines.append("… 另有 \(slots.count - 8) 段 / \(slots.count - 8) more") }
        }
        if let summary = outcome.fields["summary"]?.stringValue { lines.append(summary) }
        if let path = outcome.fields["path"]?.stringValue, !summary(path) { lines.append("文件 / file: \(path)") }
        if let target = outcome.fields["target"]?.stringValue { lines.append("目标 / target: \(target)") }
        if let message = outcome.fields["message"]?.stringValue { lines.append(message) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func summary(_ text: String) -> Bool { text.isEmpty }

    // MARK: NodeConsoleFacade

    public func snapshot() async -> ConsoleSnapshot {
        async let profile = environment.profile()
        async let plan = environment.plan()
        async let load = environment.loadSample()
        async let toolchain = environment.toolchain()
        async let install = environment.installState()
        async let identity = signaling.identity()
        async let bridge = signaling.status()
        async let pairing = signaling.currentOffer()
        async let paired = signaling.pairedDevices()
        async let descriptors = engines.descriptors()
        async let runtimes = engines.runtimes()
        async let mesh = engines.meshSummary()
        async let lockdowns = engines.recentLockdowns()
        async let vaults = engines.recentVaults()
        async let events = hub.replay()

        let current = await settings.current()
        let hardware = await profile
        let backlog = await events
        return ConsoleSnapshot(
            node: await identity,
            hardware: hardware,
            // The ladder the page paints is the ladder the engines will run, so it
            // has to carry the owner's model selection rather than only the tier.
            plan: (await plan).applying(selection: current.llmModelOverride, memoryGB: hardware.memoryGB),
            load: await load,
            toolchain: await toolchain,
            install: await install,
            bridge: await bridge,
            pairing: await pairing,
            pairedDevices: await paired,
            descriptors: await descriptors,
            engines: await runtimes,
            settings: current,
            mesh: await mesh,
            recentResults: Array(recent.suffix(20)),
            lockdowns: await lockdowns,
            vaults: await vaults,
            consoleURL: consoleURLString,
            eventsBacklog: Array(backlog.suffix(60)),
            privacy: await privacySnapshot(saved: current)
        )
    }

    /// `nonisolated` because the protocol requirement is synchronous: the console
    /// calls it once per SSE connection, and hopping through the actor would
    /// serialise every browser tab behind whatever the node is rendering.
    public nonisolated func events() -> AsyncStream<ConsoleEvent> {
        let hub = self.hub
        return AsyncStream { continuation in
            let task = Task {
                for await event in await hub.subscribe() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startInstall() async {
        await hub.publish(.install, "控制台触发一键部署 / deploy requested from console", level: .notice)
        await environment.startInstall()
    }

    public func cancelInstall() async {
        await hub.publish(.install, "控制台触发取消部署 / deploy cancel requested", level: .warning)
        await environment.cancelInstall()
    }

    public func setEngineEnabled(_ kind: EngineKind, enabled: Bool) async {
        _ = await settings.mutate { document in
            document.enginesEnabled[kind.rawValue] = enabled
        }
        await engines.setEnabled(kind, enabled: enabled)
        await hub.publish(
            .engine,
            "\(kind.displayNameEn) \(enabled ? "已启用 / enabled" : "已停用 / disabled")",
            level: .notice,
            payload: ["engine": .string(kind.rawValue), "enabled": .bool(enabled)]
        )
    }

    public func rotatePairing() async -> PairingOffer? {
        let offer = await signaling.rotateOffer()
        if let offer {
            await hub.publish(
                .pairing,
                "已生成新的配对二维码 / new pairing offer minted",
                level: .notice,
                payload: ["expiresIn": .int(offer.secondsRemaining()), "code": .string(offer.code)]
            )
        }
        return offer
    }

    public func pairingQR(pixelSize: Int) async -> QRAsset? {
        await signaling.qrAsset(pixelSize: pixelSize)
    }

    public func revokePairing(publicKey: String) async {
        await signaling.revokeDevice(publicKey: publicKey)
        await hub.publish(
            .pairing,
            "已撤销设备 / device revoked: \(TextKit.truncate(publicKey, to: 16))",
            level: .warning
        )
    }

    public func updateSettings(_ incoming: NodeSettings) async -> NodeSettings {
        let existing = await settings.current()
        // The console posts the whole document, so a browser tab that was opened
        // before the node rotated its engine switches must not silently re-enable
        // something the owner switched off in the menu bar in the meantime. Merge
        // the switches the node owns and keep everything the owner edits here.
        var merged = incoming
        merged.enginesEnabled = existing.enginesEnabled.merging(incoming.enginesEnabled) { _, new in new }
        merged.mesh.accruedPoints = existing.mesh.accruedPoints
        merged.mesh.settledJobs = existing.mesh.settledJobs
        merged.sentinel.lastLockAt = existing.sentinel.lastLockAt
        merged.ark.lastHeartbeatAt = existing.ark.lastHeartbeatAt
        merged.ark.releasedAt = existing.ark.releasedAt
        let stored = await settings.apply(merged)
        // The bridges read their switches, directories and timezone out of the same
        // document, so saving it is the only way they change.
        await configurePrivacy(from: stored)
        await hub.publish(
            .settings,
            "配置已保存（修订 \(stored.revision)）/ settings saved",
            level: .success,
            payload: ["revision": .int(stored.revision)]
        )
        return stored
    }

    /// Parses a human-typed `::popopx_sys::NODE_CMD::service::action::payload`
    /// line from the console's developer drawer. Commands injected this way are
    /// marked `authenticated: false`: they came from the owner's own browser on
    /// the loopback interface, not from a paired device key, and engines that care
    /// can check the flag.
    public func submitWireCommand(_ text: String) async -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = NodeConsole.parse(wire: trimmed) else {
            return CommandResult(
                engine: .shadowCos,
                ok: false,
                headline: "无法解析指令 / could not parse",
                body: "期望格式 / expected: \(NodeWire.commandPrefix){serviceId}::{action}::{payload}"
            )
        }
        // The drawer speaks the same grammar as the phone, so a card copied out of
        // the chat can be pasted here and approved locally.
        if let call = PrivacyToolRoute.parseCommand(
            serviceId: command.serviceId,
            action: command.action,
            payload: command.payload
        ) {
            var shaped = call
            shaped.source = "console-drawer"
            let outcome = await privacyTool(shaped)
            let result = Self.toolResult(outcome, command: command)
            record(result)
            await hub.publish(.result, result.cardText, level: result.ok ? .success : .error)
            return result
        }
        let result = await engines.execute(command)
        record(result)
        await hub.publish(.result, result.cardText, level: result.ok ? .success : .error)
        return result
    }

    public func invokeEngine(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult {
        let result = await engines.invoke(kind, action: action, payload: payload)
        record(result)
        await hub.publish(.result, result.cardText, level: result.ok ? .success : .error)
        return result
    }

    /// Reveals an artifact in Finder. The path comes from the browser, so it is
    /// refused unless it resolves inside the node's own data directory — otherwise
    /// a console bug would turn into "open any path the owner has never seen".
    public func openInFinder(path: String) async {
        guard let url = AppPaths.resolveContained(userPath: path) else {
            await hub.publish(
                .system,
                "拒绝访问节点数据目录之外的路径 / refused a path outside the node data directory",
                level: .warning,
                payload: ["probe": .string(Digest.short(Data(path.utf8), length: 8))]
            )
            return
        }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: NodeConsoleFacade — privacy bridges

    /// The panel's data. With no stack built, the answer is the honest one: every
    /// switch off, nothing pending, nothing ever written.
    private func privacySnapshot(saved: NodeSettings) async -> PrivacyBridgeSnapshot {
        guard let privacy else {
            return PrivacyBridgeSnapshot(
                calendarAllowed: false,
                workspaceReadAllowed: false,
                workspaceWriteAllowed: false,
                eventAuthorization: PrivacyAuthorization.notDetermined,
                directories: [],
                reachableDirectories: [],
                pendingProposals: [],
                bookings: [],
                auditLog: [],
                notifyOnProposal: true,
                // Even with nothing switched on, the console edits the saved
                // document rather than an empty one.
                bridges: saved.bridges.normalised
            )
        }
        return await privacy.engine.snapshot()
    }

    public func privacyTool(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard let privacy else {
            return PrivacyToolResponse.failure(
                503,
                "隐私桥接未启用 / the privacy bridge is switched off",
                extra: ["switch": .string(call.namespace.rawValue)]
            )
        }
        // Swept on the way past the door, so a proposal that aged out while nobody
        // was looking is expired before it can be approved, and the answer the
        // caller gets is the same one the panel will show afterwards.
        await privacy.ledger.expire()
        let outcome = await privacy.engine.handle(call)
        await hub.publish(
            .privacy,
            "\(call.namespace.rawValue) · \(call.action) → \(outcome.ok ? "已受理 / answered" : "已拒绝 / refused")",
            level: outcome.ok ? .notice : .warning,
            payload: [
                "namespace": .string(call.namespace.rawValue),
                "action": .string(call.action),
                "status": .int(outcome.status),
                "source": .string(call.source)
            ]
        )
        return outcome
    }

    /// Applies a console 「批准 / 驳回」 click.
    ///
    /// The receipt is minted here rather than handed to the page: the panel's poll
    /// carries proposal ids, and a payload that also carried the signing token would turn
    /// any leak of the console response into a write capability. The ledger still sees
    /// the same `id + verb` HMAC it does for a phone card reply, so both entry points
    /// walk one validated road to the executor and neither can approve a proposal other
    /// than the one it was shown.
    public func privacyDecision(domain: String, id: String, verb: String) async -> PrivacyToolResponse {
        guard let privacy, let namespace = PrivacyToolNamespace(rawValue: domain) else {
            return PrivacyToolResponse.failure(
                503,
                "隐私桥接未启用 / the privacy bridge is switched off",
                extra: ["switch": .string(domain)]
            )
        }
        await privacy.ledger.expire()
        let receipt = await privacy.ledger.receipt(id: id, verb: verb)
        let call = PrivacyToolCall(
            namespace: namespace,
            action: verb,
            id: id,
            payload: ["receipt": .string(receipt)],
            source: "console"
        )
        let outcome = await privacy.engine.handle(call)
        await hub.publish(
            .privacy,
            "控制台\(verb == PrivacyToolAction.approve ? "批准" : "驳回") · \(domain) · \(outcome.ok ? "已执行 / applied" : "未执行 / not applied")",
            level: outcome.ok ? .notice : .warning,
            payload: [
                "namespace": .string(domain),
                "action": .string(verb),
                "status": .int(outcome.status),
                "source": .string("console")
            ]
        )
        return outcome
    }

    /// Console-only: raises the TCC dialog. No tool route reaches this, because an
    /// authorization grant is the one thing a caller must not be able to ask for.
    public func requestCalendarAccess() async -> String {
        guard let privacy else { return PrivacyAuthorization.notDetermined }
        let state = await privacy.engine.requestCalendarAccess()
        await hub.publish(
            .privacy,
            "日历授权状态 · \(state) / calendar authorization state",
            level: state == PrivacyAuthorization.denied ? .warning : .notice,
            payload: ["authorization": .string(state)]
        )
        return state
    }

    /// Delegates to the wire parser in the contract so the console, the bridge and
    /// the test target all share one copy of the grammar.
    public static func parse(wire: String) -> NodeCommand? {
        NodeWire.parseCommand(wire)
    }
}

// MARK: - Host model

/// Owns the process lifetime: creates the directories, builds the subsystems,
/// binds the console, and keeps a polled snapshot for SwiftUI to render.
@MainActor
final class NodeModel: ObservableObject {
    @Published var snapshot: ConsoleSnapshot?
    @Published var consoleURL: String = ""
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var loginItemEnabled = false

    let headless: Bool
    private var console: NodeConsole?
    private var server: LocalWebConsoleServer?
    private var refreshTask: Task<Void, Never>?
    private var signalsInstalled = false

    init(headless: Bool) {
        self.headless = headless
    }

    /// The one model per process. SwiftUI's `App` protocol requires a
    /// zero-argument `init()`, so the composition root cannot inject the model the
    /// way a plain view can; both the CLI entry point and the scene resolve it
    /// through here, which keeps a single stack, socket and bridge per launch.
    static func current(headless: Bool = false) -> NodeModel {
        if let existing = shared { return existing }
        let created = NodeModel(headless: headless)
        shared = created
        return created
    }

    private static var shared: NodeModel?

    /// Idempotent; safe to call from both `--headless` and the GUI path.
    func bootstrap() async {
        if isRunning { return }
        do {
            try AppPaths.ensureLayout()
        } catch {
            lastError = "无法创建数据目录 / could not create the data directory: \(AppPaths.anonymise(error.localizedDescription))"
            return
        }

        let stack = Self.buildStack()
        console = stack.console
        server = stack.server

        // Bind the socket before waking the bridge: the console URL is only
        // trustworthy once the listener exists, and a failed bind must not leave a
        // chat daemon running that nothing can be paired through.
        do {
            try await stack.server.start()
        } catch {
            lastError = "本地控制台启动失败 / console failed to bind: \(AppPaths.anonymise(error.localizedDescription))"
            return
        }

        let url = await stack.server.url.absoluteString
        consoleURL = url
        await stack.console.start(consoleURL: url)
        isRunning = true
        loginItemEnabled = Self.loginItemRegistered

        if await SettingsStore.shared.current().autoStartConsole {
            await stack.server.openInBrowser()
        }

        await ConsoleEventHub.shared.publish(
            .system,
            "控制台监听 \(NodeWire.consoleHost):\(NodeWire.consolePort) / console listening",
            level: .success
        )
        startPolling()
    }

    /// Blocks until SIGINT/SIGTERM, so `--headless` works under launchd or tmux.
    func runHeadless() async {
        installSignalHandlers()
        print("""
        \(NodeVersion.current.description)
        console: \(consoleURL)
        data:    \(AppPaths.anonymise(url: AppPaths.root))
        (press Ctrl-C to stop)
        """)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func shutdown() async {
        refreshTask?.cancel()
        refreshTask = nil
        await server?.stop()
        await console?.stop()
        isRunning = false
    }

    func refreshNow() {
        Task {
            guard let snapshot = await console?.snapshot() else { return }
            self.snapshot = snapshot
            self.loginItemEnabled = Self.loginItemRegistered
        }
    }

    /// The menu bar renders from the same snapshot the browser gets, on a slower
    /// cadence than SSE because nothing here needs sub-second accuracy.
    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let console = self.console else { return }
                let snapshot = await console.snapshot()
                self.snapshot = snapshot
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Menu actions

    func openConsole() {
        guard !consoleURL.isEmpty, let url = URL(string: consoleURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyConsoleURL() {
        guard !consoleURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(consoleURL, forType: .string)
    }

    func setEngine(_ kind: EngineKind, enabled: Bool) {
        Task { await console?.setEngineEnabled(kind, enabled: enabled) }
    }

    func toggleMeshSharing() {
        Task {
            guard let console else { return }
            var document = await SettingsStore.shared.current()
            document.mesh.sharingEnabled.toggle()
            _ = await console.updateSettings(document)
            await ConsoleEventHub.shared.publish(
                .mesh,
                document.mesh.sharingEnabled ? "空闲算力共享已开启 / mesh sharing on" : "空闲算力共享已暂停 / mesh sharing paused",
                level: .notice
            )
        }
    }

    func rotatePairingNow() {
        Task { _ = await console?.rotatePairing() }
    }

    /// Pins the local language model to a catalog id (any reference the catalog
    /// recognises works), or clears the pin with an empty string so the node goes
    /// back to the hardware tier. Same settings document the console edits, so the
    /// two halves of the UI cannot disagree.
    func setLLMModel(_ selection: String) {
        Task {
            guard let console else { return }
            var document = await SettingsStore.shared.current()
            document.llmModelOverride = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await console.updateSettings(document)
            await ConsoleEventHub.shared.publish(
                .install,
                document.llmModelOverride.isEmpty
                    ? "本地模型回到内存档位 / local model back to the hardware tier"
                    : "本地模型切换为 \(document.llmModelOverride) / local model set to \(document.llmModelOverride)",
                level: .notice
            )
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = enabled
            Task {
                guard let console else { return }
                var document = await SettingsStore.shared.current()
                document.launchAtLogin = enabled
                _ = await console.updateSettings(document)
            }
        } catch {
            // A binary launched by `swift run` is not a proper bundle, so
            // ServiceManagement legitimately refuses there; the DMG build works.
            lastError = "开机自启注册失败（需以 .app 形式运行）/ \(error.localizedDescription)"
        }
    }

    static var loginItemRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The only place in the product that names the concrete subsystem types.
    ///
    /// Everything downstream depends on the four frozen protocols, so if a module
    /// changes its initializer this one function is what breaks — and nothing else
    /// has to be re-read. The node identity is deliberately not constructed here:
    /// it is derived from the Ed25519 key the signalling layer owns, because that
    /// key is what the pairing QR signs.
    private static func buildStack() -> (console: NodeConsole, server: LocalWebConsoleServer) {
        let hub = ConsoleEventHub.shared
        let settings = SettingsStore.shared
        let console = NodeConsole(
            environment: NodeEnvironment(),
            signaling: MacNodePopopxBridge(settings: settings, hub: hub),
            engines: TenBusinessEngines(settings: settings, hub: hub),
            settings: settings,
            hub: hub
        )
        return (console, LocalWebConsoleServer(facade: console))
    }

    private func installSignalHandlers() {
        guard !signalsInstalled else { return }
        signalsInstalled = true
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { await self?.shutdown() }
                exit(0)
            }
            source.resume()
        }
    }
}

// MARK: - SwiftUI host

struct PopopxMacNodeApp: App {
    @NSApplicationDelegateAdaptor(NodeAppDelegate.self) private var delegate
    @StateObject private var model: NodeModel

    /// `App` gives us no way to inject the composition root, so the scene adopts
    /// the model the CLI dispatcher already created and bootstrapped.
    init() {
        let model = NodeModel.current()
        _model = StateObject(wrappedValue: model)
        delegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(nsImage: BrandIcon.menuBarImage)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps the process out of the Dock and the Command-Tab list even if the
/// `LSUIElement` key is missing from a hand-assembled bundle.
final class NodeAppDelegate: NSObject, NSApplicationDelegate {
    var model: NodeModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let model else { return }
        Task { await model.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        let model = self.model
        Task { await model?.shutdown() }
    }
}

// MARK: - Menu content

struct MenuBarContent: View {
    @EnvironmentObject private var model: NodeModel

    /// The menu speaks the node's language, not the browser's: the same setting
    /// the phone and the console write, so one choice cannot paint two halves
    /// of the product in two languages.
    private var language: ConsoleLanguage { model.snapshot?.settings.language ?? .system }

    private func label(_ zh: String, _ en: String) -> String {
        language.text(zh: zh, en: en)
    }

    private var hardwareLine: String {
        guard let snapshot = model.snapshot else { return label("扫描中…", "Scanning…") }
        return snapshot.hardware.shortLabel
    }

    private var activeTasks: Int {
        model.snapshot?.engines.filter { $0.busy }.count ?? 0
    }

    private var daemonLabel: String {
        guard let bridge = model.snapshot?.bridge else { return "—" }
        switch bridge.daemon {
        case .running: return label("SMP 在线 · \(bridge.pairedDevices) 台设备",
                                    "SMP online · \(bridge.pairedDevices) device(s)")
        case .degraded: return label("SMP 降级 · \(bridge.lastError ?? "")",
                                     "SMP degraded · \(bridge.lastError ?? "")")
        case .starting: return label("SMP 启动中…", "SMP starting…")
        case .missingBinary: return label("未安装 popopx-chat",
                                          "popopx-chat not installed")
        case .stopped: return label("SMP 已停止", "SMP stopped")
        }
    }

    var body: some View {
        Section {
            LabeledContent(hardwareLine, value: label("\(activeTasks) 个任务", "\(activeTasks) task(s)"))
            LabeledContent(daemonLabel, value: model.snapshot?.mesh.acceptingNow == true
                ? label("接单中", "Accepting")
                : label("不接单", "Paused"))
        }

        Divider()

        Button(label("打开网页控制台", "Open Web Console")) { model.openConsole() }
            .keyboardShortcut(",", modifiers: [.command, .shift])
        Button(label("复制配对地址", "Copy Console URL")) { model.copyConsoleURL() }
            .disabled(model.consoleURL.isEmpty)
        Button(label("立即重新扫描", "Rescan Now")) { model.refreshNow() }
        Button(label("生成新的配对二维码", "New Pairing QR")) { model.rotatePairingNow() }

        Divider()

        Button(model.snapshot?.mesh.sharingEnabled == true
               ? label("暂停空闲算力接单", "Pause Mesh Sharing")
               : label("开启空闲算力接单", "Resume Mesh Sharing")) {
            model.toggleMeshSharing()
        }

        Menu(label("十大引擎", "Engines")) {
            if let snapshot = model.snapshot {
                ForEach(snapshot.descriptors) { descriptor in
                    Toggle(
                        descriptor.kind.displayName(for: language),
                        isOn: Binding(
                            get: { snapshot.settings.isEnabled(descriptor.kind) },
                            set: { model.setEngine(descriptor.kind, enabled: $0) }
                        )
                    )
                }
            } else {
                Text(label("加载中…", "Loading…")).disabled(true)
            }
        }

        Menu(label("本地模型", "Local Model")) {
            if let snapshot = model.snapshot {
                let memoryGB = snapshot.hardware.memoryGB
                Picker(label("语言模型", "Language model"), selection: Binding(
                    get: { snapshot.settings.llmModelOverride },
                    set: { model.setLLMModel($0) }
                )) {
                    Text(label("默认 · 按内存档位", "Default · by memory tier")).tag("")
                    ForEach(ModelCatalog.options) { option in
                        // The catalog id, not the Ollama reference: it is the token
                        // `settings.json` stores and the key `model_refs.json` maps.
                        Text(option.displayName).tag(option.id)
                    }
                }
                Divider()
                if let option = ModelCatalog.option(matching: snapshot.plan.llmRef) {
                    let verdict = option.admission(memoryGB: memoryGB)
                    LabeledContent(
                        label("常驻估算", "Estimated resident"),
                        value: "\(option.weightGigabytes) GB + \(option.contextOverheadGB) GB ≈ \(option.estimatedResidentGB) GB"
                    )
                    LabeledContent(
                        label("内存准入", "Memory admission"),
                        value: language.text(zh: verdict.titleZh, en: verdict.titleEn)
                    )
                    Text(option.pullCommand(for: snapshot.plan.llmRef))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if let hint = option.ggufCreateHint {
                        Text(hint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !verdict.permitsLocalLoad {
                        Text(label(
                            "预计触发内存交换，节点已拒绝本机重载任务。",
                            "Swap is expected here, so heavy local jobs are refused."
                        ))
                        .foregroundStyle(.orange)
                    }
                } else {
                    // A pin the catalog has never seen: the node still runs it, so
                    // name it and say where the numbers come from.
                    Text(snapshot.plan.llmRef)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Text(label(
                        "该模型不在目录内，内存数字仍是本档位的估算值。",
                        "This model is not in the catalog, so the figures are still the tier's estimate."
                    ))
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(label("加载中…", "Loading…")).disabled(true)
            }
        }

        Toggle(label("开机自启", "Launch at Login"), isOn: Binding(
            get: { model.loginItemEnabled },
            set: { model.setLaunchAtLogin($0) }
        ))

        if let error = model.lastError {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Divider()

        Button(label("退出 POPOPX Mac Node", "Quit POPOPX Mac Node")) {
            Task {
                await model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")

        Text(NodeVersion.current.semanticString)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Brand icon

/// Programmatic brand mark: a violet shield with a node lattice, drawn with
/// CoreGraphics so the repository ships no binary asset and the DMG script can
/// rasterise every required size from the same source of truth.
enum BrandIcon {
    static let accentTop = NSColor(srgbRed: 0.55, green: 0.36, blue: 1.00, alpha: 1.0)
    static let accentBottom = NSColor(srgbRed: 0.26, green: 0.13, blue: 0.66, alpha: 1.0)

    /// Shield outline in AppKit's bottom-left coordinate space: flat, broad
    /// shoulders at the top and a point at the bottom. Rounded with `radius` so it
    /// survives being drawn at 16 px in the menu bar.
    static func shieldPath(in rect: NSRect, radius: CGFloat? = nil) -> NSBezierPath {
        let corner = radius ?? rect.width * 0.16
        let shoulder = rect.minY + rect.height * 0.58
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + corner, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX - corner, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - corner, y: rect.maxY - corner),
            radius: corner,
            startAngle: 90,
            endAngle: 0,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.maxX, y: shoulder))
        path.curve(
            to: NSPoint(x: rect.midX, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            controlPoint2: NSPoint(x: rect.midX + rect.width * 0.30, y: rect.minY + rect.height * 0.03)
        )
        path.curve(
            to: NSPoint(x: rect.minX, y: shoulder),
            controlPoint1: NSPoint(x: rect.midX - rect.width * 0.30, y: rect.minY + rect.height * 0.03),
            controlPoint2: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.22)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - corner))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + corner, y: rect.maxY - corner),
            radius: corner,
            startAngle: 180,
            endAngle: 90,
            clockwise: true
        )
        path.close()
        return path
    }

    /// Rasterises the mark at an arbitrary square size. Used by `--render-icon`
    /// for every iconutil size and by the menu bar label, so there is exactly one
    /// drawing routine and no PNG in the repository.
    static func bitmap(pixelSize: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context

        let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        NSColor.clear.setFill()
        canvas.fill()

        let inset = canvas.insetBy(dx: CGFloat(pixelSize) * 0.06, dy: CGFloat(pixelSize) * 0.06)
        let shield = shieldPath(in: inset)

        // Vertical violet fill, clipped to the shield so the gradient never
        // bleeds into the transparent margin.
        shield.addClip()
        NSGradient(starting: accentTop, ending: accentBottom)?.draw(in: inset, angle: -90)

        let glyph = NSColor.white.withAlphaComponent(0.94)
        let cg = context.cgContext
        cg.resetClip()

        shield.lineWidth = max(1, CGFloat(pixelSize) * 0.032)
        glyph.setStroke()
        shield.stroke()

        // Node lattice: one hub with three paired endpoints, drawn as thick
        // round-capped links so it still reads at 16 px.
        let hub = NSPoint(x: inset.midX, y: inset.midY + inset.height * 0.05)
        let dot = max(1.5, CGFloat(pixelSize) * 0.05)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        glyph.setFill()
        for offset in latticeOffsets {
            let point = NSPoint(
                x: hub.x + offset.x * inset.width * 0.21,
                y: hub.y + offset.y * inset.height * 0.20
            )
            let link = NSBezierPath()
            link.move(to: hub)
            link.line(to: point)
            link.lineWidth = max(1, CGFloat(pixelSize) * 0.022)
            link.stroke()
            NSBezierPath(ovalIn: NSRect(
                x: point.x - dot * 0.7,
                y: point.y - dot * 0.7,
                width: dot * 1.4,
                height: dot * 1.4
            )).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: hub.x - dot, y: hub.y - dot, width: dot * 2, height: dot * 2)).fill()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Left, right and below the hub — three paired devices, which is also what
    /// the whitelist looks like on a typical owner's machine.
    private static let latticeOffsets: [CGPoint] = [
        CGPoint(x: -1, y: -0.5),
        CGPoint(x: 1, y: -0.5),
        CGPoint(x: 0, y: 1.1)
    ]

    static func pngData(pixelSize: Int) -> Data? {
        guard let rep = bitmap(pixelSize: pixelSize) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Menu-bar glyph. Not a template image: the product asks for a purple shield
    /// that stays recognisable next to monochrome system items.
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        accentBottom.setFill()
        shieldPath(in: rect).fill()
        let gradient = NSGradient(starting: accentTop, ending: accentBottom)
        shieldPath(in: rect).setClip()
        gradient?.draw(in: rect, angle: -90)
        NSGraphicsContext.current?.cgContext.resetClip()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = shieldPath(in: rect)
        border.lineWidth = 0.9
        border.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()
}

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
        let mcp: MCPBridge
        let smartHome: SmartHomeBridge
        let calDav: CalDavBridge
    }

    /// Reads `config/mcp_servers.json`. Built unconditionally, unlike the stack: the console's
    /// 「协议桥接」 card has to be able to say *why* nothing is reachable — no file, no enabled
    /// entry, or the switch is off — and that answer comes from the registry, not from a bridge.
    private let hubRegistry = MCPServerRegistry(fileURL: AppPaths.mcpServersFile)

    /// Also unconditional, and deliberately holding neither a gateway nor a sandbox until the
    /// stack exists: it reports `off` for those rows rather than being absent, because "the
    /// owner switched it off" and "this node cannot answer" are different cards.
    private let discovery = LocalCapabilityDiscovery()

    /// Built at `start()` and re-configured on every settings save. Both hold no
    /// socket: the update centre dials only on an explicit check, and the
    /// aggregator only on its interval or a click.
    private var updateCenter: UpdateCenter?
    private var discoverCenter: DiscoverCenter?

    /// Owns the local God's Eye View process and its one MCP registration. Built at
    /// `start()`; until then the card reads the saved document and nothing runs.
    private var godsEye: GodsEyeViewBridge?
    /// Its own store instance: the Keychain service is shared, and in a bare
    /// executable this is the same process-volatile answer the hub bridges get.
    private let godsEyeSecrets: any HubSecretStoring = HubSecrets.makeStore()

    /// Built the first time the owner switches the assistant on, then kept across
    /// switches so the SQLite audit trail and the approval queue survive a reboot of
    /// the card. Default off costs no database and no key file.
    private var assistant: PersonalAssistantManager?
    /// The adapter the manager is holding, kept here so the doctor and the watchdog
    /// can probe the same runtime without reaching through the manager's internals.
    private var assistantInkling: Inkling2MiniAdapter?
    /// Sealed episodic index and the voice pipeline that feeds it. Built with the
    /// assistant and kept across switches, so an approval queue survives a reboot.
    private var rag: LocalEpisodicRAG?
    private var voice: LocalVoiceMemoPipeline?
    /// Built once at `start()`. The LaunchAgent switch and its last check rows live
    /// here even when the assistant is off, because these are node-level seams.
    private var watchdog: SystemWatchdog?
    /// Owns the one model pull the node allows at a time. It lives here, not in a
    /// browser tab: closing the console must not cancel a multi-gigabyte download,
    /// and every poll and every menu-bar read sees the same progress card.
    private let modelPull = ModelPullCenter()
    private let assistantSecrets: any HubSecretStoring = HubSecrets.makeStore()
    private let assistantProvider = AssistantLiveSentinelProvider()

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
        var current = await settings.current()
        // The card's association is an MCP registration, so switching the card on is
        // also a decision to let the MCP tier run. The writer applies it once, where
        // it is visible in the settings document, not only in this process's memory.
        let synchronised = Self.synchronisingGodsEyeMCP(current)
        if synchronised != current {
            current = await settings.apply(synchronised)
        }
        await configurePrivacy(
            from: current,
            nodeReference: Digest.short(Data(identity.nodeId.utf8), length: 8)
        )
        await configureUpdates(from: current)
        await configureDiscover(from: current)
        await configureGodsEye(from: current)
        await configureAssistant(from: current)
        await assistant?.setLightweight(current.isLightweight)
        await configureWatchdog()
        if let bridge = signaling as? MacNodePopopxBridge {
            await bridge.setInboundFileHandler { [weak self] url in
                await self?.handleInboundAudio(url)
            }
        }
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
        await modelPull.cancel()
        await assistant?.stop()
        await godsEye?.shutdown()
        await signaling.stop()
        await hub.publish(.system, "节点已停止 / node stopped", level: .warning)
    }

    /// Pushes the current wall clock through so time-based engines (the Ark
    /// heartbeat watchdog, the mesh idle windows, the morning schedule) get a
    /// nudge even when the browser is closed and nobody is polling.
    private func tick() async {
        await hub.publish(.system, "心跳 \(Date().ppxClock)", level: .debug)
        // Detection is automatic; installation never is. `tick()` returns a release
        // only when one verified, is newer, is not snoozed and was not announced.
        if let release = await updateCenter?.tick() {
            await announceUpdate(release)
        }
        if let outcome = await discoverCenter?.tick(),
           case let .refreshed(feed, path, newIDs) = outcome,
           !newIDs.isEmpty {
            await publishDiscover(feed: feed, path: path)
        }
        // The watchdog enforces its own 60 s floor and its own alert cooldown;
        // `tick()` is the heartbeat that gives it a chance to observe the Mac.
        _ = await watchdog?.check()
    }

    /// SMP-originated commands run regardless of the console being open; the
    /// whitelist check already happened inside the bridge.
    private func route(_ command: NodeCommand) async {
        // The two control namespaces are not subscription businesses: they are
        // answered here, before engine dispatch, and they share one handler with
        // the console drawer so a card copied out of chat approves the same road.
        if command.serviceId == "updates" {
            let result = await handleUpdateCommand(command, source: command.authenticated ? "phone" : "phone-unauthenticated")
            record(result)
            let delivered = await signaling.deliver(result, to: command.serviceId)
            await hub.publish(
                .update,
                delivered ? "更新回执已回传 / update reply delivered" : "更新回执待回传 / queued in outbox",
                level: result.ok ? .notice : .warning,
                payload: ["commandId": .string(command.id), "delivered": .bool(delivered)]
            )
            return
        }
        if command.serviceId == "discover" {
            await routeDiscover(command)
            return
        }
        // The assistant's approval replies arrive as ordinary commands on the paired
        // session; the receipt in the payload is the same one the phone card minted.
        if command.serviceId == "assistant" {
            let result = await handleAssistantCommand(
                command, source: command.authenticated ? "phone" : "phone-unauthenticated"
            )
            record(result)
            let delivered = await signaling.deliver(result, to: command.serviceId)
            await hub.publish(
                .system,
                delivered ? "私人助手回执已回传 / decision delivered" : "私人助手回执待回传 / queued in outbox",
                level: result.ok ? .notice : .warning,
                payload: ["commandId": .string(command.id), "delivered": .bool(delivered)]
            )
            return
        }
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
    ///
    /// The hub bridges are constructed with the stack rather than separately because a
    /// write-shaped MCP or home call *is* a ledger proposal: the approval queue, its HMAC
    /// receipts and its audit log are the gate the feature depends on, and a second queue
    /// would be a second answer to "was this approved".
    private func configurePrivacy(from settings: NodeSettings, nodeReference: String = "") async {
        if !nodeReference.isEmpty { self.nodeReference = nodeReference }
        var bridges = settings.bridges.normalised
        if bridges.timezoneIdentifier.isEmpty {
            bridges.timezoneIdentifier = TimeZone.current.identifier
        }
        let hubs = settings.hubs.normalised
        // The association is an MCP registration: a Gods Eye View card that is on
        // while the MCP tier is off would register a server nobody can reach, so the
        // effective config carries the switch even if a hand edit dropped it. The
        // settings writer persists the same decision on save.
        var effectiveHubs = hubs
        if settings.godsEyeConfig.enabled, !effectiveHubs.allowMcpBridge {
            effectiveHubs.allowMcpBridge = true
        }
        // The file is re-read on every settings save, never watched: an owner edits
        // `config/mcp_servers.json` with an editor and then clicks 「重新载入」 or toggles a
        // switch. A watcher would change what this node is willing to execute with no click.
        await hubRegistry.reload()
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
            await stack.engine.applyHubConfig(effectiveHubs)
            await stack.executor.update(gateway: stack.gateway, sandbox: sandbox)
            await discovery.update(config: effectiveHubs, gateway: stack.gateway, sandbox: sandbox)
            return
        }
        let hubAsked = effectiveHubs.allowMcpBridge || effectiveHubs.allowSmartHomeBridge
            || effectiveHubs.allowCalDavBridge
            || !effectiveHubs.discovery.lanTargets.isEmpty
            || effectiveHubs.calDav.servers.contains { $0.enabled }
        guard bridges.allowCalendarAccess || bridges.allowWorkspaceRead || bridges.allowWorkspaceWrite
            || !bridges.workspaceDirectories.isEmpty || hubAsked else {
            // Nothing is switched on yet, so nothing is constructed: no event store,
            // no key file, no ledger. A disabled bridge must cost the process
            // nothing it could later be accused of holding.
            await discovery.update(config: effectiveHubs, gateway: nil, sandbox: sandbox)
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
        let secrets = HubSecrets.makeStore()
        let mcp = MCPBridge(
            registry: hubRegistry, ledger: ledger, config: effectiveHubs,
            toolGate: GodsEyeViewToolGate()
        )
        let smartHome = SmartHomeBridge(config: effectiveHubs, secrets: secrets, ledger: ledger)
        let calDav = CalDavBridge(config: effectiveHubs, secrets: secrets)
        let engine = PrivacyToolEngine(
            config: bridges,
            gateway: gateway,
            ledger: ledger,
            hub: executor,
            sandbox: sandbox,
            nodeReference: self.nodeReference,
            mcp: mcp,
            smartHome: smartHome,
            calDav: calDav
        )
        // After the ledger has this executor, so an approval executed from the phone finds the
        // hub bridges attached rather than failing with "桥接未装配".
        await engine.attachHubBridges()
        await discovery.update(config: effectiveHubs, gateway: gateway, sandbox: sandbox)
        privacy = PrivacyStack(
            gateway: gateway,
            executor: executor,
            ledger: ledger,
            engine: engine,
            mcp: mcp,
            smartHome: smartHome,
            calDav: calDav
        )
    }

    // MARK: Signed updates and Discover

    /// Built once and re-configured in place: the centre owns persisted state and a
    /// verified pending offer, and throwing the actor away on every settings save
    /// would forget both.
    private func configureUpdates(from settings: NodeSettings) async {
        let config = settings.updateConfig.normalised
        if let updateCenter {
            await updateCenter.update(config: config)
            return
        }
        updateCenter = UpdateCenter(
            config: config,
            transport: URLSessionUpdateTransport(),
            installer: WorkspaceUpdateInstaller(),
            signer: PrivacyApprovalSigner.loadOrCreate(at: AppPaths.updateApprovalKeyFile),
            stateStore: UpdateStateStore(url: AppPaths.updateStateFile),
            stagingDirectory: AppPaths.updateStaging,
            currentVersion: { NodeVersion.current },
            audit: { [weak self] entry in
                await self?.recordUpdateAudit(entry)
            }
        )
    }

    /// The aggregator gets its own scope roots (home and the node tree), its own
    /// signing key and its own state file. Folders are read locally; feeds leave
    /// only through `EdgeBoundary.privateNetworkOnly`; MCP output is read-only.
    private func configureDiscover(from settings: NodeSettings) async {
        let config = settings.discoverConfig.normalised
        if let discoverCenter {
            await discoverCenter.update(config: config)
            return
        }
        discoverCenter = DiscoverCenter(
            config: config,
            transport: URLSessionUpdateTransport(),
            mcpCall: { [weak self] source in
                guard let self else {
                    return .failure(DiscoverMCPFailure("节点已停止 / the node is gone"))
                }
                return await self.discoverMCPText(source)
            },
            keyURL: AppPaths.discoverSigningKeyFile,
            feedFile: AppPaths.discoverFeedFile,
            stateFile: AppPaths.discoverStateFile,
            scopeRoots: [FileManager.default.homeDirectoryForCurrentUser, AppPaths.root],
            nodeID: { [weak self] in
                guard let self else { return "" }
                return await self.currentNodeID()
            },
            audit: { [weak self] entry in
                await self?.recordDiscoverAudit(entry)
            }
        )
    }

    private func currentNodeID() async -> String {
        await signaling.identity().nodeId
    }

    // MARK: God's Eye View

    /// Switches the card on ⇒ the MCP tier is available to carry the association.
    /// The reverse is not implied: switching the card off leaves the owner's other
    /// MCP servers exactly as they were.
    private static func synchronisingGodsEyeMCP(_ settings: NodeSettings) -> NodeSettings {
        guard settings.godsEyeConfig.enabled, !settings.hubs.allowMcpBridge else { return settings }
        var hubs = settings.hubs
        hubs.allowMcpBridge = true
        return settings.withHubs(hubs)
    }

    /// Built once and re-configured in place, like the update centre: the bridge owns
    /// a verified-install cache and the running process, and replacing the actor on a
    /// settings save would lose both. The MCP bridge is handed in on every update
    /// because the privacy stack may have been rebuilt with a new ledger.
    private func configureGodsEye(from settings: NodeSettings) async {
        let config = settings.godsEyeConfig.normalised
        if let godsEye {
            await godsEye.update(config: config, mcp: privacy?.mcp)
            return
        }
        godsEye = GodsEyeViewBridge(
            config: config,
            registry: hubRegistry,
            mcp: privacy?.mcp,
            secrets: godsEyeSecrets
        )
    }

    // MARK: Personal assistant

    /// Builds the assistant the first time it is switched on, then re-applies every
    /// save. The default-off path constructs nothing: no SQLite file, no HMAC key,
    /// no IMAP endpoint. Once built it is kept across switches so the audit trail
    /// and the approval queue survive the card being turned off and on again.
    private func configureAssistant(from settings: NodeSettings, now: Date = Date()) async {
        assistantProvider.set(privacy?.smartHome)
        let config = settings.assistantConfig.normalised
        var hubs = settings.hubs.normalised
        if settings.godsEyeConfig.enabled, !hubs.allowMcpBridge {
            hubs.allowMcpBridge = true
        }
        if let assistant {
            await assistant.apply(
                config: config,
                privacy: settings.bridges.normalised,
                hub: hubs,
                godsEyeEnabled: settings.godsEyeConfig.enabled,
                now: now
            )
            return
        }
        guard config.enabled else { return }
        let store = AssistantAuditStore(url: AppPaths.assistantDatabaseFile)
        let gate = AssistantApprovalGate(
            signer: AssistantApprovalSigner.loadOrCreate(at: AppPaths.assistantApprovalKeyFile),
            audit: store
        )
        let scheduler = LocalTaskScheduler(config: config, store: store)
        let mail = MailAssistantBridge(
            config: config.mail,
            secrets: assistantSecrets,
            transport: MailNetTransport(),
            gate: gate,
            store: store
        )
        let sentinel = HomeSentinelLoop(
            config: config,
            provider: assistantProvider,
            gate: gate,
            store: store
        )
        // The adapter is assembled only with the assistant: a node whose assistant
        // is off owns no model client and probes nothing. Scope roots come from the
        // same workspace authorization the privacy bridge already requires.
        let inkling = Inkling2MiniAdapter(
            config: config.inkling,
            scopeRoots: settings.bridges.normalised.allowWorkspaceRead
                ? settings.bridges.normalised.workspaceDirectories
                : [],
            transport: InklingURLSessionTransport(),
            store: store
        )
        // The sealed index opens before a phone exists, and the voice pipeline only
        // accepts files that land under the bridge's own quarantine roots. Both are
        // reused across settings saves so approvals and the FTS index survive.
        let rag = self.rag ?? LocalEpisodicRAG(
            databaseURL: AppPaths.assistantRAGDatabaseFile,
            keyURL: AppPaths.assistantRAGKeyFile
        )
        let voice = self.voice ?? LocalVoiceMemoPipeline(
            transcribers: [AppleOnDeviceSpeechTranscriber(), LoopbackWhisperTranscriber()],
            rag: rag,
            store: store,
            inboxRoots: [AppPaths.quarantine, FileManager.default.temporaryDirectory]
        )
        let manager = PersonalAssistantManager(
            config: config,
            privacy: settings.bridges.normalised,
            hub: hubs,
            godsEyeEnabled: settings.godsEyeConfig.enabled,
            secrets: assistantSecrets,
            gate: gate,
            store: store,
            scheduler: scheduler,
            mail: mail,
            sentinel: sentinel,
            inkling: inkling,
            rag: rag,
            voice: voice
        ) { [weak self] result in
            guard let self else { return false }
            return await self.deliverAssistantCard(result)
        }
        self.rag = rag
        self.voice = voice
        self.assistantInkling = inkling
        self.assistant = manager
        await manager.apply(config: config, now: now)
        await manager.start()
        await hub.publish(
            .system,
            "私人助手已装配 / the personal assistant is assembled",
            level: .notice,
            payload: ["enabled": .bool(config.enabled)]
        )
    }

    /// Built once, after the assistant so the local-model probe reads the adapter that
    /// was just assembled. The probes are the node-level seams; the restart closure
    /// only ever restarts the daemon, because the Ollama/MLX runtime is the owner's.
    private func configureWatchdog() async {
        guard watchdog == nil else { return }
        let signaling = self.signaling
        let executable = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? ""
        let localModel: @Sendable () async -> Inkling2MiniAdapter? = { [weak self] in
            await self?.assistantInkling
        }
        let probes: [WatchdogProbe] = [
            SystemWatchdog.diskProbe(),
            SystemWatchdog.memoryProbe(),
            SystemWatchdog.daemonProbe(signaling),
            SystemWatchdog.localModelProbe(provider: localModel)
        ]
        watchdog = SystemWatchdog(
            executablePath: executable,
            probes: probes,
            restart: { target in
                guard target == WatchdogTarget.daemon.rawValue else { return false }
                await signaling.stop()
                await signaling.start()
                let status = await signaling.status()
                return status.daemon.isLive
            },
            deliver: { [weak self] result in
                guard let self else { return false }
                return await self.deliverAssistantCard(result)
            }
        )
    }

    /// Inbound files are already quarantined by the bridge. Only an audio suffix
    /// reaches the pipeline; anything else stays a plain inbound file.
    private func handleInboundAudio(_ url: URL) async {
        let audio = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "ogg", "opus"]
        guard audio.contains(url.pathExtension.lowercased()) else { return }
        guard let assistant else {
            await hub.publish(.system, "收到音频但私人助手未开启 / audio arrived while the assistant is off", level: .warning)
            return
        }
        let report = await assistant.handleVoiceMemo(audioURL: url)
        await hub.publish(
            .system,
            report.ok
                ? "语音备忘录已转录 · \(report.actions.count) 个行动项待审批 / voice memo transcribed"
                : "语音备忘录未处理 / voice memo not processed",
            level: report.ok ? .notice : .warning,
            payload: ["engine": .string(report.engine), "actions": .int(report.actions.count)]
        )
    }

    /// One assistant card over the paired E2E session, mirrored into the console
    /// drawer. The return value is the delivery answer, so the caller can audit a
    /// card that was queued instead of claiming the phone received it.
    private func deliverAssistantCard(_ result: CommandResult) async -> Bool {
        record(result)
        let delivered = await signaling.deliver(result, to: "assistant")
        await hub.publish(
            .system,
            delivered ? "私人助手卡片已回传 / assistant card delivered" : "私人助手卡片待回传 / queued in outbox",
            level: delivered ? .notice : .warning,
            payload: ["card": .string(String(result.headline.prefix(80))), "delivered": .bool(delivered)]
        )
        return delivered
    }

    /// The card's data. Before the owner switches it on, this is the saved document
    /// rendered honestly: every loop off, no credentials read, no socket.
    private func assistantSnapshotValue() async -> AssistantSnapshot {
        if let assistant { return await assistant.snapshot() }
        let config = (await settings.current()).assistantConfig.normalised
        var snapshot = AssistantSnapshot.empty
        snapshot.enabled = config.enabled
        snapshot.scheduler = AssistantSchedulerCard(
            enabled: config.enabled,
            briefingEnabled: config.briefing.enabled,
            briefingHour: config.briefing.hour,
            briefingMinute: config.briefing.minute,
            patrolEnabled: config.patrol.enabled,
            patrolIntervalMinutes: config.patrol.intervalMinutes,
            offlineMinutes: config.patrol.offlineMinutes
        )
        snapshot.mail = AssistantMailCard(
            enabled: config.mail.enabled,
            configured: config.mail.hasAccount,
            usable: config.mail.usable,
            imapHost: config.mail.imapHost,
            imapPort: config.mail.imapPort,
            smtpHost: config.mail.smtpHost,
            smtpPort: config.mail.smtpPort,
            username: config.mail.username,
            fromAddress: config.mail.fromAddress,
            imapPasswordRef: config.mail.imapPasswordRef,
            smtpPasswordRef: config.mail.smtpPasswordRef,
            imapStored: assistantSecrets.secret(for: config.mail.imapPasswordRef) != nil,
            smtpStored: assistantSecrets.secret(for: config.mail.smtpPasswordRef) != nil,
            credentialBacking: assistantSecrets.backingName,
            lookbackDays: config.mail.lookbackDays,
            maxMessages: config.mail.maxMessages,
            boundary: "IMAPS/SMTPS 993/465 · 只读 EXAMINE · 发送须审批 / read-only fetch, approved send"
        )
        snapshot.boundary = Self.assistantBoundary
        snapshot.inkling = AssistantInklingCard.saved(config.inkling)
        snapshot.updatedAt = Date()
        return snapshot
    }

    private static let assistantBoundary =
        "执行层 HMAC 审批回执 · 127.0.0.1 控制台 · 邮件为唯一命名外部出口 / executor HMAC receipts · loopback console · mail is the one named egress exception"

    /// Parses `assistant::{approve|reject}::{"id":"…","receipt":"…"}`. The receipt is
    /// signed over kind/target/digest/expiry inside the gate, so a stale one cannot
    /// authorize a different operation or a body that changed after the card.
    private static func assistantPayload(_ text: String) -> (id: String, receipt: String)? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty,
              let receipt = object["receipt"] as? String, !receipt.isEmpty else {
            return nil
        }
        return (id, receipt)
    }

    private func handleAssistantCommand(_ command: NodeCommand, source: String) async -> CommandResult {
        let label = "POPOPX 私人助手 / Private Assistant"
        guard command.action == "approve" || command.action == "reject" else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "未知私人助手操作 / unknown assistant action: \(command.action)",
                cardLabel: label
            )
        }
        guard let assistant else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "私人助手未装配 / the assistant is not assembled", cardLabel: label
            )
        }
        guard let payload = Self.assistantPayload(command.payload) else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "审批载荷无效 / malformed approval payload", cardLabel: label
            )
        }
        let report = await assistant.decide(
            proposalID: payload.id, verb: command.action, receipt: payload.receipt
        )
        return CommandResult(
            commandID: command.id,
            engine: .shadowCos,
            ok: report.ok,
            headline: "私人助手 · \(report.outcome) / \(report.ok ? "applied" : "not applied")",
            body: report.detail,
            metrics: ["outcome": .string(report.outcome), "source": .string(source)],
            cardLabel: label
        )
    }

    private func discoverMCPText(_ source: DiscoverMCPSource) async -> Result<String, DiscoverMCPFailure> {
        guard let privacy else {
            return .failure(DiscoverMCPFailure("MCP 桥接未启用 / the MCP bridge is off"))
        }
        let outcome = await privacy.mcp.invoke(
            serverID: source.serverID,
            toolName: source.toolName,
            arguments: source.arguments,
            source: "discover"
        )
        switch outcome {
        case let .executed(text, _):
            return .success(text)
        case .proposed:
            // A write-shaped tool never becomes a feed item: discovery is a read.
            return .failure(DiscoverMCPFailure("写操作不能作为发现来源 / a mutating tool cannot feed Discover"))
        case let .refused(reason):
            return .failure(DiscoverMCPFailure(reason))
        }
    }

    private func recordUpdateAudit(_ entry: UpdateAuditEntry) async {
        appendFeatureAudit(
            channel: UpdateCenter.auditAction, outcome: entry.outcome,
            detail: "\(entry.action) \(entry.detail)", at: entry.at
        )
        await hub.publish(
            .update, "更新 · \(entry.action) → \(entry.outcome)",
            level: Self.auditLevel(entry.outcome),
            payload: ["action": .string(entry.action), "outcome": .string(entry.outcome)]
        )
    }

    private func recordDiscoverAudit(_ entry: DiscoverAuditEntry) async {
        appendFeatureAudit(
            channel: DiscoverCenter.auditAction, outcome: entry.outcome,
            detail: "\(entry.action) \(entry.detail)", at: entry.at
        )
        await hub.publish(
            .discover, "发现 · \(entry.action) → \(entry.outcome)",
            level: Self.auditLevel(entry.outcome),
            payload: ["action": .string(entry.action), "outcome": .string(entry.outcome)]
        )
    }

    private static func auditLevel(_ outcome: String) -> EventLevel {
        if outcome.contains("fail") || outcome.contains("refus") || outcome.contains("mismatch") {
            return .warning
        }
        if outcome.contains("install") || outcome == "available" { return .success }
        return .notice
    }

    /// One append-only line in `logs/node.log`. The centre is the only writer for
    /// its own rows and the actor serialises these calls, so lines cannot interleave
    /// with each other; the SMP bridge writes to the same file from another actor,
    /// which is the pre-existing behaviour of this log.
    private func appendFeatureAudit(channel: String, outcome: String, detail: String, at: Date) {
        let line = "\(PrivacyStamp.iso(at)) [\(channel)] \(outcome) \(detail)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = AppPaths.auditLogFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func updateSnapshotValue() async -> UpdateSnapshot {
        if let updateCenter { return await updateCenter.snapshot() }
        let config = (await settings.current()).updateConfig.normalised
        return UpdateSnapshot(
            enabled: config.enabled,
            usable: config.usable,
            manifestHost: config.manifestHost ?? "",
            pinnedHosts: config.pinnedHosts.sorted(),
            keyFingerprint: config.keyFingerprint,
            boundary: "https · 仅机主固定的主机 / https, owner-pinned hosts only"
        )
    }

    private func discoverSnapshotValue() async -> DiscoverSnapshot {
        if let discoverCenter { return await discoverCenter.snapshot() }
        let config = (await settings.current()).discoverConfig.normalised
        return DiscoverSnapshot(
            enabled: config.hasAnySource,
            intervalMinutes: config.intervalMinutes,
            boundary: DiscoverCenter.boundaryText
        )
    }

    /// Polled by every open console tab. The bridge answers from cached measurements
    /// and starts at most one background health probe, so this never waits on a socket.
    private func godsEyeSnapshotValue() async -> GodsEyeViewSnapshot {
        guard let godsEye else {
            var snapshot = GodsEyeViewSnapshot.disabled
            let config = (await settings.current()).godsEyeConfig
            snapshot.enabled = config.enabled
            snapshot.pinnedVersion = config.pinnedVersion
            return snapshot
        }
        return await godsEye.snapshot()
    }

    /// The phone card goes out with detection, not with approval: it carries the
    /// two commands and nothing executable. `markNotified` runs even when the
    /// delivery was queued to the outbox, so the same version is not announced twice.
    private func announceUpdate(_ release: UpdateRelease) async {
        guard let center = updateCenter, let commands = await center.cardCommands() else { return }
        guard !(await center.snapshot()).notified else { return }
        let card = UpdateCard(
            release: release, approveCommand: commands.approve, snoozeCommand: commands.snooze
        )
        let changes = release.summaryLines.isEmpty
            ? "（无更新说明 / no summary）"
            : release.summaryLines.prefix(8).map { "· \($0)" }.joined(separator: "\n")
        let body = """
        新版本 / new version: \(release.version) · \(release.releasedAt)
        \(changes)
        在您点击「立即更新」之前不会下载任何内容。 / Nothing is downloaded until you choose 立即更新.
        """
        let result = CommandResult(
            engine: .shadowCos,
            ok: true,
            headline: card.text,
            body: body,
            metrics: ["version": .string(release.version), "build": .int(release.build)],
            cardLabel: "POPOPX 更新 / Update"
        )
        record(result)
        let delivered = await signaling.deliver(result, to: "updates")
        await center.markNotified(version: release.version)
        await hub.publish(
            .update,
            "发现新版本 v\(release.version) · 等待机主点击 / awaiting owner click",
            level: .notice,
            payload: [
                "version": .string(release.version),
                "delivered": .bool(delivered)
            ]
        )
    }

    /// The signed feed is the artifact; the card is a readable index. The phone's
    /// Discover page reads the file and verifies it with the embedded public key.
    private func publishDiscover(feed: DiscoverFeed, path: String) async {
        let items = feed.items
        let body = items.isEmpty
            ? "本次没有条目 / the feed is empty this run"
            : items.prefix(8).map { "· \($0.title) — \($0.sourceLabel)" }.joined(separator: "\n")
        let artifacts = FileManager.default.fileExists(atPath: path) ? [path] : []
        let result = CommandResult(
            engine: .shadowCos,
            ok: true,
            headline: "\(DiscoverFeed.schemaIdentifier) · \(items.count) 条 / items",
            body: body,
            artifacts: artifacts,
            metrics: [
                "schema": .string(feed.schema),
                "items": .int(items.count),
                "signed": .bool(!feed.signature.isEmpty)
            ],
            cardLabel: "POPOPX 发现 / Discover"
        )
        record(result)
        let delivered = await signaling.deliver(result, to: "discover")
        await discoverCenter?.markDelivered(ids: items.map(\.id))
        await hub.publish(
            .discover,
            "发现已推送 · \(items.count) 条 / feed pushed",
            level: .notice,
            payload: ["items": .int(items.count), "delivered": .bool(delivered)]
        )
    }

    /// Parses `updates::{approve|snooze}::{"v":"…","rcp":"…"}`. The receipt is
    /// bound to version and verb inside the centre, so a stale one from another
    /// release cannot authorize this one.
    private static func updatePayload(_ text: String) -> (version: String, receipt: String)? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? String, !version.isEmpty,
              let receipt = object["rcp"] as? String, !receipt.isEmpty else {
            return nil
        }
        return (version, receipt)
    }

    private func handleUpdateCommand(_ command: NodeCommand, source: String) async -> CommandResult {
        let label = "POPOPX 更新 / Update"
        guard let center = updateCenter else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "更新检查未启用 / the update feed is off", cardLabel: label
            )
        }
        guard command.action == "approve" || command.action == "snooze" else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "未知更新操作 / unknown update action: \(command.action)", cardLabel: label
            )
        }
        guard let payload = Self.updatePayload(command.payload) else {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "回执载荷无效 / malformed update payload", cardLabel: label
            )
        }
        let snapshot = await center.snapshot()
        if let pending = snapshot.available, pending.version != payload.version {
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "版本不符 / this receipt is for \(payload.version), pending is \(pending.version)",
                cardLabel: label
            )
        }
        let outcome = await center.decision(verb: command.action, receipt: payload.receipt, source: source)
        let report = UpdateDecisionReport.make(outcome, snapshot: await center.snapshot())
        let headline: String
        switch outcome {
        case let .installed(version, _):
            headline = "已校验并交给安装器 v\(version) / verified and handed to the installer"
        case let .snoozed(until):
            headline = "已推迟到 \(PrivacyStamp.display(until, timeZone: .current)) / snoozed"
        case let .refused(detail), let .failed(detail):
            headline = detail
        }
        return CommandResult(
            commandID: command.id,
            engine: .shadowCos,
            ok: report.ok,
            headline: headline,
            body: report.detail,
            metrics: [
                "verb": .string(command.action),
                "outcome": .string(report.outcome),
                "source": .string(source)
            ],
            cardLabel: label
        )
    }

    @discardableResult
    private func routeDiscover(_ command: NodeCommand) async -> CommandResult {
        let label = "POPOPX 发现 / Discover"
        guard let center = discoverCenter else {
            let result = CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "发现聚合器未启用 / the aggregator is off", cardLabel: label
            )
            record(result)
            _ = await signaling.deliver(result, to: command.serviceId)
            return result
        }
        guard command.action == "refresh" else {
            let result = CommandResult(
                commandID: command.id, engine: .shadowCos, ok: false,
                headline: "未知发现操作 / unknown discover action: \(command.action)", cardLabel: label
            )
            record(result)
            _ = await signaling.deliver(result, to: command.serviceId)
            return result
        }
        let outcome = await center.refresh()
        if case let .refreshed(feed, path, _) = outcome {
            await publishDiscover(feed: feed, path: path)
            return CommandResult(
                commandID: command.id, engine: .shadowCos, ok: true,
                headline: "发现已刷新并推送 / refreshed and pushed", cardLabel: label
            )
        }
        let report = DiscoverRefreshReport.make(outcome, snapshot: await center.snapshot())
        let result = CommandResult(
            commandID: command.id, engine: .shadowCos,
            ok: report.outcome == "unchanged",
            headline: "发现刷新 · \(report.outcome)", body: report.detail, cardLabel: label
        )
        record(result)
        _ = await signaling.deliver(result, to: command.serviceId)
        return result
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
            privacy: await privacySnapshot(saved: current),
            update: await updateSnapshotValue(),
            discover: await discoverSnapshotValue(),
            godsEye: await godsEyeSnapshotValue(),
            assistant: await assistantSnapshotValue(),
            watchdog: await watchdog?.card() ?? .disabled,
            model: await modelCardValue(saved: current)
        )
    }

    /// The model card's data: the saved switch, the live pull, and whether the
    /// assistant's configured model actually answers. `isReady` is the adapter's
    /// TTL-cached probe (60 s), so an open console costs at most one loopback
    /// round trip a minute — and none at all in lightweight mode.
    private func modelCardValue(saved: NodeSettings) async -> LocalModelCard {
        let lightweight = saved.isLightweight
        let pull = await modelPull.current()
        let ready: Bool
        if lightweight {
            ready = false
        } else if let assistantInkling {
            ready = await assistantInkling.isReady()
        } else {
            // No adapter means the assistant is off; the pull card's own verified
            // `/api/tags` read is then the only honest readiness signal.
            ready = pull.isReady
        }
        return LocalModelCard.resolve(
            lightweight: lightweight,
            modelRef: saved.assistantConfig.normalised.inkling.model,
            modelReady: ready,
            pull: pull
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
                payload: [
                    "expiresIn": .int(offer.secondsRemaining()),
                    // The event log outlives the offer and is readable from the
                    // drawer, so it keeps the masked envelope, never the credential.
                    "pairing": .string(
                        (try? OpaquePairingCodec.pairingLink(offer.code))
                            .map(OpaquePairingCodec.mask) ?? "…"
                    )
                ]
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
        merged = Self.synchronisingGodsEyeMCP(merged)
        let stored = await settings.apply(merged)
        // The bridges read their switches, directories and timezone out of the same
        // document, so saving it is the only way they change.
        await configurePrivacy(from: stored)
        await configureUpdates(from: stored)
        await configureDiscover(from: stored)
        // After the privacy stack: a save may have rebuilt it, and the Gods Eye
        // bridge must hold the MCP bridge that is actually serving requests.
        await configureGodsEye(from: stored)
        await configureAssistant(from: stored)
        await assistant?.setLightweight(stored.isLightweight)
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
        if command.serviceId == "updates" {
            let result = await handleUpdateCommand(command, source: "console-drawer")
            record(result)
            await hub.publish(.update, result.cardText, level: result.ok ? .success : .warning)
            return result
        }
        if command.serviceId == "discover" {
            return await routeDiscover(command)
        }
        if command.serviceId == "assistant" {
            let result = await handleAssistantCommand(command, source: "console-drawer")
            record(result)
            await hub.publish(.result, result.cardText, level: result.ok ? .success : .error)
            return result
        }
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
        guard let privacy, let namespace = PrivacyToolRoute.namespace(accepting: domain) else {
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

    /// The 「本地能力发现」 card. `force` is the 「立即探测」 button, so it is the only path
    /// that waits; a poll reads the cache.
    public func discoverySnapshot(force: Bool) async -> DiscoverySnapshot {
        let snapshot = await discovery.snapshot(force: force)
        if force {
            await hub.publish(
                .system,
                "本地能力探测完成 · \(snapshot.capabilities.count) 项 / capability scan finished",
                level: .notice,
                payload: [
                    "capabilities": .int(snapshot.capabilities.count),
                    "scannedAt": .string(snapshot.scannedAt)
                ]
            )
        }
        return snapshot
    }

    /// Console-only: one credential into the Keychain, and the *reference* into the settings
    /// document. The value itself is never stored, echoed, or logged — the settings write
    /// carries `smarthome/mqtt/password`, not the password.
    public func storeHubCredential(bridge: String, serverID: String, secret: String) async -> PrivacyToolResponse {
        guard let privacy else {
            return PrivacyToolResponse.failure(503, "本节点没有桥接栈 / this node has no bridge stack")
        }
        let outcome = await privacy.engine.storeHubCredential(bridge: bridge, serverID: serverID, secret: secret)
        guard outcome.ok, let reference = outcome.fields["reference"]?.stringValue else {
            // The refusal text names the reason and never the value, so forwarding it whole is
            // safe; nothing here concatenates `secret`.
            return outcome
        }
        let current = await settings.current()
        var hubs = current.hubs
        switch bridge.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hometoken": hubs.smartHome.homeAssistantTokenRef = reference
        case "mqttpassword": hubs.smartHome.mqttPasswordRef = reference
        case "caldav":
            if let index = hubs.calDav.servers.firstIndex(where: { $0.id == serverID }) {
                hubs.calDav.servers[index].passwordRef = reference
            }
        default: break
        }
        let stored = await settings.apply(current.withHubs(hubs))
        await privacy.engine.applyHubConfig(stored.hubs)
        await hub.publish(
            .privacy,
            "凭据已存入钥匙串 · \(bridge) / credential stored in the Keychain",
            level: .success,
            payload: ["bridge": .string(bridge), "reference": .string(reference)]
        )
        return PrivacyToolResponse(ok: true, status: 200, fields: [
            "ok": .bool(true),
            "reference": .string(reference),
            "stored": .bool(true),
            "revision": .int(stored.revision),
            "detail": .string("已加密存入 macOS 钥匙串，设置文件仅记录引用 / stored encrypted in the Keychain; the settings document holds the reference only")
        ])
    }

    // MARK: NodeConsoleFacade — personal assistant

    public func assistantControl(verb: String) async -> AssistantControlReport {
        guard let assistant else {
            return .refused("私人助手未开启 / the assistant is off", snapshot: await assistantSnapshotValue())
        }
        let report = await assistant.control(verb: verb)
        await hub.publish(
            .system,
            "私人助手 · \(report.outcome)",
            level: report.ok ? .notice : .warning,
            payload: ["verb": .string(verb), "outcome": .string(report.outcome)]
        )
        return report
    }

    public func assistantDecision(id: String, verb: String) async -> AssistantDecisionReport {
        guard let assistant else {
            return AssistantDecisionReport(
                ok: false, outcome: "refused",
                detail: "私人助手未开启 / the assistant is off",
                assistant: await assistantSnapshotValue()
            )
        }
        let report = await assistant.consoleDecide(proposalID: id, verb: verb)
        await hub.publish(
            .system,
            "私人助手审批 · \(report.outcome)",
            level: report.ok ? .success : .warning,
            payload: ["outcome": .string(report.outcome)]
        )
        return report
    }

    /// Console-only, like `storeHubCredential`: the value goes to the assistant's
    /// Keychain store and the reply is the reference. Nothing here echoes it.
    public func storeMailCredential(kind: String, secret: String) async -> AssistantCredentialReport {
        guard let assistant else {
            return AssistantCredentialReport(
                ok: false,
                detail: "私人助手未开启 / the assistant is off",
                reference: "",
                assistant: await assistantSnapshotValue()
            )
        }
        let report = await assistant.storeMailCredential(kind: kind, secret: secret)
        await hub.publish(
            .system,
            report.ok ? "邮箱凭据已存入钥匙串 / mail credential stored" : "邮箱凭据未存入 / mail credential refused",
            level: report.ok ? .success : .warning,
            payload: ["kind": .string(kind), "reference": .string(report.reference)]
        )
        return report
    }

    // MARK: NodeConsoleFacade — doctor, recall, watchdog

    public func assistantDoctor() async -> LiveIntegrationReport {
        let config = (await settings.current()).assistantConfig.normalised
        var probes: [DoctorProbe] = [
            LiveIntegrationDoctor.keychainProbe(assistantSecrets),
            LiveIntegrationDoctor.signalingProbe(signaling)
        ]
        if let assistantInkling {
            probes.append(LiveIntegrationDoctor.localModelProbe(assistantInkling))
        } else {
            probes.append(DoctorProbe(id: "local_model", title: "本机模型 Ollama / MLX / Local model") {
                .skipped("未装配本地模型适配器 / no local model adapter")
            })
        }
        if assistant != nil {
            probes.append(LiveIntegrationDoctor.mailProbe(config.mail, secrets: assistantSecrets))
        } else {
            probes.append(DoctorProbe(id: "mail", title: "邮箱认证握手 / Mail authentication handshake") {
                .skipped("私人助手未开启 / the assistant is off")
            })
        }
        probes.append(LiveIntegrationDoctor.calendarProbe(privacy?.calDav))
        probes.append(LiveIntegrationDoctor.smartHomeProbe(privacy?.smartHome))
        let report = await LiveIntegrationDoctor(probes: probes).run()
        await hub.publish(
            .system,
            "全链路体检 · \(report.headline)",
            level: report.ok ? .success : .warning,
            payload: ["checks": .int(report.checks.count)]
        )
        return report
    }

    public func assistantHistory(query: String) async -> EpisodicAnswer {
        guard let assistant else {
            return EpisodicAnswer(
                ok: false,
                question: query,
                answer: "私人助手未开启 / the assistant is off"
            )
        }
        return await assistant.askHistory(query)
    }

    public func watchdogStatus() async -> SystemWatchdogCard {
        await watchdog?.card() ?? .disabled
    }

    public func watchdogControl(verb: String) async -> WatchdogControlReport {
        guard let watchdog else {
            return WatchdogControlReport(
                ok: false,
                outcome: "refused",
                detail: "系统看门狗未装配 / the watchdog is not assembled",
                watchdog: .disabled
            )
        }
        switch verb.lowercased() {
        case "install":
            let report = await watchdog.install()
            await hub.publish(
                .system,
                report.ok ? "开机自启已写入 / launch at login installed" : "开机自启未写入 / launch at login refused",
                level: report.ok ? .success : .warning
            )
            return report
        case "uninstall":
            let report = await watchdog.uninstall()
            await hub.publish(
                .system,
                report.ok ? "开机自启已移除 / launch at login removed" : "开机自启未移除 / removal failed",
                level: report.ok ? .notice : .warning
            )
            return report
        case "check":
            let outcome = await watchdog.check(force: true)
            let report = WatchdogControlReport(
                ok: outcome.checked,
                outcome: outcome.checked ? "checked" : "throttled",
                detail: outcome.checked
                    ? "\(outcome.watchdog.checks.count) 项检查 · \(outcome.alerts.count) 条告警"
                    : "未到检查间隔 / the 60 s floor has not elapsed",
                watchdog: outcome.watchdog
            )
            return report
        case "status":
            let card = await watchdog.card()
            return WatchdogControlReport(
                ok: true,
                outcome: card.installed ? "installed" : "absent",
                detail: card.lastDetail,
                watchdog: card
            )
        default:
            return WatchdogControlReport(
                ok: false,
                outcome: "refused",
                detail: "未知看门狗指令 / unknown watchdog verb: \(verb)",
                watchdog: await watchdog.card()
            )
        }
    }

    // MARK: NodeConsoleFacade — model card and pairing test

    public func modelControl(verb: String, model: String) async -> ModelPullReport {
        let clean = verb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "pull":
            let card = await modelPull.start(ref: model)
            await hub.publish(
                .install,
                "模型拉取 · \(card.state.rawValue)",
                level: card.state.isRunning ? .notice : .warning,
                payload: [
                    "model": .string(card.modelRef),
                    "percent": .int(card.percent),
                    "state": .string(card.state.rawValue)
                ]
            )
            return ModelPullReport.make(card)
        case "cancel":
            let card = await modelPull.cancel()
            await hub.publish(.install, "模型拉取已取消 / pull cancelled", level: .warning)
            return ModelPullReport.make(card)
        case "status":
            return ModelPullReport.make(await modelPull.current())
        case "lightweighton", "lightweightoff":
            let value = clean == "lightweighton"
            let stored = await settings.mutate { document in
                document = document.withLightweight(value)
            }
            await assistant?.setLightweight(value)
            await hub.publish(
                .system,
                value
                    ? "已切换纯轻量模式 · 零模型运行 / lightweight mode on"
                    : "已切回 AI 增强模式 / AI-enhanced mode on",
                level: .notice,
                payload: ["lightweight": .bool(value), "revision": .int(stored.revision)]
            )
            let card = await modelPull.current()
            return ModelPullReport(
                ok: true,
                outcome: value ? "lightweight" : "enhanced",
                detail: value
                    ? "零模型运行：确定性能力继续工作 / zero models run; deterministic features keep working"
                    : "本机模型重新参与助手推理 / the local model rejoins the assistant",
                pull: card
            )
        case "wizarddone":
            _ = await settings.mutate { document in
                document = document.withWizardCompleted()
            }
            await hub.publish(.system, "首次运行向导已完成 / setup wizard completed", level: .success)
            return ModelPullReport(
                ok: true,
                outcome: "wizard",
                detail: "向导已完成，可从控制台随时重开 / the wizard is done and can be reopened from the console",
                pull: await modelPull.current()
            )
        default:
            return ModelPullReport(
                ok: false,
                outcome: "refused",
                detail: "未知模型指令 / unknown model verb: \(verb)",
                pull: await modelPull.current()
            )
        }
    }

    /// The wizard's 「发送测试简报」. It goes over the same paired E2E session the
    /// real briefing uses and reports the delivery answer, so a node with no paired
    /// phone says so instead of claiming the card was received.
    public func pairingTestPush() async -> PairingTestReport {
        let paired = await signaling.pairedDevices()
        guard !paired.isEmpty else {
            return PairingTestReport(
                ok: false,
                delivered: false,
                pairedCount: 0,
                detail: "还没有已配对设备：先用手机扫描二维码 / no paired device yet — scan the QR with the phone first"
            )
        }
        let current = await settings.current()
        var modelReady = false
        if !current.isLightweight, let assistantInkling {
            modelReady = await assistantInkling.isReady()
        }
        let mode = NodeIntelligenceMode.resolve(
            lightweight: current.isLightweight,
            modelReady: modelReady
        )
        let result = CommandResult(
            engine: .shadowCos,
            ok: true,
            deterministic: true,
            headline: "测试简报 / test briefing",
            body: [
                "这是来自本机节点 \(current.nodeName) 的测试消息。",
                "模式 / mode: \(mode.headlineZh)",
                "时间 / time: \(Date().ppxClock)",
                "收到即代表配对通道可用；不会触发任何写入。",
                "This is a test card from the node; receiving it proves the pairing channel, and it triggers no write."
            ].joined(separator: "\n"),
            at: Date(),
            metrics: ["kind": .string("pairing-test")],
            cardLabel: "POPOPX 私人助手 / Private Assistant"
        )
        let delivered = await signaling.deliver(result, to: "assistant")
        record(result)
        await hub.publish(
            .pairing,
            delivered ? "测试简报已送达手机 / test briefing delivered" : "测试简报已入发件箱 / test briefing queued in outbox",
            level: delivered ? .success : .warning,
            payload: ["paired": .int(paired.count), "delivered": .bool(delivered)]
        )
        return PairingTestReport(
            ok: delivered,
            delivered: delivered,
            pairedCount: paired.count,
            detail: delivered
                ? "手机已确认收到测试简报 / the phone accepted the test card"
                : "已配对，但当前未建立会话，卡片在发件箱等待 / paired, but no live session; the card waits in the outbox"
        )
    }

    // MARK: NodeConsoleFacade — signed updates and Discover

    public func updateStatus() async -> UpdateSnapshot {
        await updateSnapshotValue()
    }

    public func updateCheck() async -> UpdateCheckReport {
        guard let center = updateCenter else {
            return UpdateCheckReport(
                outcome: "disabled",
                detail: "更新检查未启用 / the update feed is off",
                update: await updateSnapshotValue()
            )
        }
        let outcome = await center.check()
        let report = UpdateCheckReport.make(outcome, snapshot: await center.snapshot())
        await hub.publish(
            .update, "更新检查 · \(report.outcome)",
            level: Self.auditLevel(report.outcome),
            payload: ["outcome": .string(report.outcome)]
        )
        if case let .available(release) = outcome {
            await announceUpdate(release)
        }
        return report
    }

    /// The console's 「立即更新 / 稍后提醒」. The receipt is minted inside the node
    /// from this call, exactly like a privacy approval: the page never receives one.
    public func updateDecision(verb: String) async -> UpdateDecisionReport {
        guard let center = updateCenter, let receipt = await center.consoleReceipt(verb: verb) else {
            return UpdateDecisionReport(
                outcome: "refused", ok: false,
                detail: "没有待批准的版本 / there is no verified pending release",
                update: await updateSnapshotValue()
            )
        }
        let outcome = await center.decision(verb: verb, receipt: receipt, source: "console")
        let report = UpdateDecisionReport.make(outcome, snapshot: await center.snapshot())
        await hub.publish(
            .update, "控制台更新操作 · \(report.outcome)",
            level: report.ok ? .success : .warning,
            payload: ["verb": .string(verb), "outcome": .string(report.outcome)]
        )
        return report
    }

    public func discoverStatus() async -> DiscoverSnapshot {
        await discoverSnapshotValue()
    }

    public func discoverRefresh() async -> DiscoverRefreshReport {
        guard let center = discoverCenter else {
            return DiscoverRefreshReport(
                outcome: "disabled",
                detail: "发现聚合未启用 / the aggregator is off",
                discover: await discoverSnapshotValue()
            )
        }
        let outcome = await center.refresh()
        let report = DiscoverRefreshReport.make(outcome, snapshot: await center.snapshot())
        if case let .refreshed(feed, path, _) = outcome {
            await publishDiscover(feed: feed, path: path)
        }
        await hub.publish(
            .discover, "发现刷新 · \(report.outcome)",
            level: Self.auditLevel(report.outcome),
            payload: ["outcome": .string(report.outcome), "items": .int(report.itemCount)]
        )
        return report
    }

    /// One owner click on the 「全球情报地图」 card. Every verb still passes the
    /// bridge's own switch checks; this method only records that the click happened.
    public func godsEyeControl(verb: String) async -> GodsEyeControlReport {
        guard let godsEye else {
            return GodsEyeControlReport(
                outcome: verb.isEmpty ? "disabled" : verb,
                ok: false,
                detail: "Gods Eye View 桥未装配 / the Gods Eye View bridge is not assembled",
                godsEye: .disabled
            )
        }
        let report = await godsEye.control(verb: verb)
        await hub.publish(
            .system,
            "全球情报地图 · \(report.outcome) → \(report.ok ? "ok" : "refused")",
            level: report.ok ? .notice : .warning,
            payload: ["verb": .string(report.outcome), "running": .bool(report.godsEye.running)]
        )
        return report
    }

    /// Console-only: the value goes to the bridge's Keychain store and only the
    /// reference is written into the settings document. Nothing here echoes it.
    public func storeGodsEyeCredential(sourceID: String, secret: String) async -> PrivacyToolResponse {
        guard let godsEye else {
            return PrivacyToolResponse.failure(503, "Gods Eye View 桥未装配 / the bridge is not assembled")
        }
        let outcome = await godsEye.storeCredential(sourceID: sourceID, secret: secret)
        guard case let .stored(reference) = outcome,
              let source = GodsEyeDataSource(rawValue: sourceID) else {
            if case let .refused(reason) = outcome {
                return PrivacyToolResponse.failure(400, reason)
            }
            return PrivacyToolResponse.failure(400, "凭据未存入 / the credential was not stored")
        }
        let current = await settings.current()
        var config = current.godsEyeConfig
        config.credentials[source.rawValue] = GodsEyeCredentialSlot(enabled: true, reference: reference)
        let stored = await settings.apply(current.withGodsEye(config))
        await godsEye.update(config: stored.godsEyeConfig, mcp: privacy?.mcp)
        await hub.publish(
            .system,
            "全球情报地图凭据 · \(source.rawValue) 已存入钥匙串 / credential stored in the Keychain",
            level: .success,
            payload: ["source": .string(source.rawValue), "reference": .string(reference)]
        )
        return PrivacyToolResponse(ok: true, status: 200, fields: [
            "ok": .bool(true),
            "source": .string(source.rawValue),
            "reference": .string(reference),
            "stored": .bool(true),
            "revision": .int(stored.revision),
            "detail": .string("已加密存入 macOS 钥匙串，设置文件仅记录引用 / stored encrypted in the Keychain; the settings document holds the reference only")
        ])
    }

    /// Delegates to the wire parser in the contract so the console, the bridge and
    /// the test target all share one copy of the grammar.
    public static func parse(wire: String) -> NodeCommand? {
        NodeWire.parseCommand(wire)
    }
}

// MARK: - Live sentinel provider

/// Bridges the sentinel's protocol to whichever `SmartHomeBridge` the privacy stack
/// owns. The stack is built at `start()` and may not exist yet when the assistant is
/// assembled; the lock makes the later hand-off visible without rebuilding the loop.
final class AssistantLiveSentinelProvider: HomeSentinelEntityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: SmartHomeBridge?

    func set(_ bridge: SmartHomeBridge?) {
        lock.lock()
        self.bridge = bridge
        lock.unlock()
    }

    private func current() -> SmartHomeBridge? {
        lock.lock()
        defer { lock.unlock() }
        return bridge
    }

    func sentinelEntities() async -> [SmartHomeEntityCard] {
        guard let bridge = current() else { return [] }
        return await bridge.entityCards()
    }

    func sentinelReadOnly() async -> Bool {
        guard let bridge = current() else { return true }
        return await bridge.assistantReadOnlyMode()
    }

    func performSentinelRepair(_ payload: HubCallPayload) async -> HomeRepairOutcome {
        guard let bridge = current() else {
            return .refused("家居桥接未装配 / the smart-home bridge is not assembled")
        }
        let execution = await bridge.performAssistantRepair(payload)
        return HomeRepairOutcome(ok: execution.ok, detail: execution.message)
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
    /// The wizard's step and the two answers that are not part of the snapshot:
    /// the freshly rendered QR image and whether a test briefing reached a phone.
    @Published var wizardStep = 1
    @Published var pairingImage: NSImage?
    @Published var wizardTestResult: String?
    @Published var wizardTestSending = false
    @Published var wizardTestDelivered: Bool

    let headless: Bool
    private var console: NodeConsole?
    private var server: LocalWebConsoleServer?
    private var refreshTask: Task<Void, Never>?
    private var signalsInstalled = false
    private var wizardWindow: NSWindow?

    static let wizardTestSentKey = "popopx.wizard.testSent"

    init(headless: Bool) {
        self.headless = headless
        self.wizardTestDelivered = UserDefaults.standard.bool(forKey: NodeModel.wizardTestSentKey)
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

    // MARK: Model, wizard and approval actions

    /// The zero-model switch. Persisted through the model route, which owns the
    /// settings write, the assistant's refusal state and the event line.
    func setLightweight(_ enabled: Bool) {
        Task {
            _ = await console?.modelControl(verb: enabled ? "lightweightOn" : "lightweightOff", model: "")
            refreshNow()
        }
    }

    /// One click on the model card. An empty reference falls back to the node's
    /// configured model and then to the first catalog entry.
    func pullModel(_ reference: String = "") {
        var target = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { target = snapshot?.model.modelRef ?? "" }
        if target.isEmpty { target = ModelCatalog.options.first?.id ?? "" }
        guard !target.isEmpty, let console else { return }
        Task {
            _ = await console.modelControl(verb: "pull", model: target)
            refreshNow()
        }
    }

    func cancelModelPull() {
        Task {
            _ = await console?.modelControl(verb: "cancel", model: "")
            refreshNow()
        }
    }

    func decideAssistant(_ id: String, verb: String) {
        Task {
            _ = await console?.assistantDecision(id: id, verb: verb)
            refreshNow()
        }
    }

    func startInstall() {
        Task {
            await console?.startInstall()
            refreshNow()
        }
    }

    // MARK: Setup wizard

    func maybeShowWizardOnFirstRun() async {
        guard !headless else { return }
        let current = await SettingsStore.shared.current()
        guard !current.wizardCompleted else { return }
        showWizard()
    }

    /// Reopenable at any time from the menu bar; the window is created once and
    /// kept, so a second open shows the same step instead of a fresh wizard.
    func showWizard() {
        refreshPairingImage()
        if let window = wizardWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: FirstRunWizardView().environmentObject(self))
        let window = NSWindow(contentViewController: host)
        window.title = "POPOPX · 首次运行向导 / Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        wizardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWizard() {
        wizardWindow?.orderOut(nil)
    }

    /// Marks the wizard done in `settings.json`, which is what stops it from
    /// auto-opening on the next launch.
    func completeWizard() {
        Task {
            _ = await console?.modelControl(verb: "wizarddone", model: "")
            hideWizard()
            refreshNow()
        }
    }

    /// The prominent skip: zero models run from now on, and the wizard advances
    /// instead of vanishing so the remaining three steps still happen.
    func skipModelToLightweight() {
        Task {
            _ = await console?.modelControl(verb: "lightweightOn", model: "")
            wizardStep = 2
            refreshNow()
        }
    }

    func refreshPairingImage() {
        guard let console else { return }
        Task {
            let asset = await console.pairingQR(pixelSize: 1024)
            pairingImage = asset.flatMap { NSImage(data: $0.png) }
        }
    }

    func rotatePairingAndRefresh() {
        guard let console else { return }
        Task {
            _ = await console.rotatePairing()
            let asset = await console.pairingQR(pixelSize: 1024)
            pairingImage = asset.flatMap { NSImage(data: $0.png) }
            refreshNow()
        }
    }

    /// Step 3's 「发送测试简报」. The report says whether a phone actually took
    /// the card, so the step only ticks on a real delivery.
    func sendTestBriefing() {
        guard let console else { return }
        wizardTestSending = true
        Task {
            let report = await console.pairingTestPush()
            wizardTestSending = false
            wizardTestResult = report.detail
            if report.delivered {
                wizardTestDelivered = true
                UserDefaults.standard.set(true, forKey: Self.wizardTestSentKey)
            }
            refreshNow()
        }
    }

    /// The native folder picker behind step 2. It writes the same
    /// `privacyBridges` document the console edits, so the two cannot disagree.
    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "授权此文件夹 / Authorize"
        panel.message = "选择助手与索引可读的工作区文件夹 / Choose a workspace folder the assistant may read"
        guard panel.runModal() == .OK, let url = panel.url, let console else { return }
        Task {
            var document = await SettingsStore.shared.current()
            var bridges = document.bridges
            var directories = bridges.workspaceDirectories
            if !directories.contains(url.path), directories.count < PrivacyBridgeConfig.maximumDirectories {
                directories.append(url.path)
            }
            bridges.workspaceDirectories = directories
            bridges.allowWorkspaceRead = true
            document = document.withBridges(bridges)
            _ = await console.updateSettings(document)
            refreshNow()
        }
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
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the process out of the Dock and the Command-Tab list even if the
/// `LSUIElement` key is missing from a hand-assembled bundle.
final class NodeAppDelegate: NSObject, NSApplicationDelegate {
    var model: NodeModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let model else { return }
        Task {
            await model.bootstrap()
            await model.maybeShowWizardOnFirstRun()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        let model = self.model
        Task { await model?.shutdown() }
    }
}

// MARK: - First-run setup wizard

/// The four-step, reopenable setup wizard. Every gate it paints comes from
/// `SetupWizardState`, which is resolved from snapshot values the node already
/// measures — so "step 1 is done" means a ready model or the explicit zero-model
/// choice, not "the owner clicked a button".
struct FirstRunWizardView: View {
    @EnvironmentObject private var model: NodeModel

    private var language: ConsoleLanguage { model.snapshot?.settings.language ?? .system }

    private func label(_ zh: String, _ en: String) -> String {
        language.text(zh: zh, en: en)
    }

    private var snapshot: ConsoleSnapshot? { model.snapshot }

    private var step: Int { min(max(model.wizardStep, 1), 4) }

    private var state: SetupWizardState? {
        guard let snapshot else { return nil }
        return SetupWizardState.resolve(
            installPhase: snapshot.install.phase,
            lightweight: snapshot.settings.isLightweight,
            modelReady: snapshot.model.mode.modelReady,
            workspaceCount: snapshot.settings.bridges.workspaceDirectories.count,
            pairedCount: snapshot.pairedDevices.count,
            testSent: model.wizardTestDelivered
        )
    }

    private func done(_ index: Int) -> Bool {
        guard let state else { return false }
        switch index {
        case 1: return state.hardwareDone
        case 2: return state.workspaceDone
        case 3: return state.pairingDone
        default: return state.testDone
        }
    }

    private var isLightweight: Bool { snapshot?.settings.isLightweight ?? false }

    private var recommendedRef: String {
        if let ref = snapshot?.plan.llmRef, !ref.isEmpty { return ref }
        return ModelCatalog.options.first?.ollamaRef ?? ""
    }

    private var recommendedName: String {
        ModelCatalog.option(matching: recommendedRef)?.displayName ?? recommendedRef
    }

    private var admissionLine: String {
        guard let snapshot, let option = ModelCatalog.option(matching: snapshot.plan.llmRef) else { return "—" }
        let verdict = option.admission(memoryGB: snapshot.hardware.memoryGB)
        return language.text(zh: verdict.titleZh, en: verdict.titleEn)
    }

    private var pull: ModelPullCard { snapshot?.model.pull ?? .idle }

    private var pullStateLine: String {
        switch pull.state {
        case .idle: return label("尚未拉取", "not pulled yet")
        case .pulling: return label("正在拉取", "pulling")
        case .verifying: return label("正在校验本机清单", "verifying the local list")
        case .ready: return label("已就绪", "ready")
        case .failed: return label("拉取失败", "failed")
        case .cancelled: return label("已取消", "cancelled")
        case .refused: return label("已拒绝", "refused")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stepIndicator
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 640, height: 660)
        .onAppear { model.refreshPairingImage() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: BrandIcon.menuBarImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(label("POPOPX · 首次运行向导", "POPOPX · First-Run Setup"))
                    .font(.headline)
                Text(label(
                    "四步完成本机节点的体验配置；任何一步都可以稍后从菜单栏再来。",
                    "Four steps configure this node; every step can be revisited later from the menu bar."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(label("稍后再说", "Later")) { model.hideWizard() }
                .buttonStyle(.link)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 14) {
            chip(1, "算力与模型", "Hardware & model")
            chip(2, "工作区授权", "Workspace")
            chip(3, "手机配对", "Phone pairing")
            chip(4, "测试简报", "Test briefing")
            Spacer()
        }
    }

    private func chip(_ index: Int, _ zh: String, _ en: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(index == step
                          ? Color.accentColor
                          : (done(index) ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14)))
                    .frame(width: 20, height: 20)
                if done(index) && index != step {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.green)
                } else {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(index == step ? Color.white : Color.secondary)
                }
            }
            Text(label(zh, en))
                .font(.caption)
                .foregroundStyle(index == step ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.wizardStep = index }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: hardwareStep
        case 2: workspaceStep
        case 3: pairingStep
        default: testStep
        }
    }

    // MARK: Step 1 — hardware, install, one-click pull, explicit skip

    private var hardwareStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text(label("算力检测", "Hardware check"))) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(label("本机芯片与内存", "Chip & memory"), value: snapshot?.hardware.shortLabel ?? "—")
                    LabeledContent(label("推荐本机模型", "Recommended local model"), value: recommendedName)
                    LabeledContent(label("内存准入", "Memory admission"), value: admissionLine)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let steps = snapshot?.install.steps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label("部署清单", "Install checklist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(steps.prefix(8)) { row in
                        HStack(spacing: 6) {
                            Image(systemName: installGlyph(row.state))
                                .font(.system(size: 10))
                                .foregroundStyle(installColor(row.state))
                            Text(language.text(zh: row.titleZh, en: row.titleEn))
                                .font(.caption)
                            Spacer()
                            if row.state == .running {
                                ProgressView(value: row.progress)
                                    .frame(width: 80)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(label("开始部署", "Start install")) { model.startInstall() }
                    .disabled(snapshot?.install.running == true)
                if pull.state.isRunning {
                    Button(label("取消拉取", "Cancel pull")) { model.cancelModelPull() }
                } else {
                    Button(label("一键拉取 \(recommendedName)", "Pull \(recommendedName)")) {
                        model.pullModel(recommendedRef)
                    }
                    .disabled(recommendedRef.isEmpty)
                }
                Spacer()
            }

            if pull.state != .idle {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(pull.percent) / 100)
                    HStack(spacing: 8) {
                        Text("\(pullStateLine) · \(pull.percent)%")
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        if !pull.sizeLine.isEmpty {
                            Text(pull.sizeLine)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !pull.detail.isEmpty {
                        Text(pull.detail)
                            .font(.caption2)
                            .foregroundStyle(pull.state == .failed || pull.state == .refused ? Color.orange : Color.secondary)
                    }
                }
            }

            lightweightSkipBlock
        }
    }

    /// The explicit zero-model fork. It is a real button, not a link in small
    /// print, and the deterministic rows are listed under it so "skip" never
    /// reads as "lose everything".
    private var lightweightSkipBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLightweight {
                Label(label(
                    "已处于纯轻量模式：零模型运行，确定性能力全部继续工作。",
                    "Lightweight mode is on: zero models run and every deterministic feature keeps working."
                ), systemImage: "bolt.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(label("切回 AI 增强模式", "Switch back to AI-enhanced mode")) {
                    model.setLightweight(false)
                }
                .controlSize(.small)
            } else {
                Button {
                    model.skipModelToLightweight()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "hare.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label("跳过模型，以纯轻量模式继续", "Skip the model and continue in lightweight mode"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(label("零模型运行 · 不下载任何权重 · 随时可切换", "Zero models · no weights to download · reversible anytime"))
                                .font(.caption2)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(label("纯轻量模式下继续工作的能力", "What keeps working with zero models"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(LightweightModePlan.resolve(lightweight: true)) { feature in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: feature.enabled ? "checkmark.circle.fill" : "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(feature.enabled ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(language.text(zh: feature.titleZh, en: feature.titleEn))
                                .font(.caption)
                            if !feature.enabled {
                                Text(language.text(zh: feature.detailZh, en: feature.detailEn))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.18)))
    }

    private func installGlyph(_ value: StepState) -> String {
        switch value {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func installColor(_ value: StepState) -> Color {
        switch value {
        case .pending: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    // MARK: Step 2 — native folder picker

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label(
                "授权一个工作区文件夹，助手与本地情景记忆才能读取你明确放进来的文件。授权是只读的，任何写入仍然逐次生成人工审批回执。",
                "Authorize a workspace folder so the assistant and local episodic memory can read files you deliberately place there. The grant is read-only; every write still becomes a human approval receipt."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.chooseWorkspaceFolder()
            } label: {
                Label(label("选择文件夹…", "Choose folder…"), systemImage: "folder.badge.plus")
            }
            .controlSize(.large)

            GroupBox(label: Text(label("已授权目录", "Authorized folders"))) {
                VStack(alignment: .leading, spacing: 4) {
                    let directories = snapshot?.privacy.directories ?? []
                    if directories.isEmpty {
                        Text(label("尚未授权任何目录", "No folder authorized yet"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(directories, id: \.self) { path in
                            Label(path, systemImage: "folder")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(label(
                "最多保留 \(snapshot?.privacy.directoryCeiling ?? 8) 个目录；路径以 ~ 显示。",
                "Up to \(snapshot?.privacy.directoryCeiling ?? 8) folders are kept; paths are shown with ~."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if isLightweight {
                Text(label(
                    "纯轻量模式下可以暂时跳过这一步，之后随时在控制台补上。",
                    "You may skip this step in lightweight mode and add folders from the console later."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 3 — large sealed QR and live phone detection

    private var pairingStep: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white)
                if let image = model.pairingImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 272, height: 272)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
            .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                pairingStatusPill
                VStack(alignment: .leading, spacing: 5) {
                    Text(label("1 · 在手机上打开 POPOPX", "1 · Open POPOPX on the phone"))
                    Text(label("2 · 扫描左侧二维码（密封的 /i/v1/ 配对码）", "2 · Scan the QR on the left (the sealed /i/v1/ pairing code)"))
                    Text(label("3 · 保持手机与这台 Mac 都已解锁", "3 · Keep both the phone and this Mac unlocked"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(label("生成新二维码", "New QR code")) { model.rotatePairingAndRefresh() }
                    Button(label("刷新", "Refresh")) {
                        model.refreshPairingImage()
                        model.refreshNow()
                    }
                }
                .controlSize(.small)

                Text(label(
                    "二维码只含密封配对信封；扫到后再由节点签名确认，未配对设备拿不到任何能力。",
                    "The QR carries only the sealed pairing envelope; the node signs it afterwards, and an unpaired device receives no capability."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var pairingStatusPill: some View {
        let paired = snapshot?.pairedDevices.count ?? 0
        let daemon = snapshot?.bridge.daemon
        let text: String
        let icon: String
        let color: Color
        if paired > 0 {
            text = label("已检测到 \(paired) 台手机连接", "\(paired) phone(s) connected")
            icon = "iphone.badge.checkmark"
            color = .green
        } else if daemon == .running {
            text = label("二维码就绪，等待手机扫描…", "QR ready, waiting for the phone…")
            icon = "iphone"
            color = .secondary
        } else if daemon == .missingBinary {
            text = label("未安装 popopx-chat，无法接受配对", "popopx-chat is not installed, so pairing cannot complete")
            icon = "exclamationmark.triangle"
            color = .orange
        } else {
            text = label("配对服务尚未在线", "the pairing service is not online yet")
            icon = "exclamationmark.triangle"
            color = .orange
        }
        return Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Step 4 — one-click test briefing

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text(label("发送目标", "Delivery target"))) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(label("节点名称", "Node name"), value: snapshot?.node.displayName ?? "—")
                    LabeledContent(label("当前模式", "Current mode"), value: modeLine)
                    LabeledContent(label("已配对设备", "Paired devices"), value: "\(snapshot?.pairedDevices.count ?? 0)")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.sendTestBriefing()
            } label: {
                HStack(spacing: 8) {
                    if model.wizardTestSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(label("发送测试简报", "Send test briefing"))
                }
            }
            .controlSize(.large)
            .disabled(model.wizardTestSending || (snapshot?.pairedDevices.count ?? 0) == 0)

            if let result = model.wizardTestResult {
                Label(result, systemImage: model.wizardTestDelivered ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(model.wizardTestDelivered ? Color.green : Color.orange)
            } else if (snapshot?.pairedDevices.count ?? 0) == 0 {
                Text(label("还没有已配对设备，先回到第 3 步扫码。", "No paired device yet; go back to step 3 and scan the QR."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.wizardTestDelivered {
                Label(label("手机已确认收到测试简报", "The phone confirmed the test card"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Text(label(
                "测试简报走与正式简报相同的加密配对通道，不触发任何写入，也不会携带任何凭据。",
                "The test card uses the same encrypted pairing channel as a real briefing; it triggers no write and carries no credential."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var modeLine: String {
        guard let mode = snapshot?.model.mode else { return "—" }
        return language.text(zh: mode.headlineZh, en: mode.headlineEn)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(label("稍后再说", "Later")) { model.hideWizard() }
            Spacer()
            if let state {
                Text(label(
                    "已完成 \(state.completedSteps)/4 步",
                    "\(state.completedSteps)/4 steps done"
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if step > 1 {
                Button(label("上一步", "Back")) { model.wizardStep = step - 1 }
            }
            if step < 4 {
                Button(label("下一步", "Next")) { model.wizardStep = step + 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(label("完成", "Finish")) { model.completeWizard() }
                    .buttonStyle(.borderedProminent)
            }
        }
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

    private var pendingCards: [AssistantProposalCard] {
        model.snapshot?.assistant.pending.filter { $0.state.isPending } ?? []
    }

    /// The health light: green when the enhanced mode's model answers, amber when
    /// it does not, grey when the owner chose zero models. It is derived from
    /// `LocalModelCard.mode`, the same value the console paints, so the two
    /// surfaces cannot disagree about which mode the node is in.
    private var healthColor: Color {
        switch model.snapshot?.model.mode.health ?? "" {
        case "ok": return .green
        case "warn": return .orange
        default: return .gray
        }
    }

    private var modeHeadline: String {
        guard let mode = model.snapshot?.model.mode else {
            return label("正在连接本机节点…", "Connecting to the local node…")
        }
        return language.text(zh: mode.headlineZh, en: mode.headlineEn)
    }

    private var lightweightBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot?.settings.isLightweight ?? false },
            set: { model.setLightweight($0) }
        )
    }

    /// The quick-approval strip. The receipt is minted inside the node by
    /// `assistantDecision`; this view only sends the id and a verb, exactly like
    /// the console's own click.
    private var pendingApprovals: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pendingCards.prefix(3)) { card in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(language.text(zh: card.kind.labelZh, en: card.kind.labelEn)
                             + " · "
                             + label("剩余 \(card.secondsLeft) 秒", "\(card.secondsLeft) s left"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        model.decideAssistant(card.id, verb: "approve")
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(card.canApprove ? Color.green : Color.secondary)
                    .disabled(!card.canApprove)
                    .help(label("批准并执行 · 回执在节点内生成", "Approve and run · the receipt is minted inside the node"))
                    Button {
                        model.decideAssistant(card.id, verb: "reject")
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(label("拒绝", "Reject"))
                }
            }
            if pendingCards.count > 3 {
                Text(label("还有 \(pendingCards.count - 3) 项，见网页控制台", "\(pendingCards.count - 3) more in the web console"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25)))
    }

    /// Mode, model, pull progress and the lightweight switch. The switch writes
    /// through the model route, which also tells the assistant to stop using the
    /// local model, so flipping it here is the same operation as the console's.
    @ViewBuilder
    private func modelCenterRow(_ card: LocalModelCard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: card.mode.mode == .lightweight ? "bolt.slash" : "bolt.fill")
                    .foregroundStyle(card.mode.mode == .lightweight ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text(zh: card.mode.headlineZh, en: card.mode.headlineEn))
                        .font(.caption)
                    Text(card.modelRef.isEmpty ? label("未指定本机模型", "no local model pinned") : card.modelRef)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: lightweightBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(label("纯轻量模式：零模型运行", "Lightweight mode: zero models run"))
            }
            if card.pull.state.isRunning {
                ProgressView(value: Double(card.pull.percent) / 100)
                HStack(spacing: 6) {
                    Text("\(card.pull.percent)% · \(card.pull.status)")
                        .font(.caption2.monospacedDigit())
                    Spacer(minLength: 4)
                    if !card.pull.sizeLine.isEmpty {
                        Text(card.pull.sizeLine)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button(label("取消", "Cancel")) { model.cancelModelPull() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            } else if !card.mode.modelReady {
                Button(label("一键拉取本机模型", "Pull the local model")) { model.pullModel() }
                    .controlSize(.small)
            }
            if card.pull.state == .failed || card.pull.state == .refused {
                Text(card.pull.detail)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: healthColor.opacity(0.55), radius: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(modeHeadline)
                        .font(.system(size: 13, weight: .semibold))
                    Text(label("Connect Everything. 连接一切，让智能自由协作。", "Connect Everything."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(label(
                        "POPOPX 隐私优先智能连接平台的本机边缘算力与隐私执行节点",
                        "The on-device edge compute and privacy execution node of POPOPX, the Privacy-First Intelligent Connection Platform"
                    ))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(NodeVersion.current.semanticString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(daemonLabel, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                Label(label("手机配对 · \(model.snapshot?.pairedDevices.count ?? 0) 台设备",
                            "Phone pairing · \(model.snapshot?.pairedDevices.count ?? 0) device(s)"),
                      systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle((model.snapshot?.pairedDevices.count ?? 0) > 0 ? Color.green : Color.secondary)
                Label(label("待审批 · \(pendingCards.count) 项", "Pending approvals · \(pendingCards.count)"),
                      systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(pendingCards.isEmpty ? Color.secondary : Color.orange)
                Label(hardwareLine + " · " + label("\(activeTasks) 个任务", "\(activeTasks) task(s)"),
                      systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !pendingCards.isEmpty {
                pendingApprovals
            }

            if let card = model.snapshot?.model {
                modelCenterRow(card)
            }

            Divider()

        Button(action: { model.openConsole() }) {
                Label(label("打开网页控制台", "Open Web Console"), systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(",", modifiers: [.command, .shift])

            HStack(spacing: 6) {
                Button(label("复制配对地址", "Copy Console URL")) { model.copyConsoleURL() }
                    .disabled(model.consoleURL.isEmpty)
                Button(label("立即重新扫描", "Rescan Now")) { model.refreshNow() }
                Button(label("生成新的配对二维码", "New Pairing QR")) { model.rotatePairingNow() }
                Button(label("打开首次运行向导", "Open Setup Wizard")) { model.showWizard() }
            }
            .controlSize(.small)

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

        if let watchdog = model.snapshot?.watchdog {
            Label(watchdog.installed
                  ? label("看门狗已安装 · 已重启 \(watchdog.restartCount) 次",
                          "Watchdog installed · \(watchdog.restartCount) restart(s)")
                  : label("看门狗未安装", "Watchdog not installed"),
                  systemImage: "heart.text.square")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        }
        .padding(14)
        .frame(width: 360)
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

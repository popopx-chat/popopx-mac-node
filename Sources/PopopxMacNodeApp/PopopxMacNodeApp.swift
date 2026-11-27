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
            sentinel: sentinel
        ) { [weak self] result in
            guard let self else { return false }
            return await self.deliverAssistantCard(result)
        }
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
            assistant: await assistantSnapshotValue()
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
            Text(label("Connect Everything. 连接一切，让智能自由协作。", "Connect Everything."))
                .font(.system(size: 12, weight: .semibold))
                .disabled(true)
            Text(label(
                "POPOPX 隐私优先智能连接平台的本机边缘算力与隐私执行节点",
                "The on-device edge compute and privacy execution node of POPOPX, the Privacy-First Intelligent Connection Platform"
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .disabled(true)
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

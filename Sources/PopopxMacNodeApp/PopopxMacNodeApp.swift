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
    static func main() async {
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
        await model.bootstrap()

        if headless {
            await model.runHeadless()
            return
        }

        await MainActor.run {
            PopopxMacNodeApp.main()
        }
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

    private var consoleURLString = ""
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

    private func record(_ result: CommandResult) {
        recent.append(result)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }

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
        let backlog = await events
        return ConsoleSnapshot(
            node: await identity,
            hardware: await profile,
            plan: await plan,
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
            eventsBacklog: Array(backlog.suffix(60))
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

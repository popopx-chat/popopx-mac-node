//
//  HardwareProfilerAndInstaller.swift
//  PopopxMacNode — module 1: hardware portrait + one-click environment deployer.
//
//  Two responsibilities live here:
//
//  * `HardwareProfiler` reads the machine (sysctl, Mach host statistics, volume
//    resource values) and turns it into a `MacHardwareProfile`, a live
//    `SystemLoad` sample and a `ToolchainProbe` list.
//  * `EnvironmentInstaller` runs the wizard's "一键自动部署本地 AI 引擎" flow as a
//    cancellable, sequentially-weighed step plan, streaming `InstallEvent` lines
//    that the console renders into its log window.
//
//  `NodeEnvironment` fuses the two behind the frozen `NodeHardwareProbing`
//  protocol so the composition root sees one collaborator.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Weight source configuration

/// Optional, user-supplied description of where model weights come from.
///
/// The node deliberately ships with **no** hard-coded weight URLs: a checksum
/// we cannot verify is not a download we should start, and an upstream path we
/// invent would silently break every install. Instead the operator declares the
/// sources they trust in `config/engines.json`, and the installer verifies each
/// artifact against the declared SHA-256 before promoting it into `weights/`.
public struct HWWeightSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var url: String
    public var sha256: String
    public var targetSubdirectory: String
    public var sizeBytesHint: Int64?

    public init(
        name: String,
        url: String,
        sha256: String,
        targetSubdirectory: String = "",
        sizeBytesHint: Int64? = nil
    ) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.targetSubdirectory = targetSubdirectory
        self.sizeBytesHint = sizeBytesHint
    }
}

/// Contents of `config/engines.json`.
public struct HWEngineConfig: Codable, Sendable, Equatable {
    public var weightSources: [HWWeightSource]
    public var simplexChatBinaryPath: String?
    public var ollamaBaseURL: String?
    public var allowHomebrewBootstrap: Bool

    public init(
        weightSources: [HWWeightSource] = [],
        simplexChatBinaryPath: String? = nil,
        ollamaBaseURL: String? = nil,
        allowHomebrewBootstrap: Bool = false
    ) {
        self.weightSources = weightSources
        self.simplexChatBinaryPath = simplexChatBinaryPath
        self.ollamaBaseURL = ollamaBaseURL
        self.allowHomebrewBootstrap = allowHomebrewBootstrap
    }

    public static let empty = HWEngineConfig()

    public static var configFile: URL {
        AppPaths.config.appendingPathComponent("engines.json")
    }

    /// Missing file is the normal case, not an error.
    public static func load() -> HWEngineConfig {
        guard let data = try? Data(contentsOf: configFile) else { return .empty }
        return NodeJSON.decode(HWEngineConfig.self, from: data) ?? .empty
    }

    public func save() -> Bool {
        guard let data = NodeJSON.encodePretty(self) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: Self.configFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.configFile, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Mach statistics sampling

/// One `host_cpu_load_info` snapshot; deltas between two of these give CPU %.
private struct HWCPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice) }
    var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }

    static func sample() -> HWCPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = withUnsafePointer(to: info.cpu_ticks) { pointer in
            pointer.withMemoryRebound(to: UInt32.self, capacity: 4) { $0 }
        }
        return HWCPUTicks(user: ticks[0], system: ticks[1], idle: ticks[2], nice: ticks[3])
    }

    static func busyFraction(before: HWCPUTicks, after: HWCPUTicks) -> Double? {
        let totalDelta = after.total - before.total
        guard totalDelta > 0 else { return nil }
        return Double(after.busy - before.busy) / Double(totalDelta)
    }
}

/// Kernel VM statistics converted into a "memory in use" number that matches
/// what Activity Monitor reports (active + wired + compressed).
private struct HWMemorySample {
    var totalBytes: UInt64
    var activeBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freeBytes: UInt64

    var usedBytes: UInt64 {
        min(totalBytes, activeBytes + wiredBytes + compressedBytes)
    }

    var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }

    static func sample() -> HWMemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        return HWMemorySample(
            totalBytes: Sysctl.memorySize,
            activeBytes: UInt64(stats.active_count) * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
            freeBytes: UInt64(stats.free_count) * pageSize
        )
    }

    /// Pressure is derived from the used fraction rather than the swap sysctl,
    /// because `vm.swapusage` is only refreshed lazily by the kernel.
    var pressure: SystemLoad.MemoryPressure {
        switch usedFraction {
        case ..<0.72: return .nominal
        case ..<0.90: return .warning
        default: return .critical
        }
    }
}

// MARK: - Hardware profiler

/// Reads the machine. Every method is safe to call repeatedly and never writes.
public actor HardwareProfiler {
    public static let shared = HardwareProfiler()

    private var cachedProfile: MacHardwareProfile?
    private var lastCPUTicks: HWCPUTicks?
    private let fileManager = FileManager.default

    public init() {}

    /// Full portrait, memoised for the process lifetime. Re-read `loadSample()`
    /// for anything that actually moves.
    public func profile(forceRefresh: Bool = false) -> MacHardwareProfile {
        if let cachedProfile, !forceRefresh { return cachedProfile }
        let memoryBytes = Int64(clamping: Sysctl.memorySize)
        let totalMemory = ByteCount(memoryBytes)

        let perfCores = Sysctl.performanceCores
        let effCores = Sysctl.efficiencyCores
        let physical = Sysctl.physicalCPUCount

        let chip = Sysctl.chipName
            ?? (Sysctl.string("hw.machine") ?? "Apple Silicon").replacingOccurrences(of: "-", with: " ")

        let profile = MacHardwareProfile(
            chipName: chip,
            modelIdentifier: Sysctl.modelIdentifier ?? "unknown",
            cpuArchitecture: Sysctl.string("hw.machine") ?? "unknown",
            logicalCPUCount: Sysctl.logicalCPUCount,
            physicalCPUCount: physical > 0 ? physical : Sysctl.logicalCPUCount,
            performanceCoreCount: perfCores,
            efficiencyCoreCount: effCores,
            memoryTotal: totalMemory,
            freeDisk: ByteCount(volumeFreeBytes),
            totalDisk: ByteCount(volumeTotalBytes),
            systemVolumeName: volumeName,
            operatingSystem: Sysctl.operatingSystemVersion,
            kernelVersion: Sysctl.kernelVersion ?? "unknown",
            serialMasked: maskedSerial,
            sampledAt: Date()
        )
        cachedProfile = profile
        // A machine the brief does not cover still gets a plan, never a crash.
        _ = ModelPlan.recommend(for: profile)
        return profile
    }

    /// Convenience so callers never re-derive the tier themselves.
    public func plan() -> ModelPlan {
        ModelPlan.recommend(for: profile())
    }

    public func recommendedPlan(memoryGB override: Int? = nil) -> ModelPlan {
        ModelPlan.recommend(memoryGB: override ?? profile().memoryGB)
    }

    /// Live load. The first call samples over a short interval so the CPU figure
    /// is meaningful even immediately after launch.
    public func loadSample() -> SystemLoad {
        let total = ByteCount(Int64(clamping: Sysctl.memorySize))
        var cpuPercent = 0.0
        let current = HWCPUTicks.sample()
        if let previous = lastCPUTicks, let current,
           let fraction = HWCPUTicks.busyFraction(before: previous, after: current) {
            cpuPercent = fraction * 100
        }
        lastCPUTicks = current

        let memory = HWMemorySample.sample()
        let used = memory.map { ByteCount(Int64(clamping: $0.usedBytes)) } ?? ByteCount(0)
        let pressure: SystemLoad.MemoryPressure
        if let memory {
            pressure = memory.pressure
        } else {
            pressure = used.gibibytes > total.gibibytes * 0.9 ? .warning : .nominal
        }

        return SystemLoad(
            cpuLoadPercent: max(0, min(100, cpuPercent)),
            memoryUsed: used,
            memoryPressure: pressure,
            activeProcessCount: Self.activeProcessCount(),
            throughputMBps: nil,
            sampledAt: Date()
        )
    }

    /// Probes a cold-start CPU figure by taking two samples around a short wait.
    public func loadSampleWithWarmup(nanoseconds: UInt64 = 150_000_000) async -> SystemLoad {
        lastCPUTicks = HWCPUTicks.sample()
        try? await Task.sleep(nanoseconds: nanoseconds)
        return loadSample()
    }

    /// Presence and version of every binary the engines and the installer rely on.
    public func toolchain() async -> [ToolchainProbe] {
        let config = HWEngineConfig.load()
        let now = Date()
        var probes: [ToolchainProbe] = []

        for name in ["brew", "ffmpeg", "ffprobe", "uv", "git", "curl", "python3"] {
            let path = Shell.which(name)
            var version: String?
            if let path {
                version = await Self.versionLine(at: path, name: name)
            }
            probes.append(ToolchainProbe(
                name: name,
                resolvedPath: path.map { AppPaths.anonymise($0) },
                versionLine: version,
                present: path != nil,
                checkedAt: now
            ))
        }

        // The chat daemon is reported once, under the name that resolves.
        // `popopx-chat` is the executable of our own fork (popopx-chat.cabal:607)
        // and the only candidate probed: an upstream install would answer a version
        // line here and then fail every command later, which is worse than an
        // honest "missing dependency".
        let configured = config.simplexChatBinaryPath
        let resolved = Self.resolveChatBinary(configured: configured)
        var chatVersion: String?
        if let resolved {
            chatVersion = await Self.versionLine(at: resolved.path, name: resolved.name)
        }
        probes.append(ToolchainProbe(
            name: resolved?.name ?? NodeWire.chatDaemonCandidates[0],
            resolvedPath: resolved.map { AppPaths.anonymise($0.path) },
            versionLine: chatVersion,
            present: resolved != nil,
            checkedAt: now
        ))

        probes.append(await Self.probeOllama(baseURL: config.ollamaBaseURL))
        probes.append(Self.probeLTXWorkspace())
        return probes
    }

    /// Explicit path from `engines.json` wins, otherwise the first candidate found
    /// on the augmented PATH. Returns nil when nothing is installed — the console
    /// then offers the manual-install hint instead of pretending.
    static func resolveChatBinary(configured: String? = nil) -> (name: String, path: String)? {
        if let configured, !configured.isEmpty {
            let expanded = AppPaths.resolve(userPath: configured)
            if let expanded, FileManager.default.isExecutableFile(atPath: expanded.path) {
                return (expanded.lastPathComponent, expanded.path)
            }
        }
        for name in NodeWire.chatDaemonCandidates {
            if let found = Shell.which(name) {
                return (name, found)
            }
        }
        return nil
    }

    /// `true` when everything a given engine needs is actually on this machine.
    public func readiness(for kind: EngineKind) async -> (ready: Bool, missing: [String]) {
        let present = Set(await toolchain().filter { $0.present }.map { $0.name })
        var missing: [String] = []
        if !kind.worksWithoutLocalModels {
            if !present.contains("ollama") && !present.contains("Ollama") { missing.append("ollama") }
        }
        if !present.contains("ffmpeg") { missing.append("ffmpeg") }
        return (missing.isEmpty, missing)
    }

    // MARK: Volume and identity details

    private var volumeFreeBytes: Int64 {
        guard let values = try? fileManager.attributesOfFileSystem(forPath: "/"),
              let free = values[.systemFreeSize] as? NSNumber
        else { return 0 }
        return free.int64Value
    }

    private var volumeTotalBytes: Int64 {
        guard let values = try? fileManager.attributesOfFileSystem(forPath: "/"),
              let size = values[.systemSize] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private var volumeName: String {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey]),
           let name = values.volumeName {
            return name
        }
        return "System Volume"
    }

    /// Serial numbers are never surfaced, not even masked, on Apple Silicon where
    /// `IOPlatformSerialNumber` is unavailable — there we fall back to a digest of
    /// the host name, which is stable but not identifying outside this machine.
    private var maskedSerial: String {
        if let serial = Sysctl.string("IOPlatformSerialNumber"), serial.count >= 4 {
            return "••••" + String(serial.suffix(4))
        }
        return "••••" + String(Digest.sha256Hex(ProcessInfo.processInfo.hostName).prefix(4)).uppercased()
    }

    private static func versionLine(at path: String, name: String) async -> String? {
        // FFmpeg family is the only one that spells its version flag differently;
        // everything else (Homebrew, uv, git, curl, python3 and both chat daemon
        // names) answers `--version`.
        let arguments = (name == "ffmpeg" || name == "ffprobe") ? ["-version"] : ["--version"]
        // Each probe is a sub-100 ms `--version`; `Shell.runAbsolute` already
        // carries an 8 s watchdog, so a hung binary degrades to a missing probe
        // rather than stalling the snapshot the console is waiting on.
        let result = await Shell.runAbsolute(launchPath: path, arguments, timeout: 8)
        let trimmed = result.firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
    }

    /// Ollama is a resident HTTP service rather than a PATH entry, so the probe
    /// asks the daemon itself. `GET /api/version` is answered by every shipped
    /// Ollama build and costs one round trip to loopback.
    private static func probeOllama(baseURL: String?) async -> ToolchainProbe {
        let base = baseURL ?? "http://127.0.0.1:\(NodeWire.ollamaPort)"
        var present = false
        var version: String?
        var resolved: String?

        if let url = URL(string: base + "/api/version"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let object = NodeJSON.decode(HWOllamaVersion.self, from: data) {
            present = true
            version = "ollama \(object.version ?? "?")"
            resolved = base
        }

        if !present, let path = Shell.which("ollama") {
            resolved = AppPaths.anonymise(path)
            version = "daemon offline · binary present"
        }
        return ToolchainProbe(
            name: "ollama",
            resolvedPath: resolved,
            versionLine: version,
            present: present || Shell.which("ollama") != nil,
            checkedAt: Date()
        )
    }

    private static func probeLTXWorkspace() -> ToolchainProbe {
        let manifest = AppPaths.ltxWorkspace.appendingPathComponent("workspace.json")
        let weights = AppPaths.weights
        let weightFiles = (try? FileManager.default.contentsOfDirectory(atPath: weights.path)) ?? []
        let prepared = FileManager.default.fileExists(atPath: manifest.path) && !weightFiles.isEmpty
        return ToolchainProbe(
            name: "ltx-2-mlx",
            resolvedPath: prepared ? AppPaths.anonymise(url: AppPaths.ltxWorkspace) : nil,
            versionLine: prepared ? "\(weightFiles.count) weight artifact(s)" : "workspace not provisioned",
            present: prepared,
            checkedAt: Date()
        )
    }

    /// `kern_proc` list size, used as the "active process count" tile. Reads the
    /// size only — the kernel struct array is never copied into the process.
    static func activeProcessCount() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        return max(0, size / MemoryLayout<kinfo_proc>.stride)
    }
}

struct HWOllamaVersion: Codable {
    let version: String?
}

// MARK: - Environment installer

/// Runs the one-click deploy plan and streams its log.
///
/// Cancellation is cooperative: a step boundary always observes it, and every
/// long-running child process is tracked in `runningProcesses` so a cancel
/// terminates it instead of leaving an orphaned `ffmpeg` or model pull behind.
public actor EnvironmentInstaller {
    public static let shared = EnvironmentInstaller()

    /// Step weights sum to 1 so `InstallState.progress` is a real percentage
    /// rather than "steps finished divided by steps guessed".
    struct HWStep: Sendable {
        let id: String
        let titleZh: String
        let titleEn: String
        let weight: Double
    }

    static let plan: [HWStep] = [
        HWStep(id: "brew", titleZh: "Homebrew 包管理器", titleEn: "Homebrew package manager", weight: 0.08),
        HWStep(id: "ffmpeg", titleZh: "FFmpeg 与 ffprobe", titleEn: "FFmpeg and ffprobe", weight: 0.22),
        HWStep(id: "uv", titleZh: "uv Python 环境", titleEn: "uv Python toolchain", weight: 0.10),
        HWStep(id: "ollama", titleZh: "本地推理服务 Ollama", titleEn: "Local inference service (Ollama)", weight: 0.10),
        HWStep(id: "llm", titleZh: "拉取适配内存的 Qwen 模型", titleEn: "Pull memory-matched Qwen model", weight: 0.24),
        HWStep(id: "workspace", titleZh: "初始化 LTX-2.5 MLX 工作区", titleEn: "Initialise LTX-2.5 MLX workspace", weight: 0.08),
        HWStep(id: "weights", titleZh: "下载并校验模型权重", titleEn: "Download and verify model weights", weight: 0.12),
        HWStep(id: "verify", titleZh: "端到端自检", titleEn: "End-to-end self-check", weight: 0.06)
    ]

    private var state = InstallState(steps: EnvironmentInstaller.initialSteps())
    private var events: [InstallEvent] = []
    private var sequence = 0
    private var subscribers: [UUID: AsyncStream<InstallEvent>.Continuation] = [:]
    private var runningProcesses: [String: Process] = [:]
    private var job: Task<Void, Never>?
    private var cancelRequested = false
    private let profiler: HardwareProfiler
    private let hub: ConsoleEventHub
    private let fileManager = FileManager.default

    public init(profiler: HardwareProfiler = .shared, hub: ConsoleEventHub = .shared) {
        self.profiler = profiler
        self.hub = hub
    }

    static func initialSteps() -> [InstallStep] {
        plan.map { HWStep in
            InstallStep(id: HWStep.id, titleZh: HWStep.titleZh, titleEn: HWStep.titleEn)
        }
    }

    // MARK: Public surface

    public func current() -> InstallState {
        var snapshot = state
        snapshot.tail = Array(events.suffix(160))
        return snapshot
    }

    public func start() {
        if state.running {
            emit(.detecting, "部署已在进行中，忽略重复触发 / deploy already in progress", level: .warning)
            return
        }
        cancelRequested = false
        sequence = 0
        events.removeAll(keepingCapacity: true)
        state = InstallState(
            phase: .detecting,
            running: true,
            progress: 0,
            steps: Self.initialSteps(),
            startedAt: Date()
        )
        emit(.detecting, "开始本机环境部署 / starting environment deployment", level: .notice, progress: 0)
        job = Task { [weak self] in
            await self?.runPlan()
        }
    }

    public func cancel() {
        guard state.running else { return }
        cancelRequested = true
        emit(.cancelled, "收到取消请求，正在终止本机子进程 / cancelling, terminating child processes", level: .warning)
        for (id, process) in runningProcesses where process.isRunning {
            process.terminate()
            emit(.cancelled, "已终止 \(id)", level: .warning)
        }
    }

    public func wait(completionTimeout: TimeInterval = 3600) async -> Bool {
        guard job != nil else { return state.phase == .ready }
        let deadline = Date().addingTimeInterval(completionTimeout)
        while !Task.isCancelled {
            if state.finishedAt != nil || !state.running { return state.phase == .ready }
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    public func subscribe() -> AsyncStream<InstallEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            attach(id: id, continuation: continuation)
        }
    }

    private func attach(id: UUID, continuation: AsyncStream<InstallEvent>.Continuation) {
        subscribers[id] = continuation
        for event in events.suffix(160) { continuation.yield(event) }
        continuation.onTermination = { _ in
            Task { await EnvironmentInstaller.shared.detach(id: id) }
        }
    }

    private func detach(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: Plan execution

    private func runPlan() async {
        let profile = await profiler.profile()
        let modelPlan = ModelPlan.recommend(for: profile)

        emit(.detecting, "芯片 \(profile.chipName) · \(profile.memoryGB) GB 统一内存 · \(profile.physicalCPUCount) 物理核心", level: .info, progress: 0.02)
        emit(.detecting, "内存档位 \(modelPlan.tier.rawValue) / tier: \(modelPlan.tier.titleEn) → \(modelPlan.llmRef) + \(modelPlan.videoRef)", level: .notice)

        let config = HWEngineConfig.load()
        var completedWeight = 0.0
        var failures: [String] = []
        var skipped: [String] = []

        for step in Self.plan {
            if cancelRequested {
                finish(phase: .cancelled, error: "已取消 / cancelled by user")
                return
            }
            setStep(step.id, state: .running, detail: "")
            emit(stepPhase(step.id), "› \(step.titleZh) / \(step.titleEn)", level: .info, progress: completedWeight)

            let outcome = await perform(stepID: step.id, profile: profile, plan: modelPlan, config: config)
            completedWeight += step.weight

            switch outcome {
            case .done(let detail):
                setStep(step.id, state: .done, detail: detail, progress: 1)
                emit(stepPhase(step.id), "✓ \(step.titleZh) 完成 / done — \(detail)", level: .success, progress: completedWeight)
            case .skipped(let reason):
                skipped.append(step.id)
                setStep(step.id, state: .skipped, detail: reason, progress: 1)
                emit(stepPhase(step.id), "! \(step.titleZh) 已跳过 / skipped — \(reason)", level: .warning, progress: completedWeight)
            case .failed(let reason):
                failures.append(step.id)
                setStep(step.id, state: .failed, detail: reason, progress: 0)
                emit(stepPhase(step.id), "✕ \(step.titleZh) 失败 / failed — \(reason)", level: .error, progress: completedWeight)
            }

            updateProgress(completedWeight)

            if cancelRequested {
                finish(phase: .cancelled, error: "已取消 / cancelled by user")
                return
            }
        }

        if failures.isEmpty {
            finish(phase: .ready, error: nil, skipped: skipped)
        } else {
            finish(
                phase: .failed,
                error: "失败步骤 / failed steps: \(failures.joined(separator: ", "))"
                    + (skipped.isEmpty ? "" : " · 跳过 / skipped: \(skipped.joined(separator: ", "))")
            )
        }
    }

    private enum Outcome {
        case done(String)
        case skipped(String)
        case failed(String)
    }

    private func perform(
        stepID: String,
        profile: MacHardwareProfile,
        plan modelPlan: ModelPlan,
        config: HWEngineConfig
    ) async -> Outcome {
        switch stepID {
        case "brew": return await ensureHomebrew(config: config)
        case "ffmpeg": return await ensureFFmpeg()
        case "uv": return await ensureUV()
        case "ollama": return await ensureOllama(config: config)
        case "llm": return await pullLLM(modelPlan: modelPlan, config: config)
        case "workspace": return await prepareLTXWorkspace(modelPlan: modelPlan)
        case "weights": return await fetchWeights(config: config, modelPlan: modelPlan)
        case "verify": return await selfCheck(modelPlan: modelPlan)
        default: return .skipped("unknown step")
        }
    }

    // MARK: Steps

    /// Detection first, install second, and never an assumed formula name: we ask
    /// Homebrew whether it knows the formula before invoking an install, so a
    /// renamed or removed upstream package degrades to `skipped` instead of
    /// producing a confusing `Error: No available formula`.
    private func ensureHomebrew(config: HWEngineConfig) async -> Outcome {
        if let path = Shell.which("brew") {
            let version = await Shell.run(path, ["--version"], timeout: 15)
            return .done(AppPaths.anonymise(path) + " · " + version.firstLine)
        }
        guard config.allowHomebrewBootstrap else {
            return .skipped(
                "未安装 Homebrew，且未开启自动引导。在 config/engines.json 设置 "
                    + "\"allowHomebrewBootstrap\": true 后重试 / Homebrew missing and bootstrap is opt-in"
            )
        }
        emit(.provisioning, "正在通过官方脚本引导安装 Homebrew（需要管理员权限，非交互模式）", level: .notice)
        // The payload below is a fixed literal, not user input, so passing it to
        // `bash -c` cannot inject anything; every other step in this file uses an
        // argument vector instead precisely so that untrusted text never becomes
        // a shell string.
        let result = await Shell.run(
            "/bin/bash",
            ["-c", "curl -fsSL https://brew.sh | NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash"],
            timeout: 1_800
        )
        guard result.succeeded else {
            return .failed("Homebrew 引导失败 / bootstrap failed: \(AppPaths.anonymise(result.firstLine))")
        }
        return Shell.which("brew") == nil
            ? .failed("Homebrew 安装后仍不可见于 PATH / installed but not on PATH")
            : .done("bootstrap ok")
    }

    private func ensureFFmpeg() async -> Outcome {
        if Shell.which("ffmpeg") != nil, Shell.which("ffprobe") != nil {
            let version = await Shell.run("ffmpeg", ["-version"], timeout: 20)
            return .done(version.firstLine)
        }
        guard Shell.which("brew") != nil else {
            return .skipped("需要 Homebrew 才能自动安装 FFmpeg / needs Homebrew")
        }
        guard await formulaExists("ffmpeg") else {
            return .skipped("Homebrew 仓库中没有 ffmpeg formula / formula not found")
        }
        emit(.provisioning, "brew install ffmpeg（体积较大，取决于网络）", level: .notice)
        let result = await Shell.run(
            "brew",
            ["install", "--formula", "ffmpeg"],
            timeout: 3_000
        )
        guard result.succeeded else {
            return .failed("brew install ffmpeg 失败: \(AppPaths.anonymise(result.firstLine))")
        }
        return Shell.which("ffmpeg") == nil
            ? .failed("ffmpeg 安装后不在 PATH / not on PATH after install")
            : .done("installed")
    }

    private func ensureUV() async -> Outcome {
        if let path = Shell.which("uv") {
            let version = await Shell.run(path, ["--version"], timeout: 15)
            return .done(version.firstLine)
        }
        guard Shell.which("brew") != nil else {
            return .skipped("需要 Homebrew 才能自动安装 uv / needs Homebrew")
        }
        guard await formulaExists("uv") else {
            return .skipped("Homebrew 仓库中没有 uv formula / formula not found")
        }
        let result = await Shell.run("brew", ["install", "--formula", "uv"], timeout: 900)
        guard result.succeeded else {
            return .failed("brew install uv 失败: \(AppPaths.anonymise(result.firstLine))")
        }
        return Shell.which("uv") == nil ? .failed("uv 安装后不在 PATH") : .done("installed")
    }

    /// Ollama is normally a GUI-installed app; we start an existing install rather
    /// than downloading an installer, because silently pulling and executing a
    /// third-party `.dmg` is exactly the kind of step a security-conscious user
    /// should approve themselves.
    private func ensureOllama(config: HWEngineConfig) async -> Outcome {
        if await ollamaReachable(config: config) {
            return .done("daemon live")
        }
        let appPath = "/Applications/Ollama.app"
        if fileManager.fileExists(atPath: appPath) {
            emit(.provisioning, "检测到 Ollama.app，正在启动守护进程", level: .notice)
            _ = await Shell.run("/usr/bin/open", ["-a", "Ollama"], timeout: 30)
            for attempt in 1...20 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if await ollamaReachable(config: config) {
                    return .done(String(format: "daemon live after %.1fs", Double(attempt) * 1.5))
                }
                if cancelRequested { return .skipped("cancelled while waiting for daemon") }
            }
            return .failed("Ollama 已启动但 \(NodeWire.ollamaPort) 端口无响应 / port not answering")
        }
        if Shell.which("ollama") != nil {
            emit(.provisioning, "以 serve 模式启动本机 ollama 二进制", level: .notice)
            startTracked(
                id: "ollama-serve",
                launchPath: Shell.which("ollama") ?? "ollama",
                arguments: ["serve"],
                environment: ["OLLAMA_HOST": "127.0.0.1:\(NodeWire.ollamaPort)"],
                timeout: 86_400
            )
            for _ in 1...12 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await ollamaReachable(config: config) { return .done("daemon live (serve)") }
            }
            return .failed("ollama serve 未就绪 / serve did not come up")
        }
        return .skipped(
        """
        未检测到 Ollama。请自行安装后重新点击一键部署，或在「影子幕僚」等引擎卡片上改用边缘算力节点。
        Ollama was not found; install it, then re-run the deploy.
        """
        )
    }

    private func pullLLM(modelPlan: ModelPlan, config: HWEngineConfig) async -> Outcome {
        guard await ollamaReachable(config: config) else {
            return .skipped("Ollama 不可用，跳过模型拉取 / Ollama unavailable")
        }
        if await ollamaHasModel(ref: modelPlan.llmRef, config: config) {
            return .done("\(modelPlan.llmRef) 已存在 / already present")
        }
        emit(.pullingLLM, "\(modelPlan.ollamaModelPull)（数 GB，进度由守护进程侧统计）", level: .notice)
        let result = await Shell.run(
            "ollama",
            ["pull", modelPlan.llmRef],
            timeout: 5_400
        )
        if cancelRequested { return .skipped("cancelled during model pull") }
        guard result.succeeded else {
            return .failed("拉取 \(modelPlan.llmRef) 失败: \(AppPaths.anonymise(result.firstLine))")
        }
        let verify = await ollamaHasModel(ref: modelPlan.llmRef, config: config)
        return verify
            ? .done(modelPlan.llmRef)
            : .failed("拉取完成但 /api/tags 未列出该模型 / pull finished, model absent from tags")
    }

    /// Creates the MLX workspace skeleton: directories, a venv, and a manifest the
    /// console and the engines both read. We do not clone an upstream repository
    /// on the user's behalf — the spec names no verifiable source, and pinning a
    /// URL we guessed would make every install silently depend on our guess.
    private func prepareLTXWorkspace(modelPlan: ModelPlan) async -> Outcome {
        let hardware = await profiler.profile()
        do {
            try fileManager.createDirectory(at: AppPaths.ltxWorkspace, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: AppPaths.ltxModelDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: AppPaths.weights, withIntermediateDirectories: true)
        } catch {
            return .failed("无法创建工作区: \(AppPaths.anonymise(error.localizedDescription))")
        }

        var venvState = "未创建 / not created"
        if Shell.which("uv") != nil {
            let result = await Shell.run(
                "uv",
                ["venv", AppPaths.ltxVenv.path, "--python", "3.12"],
                at: AppPaths.ltxWorkspace,
                timeout: 600
            )
            venvState = result.succeeded ? "uv venv ready (python 3.12)" : "venv failed: \(result.firstLine)"
        } else {
            venvState = "skipped: uv missing"
        }

        let manifest = HWWorkspaceManifest(
            workspace: AppPaths.anonymise(url: AppPaths.ltxWorkspace),
            tier: modelPlan.tier.rawValue,
            videoRef: modelPlan.videoRef,
            videoPrecision: modelPlan.videoPrecision,
            audioSampleRateHz: modelPlan.audioSampleRateHz,
            renderWorkerBudget: hardware.renderWorkerBudget,
            provisionedAt: Date(),
            venv: venvState
        )
        guard let data = NodeJSON.encodePretty(manifest) else {
            return .failed("无法序列化 workspace.json")
        }
        let manifestURL = AppPaths.ltxWorkspace.appendingPathComponent("workspace.json")
        do {
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            return .failed("无法写入 workspace.json: \(AppPaths.anonymise(error.localizedDescription))")
        }
        return venvState.hasPrefix("venv failed") ? .skipped(venvState) : .done(manifest.venv)
    }

    /// Downloads only what the operator declared in `config/engines.json`, and only
    /// after the streamed SHA-256 matches. A hint that is absent is a `skipped`
    /// step, never a silent failure.
    private func fetchWeights(config: HWEngineConfig, modelPlan: ModelPlan) async -> Outcome {
        guard !config.weightSources.isEmpty else {
            return .skipped(
            """
            未声明权重源。在 config/engines.json 的 weightSources 中填入 name/url/sha256 后重试。
            No weight sources declared; add name/url/sha256 entries to config/engines.json.
            """
            )
        }
        let profile = await profiler.profile()
        guard profile.freeDisk.bytes > ByteCount(40).bytes else {
            return .skipped("可用空间不足 40 GB / less than 40 GB free")
        }

        var stored = 0
        var mismatched: [String] = []
        for source in config.weightSources {
            if cancelRequested { return .skipped("cancelled during weight download") }
            emit(.downloadingWeights, "下载 \(source.name) → \(AppPaths.anonymise(url: AppPaths.weights))", level: .notice)
            let destination = AppPaths.weights
                .appendingPathComponent(source.targetSubdirectory, isDirectory: true)
                .appendingPathComponent(TextKit.safeFileName(source.url.deletingPathExtensionComponents))
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                mismatched.append("\(source.name): cannot stage directory")
                emit(.downloadingWeights, "✕ \(source.name) 无法创建目标目录 / cannot stage directory", level: .error)
                continue
            }
            guard await downloadFile(from: source.url, to: destination) else {
                mismatched.append("\(source.name): download failed")
                emit(.downloadingWeights, "✕ \(source.name) 下载失败 / download failed", level: .error)
                continue
            }

            let digest = await Task.detached(priority: .utility) {
                EnvironmentInstaller.sha256(ofFileAt: destination)
            }.value
            guard let expected = Digest.normalized(source.sha256), let actual = Digest.normalized(digest),
                  Digest.matches(expected, actual) else {
                try? fileManager.removeItem(at: destination)
                mismatched.append("\(source.name): sha256 mismatch")
                emit(.downloadingWeights, "✕ \(source.name) 校验失败，已删除 / checksum mismatch, artifact removed", level: .error)
                continue
            }
            stored += 1
            emit(.downloadingWeights, "✓ \(source.name) 校验通过 / verified", level: .success)
        }

        if stored == 0 {
            return .failed("全部权重均未通过校验 / no artifact passed verification: \(mismatched.joined(separator: "; "))")
        }
        let manifestURL = AppPaths.weights.appendingPathComponent("verified.json")
        let manifest = HWWeightManifest(
            artifacts: config.weightSources.map { HWWeightRecord(name: $0.name, sha256: $0.sha256, tier: modelPlan.tier.rawValue) },
            verifiedAt: Date()
        )
        if let data = NodeJSON.encodePretty(manifest) {
            try? data.write(to: manifestURL, options: [.atomic])
        }
        return mismatched.isEmpty
            ? .done("\(stored) artifact(s) verified")
            : .skipped("\(stored) ok, rejected: \(mismatched.joined(separator: "; "))")
    }

    private func selfCheck(modelPlan: ModelPlan) async -> Outcome {
        var problems: [String] = []
        if Shell.which("ffmpeg") == nil { problems.append("ffmpeg") }
        let daemonUp = await ollamaReachable(config: HWEngineConfig.load())
        if !daemonUp { problems.append("ollama") }
        if !fileManager.fileExists(atPath: AppPaths.ltxWorkspace.appendingPathComponent("workspace.json").path) {
            problems.append("ltx workspace")
        }
        let probes = await profiler.toolchain()
        let presentCount = probes.filter { $0.present }.count
        emit(
            .verifying,
            "自检：\(probes.count) 项探测中 \(presentCount) 项就绪，档位 \(modelPlan.tier.titleZh) / \(modelPlan.tier.titleEn)",
            level: problems.isEmpty ? .success : .warning
        )
        guard problems.isEmpty else {
            return .skipped("缺失 / missing: \(problems.joined(separator: ", "))")
        }
        return .done("全部关键组件就绪 / all critical components present")
    }

    // MARK: Ollama HTTP helpers

    private func ollamaReachable(config: HWEngineConfig) async -> Bool {
        let base = config.ollamaBaseURL ?? "http://127.0.0.1:\(NodeWire.ollamaPort)"
        guard let url = URL(string: base + "/api/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func ollamaHasModel(ref: String, config: HWEngineConfig) async -> Bool {
        let base = config.ollamaBaseURL ?? "http://127.0.0.1:\(NodeWire.ollamaPort)"
        guard let url = URL(string: base + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = NodeJSON.decode(HWOllamaTags.self, from: data)
        else { return false }
        return list.models.contains { $0.name == ref || $0.name.hasPrefix(ref + ":") }
    }

    private func formulaExists(_ name: String) async -> Bool {
        let result = await Shell.run("brew", ["info", "--formula", name], timeout: 90)
        return result.succeeded
    }

    // MARK: Tracked subprocess execution

    /// Launches a long-lived child (model pulls, `ollama serve`) while keeping the
    /// handle, so `cancel()` can terminate it. Short probes use `Shell.run`, whose
    /// own watchdog already bounds the lifetime.
    private func startTracked(
        id: String,
        launchPath: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var env = Shell.augmentedEnvironment
        for (key, value) in environment ?? [:] { env[key] = value }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.clearTracked(id: id) }
        }
        do {
            try process.run()
            runningProcesses[id] = process
            if timeout > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    await self.terminateTracked(id: id)
                }
            }
        } catch {
            emit(.provisioning, "无法启动 \(id): \(AppPaths.anonymise(error.localizedDescription))", level: .error)
        }
    }

    private func terminateTracked(id: String) {
        guard let process = runningProcesses[id], process.isRunning else { return }
        process.terminate()
        emit(.provisioning, "\(id) 超时，已终止 / exceeded its budget", level: .warning)
    }

    private func clearTracked(id: String) {
        runningProcesses.removeValue(forKey: id)
    }

    // MARK: Event plumbing

    private func emit(_ phase: InstallPhase, _ text: String, level: EventLevel = .info, progress: Double? = nil) {
        sequence += 1
        let event = InstallEvent(
            seq: sequence,
            phase: phase,
            level: level,
            text: text,
            progress: progress ?? state.progress
        )
        events.append(event)
        if events.count > 800 { events.removeFirst(events.count - 800) }
        for continuation in subscribers.values { continuation.yield(event) }
        Task {
            await hub.publish(
                .install,
                text,
                level: level,
                payload: ["seq": .int(event.seq), "phase": .string(phase.rawValue)]
            )
        }
        appendToFile(event)
    }

    private func appendToFile(_ event: InstallEvent) {
        let url = AppPaths.installLogFile
        let line = "\(event.at.ppxISO8601) [\(event.level.rawValue)] (\(event.phase.rawValue)) \(event.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func setStep(_ id: String, state stepState: StepState, detail: String, progress: Double = 0) {
        guard let index = state.steps.firstIndex(where: { $0.id == id }) else { return }
        state.steps[index].state = stepState
        state.steps[index].detail = detail
        state.steps[index].progress = progress
        state.steps[index].updatedAt = Date()
    }

    private func updateProgress(_ value: Double) {
        state.progress = min(max(value, 0), 1)
    }

    private func finish(phase: InstallPhase, error: String?, skipped: [String] = []) {
        state.running = false
        state.phase = phase
        state.finishedAt = Date()
        state.lastError = error
        if phase == .ready { state.progress = 1 }
        emit(
            phase,
            phase == .ready
                ? "本机环境部署完成，可进入下一步扫码配对 / environment ready, proceed to pairing"
                : "部署结束 / deployment finished: \(error ?? phase.rawValue)",
            level: phase == .ready ? .success : .warning,
            progress: state.progress
        )
        if !skipped.isEmpty {
            emit(phase, "已跳过 / skipped: \(skipped.joined(separator: ", "))", level: .warning)
        }
        job = nil
    }

    private func stepPhase(_ id: String) -> InstallPhase {
        switch id {
        case "brew", "ffmpeg", "uv", "ollama": return .provisioning
        case "llm": return .pullingLLM
        case "workspace": return .preparingWorkspace
        case "weights": return .downloadingWeights
        case "verify": return .verifying
        default: return .detecting
        }
    }

    // MARK: Download

    /// Streams straight to a temporary file and moves it into place, because a
    /// multi-gigabyte BF16 checkpoint must never be resident in memory.
    private func downloadFile(from string: String, to destination: URL) async -> Bool {
        guard let url = URL(string: string) else { return false }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                emit(.downloadingWeights, "HTTP \(http.statusCode) ← \(AppPaths.anonymise(string))", level: .error)
                return false
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            return true
        } catch {
            emit(.downloadingWeights, "传输中断 / transfer error: \(AppPaths.anonymise(error.localizedDescription))", level: .error)
            return false
        }
    }

    /// Chunked SHA-256 so a multi-gigabyte file does not need to be loaded at once.
    static func sha256(ofFileAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = CryptoKitStreamHasher()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            hasher.update(chunk)
            return true
        }) {}
        return hasher.finalHex()
    }
}

// MARK: - Supporting Codable types

/// `config/workspace.json` written by the installer and read by the render engines.
struct HWWorkspaceManifest: Codable, Equatable {
    var workspace: String
    var tier: String
    var videoRef: String
    var videoPrecision: String
    var audioSampleRateHz: Int
    var renderWorkerBudget: Int
    var provisionedAt: Date
    var venv: String
}

struct HWWeightRecord: Codable, Equatable {
    var name: String
    var sha256: String
    var tier: String
}

struct HWWeightManifest: Codable, Equatable {
    var artifacts: [HWWeightRecord]
    var verifiedAt: Date
}

private struct HWOllamaTags: Codable {
    struct Model: Codable { let name: String }
    let models: [Model]
}

// MARK: - Streaming hash helper

/// Thin wrapper over `CryptoKit`'s incremental SHA-256 so the file reader above
/// stays a single loop.
struct CryptoKitStreamHasher {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalHex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var buffer = Data()
    mutating func update(_ data: Data) { buffer.append(data) }
    func finalHex() -> String { Digest.sha256Hex(buffer) }
    #endif
}

extension Digest {
    /// Accepts a checksum the user pasted with spaces, `sha256:` prefixes or odd
    /// casing, and returns `nil` unless it is a plausible 64-hex digest.
    public static func normalized(_ text: String) -> String? {
        var cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if cleaned.hasPrefix("sha256:") { cleaned.removeFirst("sha256:".count) }
        guard cleaned.count == 64 else { return nil }
        return cleaned.allSatisfy { $0.isHexDigit } ? cleaned : nil
    }
}

private extension String {
    /// Last path component with its extension removed, for a staged file name.
    var deletingPathExtensionComponents: String {
        let name = self.split(separator: "/").last.map(String.init) ?? self
        return name.components(separatedBy: "?").first ?? name
    }
}

// MARK: - Fused hardware surface

/// The single collaborator the composition root wires into the console facade.
public actor NodeEnvironment: NodeHardwareProbing {
    private let profiler: HardwareProfiler
    private let installer: EnvironmentInstaller

    public init(profiler: HardwareProfiler = .shared, installer: EnvironmentInstaller = .shared) {
        self.profiler = profiler
        self.installer = installer
    }

    public func profile() async -> MacHardwareProfile {
        await profiler.profile()
    }

    public func plan() async -> ModelPlan {
        ModelPlan.recommend(for: await profiler.profile())
    }

    public func loadSample() async -> SystemLoad {
        await profiler.loadSampleWithWarmup(nanoseconds: 60_000_000)
    }

    public func toolchain() async -> [ToolchainProbe] {
        await profiler.toolchain()
    }

    public func installState() async -> InstallState {
        await installer.current()
    }

    public func startInstall() async {
        await installer.start()
    }

    public func cancelInstall() async {
        await installer.cancel()
    }

    public nonisolated func installEvents() -> AsyncStream<InstallEvent> {
        let installer = self.installer
        return AsyncStream { continuation in
            let task = Task {
                for await event in await installer.subscribe() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot-shaped convenience for the menu bar's status line.
    public func statusLine() async -> String {
        let profile = await profiler.profile()
        let install = await installer.current()
        let installText: String
        switch install.phase {
        case .ready: installText = "环境就绪"
        case .idle: installText = "环境未部署"
        case .failed: installText = "部署未完成"
        default: installText = "部署 \(Int(install.progress * 100))%"
        }
        return "\(profile.shortLabel) · \(installText)"
    }
}

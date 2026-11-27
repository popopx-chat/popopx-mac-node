//
//  GodsEyeViewManager.swift
//  PopopxMacNode — owns the local God's Eye View process and nothing else.
//
//  The manager never installs anything on its own, never retries a crashed process
//  and never starts at boot. Every transition is an owner click in the console, and
//  every transition appends one JSONL row to `logs/godseyeview-audit.jsonl`:
//  verification, clone, start, stop, health, refusal. The rows name paths and
//  references, never a credential value.
//
//  The process seam is a protocol (`GodsEyeRuntime`) so the security-relevant facts —
//  the exact argv, the exact environment, the refusal order — are testable without
//  spawning `node` or binding a socket. The real runtime is the only code here that
//  touches `Process`, `kill` or `URLSession`.
//

import Darwin
import Foundation

// MARK: - Runtime seam

public struct GodsEyeCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var ok: Bool { exitCode == 0 && !timedOut }
    public var firstLine: String {
        (stdout + "\n" + stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

public protocol GodsEyeProcessHandle: Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func forceKill()
}

public enum GodsEyeRuntimeError: Error, CustomStringConvertible {
    case notExecutable(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notExecutable(let path): return "not executable: \(path)"
        case .launchFailed(let detail): return "launch failed: \(detail)"
        }
    }
}

public protocol GodsEyeRuntime: Sendable {
    func which(_ executable: String) -> String?
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> GodsEyeCommandResult
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL?
    ) throws -> any GodsEyeProcessHandle
    /// An HTTP status from the local instance, or nil when nothing answered. Any status
    /// proves a listener; the port is loopback-only by construction, so a response is
    /// already the strongest claim this Mac can make about the process.
    func probe(_ url: URL, timeout: TimeInterval) async -> Int?
}

// MARK: - Real runtime

public final class SystemGodsEyeRuntime: GodsEyeRuntime {
    public init() {}

    public func which(_ executable: String) -> String? { Shell.which(executable) }

    public func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> GodsEyeCommandResult {
        let result = await Shell.runAbsolute(
            launchPath: executable,
            arguments,
            environment: environment,
            timeout: timeout
        )
        return GodsEyeCommandResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut
        )
    }

    public func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL?
    ) throws -> any GodsEyeProcessHandle {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GodsEyeRuntimeError.notExecutable(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        // Exactly the environment the manager built: no ambient token, no proxy and
        // no `NODE_OPTIONS` inherited from however this app was launched.
        process.environment = environment

        var logHandle: FileHandle?
        if let logURL {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: logURL.path
                )
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? logHandle?.close()
            throw GodsEyeRuntimeError.launchFailed(String(describing: error))
        }
        return SystemGodsEyeProcess(process: process, logHandle: logHandle)
    }

    public func probe(_ url: URL, timeout: TimeInterval) async -> Int? {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("close", forHTTPHeaderField: "Connection")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}

final class SystemGodsEyeProcess: GodsEyeProcessHandle, @unchecked Sendable {
    private let process: Process
    private let logHandle: FileHandle?
    private let lock = NSLock()

    init(process: Process, logHandle: FileHandle?) {
        self.process = process
        self.logHandle = logHandle
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceKill() {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    deinit {
        try? logHandle?.close()
    }
}

// MARK: - Manager

public actor GodsEyeViewManager {
    public static let auditFileName = "godseyeview-audit.jsonl"
    public static let nodeCacheSeconds: TimeInterval = 60
    public static let healthCacheSeconds: TimeInterval = 5

    private let runtime: any GodsEyeRuntime
    private let secrets: any HubSecretStoring
    private let auditURL: URL?
    private let logURL: URL?
    private let now: @Sendable () -> Date
    private let startupProbeAttempts: Int
    private let startupProbeInterval: TimeInterval

    private var config: GodsEyeViewConfig
    private var handle: (any GodsEyeProcessHandle)?
    private var startedAt: Date?
    private var lastVerify: GodsEyeInstallVerification?
    private var cachedNode: GodsEyeNodeProbe?
    private var cachedNodeAt: Date?
    private var lastHealthStatus: Int?
    private var lastHealthAt: Date?
    private var healthTaskRunning = false
    private var lastError = ""

    public init(
        config: GodsEyeViewConfig = .disabled,
        secrets: any HubSecretStoring,
        runtime: any GodsEyeRuntime = SystemGodsEyeRuntime(),
        auditURL: URL? = AppPaths.godsEyeAuditFile,
        logURL: URL? = AppPaths.godsEyeLogFile,
        now: @escaping @Sendable () -> Date = { Date() },
        startupProbeAttempts: Int = 8,
        startupProbeInterval: TimeInterval = 0.5
    ) {
        self.config = config.normalised
        self.secrets = secrets
        self.runtime = runtime
        self.auditURL = auditURL
        self.logURL = logURL
        self.now = now
        self.startupProbeAttempts = max(0, startupProbeAttempts)
        self.startupProbeInterval = max(0, startupProbeInterval)
    }

    // MARK: Configuration

    public var currentConfig: GodsEyeViewConfig { config }

    /// The bridge calls this after it has stopped a running process. Clearing the
    /// verification cache is load-bearing: a path or version edit must invalidate
    /// what was proven about the *previous* directory.
    public func update(config next: GodsEyeViewConfig) {
        let cleaned = next.normalised
        if cleaned.installPath != config.installPath || cleaned.pinnedVersion != config.pinnedVersion {
            lastVerify = nil
        }
        if cleaned.nodePath != config.nodePath { cachedNode = nil; cachedNodeAt = nil }
        if cleaned.port != config.port { lastHealthStatus = nil; lastHealthAt = nil }
        config = cleaned
    }

    public func isRunning() -> Bool {
        reconcileExit()
        return handle?.isRunning ?? false
    }

    public func lastVerification() -> GodsEyeInstallVerification? { lastVerify }

    /// One row the coordinator contributes to the same JSONL audit: MCP registration,
    /// tool sync and credential-slot edits are decisions taken over the same process
    /// and belong in one chronology, not two.
    public func auditNote(_ action: String, _ outcome: String, _ detail: String) {
        audit(action, outcome, detail)
    }

    // MARK: Snapshot

    /// Never waits on the health probe. A poll answers from the last measurement and
    /// starts one background check when it is stale; the card's own 「检查」 button is
    /// the path that waits.
    public func snapshot() async -> GodsEyeViewSnapshot {
        reconcileExit()
        let node = await nodeProbe(force: false)
        scheduleHealthProbeIfNeeded()
        let running = handle?.isRunning ?? false
        let verification = lastVerify
        let credentials = GodsEyeDataSource.allCases.map { source -> GodsEyeCredentialRow in
            let slot = config.slot(source)
            let stored = HubSecrets.isSafeReference(slot.reference) && secrets.secret(for: slot.reference) != nil
            return GodsEyeCredentialRow(
                id: source.rawValue,
                environmentName: source.environmentName,
                enabled: slot.enabled,
                stored: stored,
                display: stored ? "已存入钥匙串 / stored" : (slot.enabled ? "已启用但未存入 / enabled, no value" : "未启用 / off")
            )
        }
        return GodsEyeViewSnapshot(
            enabled: config.enabled,
            usable: config.enabled && node.ok && (verification?.ok ?? false),
            mode: config.mode.rawValue,
            installPath: config.installPath.isEmpty ? "" : AppPaths.anonymise(config.installPath),
            pinnedVersion: config.pinnedVersion,
            installedVersion: verification?.version ?? "",
            installVerified: verification?.ok ?? false,
            installDetail: verification?.detail ?? "",
            verifiedAt: verification?.verifiedAt,
            nodePath: node.path.isEmpty ? "" : AppPaths.anonymise(node.path),
            nodeVersion: node.version,
            nodeMajor: node.major,
            nodeOK: node.ok,
            nodeDetail: node.detail,
            port: config.port,
            bindHost: GodsEyeViewPolicy.bindHost,
            running: running,
            pid: running ? handle?.pid : nil,
            startedAt: running ? startedAt : nil,
            healthStatus: lastHealthStatus,
            lastHealthAt: lastHealthAt,
            lastError: lastError,
            mcpRegistered: false,
            mcpTools: [],
            sourcePullAllowed: config.allowSourcePull,
            sourcePullReady: config.sourcePullReady,
            boundary: GodsEyeViewPolicy.boundaryStatement,
            dataPolicy: GodsEyeViewPolicy.dataSourceStatement,
            credentials: credentials
        )
    }

    // MARK: Node.js

    public func nodeProbe(force: Bool) async -> GodsEyeNodeProbe {
        if !force, let cachedNode, let cachedNodeAt,
           now().timeIntervalSince(cachedNodeAt) < Self.nodeCacheSeconds {
            return cachedNode
        }
        var path = ""
        if !config.nodePath.isEmpty {
            guard config.nodePath.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: config.nodePath) else {
                let probe = GodsEyeNodeProbe(
                    detail: "配置的 Node.js 不是可执行绝对路径 / the configured Node.js is not an executable absolute path"
                )
                cachedNode = probe
                cachedNodeAt = now()
                return probe
            }
            path = config.nodePath
        } else if let found = runtime.which("node") {
            path = found
        }
        guard !path.isEmpty else {
            cachedNode = .missing
            cachedNodeAt = now()
            return .missing
        }
        let result = await runtime.run(
            path, arguments: ["--version"], environment: [:], timeout: 5
        )
        let version = result.firstLine
        let major = GodsEyeViewPolicy.nodeMajor(version) ?? 0
        let ok = result.ok && major >= GodsEyeViewPolicy.minimumNodeMajor
        let detail: String
        if !result.ok {
            detail = "无法读取 Node.js 版本 / could not read the Node.js version: \(version)"
        } else if major < GodsEyeViewPolicy.minimumNodeMajor {
            detail = "Node.js \(version) 过旧，需要 \(GodsEyeViewPolicy.minimumNodeMajor)+ / Node.js is too old"
        } else {
            detail = "Node.js \(version) ✓"
        }
        let probe = GodsEyeNodeProbe(
            ok: ok, path: path, version: version, major: major, detail: detail
        )
        cachedNode = probe
        cachedNodeAt = now()
        return probe
    }

    // MARK: Verification and installation

    @discardableResult
    public func verify() async -> GodsEyeActionResult {
        guard let url = GodsEyeViewPolicy.resolveInstallPath(config.installPath) else {
            let detail = config.installPath.isEmpty
                ? "尚未填写安装目录 / no install directory is set"
                : "安装目录不安全或不是绝对路径 / the install path is not an admitted absolute path"
            lastVerify = .refused(detail)
            audit("verify", "refused", detail)
            return .failure(detail)
        }
        let result = GodsEyeViewPolicy.verifyInstall(at: url, expectedVersion: config.pinnedVersion)
        lastVerify = result
        lastError = result.ok ? "" : result.detail
        audit("verify", result.ok ? "ok" : "refused", result.detail)
        return GodsEyeActionResult(ok: result.ok, detail: result.detail)
    }

    /// The one-click install. `existing` only verifies. `pinnedSource` clones exactly
    /// one commit into an empty target and is refused unless the owner switched the
    /// network pull on.
    @discardableResult
    public func install() async -> GodsEyeActionResult {
        guard let destination = GodsEyeViewPolicy.resolveInstallPath(config.installPath) else {
            let detail = "安装目录不安全或不是绝对路径 / the install path is not an admitted absolute path"
            audit("install", "refused", detail)
            return .failure(detail)
        }
        if config.mode == .existing {
            let verified = await verify()
            return GodsEyeActionResult(
                ok: verified.ok,
                detail: verified.ok ? "existing 模式只校验，不拉取 / verified an existing install; nothing was fetched" : verified.detail
            )
        }
        guard config.allowSourcePull else {
            let detail = "「允许拉取源码」未开启；本节点不会自行联网 / source pull is off; the node never dials on its own"
            audit("install", "refused", detail)
            return .failure(detail)
        }
        guard GodsEyeViewPolicy.isHTTPSource(config.repositoryURL) else {
            let detail = "源码仓库需为不含凭据的 https URL / the source repository must be an https URL without credentials"
            audit("install", "refused", detail)
            return .failure(detail)
        }
        guard !config.pinnedRef.isEmpty, GodsEyeViewPolicy.isCommit(config.pinnedCommit) else {
            let detail = "需要固定的 tag/branch 与 40 位 commit / a pinned ref and a 40-hex commit are both required"
            audit("install", "refused", detail)
            return .failure(detail)
        }
        guard let git = runtime.which("git") else {
            let detail = "未找到 git / git was not found"
            audit("install", "refused", detail)
            return .failure(detail)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let existing = GodsEyeViewPolicy.verifyInstall(at: destination, expectedVersion: config.pinnedVersion)
                if existing.ok {
                    lastVerify = existing
                    audit("install", "ok", "already installed \(existing.version)")
                    return GodsEyeActionResult(ok: true, detail: "该目录已是固定版本 / the pinned version is already installed")
                }
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
                guard contents.isEmpty else {
                    let detail = "目标目录非空且不是该固定版本，拒绝覆盖 / the target is not empty and is not the pinned version; refusing to overwrite"
                    audit("install", "refused", detail)
                    return .failure(detail)
                }
            } else {
                let detail = "目标路径是一个文件 / the target path is a file"
                audit("install", "refused", detail)
                return .failure(detail)
            }
        }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".godseyeview-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let clone = await runtime.run(
                git,
                arguments: [
                    "clone", "--depth", "1", "--branch", config.pinnedRef,
                    "--single-branch", "--", config.repositoryURL, staging.path
                ],
                environment: [:],
                timeout: 300
            )
            guard clone.ok else {
                let detail = clone.timedOut
                    ? "git clone 超时 / git clone timed out"
                    : "git clone 失败 / git clone failed: \(clone.firstLine)"
                audit("install", "failed", detail)
                try? FileManager.default.removeItem(at: staging)
                return .failure(detail)
            }
            let head = await runtime.run(
                git, arguments: ["-C", staging.path, "rev-parse", "HEAD"],
                environment: [:], timeout: 30
            )
            let resolved = head.firstLine.lowercased()
            guard head.ok, resolved == config.pinnedCommit else {
                let detail = "HEAD 与固定 commit 不符 / HEAD is \(resolved.isEmpty ? "unknown" : resolved), expected \(config.pinnedCommit)"
                audit("install", "refused", detail)
                try? FileManager.default.removeItem(at: staging)
                return .failure(detail)
            }
            let staged = GodsEyeViewPolicy.verifyInstall(at: staging, expectedVersion: config.pinnedVersion)
            guard staged.ok else {
                audit("install", "refused", staged.detail)
                try? FileManager.default.removeItem(at: staging)
                return .failure(staged.detail)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination) // proven empty above
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            let detail = String(describing: error)
            audit("install", "failed", detail)
            return .failure(detail)
        }
        let final = GodsEyeViewPolicy.verifyInstall(at: destination, expectedVersion: config.pinnedVersion)
        lastVerify = final
        lastError = final.ok ? "" : final.detail
        audit("install", final.ok ? "ok" : "refused",
              "\(GodsEyeViewPolicy.sourceHost(config.repositoryURL)) @ \(config.pinnedCommit.prefix(12)) · \(final.detail)")
        return GodsEyeActionResult(ok: final.ok, detail: final.detail)
    }

    // MARK: Process

    @discardableResult
    public func start() async -> GodsEyeActionResult {
        guard config.enabled else {
            return .failure("全球情报地图未启用 / God's Eye View is off")
        }
        reconcileExit()
        if handle?.isRunning == true {
            return GodsEyeActionResult(ok: true, detail: "已在运行 / already running")
        }
        let node = await nodeProbe(force: true)
        guard node.ok else {
            lastError = node.detail
            audit("start", "refused", node.detail)
            return .failure(node.detail)
        }
        let verified = await verify()
        guard verified.ok, let verification = lastVerify, verification.ok else {
            audit("start", "refused", verified.detail)
            return .failure(verified.detail)
        }
        guard let healthURL = GodsEyeViewPolicy.healthURL(port: config.port) else {
            let detail = "端口无效 / the port is not valid"
            audit("start", "refused", detail)
            return .failure(detail)
        }
        var resolvedSecrets: [GodsEyeDataSource: String] = [:]
        for source in config.enabledSources {
            let slot = config.slot(source)
            guard HubSecrets.isSafeReference(slot.reference),
                  let value = secrets.secret(for: slot.reference), !value.isEmpty else {
                let detail = "数据源 \(source.rawValue) 已启用但钥匙串无值 / \(source.environmentName) is enabled but has no Keychain value"
                lastError = detail
                audit("start", "refused", detail)
                return .failure(detail)
            }
            resolvedSecrets[source] = value
        }
        // Refuse a port that already answers: reporting somebody else's service as this
        // process would make every later health check a lie.
        if await runtime.probe(healthURL, timeout: 0.6) != nil {
            let detail = "端口 \(config.port) 已有服务响应 / port \(config.port) already answers"
            lastError = detail
            audit("start", "refused", detail)
            return .failure(detail)
        }
        let environment = GodsEyeViewPolicy.launchEnvironment(
            host: Shell.augmentedEnvironment, secrets: resolvedSecrets
        )
        let arguments = GodsEyeViewPolicy.launchArguments(entryPath: verification.entryPath, port: config.port)
        do {
            let launched = try runtime.launch(
                executable: node.path,
                arguments: arguments,
                environment: environment,
                workingDirectory: URL(fileURLWithPath: verification.path, isDirectory: true),
                logURL: logURL
            )
            handle = launched
            startedAt = now()
            lastError = ""
            lastHealthStatus = nil
            lastHealthAt = nil
            audit("start", "ok", "pid \(launched.pid) · 127.0.0.1:\(config.port)")
            if startupProbeAttempts > 0 {
                for _ in 0..<startupProbeAttempts {
                    if !launched.isRunning {
                        let detail = "进程启动后立即退出 / the process exited during startup"
                        lastError = detail
                        handle = nil
                        startedAt = nil
                        audit("exit", "failed", detail)
                        return .failure(detail)
                    }
                    if let status = await runtime.probe(healthURL, timeout: 1) {
                        lastHealthStatus = status
                        lastHealthAt = now()
                        audit("health", "ok", "HTTP \(status) · 127.0.0.1:\(config.port)")
                        return GodsEyeActionResult(ok: true, detail: "已启动并在 127.0.0.1:\(config.port) 响应 / running")
                    }
                    if startupProbeInterval > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(startupProbeInterval * 1_000_000_000))
                    }
                }
            }
            return GodsEyeActionResult(
                ok: true,
                detail: "进程已启动，本地端口尚未响应 / started; the local port has not answered yet"
            )
        } catch {
            let detail = String(describing: error)
            lastError = detail
            audit("start", "failed", detail)
            return .failure(detail)
        }
    }

    @discardableResult
    public func stop() async -> GodsEyeActionResult {
        reconcileExit()
        guard let running = handle else {
            startedAt = nil
            lastHealthStatus = nil
            lastHealthAt = nil
            return GodsEyeActionResult(ok: true, detail: "未在运行 / not running")
        }
        running.terminate()
        var waited = 0
        while running.isRunning && waited < 20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            waited += 1
        }
        let forced = running.isRunning
        if forced { running.forceKill() }
        handle = nil
        startedAt = nil
        lastHealthStatus = nil
        lastHealthAt = nil
        lastError = ""
        audit("stop", forced ? "forced" : "ok", forced ? "SIGKILL after SIGTERM" : "SIGTERM")
        return GodsEyeActionResult(ok: true, detail: forced ? "已强制停止 / stopped (SIGKILL)" : "已停止 / stopped")
    }

    /// The 「检查」 button. Waits for one probe and records it.
    @discardableResult
    public func checkHealth() async -> GodsEyeActionResult {
        reconcileExit()
        guard handle?.isRunning == true else {
            lastHealthStatus = nil
            lastHealthAt = now()
            return GodsEyeActionResult(ok: false, detail: "进程未运行 / the process is not running")
        }
        guard let url = GodsEyeViewPolicy.healthURL(port: config.port) else {
            return .failure("端口无效 / the port is not valid")
        }
        let status = await runtime.probe(url, timeout: 2)
        lastHealthStatus = status
        lastHealthAt = now()
        audit("health", status == nil ? "failed" : "ok", status.map { "HTTP \($0)" } ?? "no answer on 127.0.0.1:\(config.port)")
        return GodsEyeActionResult(
            ok: status != nil,
            detail: status.map { "127.0.0.1:\(config.port) 返回 HTTP \($0) / answered" }
                ?? "127.0.0.1:\(config.port) 未响应 / no answer"
        )
    }

    // MARK: Internals

    private func scheduleHealthProbeIfNeeded() {
        guard handle?.isRunning == true, !healthTaskRunning else { return }
        if let lastHealthAt, now().timeIntervalSince(lastHealthAt) < Self.healthCacheSeconds { return }
        healthTaskRunning = true
        Task { [weak self] in
            await self?.runScheduledHealthProbe()
        }
    }

    private func runScheduledHealthProbe() async {
        defer { healthTaskRunning = false }
        reconcileExit()
        guard handle?.isRunning == true,
              let url = GodsEyeViewPolicy.healthURL(port: config.port) else { return }
        let status = await runtime.probe(url, timeout: 1.5)
        guard handle?.isRunning == true else { return }
        lastHealthStatus = status
        lastHealthAt = now()
    }

    private func reconcileExit() {
        guard let running = handle, !running.isRunning else { return }
        handle = nil
        startedAt = nil
        lastHealthStatus = nil
        lastHealthAt = nil
        lastError = "进程已退出 / the local process exited"
        audit("exit", "failed", lastError)
    }

    private func audit(_ action: String, _ outcome: String, _ detail: String) {
        guard let auditURL else { return }
        let row = GodsEyeAuditRow(
            at: now().ppxISO8601,
            action: action,
            outcome: outcome,
            detail: AppPaths.anonymise(detail)
        )
        do {
            try FileManager.default.createDirectory(
                at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let data = NodeJSON.encodeLine(row) else { return }
            if !FileManager.default.fileExists(atPath: auditURL.path) {
                FileManager.default.createFile(atPath: auditURL.path, contents: nil)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: auditURL.path
                )
            }
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            // Auditing is best-effort by design; a full disk must not turn a refused
            // start into a crash. The console's own lastError still carries the reason.
        }
    }
}

struct GodsEyeAuditRow: Codable, Sendable, Equatable {
    var at: String
    var action: String
    var outcome: String
    var detail: String
}
//
//  SystemWatchdog.swift
//  PopopxMacNode — login autostart, liveness checks and a bounded self-healer.
//
//  Three rules shape this file:
//
//    * the LaunchAgent is generated from typed fields, never from a template a
//      caller can add an argument to. The only arguments written are the fixed
//      loopback binding pair, so an edit to this file is the only way the
//      autostarted node could bind elsewhere;
//    * a restart is exponential and capped, and every probe is low-frequency —
//      a disk/memory check every minute is a diagnostic, not a busy loop;
//    * phone cards are deduplicated by target + reason for 30 minutes. A disk
//      that stays full must not send 1,440 cards a day.
//
//  The watchdog cannot resurrect its own process. It restarts the pieces it can
//  reach (`popopx-cli`) and reports the ones it cannot (the model server, disk,
//  memory) rather than pretending a card is a repair.
//

import Darwin
import Foundation

// MARK: - Models

public enum WatchdogTarget: String, Codable, Sendable, CaseIterable {
    case daemon = "popopx_cli"
    case localModel = "local_model"
    case disk
    case memory

    public var labelZh: String {
        switch self {
        case .daemon: return "本机 daemon"
        case .localModel: return "本地推理服务"
        case .disk: return "磁盘空间"
        case .memory: return "内存压力"
        }
    }
}

public struct WatchdogSample: Sendable, Equatable {
    public var target: WatchdogTarget
    public var state: DoctorCheckState
    public var detail: String
    public var restartable: Bool

    public init(target: WatchdogTarget, state: DoctorCheckState, detail: String, restartable: Bool = false) {
        self.target = target
        self.state = state
        self.detail = detail
        self.restartable = restartable
    }
}

public struct WatchdogProbe: Sendable {
    public var target: WatchdogTarget
    public var run: @Sendable () async -> WatchdogSample
    public init(target: WatchdogTarget, run: @escaping @Sendable () async -> WatchdogSample) {
        self.target = target
        self.run = run
    }
}

public struct WatchdogAlert: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var target: WatchdogTarget
    public var state: DoctorCheckState
    public var detail: String
    public var at: Date
    public var delivered: Bool

    public init(
        id: String = UUID().uuidString,
        target: WatchdogTarget,
        state: DoctorCheckState,
        detail: String,
        at: Date,
        delivered: Bool
    ) {
        self.target = target
        self.state = state
        self.detail = detail
        self.at = at
        self.delivered = delivered
        self.id = id
    }
}

public struct SystemWatchdogCard: Codable, Sendable, Equatable {
    public var installed: Bool
    public var plistPath: String
    public var checks: [DoctorCheck]
    public var restartCount: Int
    public var lastCheckAt: Date?
    public var lastAlertAt: Date?
    public var pendingRestartAt: Date?
    public var lastDetail: String
    public var boundary: String

    public init(
        installed: Bool = false,
        plistPath: String = "",
        checks: [DoctorCheck] = [],
        restartCount: Int = 0,
        lastCheckAt: Date? = nil,
        lastAlertAt: Date? = nil,
        pendingRestartAt: Date? = nil,
        lastDetail: String = "",
        boundary: String = "固定回环参数 · 退避重启 · 30 分钟去重 / fixed loopback argv · exponential restarts · 30-minute dedupe"
    ) {
        self.installed = installed
        self.plistPath = plistPath
        self.checks = checks
        self.restartCount = restartCount
        self.lastCheckAt = lastCheckAt
        self.lastAlertAt = lastAlertAt
        self.pendingRestartAt = pendingRestartAt
        self.lastDetail = lastDetail
        self.boundary = boundary
    }

    public static let disabled = SystemWatchdogCard()
}

public struct WatchdogControlReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var outcome: String
    public var detail: String
    public var watchdog: SystemWatchdogCard

    public init(ok: Bool, outcome: String, detail: String, watchdog: SystemWatchdogCard) {
        self.ok = ok
        self.outcome = outcome
        self.detail = detail
        self.watchdog = watchdog
    }
}

public struct WatchdogCheckReport: Codable, Sendable, Equatable {
    public var checked: Bool
    public var alerts: [WatchdogAlert]
    public var watchdog: SystemWatchdogCard

    public init(checked: Bool, alerts: [WatchdogAlert], watchdog: SystemWatchdogCard) {
        self.checked = checked
        self.alerts = alerts
        self.watchdog = watchdog
    }
}

// MARK: - LaunchAgent

public enum LaunchAgentSpec {
    public static let label = "chat.popopx.mac-node"
    public static let consoleHost = "127.0.0.1"
    public static let consolePort = Int(NodeWire.consolePort)

    /// The argv is fixed here. Tests compare this exact array, which is why a
    /// future caller cannot pass a host through an "options" dictionary.
    public static func programArguments(executablePath: String) -> [String] {
        [executablePath, "--loopback-only", "--console-host", consoleHost, "--console-port", "\(consolePort)"]
    }

    public static func plist(
        executablePath: String,
        stdoutPath: String,
        stderrPath: String
    ) -> String {
        let arguments = programArguments(executablePath: executablePath)
            .map { "        <string>\(xml($0))</string>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(arguments)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>30</integer>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(xml(stdoutPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xml(stderrPath))</string>
        </dict>
        </plist>
        """
    }

    static func xml(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Watchdog

public actor SystemWatchdog {
    public typealias Restart = @Sendable (String) async -> Bool
    public typealias Delivery = @Sendable (CommandResult) async -> Bool

    public static let minimumCheckInterval: TimeInterval = 60
    public static let alertCooldown: TimeInterval = 30 * 60
    public static let restartBase: TimeInterval = 30
    public static let restartCeiling: TimeInterval = 30 * 60

    private let plistURL: URL
    private let executablePath: String
    private let probes: [WatchdogProbe]
    private let restart: Restart
    private let deliver: Delivery
    private let auditURL: URL
    private let fileManager: FileManager

    private var lastCheckAt: Date?
    private var lastAlertAt: Date?
    private var lastDetail = ""
    private var restartCount = 0
    private var checks: [DoctorCheck] = []
    private var alertTimes: [String: Date] = [:]
    private var attempts: [WatchdogTarget: Int] = [:]
    private var nextRestartAt: [WatchdogTarget: Date] = [:]

    public init(
        plistURL: URL = AppPaths.launchAgentFile,
        executablePath: String,
        probes: [WatchdogProbe],
        restart: @escaping Restart,
        deliver: @escaping Delivery,
        auditURL: URL = AppPaths.watchdogAuditFile,
        fileManager: FileManager = .default
    ) {
        self.plistURL = plistURL
        self.executablePath = executablePath
        self.probes = probes
        self.restart = restart
        self.deliver = deliver
        self.auditURL = auditURL
        self.fileManager = fileManager
    }

    // MARK: Install

    public func install(now: Date = Date()) -> WatchdogControlReport {
        guard executablePath.hasPrefix("/"), !executablePath.contains("\n") else {
            return WatchdogControlReport(
                ok: false,
                outcome: "refused",
                detail: "可执行文件路径无效 / invalid executable path",
                watchdog: card()
            )
        }
        do {
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
            let text = LaunchAgentSpec.plist(
                executablePath: executablePath,
                stdoutPath: AppPaths.logs.appendingPathComponent("watchdog.out.log").path,
                stderrPath: AppPaths.logs.appendingPathComponent("watchdog.err.log").path
            )
            guard let data = text.data(using: .utf8),
                  (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) is [String: Any]
            else {
                return WatchdogControlReport(
                    ok: false,
                    outcome: "refused",
                    detail: "生成的 plist 无法解析 / generated plist is not parseable",
                    watchdog: card()
                )
            }
            try data.write(to: plistURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            appendAudit(event: "installed", detail: "LaunchAgent \(LaunchAgentSpec.label)", at: now)
            lastDetail = "已写入登录项；下次登录生效 / written; active at next login"
            return WatchdogControlReport(ok: true, outcome: "installed", detail: lastDetail, watchdog: card())
        } catch {
            appendAudit(event: "install_failed", detail: error.localizedDescription, at: now)
            return WatchdogControlReport(
                ok: false,
                outcome: "failed",
                detail: "写入 LaunchAgent 失败 / could not write the LaunchAgent",
                watchdog: card()
            )
        }
    }

    public func uninstall(now: Date = Date()) -> WatchdogControlReport {
        do {
            if fileManager.fileExists(atPath: plistURL.path) {
                try fileManager.removeItem(at: plistURL)
            }
            appendAudit(event: "uninstalled", detail: "LaunchAgent removed", at: now)
            lastDetail = "已移除登录项 / login item removed"
            return WatchdogControlReport(ok: true, outcome: "uninstalled", detail: lastDetail, watchdog: card())
        } catch {
            appendAudit(event: "uninstall_failed", detail: error.localizedDescription, at: now)
            return WatchdogControlReport(
                ok: false,
                outcome: "failed",
                detail: "移除 LaunchAgent 失败 / could not remove the LaunchAgent",
                watchdog: card()
            )
        }
    }

    // MARK: Checks

    /// Called from the console's minute tick. It refuses to run more often than
    /// once a minute; `force` is for the owner's button, not for polling.
    public func check(now: Date = Date(), force: Bool = false) async -> WatchdogCheckReport {
        if !force, let lastCheckAt, now.timeIntervalSince(lastCheckAt) < Self.minimumCheckInterval {
            return WatchdogCheckReport(checked: false, alerts: [], watchdog: card())
        }
        lastCheckAt = now
        var rows: [DoctorCheck] = []
        var alerts: [WatchdogAlert] = []
        for probe in probes {
            let sample = await probe.run()
            rows.append(DoctorCheck(
                id: sample.target.rawValue,
                title: sample.target.labelZh,
                state: sample.state,
                detail: LiveIntegrationDoctor.sanitize(sample.detail)
            ))
            if sample.state == .failed && sample.restartable {
                let outcome = await restartIfDue(sample, now: now)
                if let detail = outcome {
                    rows[rows.count - 1].detail = LiveIntegrationDoctor.sanitize(detail)
                }
            }
            if sample.state == .failed || sample.state == .warning {
                if let alert = makeAlert(sample, now: now) {
                    let delivered = await deliverAlert(alert)
                    var value = alert
                    value.delivered = delivered
                    alerts.append(value)
                }
            } else {
                attempts[sample.target] = 0
                nextRestartAt[sample.target] = nil
            }
        }
        checks = rows
        lastDetail = rows.first(where: { $0.state == .failed || $0.state == .warning })?.detail ?? "全部正常 / all checks healthy"
        if !alerts.isEmpty { lastAlertAt = alerts.first?.at ?? now }
        appendAudit(
            event: "checked",
            detail: rows.map { "\($0.id)=\($0.state.rawValue)" }.joined(separator: " "),
            at: now
        )
        return WatchdogCheckReport(checked: true, alerts: alerts, watchdog: card())
    }

    public func card() -> SystemWatchdogCard {
        SystemWatchdogCard(
            installed: fileManager.fileExists(atPath: plistURL.path),
            plistPath: plistURL.path,
            checks: checks,
            restartCount: restartCount,
            lastCheckAt: lastCheckAt,
            lastAlertAt: lastAlertAt,
            pendingRestartAt: nextRestartAt.values.min(),
            lastDetail: lastDetail
        )
    }

    // MARK: Restart and alerts

    private func restartIfDue(_ sample: WatchdogSample, now: Date) async -> String? {
        guard sample.state == .failed, sample.restartable else { return nil }
        if let due = nextRestartAt[sample.target], now < due {
            return "\(sample.detail) · 退避至 \(PrivacyStamp.iso(due)) / backing off until \(PrivacyStamp.iso(due))"
        }
        let ok = await restart(sample.target.rawValue)
        restartCount += 1
        let attempt = (attempts[sample.target] ?? 0) + 1
        attempts[sample.target] = attempt
        if ok {
            attempts[sample.target] = 0
            nextRestartAt[sample.target] = nil
            appendAudit(event: "restarted", detail: sample.target.rawValue, at: now)
            return "已重新拉起 \(sample.target.rawValue) / restarted \(sample.target.rawValue)"
        }
        let delay = min(Self.restartCeiling, Self.restartBase * pow(2, Double(min(attempt - 1, 8))))
        nextRestartAt[sample.target] = now.addingTimeInterval(delay)
        appendAudit(
            event: "restart_failed",
            detail: "\(sample.target.rawValue) · attempt \(attempt) · next \(Int(delay))s",
            at: now
        )
        return "\(sample.detail) · 第 \(attempt) 次拉起失败，退避 \(Int(delay)) 秒 / restart \(attempt) failed, backing off \(Int(delay))s"
    }

    private func makeAlert(_ sample: WatchdogSample, now: Date) -> WatchdogAlert? {
        let key = "\(sample.target.rawValue)|\(sample.state.rawValue)"
        if let last = alertTimes[key], now.timeIntervalSince(last) < Self.alertCooldown {
            return nil
        }
        alertTimes[key] = now
        appendAudit(event: "alert", detail: "\(key) · \(sample.detail)", at: now)
        return WatchdogAlert(
            target: sample.target,
            state: sample.state,
            detail: LiveIntegrationDoctor.sanitize(sample.detail),
            at: now,
            delivered: false
        )
    }

    private func deliverAlert(_ alert: WatchdogAlert) async -> Bool {
        let result = CommandResult(
            engine: .shadowCos,
            ok: alert.state == .warning,
            deterministic: true,
            headline: "系统看门狗 · \(alert.target.labelZh) · \(alert.state.labelZh)",
            body: """
            \(alert.detail)
            时间：\(PrivacyStamp.iso(alert.at))
            处理：控制台「系统看门狗」可查看全部检查并关闭登录自启。
            """,
            at: alert.at,
            metrics: [
                "watchdog": .bool(true),
                "target": .string(alert.target.rawValue),
                "state": .string(alert.state.rawValue)
            ],
            cardLabel: "POPOPX 系统看门狗 / System Watchdog"
        )
        return await deliver(result)
    }

    private func appendAudit(event: String, detail: String, at: Date) {
        let clean = LiveIntegrationDoctor.sanitize(detail)
        let line = "{\"at\":\"\(PrivacyStamp.iso(at))\",\"event\":\"\(jsonEscaped(event))\",\"detail\":\"\(jsonEscaped(clean))\"}\n"
        do {
            try fileManager.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: auditURL.path) {
                fileManager.createFile(atPath: auditURL.path, contents: nil)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
            }
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // An audit write failure must not stop the watchdog from checking;
            // the console card still carries the latest state.
        }
    }

    private func jsonEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - Production probes

public extension SystemWatchdog {
    static func diskProbe(
        path: URL = AppPaths.root,
        warningBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        failedBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    ) -> WatchdogProbe {
        WatchdogProbe(target: .disk) {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
            guard let values = try? path.resourceValues(forKeys: keys) else {
                return WatchdogSample(target: .disk, state: .warning, detail: "无法读取磁盘容量 / capacity unavailable")
            }
            let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeTotalCapacity ?? 0)
            let gb = Double(free) / 1_073_741_824
            let state: DoctorCheckState = free < failedBytes ? .failed : (free < warningBytes ? .warning : .ok)
            return WatchdogSample(
                target: .disk,
                state: state,
                detail: String(format: "可用 %.2f GB / %.2f GB free", gb, gb)
            )
        }
    }

    static func memoryProbe() -> WatchdogProbe {
        WatchdogProbe(target: .memory) {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                return WatchdogSample(target: .memory, state: .warning, detail: "无法读取内存统计 / memory statistics unavailable")
            }
            let page = Double(vm_kernel_page_size)
            let freePages = Double(stats.free_count + stats.inactive_count + stats.speculative_count)
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            let free = freePages * page
            let ratio = total > 0 ? free / total : 0
            let state: DoctorCheckState = ratio < 0.05 ? .failed : (ratio < 0.10 ? .warning : .ok)
            return WatchdogSample(
                target: .memory,
                state: state,
                detail: String(format: "可用 %.1f%% / %.1f%% free", ratio * 100, ratio * 100)
            )
        }
    }

    static func daemonProbe(_ signaling: any NodeSignaling) -> WatchdogProbe {
        WatchdogProbe(target: .daemon) {
            let status = await signaling.status()
            guard status.daemon.isLive else {
                return WatchdogSample(
                    target: .daemon,
                    state: .failed,
                    detail: "daemon \(status.daemon.rawValue) · \(status.lastError ?? "no detail")",
                    restartable: status.binaryPath != nil
                )
            }
            return WatchdogSample(
                target: .daemon,
                state: .ok,
                detail: "\(status.daemon.rawValue) · outbox \(status.outboxDepth)"
            )
        }
    }

    static func localModelProbe(_ adapter: Inkling2MiniAdapter?) -> WatchdogProbe {
        localModelProbe { adapter }
    }

    /// The console rebuilds the assistant adapter on a settings save; a provider
    /// keeps the watchdog's check row reading the adapter that is live *now*
    /// instead of pinning the one that existed when the actor was built.
    static func localModelProbe(
        provider: @escaping @Sendable () async -> Inkling2MiniAdapter?
    ) -> WatchdogProbe {
        WatchdogProbe(target: .localModel) {
            guard let adapter = await provider() else {
                return WatchdogSample(target: .localModel, state: .ok, detail: "轻量模式，未装配模型 / lightweight mode")
            }
            let card = await adapter.probe()
            switch card.state {
            case .ready:
                return WatchdogSample(target: .localModel, state: .ok, detail: "\(card.runtime) · \(card.model)")
            case .runtimeMissing, .modelMissing:
                return WatchdogSample(
                    target: .localModel,
                    state: .warning,
                    detail: "\(card.state.rawValue)；规则与确定性功能继续运行 / deterministic features keep running"
                )
            case .refused:
                return WatchdogSample(target: .localModel, state: .warning, detail: card.lastDetail)
            case .off, .unknown:
                return WatchdogSample(target: .localModel, state: .ok, detail: "未启用 / off")
            }
        }
    }
}
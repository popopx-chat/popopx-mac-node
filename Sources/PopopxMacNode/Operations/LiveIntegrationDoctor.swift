//
//  LiveIntegrationDoctor.swift
//  PopopxMacNode — one owner click that proves the local seams are real.
//
//  A check is a closure so every dependency (Keychain, daemon, mail, LAN) can be
//  exercised without this file importing a concrete transport. The engine adds
//  the rules that must hold for *every* probe:
//
//    * details are redacted, newline-collapsed and capped before they reach a
//      page or a log — a server's error text is exactly where a credential or a
//      message subject would otherwise appear;
//    * checks run one at a time, so a mail handshake cannot overlap a Keychain
//      write and make the timing unreadable;
//    * a probe that throws becomes a failed row, never a missing row, because a
//      doctor that silently drops what it could not test is worse than no doctor.
//
//  Nothing here writes mail, fetches message bodies or talks to a host that is
//  not already allowed by the owning subsystem's boundary.
//

import Foundation

// MARK: - Models

public enum DoctorCheckState: String, Codable, Sendable, CaseIterable {
    case ok
    case warning
    case failed
    case skipped

    public var labelZh: String {
        switch self {
        case .ok: return "正常"
        case .warning: return "注意"
        case .failed: return "失败"
        case .skipped: return "未启用"
        }
    }

    public var labelEn: String {
        rawValue
    }
}

public struct DoctorCheck: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var state: DoctorCheckState
    public var detail: String
    public var durationMS: Int

    public init(id: String, title: String, state: DoctorCheckState, detail: String, durationMS: Int = 0) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.durationMS = durationMS
    }
}

public struct LiveIntegrationReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var headline: String
    public var checks: [DoctorCheck]
    public var startedAt: Date
    public var durationMS: Int
    public var boundary: String

    public init(
        ok: Bool = false,
        headline: String = "",
        checks: [DoctorCheck] = [],
        startedAt: Date = Date(),
        durationMS: Int = 0,
        boundary: String = "仅 127.0.0.1 与已配置的出站账号 · 不读取邮件正文 · 输出已脱敏 / loopback and configured accounts only · no message bodies · redacted output"
    ) {
        self.ok = ok
        self.headline = headline
        self.checks = checks
        self.startedAt = startedAt
        self.durationMS = durationMS
        self.boundary = boundary
    }

    public static let empty = LiveIntegrationReport()
}

/// A probe's own answer, before the engine adds timing and redaction.
public struct DoctorProbeResult: Sendable, Equatable {
    public var state: DoctorCheckState
    public var detail: String

    public init(_ state: DoctorCheckState, _ detail: String) {
        self.state = state
        self.detail = detail
    }

    public static func ok(_ detail: String) -> DoctorProbeResult { .init(.ok, detail) }
    public static func warning(_ detail: String) -> DoctorProbeResult { .init(.warning, detail) }
    public static func failed(_ detail: String) -> DoctorProbeResult { .init(.failed, detail) }
    public static func skipped(_ detail: String) -> DoctorProbeResult { .init(.skipped, detail) }
}

public struct DoctorProbe: Sendable {
    public var id: String
    public var title: String
    public var run: @Sendable () async -> DoctorProbeResult

    public init(id: String, title: String, run: @escaping @Sendable () async -> DoctorProbeResult) {
        self.id = id
        self.title = title
        self.run = run
    }
}

// MARK: - Engine

public struct LiveIntegrationDoctor: Sendable {
    public let probes: [DoctorProbe]
    public static let maximumDetail = 240

    public init(probes: [DoctorProbe]) {
        self.probes = probes
    }

    public func run(now: Date = Date()) async -> LiveIntegrationReport {
        let started = Date()
        var checks: [DoctorCheck] = []
        for probe in probes {
            let checkStarted = Date()
            let result = await probe.run()
            let elapsed = Int(Date().timeIntervalSince(checkStarted) * 1_000)
            checks.append(DoctorCheck(
                id: probe.id,
                title: probe.title,
                state: result.state,
                detail: Self.sanitize(result.detail),
                durationMS: elapsed
            ))
        }
        let failed = checks.filter { $0.state == .failed }.count
        let warnings = checks.filter { $0.state == .warning }.count
        let skipped = checks.filter { $0.state == .skipped }.count
        let ok = checks.filter { $0.state == .ok }.count
        let report = LiveIntegrationReport(
            ok: failed == 0,
            headline: failed > 0
                ? "\(failed) 项失败 · \(warnings) 项注意 · \(ok) 项正常"
                : "全链路正常 · \(ok) 项通过\(warnings > 0 ? " · \(warnings) 项注意" : "")\(skipped > 0 ? " · \(skipped) 项未启用" : "")",
            checks: checks,
            startedAt: started,
            durationMS: Int(Date().timeIntervalSince(started) * 1_000)
        )
        _ = now
        return report
    }

    /// One line, scrubbed, capped. A probe author cannot accidentally put a
    /// password or a message body into a report by returning raw server text.
    public static func sanitize(_ text: String) -> String {
        let scrubbed = AssistantRedaction.scrub(text)
        let clean = scrubbed.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(clean).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return String(collapsed.prefix(maximumDetail))
    }
}

// MARK: - Reusable probes

public extension LiveIntegrationDoctor {
    /// A real write/read/delete round-trip. The probe reference is random, so a
    /// previous run's item can never make a broken store look healthy.
    static func keychainProbe(_ store: any HubSecretStoring) -> DoctorProbe {
        DoctorProbe(id: "keychain", title: "钥匙串读写 / Keychain round-trip") {
            guard store.isPersistent else {
                return .warning("当前为进程内易失存储（\(store.backingName)）/ volatile store: \(store.backingName)")
            }
            let reference = "doctor/probe/\(UUID().uuidString.lowercased())"
            let token = "ppx-doctor-\(UUID().uuidString.lowercased())"
            guard store.store(token, for: reference) else {
                return .failed("写入失败 / the store refused the probe write")
            }
            defer { _ = store.delete(reference: reference) }
            guard store.secret(for: reference) == token else {
                return .failed("回读不一致 / the probe value did not survive a read")
            }
            return .ok("写入、回读与删除均成功 · \(store.backingName) / write, read and delete succeeded")
        }
    }

    /// Reads the daemon's own status. It does not spawn, stop or restart it.
    static func signalingProbe(_ signaling: any NodeSignaling) -> DoctorProbe {
        DoctorProbe(id: "signal", title: "本机 daemon 与会话 / Local daemon and session") {
            let status = await signaling.status()
            let devices = await signaling.pairedDevices()
            let active = devices.filter { !$0.revoked }
            guard status.daemon.isLive else {
                return .failed("daemon 状态 \(status.daemon.rawValue) / daemon is \(status.daemon.rawValue)")
            }
            let heartbeat = status.websocketConnected
                ? "控制通道已连接 / control link connected"
                : "控制通道未连接 / control link down"
            let deviceLine = active.isEmpty
                ? "尚无已配对设备 / no paired phone"
                : "\(active.count) 台已配对 / \(active.count) paired"
            let lastSeen = active.compactMap(\.lastSeenAt).max()
            let seenLine = lastSeen.map { " · 最近心跳 \(PrivacyStamp.iso($0))" } ?? ""
            return .ok("\(status.daemon.rawValue) · \(heartbeat) · \(deviceLine)\(seenLine)")
        }
    }

    /// Uses the adapter's own loopback-only probe; an unavailable model is a
    /// warning rather than a failure because the node's deterministic features
    /// are designed to run without one.
    static func localModelProbe(_ adapter: Inkling2MiniAdapter?) -> DoctorProbe {
        DoctorProbe(id: "local_model", title: "本机模型 Ollama / MLX / Local model") {
            guard let adapter else {
                return .skipped("未装配本地模型适配器 / no local model adapter")
            }
            let card = await adapter.probe()
            switch card.state {
            case .ready:
                return .ok("\(card.runtime) · \(card.model)")
            case .modelMissing:
                return .warning("运行时在线但缺少模型 / runtime up, model missing · \(card.lastDetail)")
            case .runtimeMissing:
                return .warning("127.0.0.1 运行时不可达；纯轻量模式仍可用 / loopback runtime offline; lightweight mode remains available")
            case .off, .unknown:
                return .skipped("本地模型尚未就绪 / the local model is not ready")
            case .refused:
                return .failed("本地模型探测被拒绝 / the local model probe was refused · \(card.lastDetail)")
            }
        }
    }

    /// A handshake only: IMAP `LOGIN` + `EXAMINE`, SMTP `AUTH`, then logout. No
    /// mailbox listing, no fetch, no send. The server's text is scrubbed twice —
    /// once in the probe, once by the engine — because SMTP banners occasionally
    /// echo the account.
    static func mailProbe(
        _ config: MailAssistantConfig,
        secrets: any HubSecretStoring,
        timeout: TimeInterval = 9
    ) -> DoctorProbe {
        DoctorProbe(id: "mail", title: "邮箱认证握手 / Mail authentication handshake") {
            let value = config.normalised
            guard value.hasAccount else {
                return .skipped("未配置邮箱 / no mail account configured")
            }
            guard value.enabled else {
                return .skipped("邮箱助手未开启 / mail is off")
            }
            let imapPassword = secrets.secret(for: value.imapPasswordRef) ?? ""
            let smtpPassword = secrets.secret(for: value.smtpPasswordRef) ?? ""
            guard !imapPassword.isEmpty, !smtpPassword.isEmpty else {
                return .failed("钥匙串缺少 IMAP 或 SMTP 口令 / a mail password is missing from the Keychain")
            }
            let mailbox = mask(value.username)
            var imapLine = "IMAP 未测试 / not tested"
            do {
                let outcome = try await MailTimeout.run(timeout) {
                    guard let channel = MailTLSChannel(host: value.imapHost, port: value.imapPort) else {
                        throw MailTransportError.refused("invalid IMAP TLS endpoint")
                    }
                    try await channel.start(timeout: timeout)
                    let session = IMAPSession(channel: channel)
                    try await session.open(username: value.username, password: imapPassword)
                    await session.close()
                    return true
                }
                imapLine = outcome ? "IMAP 993 登录成功 / login ok" : "IMAP 无结果 / no result"
            } catch {
                imapLine = "IMAP 失败：\(AssistantRedaction.scrub(String(describing: error)))"
            }
            var smtpLine = "SMTP 未测试 / not tested"
            do {
                let outcome = try await MailTimeout.run(timeout) {
                    guard let channel = MailTLSChannel(host: value.smtpHost, port: value.smtpPort) else {
                        throw MailTransportError.refused("invalid SMTP TLS endpoint")
                    }
                    try await channel.start(timeout: timeout)
                    let session = SMTPSession(channel: channel, username: value.username)
                    try await session.open(password: smtpPassword)
                    await session.close()
                    return true
                }
                smtpLine = outcome ? "SMTP 465 认证成功 / auth ok" : "SMTP 无结果 / no result"
            } catch {
                smtpLine = "SMTP 失败：\(AssistantRedaction.scrub(String(describing: error)))"
            }
            let detail = "\(mailbox) · \(imapLine) · \(smtpLine) · 未拉取未发送 / no fetch, no send"
            let failed = imapLine.contains("失败") || smtpLine.contains("失败")
            return failed ? .failed(detail) : .ok(detail)
        }
    }

    static func mask(_ mailbox: String) -> String {
        let parts = mailbox.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return "•" }
        return "\(first)***@\(parts[1])"
    }

    /// A read-only free/busy pass over the already-admitted CalDAV servers. It
    /// carries no event text: the answer is which servers answered at all.
    static func calendarProbe(_ bridge: CalDavBridge?) -> DoctorProbe {
        DoctorProbe(id: "caldav", title: "日历 CalDAV / Calendar") {
            guard let bridge else {
                return .skipped("隐私桥接未装配 / privacy bridge is not assembled")
            }
            let reading = await bridge.read(
                window: DateInterval(start: Date(), duration: 24 * 60 * 60),
                zone: .current
            )
            guard reading.serversAsked > 0 else {
                return .skipped("未配置或未启用的 CalDAV 服务器 / no enabled CalDAV server")
            }
            let reachable = reading.cards.filter(\.reachable).count
            let line = "\(reachable)/\(reading.serversAsked) 台可达 / reachable"
            return reachable == 0 ? .failed(line) : .ok(line)
        }
    }

    /// The Home Assistant and MQTT seams the sentinel would use. It never calls a
    /// service: the bridge's status probe is the whole test.
    static func smartHomeProbe(_ bridge: SmartHomeBridge?) -> DoctorProbe {
        DoctorProbe(id: "smarthome", title: "家庭中枢 HA / MQTT / Smart home") {
            guard let bridge else {
                return .skipped("隐私桥接未装配 / privacy bridge is not assembled")
            }
            let status = await bridge.status()
            guard status.enabled else {
                return .skipped("家庭桥接未启用 / the smart-home bridge is off")
            }
            guard status.homeAssistantConfigured || status.brokerConfigured else {
                return .skipped("未配置地址 / no Home Assistant or broker configured")
            }
            var parts: [String] = []
            var failed = false
            if status.homeAssistantConfigured {
                parts.append(status.homeAssistantReachable ? "HA 可达 / reachable" : "HA 不可达 / unreachable")
                if !status.homeAssistantReachable { failed = true }
            }
            if status.brokerConfigured {
                parts.append(status.brokerConnected ? "MQTT 已连接 / connected" : "MQTT 未连接 / disconnected")
            }
            if !status.reason.isEmpty { parts.append(status.reason) }
            parts.append("\(status.exposedCount) 个白名单实体 / exposed")
            return failed ? .failed(parts.joined(separator: " · ")) : .ok(parts.joined(separator: " · "))
        }
    }
}
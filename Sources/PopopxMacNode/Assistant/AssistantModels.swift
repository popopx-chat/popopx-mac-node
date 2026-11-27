//
//  AssistantModels.swift
//  PopopxMacNode — the private assistant's configuration, permission contract and
//  snapshot shapes.
//
//  Two rules shape every type in this file:
//
//  1. **A capability is a permission, not a button.** `ConnectorCapability` is the
//     one description of what the assistant may do with a connector. `read` and
//     `propose` are reachable by the assistant loop; `write` is only reachable
//     through `AssistantApprovalGate`, and `admin` is never granted here — it
//     exists so a future connector has to name it to get it.
//  2. **Nothing here carries a credential or a mail body.** A snapshot names a
//     Keychain *reference*, a message summary is a bounded snippet, and a draft
//     card carries a digest plus a preview. The full outgoing body lives in
//     `MailAssistantBridge`'s memory until the owner approves it.
//

import Foundation
import CryptoKit

// MARK: - Clock

/// The scheduler and the gate take time from here rather than calling `Date()`
/// inside, so a test can move a day without sleeping one.
public protocol AssistantClock: Sendable {
    var now: Date { get }
}

public struct SystemAssistantClock: AssistantClock {
    public init() {}
    public var now: Date { Date() }
}

/// A mutable clock for tests and for the console's one-shot ticks.
public final class ManualAssistantClock: AssistantClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    public init(_ value: Date) {
        self.value = value
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

// MARK: - Permission contract

/// The four levels the assistant understands. Raw values are what the console and
/// the phone display, so they must not change.
public enum AssistantPermission: String, Codable, Sendable, CaseIterable, Comparable {
    case read
    case propose
    case write
    case admin

    private var rank: Int {
        switch self {
        case .read: return 0
        case .propose: return 1
        case .write: return 2
        case .admin: return 3
        }
    }

    public static func < (lhs: AssistantPermission, rhs: AssistantPermission) -> Bool {
        lhs.rank < rhs.rank
    }

    public var labelZh: String {
        switch self {
        case .read: return "只读"
        case .propose: return "建议"
        case .write: return "写入（需批准）"
        case .admin: return "管理"
        }
    }

    public var labelEn: String {
        switch self {
        case .read: return "read"
        case .propose: return "propose"
        case .write: return "write · approval required"
        case .admin: return "admin"
        }
    }
}

/// The connectors the assistant can describe. Adding one here is a visible act in
/// the console, which is the point of a unified permission shell.
public enum AssistantConnectorKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case calendar
    case calDav
    case smartHome
    case mcp
    case godsEye
    case mail

    public var id: String { rawValue }

    public var labelZh: String {
        switch self {
        case .calendar: return "Apple 日程"
        case .calDav: return "CalDAV 日程"
        case .smartHome: return "家庭设备"
        case .mcp: return "MCP 工具"
        case .godsEye: return "God's Eye View"
        case .mail: return "邮件"
        }
    }

    public var labelEn: String {
        switch self {
        case .calendar: return "Apple Calendar"
        case .calDav: return "CalDAV"
        case .smartHome: return "Smart Home"
        case .mcp: return "MCP tools"
        case .godsEye: return "God's Eye View"
        case .mail: return "Mail"
        }
    }
}

/// One row of the permission table. `permission` is the highest level currently
/// granted; `writeRequiresApproval` is always true for `write` and is rendered so
/// the reader cannot mistake "the connector can write" for "the assistant writes
/// on its own".
public struct ConnectorCapability: Codable, Sendable, Equatable, Identifiable {
    public var kind: AssistantConnectorKind
    public var permission: AssistantPermission
    public var enabled: Bool
    public var ready: Bool
    public var writeRequiresApproval: Bool
    public var detail: String

    public var id: String { kind.rawValue }

    public init(
        kind: AssistantConnectorKind,
        permission: AssistantPermission,
        enabled: Bool,
        ready: Bool,
        writeRequiresApproval: Bool = true,
        detail: String = ""
    ) {
        self.kind = kind
        self.permission = permission
        self.enabled = enabled
        self.ready = ready
        self.writeRequiresApproval = writeRequiresApproval
        self.detail = detail
    }

    public var labelZh: String { kind.labelZh }
    public var labelEn: String { kind.labelEn }
}

// MARK: - Configuration

/// Mail is the assistant's one named egress exception, and it is off by default.
///
/// * The console and the MCP bridge stay on loopback. Mail cannot: an IMAP server
///   is not on this Mac. The exception is therefore narrow and owner-typed — the
///   host is a literal in the settings document, never discovered by DNS-SD and
///   never redirected by a remote answer.
/// * Only implicit TLS is implemented (IMAPS 993, SMTPS 465). A plaintext or
///   STARTTLS downgrade is not offered, so an owner who types port 143 gets a
///   refusal rather than a credential sent in the clear.
/// * The username is not a secret; the two passwords are Keychain references and
///   are never stored in settings.
public struct MailAssistantConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var username: String
    public var fromAddress: String
    public var imapPasswordRef: String
    public var smtpPasswordRef: String
    public var lookbackDays: Int
    public var maxMessages: Int

    public init(
        enabled: Bool = false,
        imapHost: String = "",
        imapPort: Int = 993,
        smtpHost: String = "",
        smtpPort: Int = 465,
        username: String = "",
        fromAddress: String = "",
        imapPasswordRef: String = "assistant/mail/imap-password",
        smtpPasswordRef: String = "assistant/mail/smtp-password",
        lookbackDays: Int = 3,
        maxMessages: Int = 12
    ) {
        self.enabled = enabled
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username
        self.fromAddress = fromAddress
        self.imapPasswordRef = imapPasswordRef
        self.smtpPasswordRef = smtpPasswordRef
        self.lookbackDays = lookbackDays
        self.maxMessages = maxMessages
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, imapHost, imapPort, smtpHost, smtpPort, username, fromAddress
        case imapPasswordRef, smtpPasswordRef, lookbackDays, maxMessages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MailAssistantConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        imapHost = try c.decodeIfPresent(String.self, forKey: .imapHost) ?? fallback.imapHost
        imapPort = try c.decodeIfPresent(Int.self, forKey: .imapPort) ?? fallback.imapPort
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? fallback.smtpHost
        smtpPort = try c.decodeIfPresent(Int.self, forKey: .smtpPort) ?? fallback.smtpPort
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? fallback.username
        fromAddress = try c.decodeIfPresent(String.self, forKey: .fromAddress) ?? fallback.fromAddress
        imapPasswordRef = try c.decodeIfPresent(String.self, forKey: .imapPasswordRef) ?? fallback.imapPasswordRef
        smtpPasswordRef = try c.decodeIfPresent(String.self, forKey: .smtpPasswordRef) ?? fallback.smtpPasswordRef
        lookbackDays = try c.decodeIfPresent(Int.self, forKey: .lookbackDays) ?? fallback.lookbackDays
        maxMessages = try c.decodeIfPresent(Int.self, forKey: .maxMessages) ?? fallback.maxMessages
    }

    public var normalised: MailAssistantConfig {
        var copy = self
        copy.imapHost = Self.host(imapHost)
        copy.smtpHost = Self.host(smtpHost)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.fromAddress = Self.mailbox(fromAddress)
        copy.imapPort = imapPort == 993 ? 993 : 0
        copy.smtpPort = smtpPort == 465 ? 465 : 0
        copy.lookbackDays = min(max(lookbackDays, 1), 14)
        copy.maxMessages = min(max(maxMessages, 1), 30)
        copy.imapPasswordRef = HubSecrets.isSafeReference(imapPasswordRef)
            ? imapPasswordRef : "assistant/mail/imap-password"
        copy.smtpPasswordRef = HubSecrets.isSafeReference(smtpPasswordRef)
            ? smtpPasswordRef : "assistant/mail/smtp-password"
        return copy
    }

    /// A writable port pair is required: the transport refuses anything that is
    /// not implicit TLS, so a non-empty host with a wrong port is worse than empty.
    public var usable: Bool {
        let value = normalised
        return value.enabled
            && !value.imapHost.isEmpty && value.imapPort == 993
            && !value.smtpHost.isEmpty && value.smtpPort == 465
            && !value.username.isEmpty && !value.fromAddress.isEmpty
    }

    public var hasAccount: Bool {
        let value = normalised
        return !value.imapHost.isEmpty && !value.smtpHost.isEmpty
            && !value.username.isEmpty && !value.fromAddress.isEmpty
    }

    static func host(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 253,
              !trimmed.contains("/"), !trimmed.contains(" "), !trimmed.contains("@"),
              !trimmed.contains(".."), trimmed.first != ".", trimmed.last != "." else {
            return ""
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } ? trimmed : ""
    }

    static func mailbox(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count <= 254, trimmed.contains("@"), !trimmed.contains(" "),
              !trimmed.contains("\r"), !trimmed.contains("\n") else {
            return ""
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return "" }
        return trimmed
    }
}

/// A repair action the sentinel may propose when a watched entity goes missing.
/// There is no implicit repair: an entity without a rule produces an audit row, not
/// a card, because the node must not guess which plug powers the gateway.
public struct SentinelRepairRule: Codable, Sendable, Equatable, Identifiable {
    public var watchEntity: String
    public var repairEntity: String
    public var repairDomain: String
    public var repairService: String
    public var offlineMinutes: Int
    public var enabled: Bool

    public var id: String { watchEntity }

    public init(
        watchEntity: String = "",
        repairEntity: String = "",
        repairDomain: String = "homeassistant",
        repairService: String = "turn_on",
        offlineMinutes: Int = 15,
        enabled: Bool = true
    ) {
        self.watchEntity = watchEntity
        self.repairEntity = repairEntity
        self.repairDomain = repairDomain
        self.repairService = repairService
        self.offlineMinutes = offlineMinutes
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case watchEntity, repairEntity, repairDomain, repairService, offlineMinutes, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SentinelRepairRule()
        watchEntity = try c.decodeIfPresent(String.self, forKey: .watchEntity) ?? fallback.watchEntity
        repairEntity = try c.decodeIfPresent(String.self, forKey: .repairEntity) ?? fallback.repairEntity
        repairDomain = try c.decodeIfPresent(String.self, forKey: .repairDomain) ?? fallback.repairDomain
        repairService = try c.decodeIfPresent(String.self, forKey: .repairService) ?? fallback.repairService
        offlineMinutes = try c.decodeIfPresent(Int.self, forKey: .offlineMinutes) ?? fallback.offlineMinutes
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
    }

    public var normalised: SentinelRepairRule {
        var copy = self
        copy.watchEntity = SmartHomeConfig.normalise(watchEntity)
        copy.repairEntity = SmartHomeConfig.normalise(repairEntity)
        copy.repairDomain = SmartHomeConfig.normalise(repairDomain)
        copy.repairService = SmartHomeConfig.normalise(repairService)
        copy.offlineMinutes = min(max(offlineMinutes, 1), 240)
        return copy
    }

    /// A rule is usable when both entities look like `domain.object_id` and the
    /// repair target is exactly two path segments. The Home Assistant executor
    /// splits the target on `.` and refuses anything but two parts, so a service
    /// such as `homeassistant.turn_on` is valid and a dotted service is not.
    public var usable: Bool {
        let value = normalised
        guard enabled,
              value.watchEntity.contains("."), !value.watchEntity.contains("#"),
              value.repairEntity.contains("."), !value.repairEntity.contains("#"),
              let domain = HubHTTP.segment(value.repairDomain, maximumLength: 40),
              let service = HubHTTP.segment(value.repairService, maximumLength: 40),
              !domain.contains("."), !service.contains(".")
        else { return false }
        return true
    }
}

/// The daily briefing and the patrol are separate switches under one master
/// switch. All three default off, and the console persists them through the
/// ordinary settings document.
public struct AssistantBriefingConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int

    public init(enabled: Bool = false, hour: Int = 8, minute: Int = 0) {
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
    }

    private enum CodingKeys: String, CodingKey { case enabled, hour, minute }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
    }

    public var normalised: AssistantBriefingConfig {
        AssistantBriefingConfig(
            enabled: enabled,
            hour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59)
        )
    }
}

public struct AssistantPatrolConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalMinutes: Int
    public var offlineMinutes: Int

    public init(enabled: Bool = false, intervalMinutes: Int = 30, offlineMinutes: Int = 15) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.offlineMinutes = offlineMinutes
    }

    private enum CodingKeys: String, CodingKey { case enabled, intervalMinutes, offlineMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
        offlineMinutes = try c.decodeIfPresent(Int.self, forKey: .offlineMinutes) ?? 15
    }

    public var normalised: AssistantPatrolConfig {
        AssistantPatrolConfig(
            enabled: enabled,
            intervalMinutes: min(max(intervalMinutes, 5), 24 * 60),
            offlineMinutes: min(max(offlineMinutes, 1), 240)
        )
    }
}

public struct AssistantConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var briefing: AssistantBriefingConfig
    public var patrol: AssistantPatrolConfig
    public var mail: MailAssistantConfig
    /// A preference, not a loop: it says "use the local model when this Mac has
    /// one". It stays on when the master switch is off so turning the assistant
    /// back on does not silently forget the owner's choice.
    public var inkling: InklingConfig
    public var repairs: [SentinelRepairRule]

    public init(
        enabled: Bool = false,
        briefing: AssistantBriefingConfig = AssistantBriefingConfig(),
        patrol: AssistantPatrolConfig = AssistantPatrolConfig(),
        mail: MailAssistantConfig = MailAssistantConfig(),
        inkling: InklingConfig = InklingConfig(),
        repairs: [SentinelRepairRule] = []
    ) {
        self.enabled = enabled
        self.briefing = briefing
        self.patrol = patrol
        self.mail = mail
        self.inkling = inkling
        self.repairs = repairs
    }

    private enum CodingKeys: String, CodingKey { case enabled, briefing, patrol, mail, inkling, repairs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        briefing = try c.decodeIfPresent(AssistantBriefingConfig.self, forKey: .briefing) ?? AssistantBriefingConfig()
        patrol = try c.decodeIfPresent(AssistantPatrolConfig.self, forKey: .patrol) ?? AssistantPatrolConfig()
        mail = try c.decodeIfPresent(MailAssistantConfig.self, forKey: .mail) ?? MailAssistantConfig()
        inkling = try c.decodeIfPresent(InklingConfig.self, forKey: .inkling) ?? InklingConfig()
        repairs = try c.decodeIfPresent([SentinelRepairRule].self, forKey: .repairs) ?? []
    }

    public static let disabled = AssistantConfig()

    public var normalised: AssistantConfig {
        var copy = self
        copy.briefing = briefing.normalised
        copy.patrol = patrol.normalised
        copy.mail = mail.normalised
        copy.inkling = inkling.normalised
        copy.repairs = Array(repairs.map { $0.normalised }.filter { !$0.watchEntity.isEmpty }.prefix(32))
        if !enabled {
            copy.briefing.enabled = false
            copy.patrol.enabled = false
            copy.mail.enabled = false
        }
        return copy
    }

    public var anyLoopEnabled: Bool {
        let value = normalised
        return value.enabled && (value.briefing.enabled || value.patrol.enabled || value.mail.enabled)
    }
}

// MARK: - Actions and proposals

public enum AssistantActionKind: String, Codable, Sendable, CaseIterable {
    case mailSend = "mail.send"
    case homeService = "home.service"

    public var labelZh: String {
        switch self {
        case .mailSend: return "发送邮件"
        case .homeService: return "家庭设备修复"
        }
    }

    public var labelEn: String {
        switch self {
        case .mailSend: return "send mail"
        case .homeService: return "home repair"
        }
    }
}

public enum AssistantProposalState: String, Codable, Sendable, Equatable {
    case pendingUserApproval = "pending_user_approval"
    case approved
    case executed
    case executionFailed = "execution_failed"
    case rejected
    case expired

    public var isPending: Bool { self == .pendingUserApproval }
}

/// The four fields the receipt signs. Kept as one value so a caller cannot pass a
/// kind from one place and a digest from another.
public struct AssistantApprovalBinding: Codable, Sendable, Equatable {
    public var kind: AssistantActionKind
    public var target: String
    public var digest: String
    public var expiresAt: Date

    public init(kind: AssistantActionKind, target: String, digest: String, expiresAt: Date) {
        self.kind = kind
        self.target = target
        self.digest = digest
        self.expiresAt = expiresAt
    }
}

/// What the console and the phone render. It deliberately does **not** contain the
/// receipt: the console's approval route mints the receipt inside the node, and
/// the phone receives it only in the command lines of its own card.
public struct AssistantProposalCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AssistantActionKind
    public var title: String
    public var detail: String
    public var target: String
    public var digest: String
    public var state: AssistantProposalState
    public var createdAt: Date
    public var expiresAt: Date
    public var secondsLeft: Int
    public var canApprove: Bool

    public init(
        id: String,
        kind: AssistantActionKind,
        title: String,
        detail: String,
        target: String,
        digest: String,
        state: AssistantProposalState,
        createdAt: Date,
        expiresAt: Date,
        secondsLeft: Int,
        canApprove: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.target = target
        self.digest = digest
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.secondsLeft = secondsLeft
        self.canApprove = canApprove
    }
}

public struct AssistantAuditRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var at: Date
    public var channel: String
    public var event: String
    public var detail: String
    public var outcome: String

    public init(
        id: String = UUID().uuidString,
        at: Date,
        channel: String,
        event: String,
        detail: String = "",
        outcome: String = "ok"
    ) {
        self.id = id
        self.at = at
        self.channel = channel
        self.event = event
        self.detail = detail
        self.outcome = outcome
    }
}

// MARK: - Mail models

public enum MailCategory: String, Codable, Sendable, CaseIterable {
    case needsReply = "needs_reply"
    case bill = "bill"
    case invitation = "invitation"
    case notification = "notification"

    public var labelZh: String {
        switch self {
        case .needsReply: return "待回复"
        case .bill: return "账单/发票"
        case .invitation: return "日程邀请"
        case .notification: return "通知/无需处理"
        }
    }

    public var labelEn: String {
        switch self {
        case .needsReply: return "needs reply"
        case .bill: return "bill"
        case .invitation: return "invitation"
        case .notification: return "notification"
        }
    }
}

/// A bounded summary, not the message. `snippet` is capped and has markup removed;
/// the full body exists only inside `MailAssistantBridge` during triage.
public struct AssistantMailMessageCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var subject: String
    public var from: String
    public var receivedAt: Date
    public var category: MailCategory
    public var amount: String
    public var deadline: String
    public var snippet: String
    public var needsReply: Bool

    public init(
        id: String,
        subject: String,
        from: String,
        receivedAt: Date,
        category: MailCategory,
        amount: String = "",
        deadline: String = "",
        snippet: String = "",
        needsReply: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.receivedAt = receivedAt
        self.category = category
        self.amount = amount
        self.deadline = deadline
        self.snippet = snippet
        self.needsReply = needsReply
    }
}

/// The outgoing draft. This is the object whose digest the receipt binds; a
/// tampered recipient, subject or body changes the digest and the executor refuses
/// before the transport is touched.
public struct MailOutgoingDraft: Codable, Sendable, Equatable {
    public var proposalID: String
    public var to: String
    public var subject: String
    public var body: String
    public var inReplyTo: String

    public init(proposalID: String = "", to: String, subject: String, body: String, inReplyTo: String = "") {
        self.proposalID = proposalID
        self.to = to
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
    }

    public var canonicalTarget: String { MailAssistantConfig.mailbox(to) }

    public var digest: String {
        AssistantDigest.mail(to: canonicalTarget, subject: subject, body: body)
    }

    /// A short, inert preview for the card. The full body never enters a snapshot,
    /// an audit row or the phone card.
    public var preview: String {
        String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }
}

/// A draft waiting on the owner, keyed by its proposal id.
public struct AssistantDraftCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var to: String
    public var subject: String
    public var preview: String
    public var digest: String
    public var createdAt: Date

    public init(id: String, to: String, subject: String, preview: String, digest: String, createdAt: Date) {
        self.id = id
        self.to = to
        self.subject = subject
        self.preview = preview
        self.digest = digest
        self.createdAt = createdAt
    }
}

public struct AssistantMailTriage: Sendable, Equatable {
    public var messages: [AssistantMailMessageCard]
    public var drafts: [MailOutgoingDraft]
    public var summaryLines: [String]
    public var fetchedAt: Date

    public init(
        messages: [AssistantMailMessageCard] = [],
        drafts: [MailOutgoingDraft] = [],
        summaryLines: [String] = [],
        fetchedAt: Date = Date()
    ) {
        self.messages = messages
        self.drafts = drafts
        self.summaryLines = summaryLines
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Home sentinel models

public struct SentinelAnomalyCard: Codable, Sendable, Equatable, Identifiable {
    public var entityID: String
    public var display: String
    public var state: String
    public var offlineSeconds: Int
    public var repairEntity: String
    public var repairAction: String

    public var id: String { entityID }

    public init(
        entityID: String,
        display: String = "",
        state: String,
        offlineSeconds: Int,
        repairEntity: String = "",
        repairAction: String = ""
    ) {
        self.entityID = entityID
        self.display = display
        self.state = state
        self.offlineSeconds = offlineSeconds
        self.repairEntity = repairEntity
        self.repairAction = repairAction
    }
}

public struct SentinelScanReport: Sendable, Equatable {
    public var anomalies: [SentinelAnomalyCard]
    public var proposed: Int
    public var skipped: [String]
    public var scannedAt: Date

    public init(
        anomalies: [SentinelAnomalyCard] = [],
        proposed: Int = 0,
        skipped: [String] = [],
        scannedAt: Date = Date()
    ) {
        self.anomalies = anomalies
        self.proposed = proposed
        self.skipped = skipped
        self.scannedAt = scannedAt
    }
}

// MARK: - Snapshot shapes

public struct AssistantSchedulerCard: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var briefingEnabled: Bool
    public var briefingHour: Int
    public var briefingMinute: Int
    public var patrolEnabled: Bool
    public var patrolIntervalMinutes: Int
    public var offlineMinutes: Int
    public var running: Bool
    public var lastBriefingAt: Date?
    public var lastPatrolAt: Date?
    public var nextBriefingAt: Date?
    public var lastRunDetail: String

    public init(
        enabled: Bool = false,
        briefingEnabled: Bool = false,
        briefingHour: Int = 8,
        briefingMinute: Int = 0,
        patrolEnabled: Bool = false,
        patrolIntervalMinutes: Int = 30,
        offlineMinutes: Int = 15,
        running: Bool = false,
        lastBriefingAt: Date? = nil,
        lastPatrolAt: Date? = nil,
        nextBriefingAt: Date? = nil,
        lastRunDetail: String = ""
    ) {
        self.enabled = enabled
        self.briefingEnabled = briefingEnabled
        self.briefingHour = briefingHour
        self.briefingMinute = briefingMinute
        self.patrolEnabled = patrolEnabled
        self.patrolIntervalMinutes = patrolIntervalMinutes
        self.offlineMinutes = offlineMinutes
        self.running = running
        self.lastBriefingAt = lastBriefingAt
        self.lastPatrolAt = lastPatrolAt
        self.nextBriefingAt = nextBriefingAt
        self.lastRunDetail = lastRunDetail
    }
}

public struct AssistantMailCard: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var configured: Bool
    public var usable: Bool
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var username: String
    public var fromAddress: String
    public var imapPasswordRef: String
    public var smtpPasswordRef: String
    public var imapStored: Bool
    public var smtpStored: Bool
    public var credentialBacking: String
    public var lookbackDays: Int
    public var maxMessages: Int
    public var lastReadAt: Date?
    public var lastSendAt: Date?
    public var lastError: String
    public var triagedCount: Int
    public var draftCount: Int
    public var messages: [AssistantMailMessageCard]
    public var boundary: String

    public init(
        enabled: Bool = false,
        configured: Bool = false,
        usable: Bool = false,
        imapHost: String = "",
        imapPort: Int = 993,
        smtpHost: String = "",
        smtpPort: Int = 465,
        username: String = "",
        fromAddress: String = "",
        imapPasswordRef: String = "",
        smtpPasswordRef: String = "",
        imapStored: Bool = false,
        smtpStored: Bool = false,
        credentialBacking: String = "",
        lookbackDays: Int = 3,
        maxMessages: Int = 12,
        lastReadAt: Date? = nil,
        lastSendAt: Date? = nil,
        lastError: String = "",
        triagedCount: Int = 0,
        draftCount: Int = 0,
        messages: [AssistantMailMessageCard] = [],
        boundary: String = ""
    ) {
        self.enabled = enabled
        self.configured = configured
        self.usable = usable
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username
        self.fromAddress = fromAddress
        self.imapPasswordRef = imapPasswordRef
        self.smtpPasswordRef = smtpPasswordRef
        self.imapStored = imapStored
        self.smtpStored = smtpStored
        self.credentialBacking = credentialBacking
        self.lookbackDays = lookbackDays
        self.maxMessages = maxMessages
        self.lastReadAt = lastReadAt
        self.lastSendAt = lastSendAt
        self.lastError = lastError
        self.triagedCount = triagedCount
        self.draftCount = draftCount
        self.messages = messages
        self.boundary = boundary
    }
}

public struct AssistantSnapshot: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var scheduler: AssistantSchedulerCard
    public var mail: AssistantMailCard
    public var connectors: [ConnectorCapability]
    public var pending: [AssistantProposalCard]
    public var drafts: [AssistantDraftCard]
    public var audit: [AssistantAuditRow]
    public var boundary: String
    public var lastReport: String
    public var updatedAt: Date
    public var inkling: AssistantInklingCard

    public init(
        enabled: Bool = false,
        scheduler: AssistantSchedulerCard = AssistantSchedulerCard(),
        mail: AssistantMailCard = AssistantMailCard(),
        connectors: [ConnectorCapability] = [],
        pending: [AssistantProposalCard] = [],
        drafts: [AssistantDraftCard] = [],
        audit: [AssistantAuditRow] = [],
        boundary: String = "",
        lastReport: String = "",
        updatedAt: Date = Date(),
        inkling: AssistantInklingCard = AssistantInklingCard()
    ) {
        self.enabled = enabled
        self.scheduler = scheduler
        self.mail = mail
        self.connectors = connectors
        self.pending = pending
        self.drafts = drafts
        self.audit = audit
        self.boundary = boundary
        self.lastReport = lastReport
        self.updatedAt = updatedAt
        self.inkling = inkling
    }

    public static let empty = AssistantSnapshot()
}

// MARK: - Reports

public struct AssistantControlReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var outcome: String
    public var detail: String
    public var assistant: AssistantSnapshot

    public init(ok: Bool, outcome: String, detail: String, assistant: AssistantSnapshot) {
        self.ok = ok
        self.outcome = outcome
        self.detail = detail
        self.assistant = assistant
    }

    public static func refused(_ detail: String, snapshot: AssistantSnapshot) -> AssistantControlReport {
        AssistantControlReport(ok: false, outcome: "refused", detail: detail, assistant: snapshot)
    }
}

public struct AssistantDecisionReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var outcome: String
    public var detail: String
    public var assistant: AssistantSnapshot

    public init(ok: Bool, outcome: String, detail: String, assistant: AssistantSnapshot) {
        self.ok = ok
        self.outcome = outcome
        self.detail = detail
        self.assistant = assistant
    }
}

public struct AssistantCredentialReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public var reference: String
    public var assistant: AssistantSnapshot

    public init(ok: Bool, detail: String, reference: String, assistant: AssistantSnapshot) {
        self.ok = ok
        self.detail = detail
        self.reference = reference
        self.assistant = assistant
    }
}

// MARK: - Digest helpers

/// The values a receipt signs are built here once, so the proposer and the
/// executor cannot disagree about field order.
public enum AssistantDigest {
    public static func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func mail(to: String, subject: String, body: String) -> String {
        let target = MailAssistantConfig.mailbox(to)
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha256("assistant.mail.v1|\(target)|\(cleanSubject)|\(body)")
    }

    /// Canonical JSON: sorted keys, no whitespace. `JSONValue` already encodes
    /// deterministically through `NodeJSON`'s sorted-keys encoder, and the prefix
    /// pins the wire version.
    public static func home(kind: AssistantActionKind, target: String, arguments: [String: JSONValue]) -> String {
        let object = JSONValue.object(arguments)
        let encoded = NodeJSON.encodeLine(object).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return sha256("assistant.home.v1|\(kind.rawValue)|\(target)|\(encoded)")
    }
}
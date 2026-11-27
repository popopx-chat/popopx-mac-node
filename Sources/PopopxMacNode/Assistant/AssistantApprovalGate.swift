//
//  AssistantApprovalGate.swift
//  PopopxMacNode — the one road from "the assistant suggested it" to "the node did it".
//
//  The gate exists because a mail send and a home-device write are the two things
//  the assistant must never be able to do on its own. The contract is deliberately
//  stricter than the existing privacy ledger's receipt:
//
//    receipt = HMAC-SHA256(key, "assistant.v1|id|kind|target|digest|expiry")
//
//  The private key lives in `vault/assistant-approval.key` (0600). A receipt is
//  therefore bound to **operation type**, **target object**, **content digest** and
//  **expiry**, not just to an id. Changing a recipient, a subject, a body or a home
//  payload after the card was shown changes the digest and the executor refuses;
//  waiting past the TTL expires it. Comparison is constant-time.
//
//  Proposals live in memory only. A restart drops every unexecuted proposal, which
//  is the intended consequence of "an unattended reboot must not leave a writeable
//  authorization lying around". The audit log is the durable record.
//

import Foundation
import CryptoKit

// MARK: - Signer

public struct AssistantApprovalSigner: Sendable {
    public static let receiptLength = 32

    public let key: Data

    public init(key: Data) {
        self.key = key
    }

    /// Loads the durable key, creating it on first use with 0600 permissions.
    /// Losing the key only invalidates proposals that were still pending; they
    /// expire anyway.
    public static func loadOrCreate(at url: URL) -> AssistantApprovalSigner {
        let data = (try? Data(contentsOf: url)) ?? Data()
        if data.count >= 16 { return AssistantApprovalSigner(key: data) }
        let fresh = AssistantApprovalSigner(key: PrivacyApprovalSigner.randomKey())
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fresh.key.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return fresh
    }

    public func receipt(id: String, binding: AssistantApprovalBinding) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message(id: id, binding: binding).utf8),
            using: SymmetricKey(data: key)
        )
        return String(TextKit.base64URL(Data(mac)).prefix(Self.receiptLength))
    }

    public func validate(_ candidate: String, id: String, binding: AssistantApprovalBinding) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Digest.matches(trimmed, receipt(id: id, binding: binding))
    }

    /// The canonical message. Field order and separators are wire format: the
    /// proposer and the executor must build the same string or nothing validates.
    private func message(id: String, binding: AssistantApprovalBinding) -> String {
        "assistant.v1|\(id)|\(binding.kind.rawValue)|\(binding.target)|\(binding.digest)|\(Int(binding.expiresAt.timeIntervalSince1970))"
    }
}

// MARK: - Values

/// What an approval click carries. The receipt is minted inside the node for the
/// console path and delivered in the command lines of the phone card; it is never
/// part of a snapshot.
public struct AssistantApproval: Codable, Sendable, Equatable {
    public var proposalID: String
    public var receipt: String

    public init(proposalID: String, receipt: String) {
        self.proposalID = proposalID
        self.receipt = receipt
    }
}

/// Returned only by `AssistantApprovalGate.validateExecution`, after the receipt,
/// state, binding and expiry have all been checked. The initializer is internal so
/// no other module can mint one; the executor still calls the gate itself before
/// performing I/O, so this is a record of a check, not a substitute for one.
public struct AssistantExecutionAuthorization: Sendable, Equatable {
    public let proposalID: String
    public let kind: AssistantActionKind
    public let target: String
    public let digest: String
    public let notAfter: Date

    init(proposalID: String, kind: AssistantActionKind, target: String, digest: String, notAfter: Date) {
        self.proposalID = proposalID
        self.kind = kind
        self.target = target
        self.digest = digest
        self.notAfter = notAfter
    }
}

public struct AssistantApprovalTicket: Sendable, Equatable {
    public var proposalID: String
    public var receipt: String
    public var binding: AssistantApprovalBinding
    public var card: AssistantProposalCard

    public init(proposalID: String, receipt: String, binding: AssistantApprovalBinding, card: AssistantProposalCard) {
        self.proposalID = proposalID
        self.receipt = receipt
        self.binding = binding
        self.card = card
    }
}

public enum AssistantGateError: Error, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case queueFull
    case unknownProposal
    case notPending
    case notApproved
    case rejected
    case expired
    case receiptInvalid
    case bindingMismatch(String)
    case alreadyExecuted

    public var description: String {
        switch self {
        case .invalidRequest(let field): return "请求字段不合法 / invalid request: \(field)"
        case .queueFull: return "待审批队列已满 / too many pending proposals"
        case .unknownProposal: return "提案不存在 / no such proposal"
        case .notPending: return "提案已处理 / the proposal is no longer pending"
        case .notApproved: return "尚未获批 / the proposal has not been approved"
        case .rejected: return "提案已被驳回 / the proposal was rejected"
        case .expired: return "提案已过期 / the proposal has expired"
        case .receiptInvalid: return "审批回执无效 / the approval receipt is invalid"
        case .bindingMismatch(let field): return "内容与审批不一致 / content changed after approval: \(field)"
        case .alreadyExecuted: return "该授权只能使用一次 / the authorization was already used"
        }
    }
}

// MARK: - Gate

public actor AssistantApprovalGate {
    public static let defaultLifetime: TimeInterval = 900
    public static let maximumPending = 32
    private static let terminalRetention = 64

    private struct Entry {
        var id: String
        var binding: AssistantApprovalBinding
        var title: String
        var detail: String
        var receipt: String
        var state: AssistantProposalState
        var createdAt: Date
        var resolvedAt: Date?
        var consumed: Bool
        var executionDetail: String
    }

    private let signer: AssistantApprovalSigner
    private let clock: AssistantClock
    private var audit: (any AssistantAuditWriting)?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(
        signer: AssistantApprovalSigner,
        clock: AssistantClock = SystemAssistantClock(),
        audit: (any AssistantAuditWriting)? = nil
    ) {
        self.signer = signer
        self.clock = clock
        self.audit = audit
    }

    public func setAudit(_ sink: (any AssistantAuditWriting)?) {
        audit = sink
    }

    // MARK: - Proposing

    /// Creates a proposal bound to exactly the four fields the receipt signs.
    /// The caller is responsible for computing `digest` over the content that will
    /// be executed; the executor recomputes it and compares.
    public func propose(
        kind: AssistantActionKind,
        target: String,
        digest: String,
        title: String,
        detail: String = "",
        ttl: TimeInterval = AssistantApprovalGate.defaultLifetime,
        now: Date? = nil
    ) async throws -> AssistantApprovalTicket {
        let moment = now ?? clock.now
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDigest = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanTarget.isEmpty, cleanTarget.count <= 320 else {
            throw AssistantGateError.invalidRequest("target")
        }
        guard cleanDigest.count >= 32, cleanDigest.count <= 128 else {
            throw AssistantGateError.invalidRequest("digest")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantGateError.invalidRequest("title")
        }
        expirePending(now: moment)
        guard pendingCount(now: moment) < Self.maximumPending else {
            throw AssistantGateError.queueFull
        }

        let id = UUID().uuidString
        let lifetime = min(max(ttl, 30), 7_200)
        let binding = AssistantApprovalBinding(
            kind: kind,
            target: cleanTarget,
            digest: cleanDigest,
            expiresAt: moment.addingTimeInterval(lifetime)
        )
        let receipt = signer.receipt(id: id, binding: binding)
        let entry = Entry(
            id: id,
            binding: binding,
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
            detail: String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
            receipt: receipt,
            state: .pendingUserApproval,
            createdAt: moment,
            resolvedAt: nil,
            consumed: false,
            executionDetail: ""
        )
        entries[id] = entry
        order.append(id)
        trimTerminal()
        await record(
            channel: "gate",
            event: "proposed",
            detail: "\(kind.rawValue) · \(cleanTarget) · \(cleanDigest.prefix(12)) · ttl \(Int(lifetime))s",
            outcome: "pending",
            at: moment
        )
        return AssistantApprovalTicket(
            proposalID: id,
            receipt: receipt,
            binding: binding,
            card: card(entry, now: moment)
        )
    }

    /// The receipt for the console's own click. The console route is authorized by
    /// the loopback bearer and acts on one specific id; minting here keeps the
    /// capability out of every poll payload.
    public func receipt(id: String, now: Date? = nil) -> String? {
        let moment = now ?? clock.now
        expirePending(now: moment)
        guard let entry = entries[id], entry.state == .pendingUserApproval, moment < entry.binding.expiresAt else {
            return nil
        }
        return entry.receipt
    }

    /// The ticket a phone card carries. Same capability as `receipt(id:)`, plus the
    /// binding so the card can show what will be executed.
    public func ticket(id: String, now: Date? = nil) -> AssistantApprovalTicket? {
        let moment = now ?? clock.now
        expirePending(now: moment)
        guard let entry = entries[id], entry.state == .pendingUserApproval else { return nil }
        return AssistantApprovalTicket(
            proposalID: entry.id,
            receipt: entry.receipt,
            binding: entry.binding,
            card: card(entry, now: moment)
        )
    }

    // MARK: - Approving / rejecting

    /// Applies the owner's click. Approving does **not** execute anything by
    /// itself; the caller dispatches to the executor, which must call
    /// `validateExecution` before doing I/O.
    @discardableResult
    public func decide(
        id: String,
        verb: String,
        receipt candidate: String,
        now: Date? = nil
    ) async throws -> AssistantProposalState {
        let moment = now ?? clock.now
        expirePending(now: moment)
        guard let entry = entries[id] else { throw AssistantGateError.unknownProposal }
        guard entry.state == .pendingUserApproval else { throw AssistantGateError.notPending }
        guard moment < entry.binding.expiresAt else {
            expire(id: id, now: moment)
            throw AssistantGateError.expired
        }
        guard signer.validate(candidate, id: id, binding: entry.binding) else {
            await record(channel: "gate", event: "receipt_refused", detail: "id \(id.prefix(8))", outcome: "refused", at: moment)
            throw AssistantGateError.receiptInvalid
        }
        let clean = verb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean == "approve" || clean == "reject" else {
            throw AssistantGateError.invalidRequest("verb")
        }
        var updated = entry
        updated.state = clean == "approve" ? .approved : .rejected
        updated.resolvedAt = moment
        entries[id] = updated
        await record(
            channel: "gate",
            event: clean == "approve" ? "approved" : "rejected",
            detail: "\(updated.binding.kind.rawValue) · \(updated.binding.target)",
            outcome: clean == "approve" ? "approved" : "rejected",
            at: moment
        )
        return updated.state
    }

    // MARK: - Executor check

    /// **The execution-layer gate.** Called at the entry of every assistant write,
    /// before the transport is opened. It refuses a pending, rejected, executed,
    /// expired, re-used or re-bound action. On success it marks the proposal
    /// consumed so a receipt cannot authorize a second write.
    @discardableResult
    public func validateExecution(
        id: String,
        receipt candidate: String,
        kind: AssistantActionKind,
        target: String,
        digest: String,
        now: Date? = nil
    ) async throws -> AssistantExecutionAuthorization {
        let moment = now ?? clock.now
        guard let entry = entries[id] else { throw AssistantGateError.unknownProposal }
        if entry.consumed || entry.state == .executed || entry.state == .executionFailed {
            throw AssistantGateError.alreadyExecuted
        }
        switch entry.state {
        case .pendingUserApproval: throw AssistantGateError.notApproved
        case .rejected: throw AssistantGateError.rejected
        case .expired: throw AssistantGateError.expired
        case .approved: break
        case .executed, .executionFailed: throw AssistantGateError.alreadyExecuted
        }
        guard moment < entry.binding.expiresAt else {
            expire(id: id, now: moment)
            throw AssistantGateError.expired
        }
        guard signer.validate(candidate, id: id, binding: entry.binding) else {
            await record(channel: "gate", event: "receipt_refused", detail: "id \(id.prefix(8))", outcome: "refused", at: moment)
            throw AssistantGateError.receiptInvalid
        }
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDigest = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entry.binding.kind != kind { throw AssistantGateError.bindingMismatch("kind") }
        if entry.binding.target != cleanTarget { throw AssistantGateError.bindingMismatch("target") }
        if entry.binding.digest != cleanDigest {
            await record(
                channel: "gate",
                event: "binding_refused",
                detail: "\(kind.rawValue) · \(cleanTarget) · digest changed",
                outcome: "refused",
                at: moment
            )
            throw AssistantGateError.bindingMismatch("digest")
        }
        var updated = entry
        updated.consumed = true
        entries[id] = updated
        await record(
            channel: "gate",
            event: "execution_authorized",
            detail: "\(kind.rawValue) · \(cleanTarget) · \(cleanDigest.prefix(12))",
            outcome: "authorized",
            at: moment
        )
        return AssistantExecutionAuthorization(
            proposalID: id,
            kind: kind,
            target: cleanTarget,
            digest: cleanDigest,
            notAfter: entry.binding.expiresAt
        )
    }

    /// Records the outcome after the executor has performed (or failed) the write.
    /// This does not change whether the receipt is valid: it is already consumed.
    public func complete(id: String, ok: Bool, detail: String = "", now: Date? = nil) async {
        let moment = now ?? clock.now
        guard var entry = entries[id] else { return }
        entry.state = ok ? .executed : .executionFailed
        entry.resolvedAt = moment
        entry.executionDetail = AssistantRedaction.scrub(detail)
        entries[id] = entry
        await record(
            channel: "gate",
            event: ok ? "executed" : "execution_failed",
            detail: "\(entry.binding.kind.rawValue) · \(entry.binding.target) · \(detail)",
            outcome: ok ? "ok" : "failed",
            at: moment
        )
    }

    // MARK: - Queue

    public func pending(now: Date? = nil) -> [AssistantProposalCard] {
        let moment = now ?? clock.now
        expirePending(now: moment)
        return order.reversed().compactMap { id -> AssistantProposalCard? in
            guard let entry = entries[id], entry.state == .pendingUserApproval else { return nil }
            return card(entry, now: moment)
        }
    }

    public func card(id: String, now: Date? = nil) -> AssistantProposalCard? {
        let moment = now ?? clock.now
        guard let entry = entries[id] else { return nil }
        return card(entry, now: moment)
    }

    public func binding(id: String) -> AssistantApprovalBinding? {
        entries[id]?.binding
    }

    public func state(id: String, now: Date? = nil) -> AssistantProposalState? {
        expirePending(now: now ?? clock.now)
        return entries[id]?.state
    }

    public func hasPending(kind: AssistantActionKind, target: String, now: Date? = nil) -> Bool {
        let moment = now ?? clock.now
        expirePending(now: moment)
        return entries.values.contains {
            $0.state == .pendingUserApproval && $0.binding.kind == kind && $0.binding.target == target
        }
    }

    /// Invalidates everything still writable. Called when the assistant is switched
    /// off or reconfigured: a capability minted under the old configuration must
    /// not survive it.
    @discardableResult
    public func cancelPending(reason: String, now: Date? = nil) -> Int {
        let moment = now ?? clock.now
        var cancelled = 0
        for (id, entry) in entries where entry.state == .pendingUserApproval || (entry.state == .approved && !entry.consumed) {
            var updated = entry
            updated.state = .rejected
            updated.resolvedAt = moment
            updated.executionDetail = "cancelled: \(reason)"
            entries[id] = updated
            cancelled += 1
        }
        if cancelled > 0 {
            Task { await self.record(channel: "gate", event: "cancelled", detail: reason, outcome: "rejected", at: moment) }
        }
        trimTerminal()
        return cancelled
    }

    public var pendingLimit: Int { Self.maximumPending }

    // MARK: - Internals

    private func pendingCount(now: Date) -> Int {
        entries.values.filter { $0.state == .pendingUserApproval && now < $0.binding.expiresAt }.count
    }

    private func expirePending(now: Date) {
        for (id, entry) in entries where entry.state == .pendingUserApproval && now >= entry.binding.expiresAt {
            expire(id: id, now: now)
        }
    }

    private func expire(id: String, now: Date) {
        guard var entry = entries[id], entry.state == .pendingUserApproval else { return }
        entry.state = .expired
        entry.resolvedAt = now
        entries[id] = entry
        Task {
            await self.record(
                channel: "gate",
                event: "expired",
                detail: "\(entry.binding.kind.rawValue) · \(entry.binding.target)",
                outcome: "expired",
                at: now
            )
        }
    }

    private func card(_ entry: Entry, now: Date) -> AssistantProposalCard {
        let left = max(0, Int(entry.binding.expiresAt.timeIntervalSince(now).rounded(.up)))
        return AssistantProposalCard(
            id: entry.id,
            kind: entry.binding.kind,
            title: entry.title,
            detail: entry.detail,
            target: entry.binding.target,
            digest: entry.binding.digest,
            state: entry.state,
            createdAt: entry.createdAt,
            expiresAt: entry.binding.expiresAt,
            secondsLeft: left,
            canApprove: entry.state == .pendingUserApproval && left > 0
        )
    }

    /// Keeps the in-memory history bounded. Pending entries are never dropped.
    private func trimTerminal() {
        let terminal = order.filter {
            guard let entry = entries[$0] else { return true }
            return !entry.state.isPending && entry.state != .approved
        }
        let excess = max(0, terminal.count - Self.terminalRetention)
        guard excess > 0 else { return }
        let doomed = Set(terminal.prefix(excess))
        for id in doomed { entries.removeValue(forKey: id) }
        order.removeAll { doomed.contains($0) }
    }

    private func record(channel: String, event: String, detail: String, outcome: String, at: Date) async {
        guard let audit else { return }
        await audit.record(AssistantAuditRow(at: at, channel: channel, event: event, detail: detail, outcome: outcome))
    }
}
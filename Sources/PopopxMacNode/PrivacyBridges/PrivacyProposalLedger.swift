import Foundation
import CryptoKit

// MARK: - Stamps

/// Timestamps as the tool contract spells them.
///
/// Everything that crosses the loopback boundary is UTC with second precision and
/// a `Z`. An offset inside a JSON field invites the reader to assume the wrong
/// zone, and the responses already carry an explicit `timezone` for display, so
/// there is nothing for a local offset to communicate that UTC does not.
public enum PrivacyStamp {
    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        Date.ppxFromISO8601(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `2026-11-27 09:00` in the caller's zone — the human-readable half of a card.
    public static func display(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Proposal model

public enum PrivacyDomain: String, Codable, Sendable, CaseIterable {
    case calendar
    case workspace
}

public enum PrivacyProposalAction: String, Codable, Sendable, CaseIterable {
    case create
    case reschedule
    case cancel
    case write
    case organize
}

/// The human-in-the-loop states. There is no separate `approved` state on purpose:
/// approval *is* the execution attempt, so a proposal can never sit in a
/// half-authorized limbo where a second caller believes it is still pending.
public enum PrivacyProposalState: String, Codable, Sendable, CaseIterable {
    case pendingUserApproval = "pending_user_approval"
    case executed
    case executionFailed = "execution_failed"
    case rejected
    case expired
}

public struct PrivacyProposal: Sendable, Equatable {
    public let id: String
    public var domain: PrivacyDomain
    public var action: PrivacyProposalAction
    public var state: PrivacyProposalState
    public var createdAt: Date
    public var expiresAt: Date
    public var resolvedAt: Date?
    /// Which entry point asked for it, so the audit trail can answer "who wanted
    /// this write" without naming a user.
    public var source: String
    public var title: String
    public var detail: String
    /// The ledgered booking a reschedule or cancel targets. Empty for a create.
    public var bookingRef: String
    /// Set once a create has been written: the `EKEvent` identifier.
    public var eventIdentifier: String
    /// The ICS UID, minted at proposal time and reused by every later
    /// reschedule/cancel of the same booking, which is what makes `SEQUENCE`
    /// mean anything.
    public var uid: String
    public var sequence: Int
    public var draft: CalendarEventDraft?
    public var file: WorkspaceFilePayload?
    public var lastMessage: String

    public init(
        id: String = "ppx-pr-" + TextKit.randomToken(bytes: 6),
        domain: PrivacyDomain,
        action: PrivacyProposalAction,
        state: PrivacyProposalState = .pendingUserApproval,
        createdAt: Date = Date(),
        lifetime: TimeInterval = NodeWire.proposalLifetime,
        resolvedAt: Date? = nil,
        source: String = "console",
        title: String = "",
        detail: String = "",
        bookingRef: String = "",
        eventIdentifier: String = "",
        uid: String = "",
        sequence: Int = 0,
        draft: CalendarEventDraft? = nil,
        file: WorkspaceFilePayload? = nil,
        lastMessage: String = ""
    ) {
        self.id = id
        self.domain = domain
        self.action = action
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
        self.resolvedAt = resolvedAt
        self.source = source
        self.title = title
        self.detail = detail
        self.bookingRef = bookingRef
        self.eventIdentifier = eventIdentifier
        self.uid = uid
        self.sequence = sequence
        self.draft = draft
        self.file = file
        self.lastMessage = lastMessage
    }

    public func secondsLeft(at now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now)))
    }

    public var isPending: Bool { state == .pendingUserApproval }

    public func isLive(at now: Date) -> Bool {
        state == .pendingUserApproval && now < expiresAt
    }
}

/// A booking this node wrote into the calendar, and the only thing the node is
/// allowed to name in a reschedule or cancel proposal.
public struct PrivacyBooking: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case active
        case cancelled
    }

    public var ref: String
    public var eventIdentifier: String
    public var uid: String
    public var summary: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var location: String
    public var notes: String
    public var url: String
    public var sequence: Int
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        ref: String,
        eventIdentifier: String,
        uid: String,
        summary: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        location: String = "",
        notes: String = "",
        url: String = "",
        sequence: Int = 0,
        status: Status = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.ref = ref
        self.eventIdentifier = eventIdentifier
        self.uid = uid
        self.summary = summary
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.url = url
        self.sequence = sequence
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One audit row: what was asked, through which entry point, and what became of
/// it. Never calendar text, because this log is the artifact an owner pastes into
/// a support thread.
public struct PrivacyAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var domain: String
    public var action: String
    public var outcome: String
    public var detail: String

    public init(
        at: Date = Date(),
        domain: String,
        action: String,
        outcome: String,
        detail: String = ""
    ) {
        self.at = at
        self.domain = domain
        self.action = action
        self.outcome = outcome
        self.detail = detail
    }
}

// MARK: - Execution seam

public struct PrivacyExecution: Sendable, Equatable {
    public var ok: Bool
    /// The event identifier, or the path that was written.
    public var identifier: String
    public var message: String

    public init(ok: Bool, identifier: String = "", message: String) {
        self.ok = ok
        self.identifier = identifier
        self.message = message
    }

    public static func succeeded(_ identifier: String, _ message: String) -> PrivacyExecution {
        PrivacyExecution(ok: true, identifier: identifier, message: message)
    }

    public static func failed(_ message: String) -> PrivacyExecution {
        PrivacyExecution(ok: false, identifier: "", message: message)
    }
}

/// Applies an already-approved proposal.
///
/// The ledger never writes to EventKit or to disk itself; it decides *whether* a
/// write is authorized and then hands the proposal to an executor. That separation
/// is what makes the strongest test in this feature cheap to state: a fake
/// executor records its calls, and a test asserts the record is empty until an
/// approval arrives.
public protocol ProposalExecutor: Sendable {
    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution
}

/// A notifier that does nothing — the value used by tests and by any host without
/// a bundle identifier, where `UNUserNotificationCenter.current()` is unavailable
/// rather than merely inconvenient.
public struct SilentProposalNotifier: ProposalNotifier {
    public init() {}
    public func announce(_ proposal: PrivacyProposal) async {}
}

public protocol ProposalNotifier: Sendable {
    func announce(_ proposal: PrivacyProposal) async
}

// MARK: - Approval receipts

/// Signs and checks the one-line receipt that turns a 「批准」 click into a write.
///
/// Two entry points can approve a proposal — the console button and a signed card
/// reply from a paired phone — and both must be unable to approve *another*
/// proposal with the token they were given. Binding the HMAC to `id + verb` is what
/// makes the token self-limiting; `Digest.matches` keeps the comparison
/// constant-time so a loopback caller cannot probe it byte by byte.
public struct PrivacyApprovalSigner: Sendable {
    public static let receiptLength = 24

    public let key: Data

    public init(key: Data) {
        self.key = key
    }

    /// Loads the durable key, creating it on first use. Losing the key only costs
    /// the receipts of proposals that were still pending, which expire anyway.
    public static func loadOrCreate(at url: URL) -> PrivacyApprovalSigner {
        let data = (try? Data(contentsOf: url)) ?? Data()
        if data.count >= 16 { return PrivacyApprovalSigner(key: data) }
        let fresh = PrivacyApprovalSigner(key: randomKey())
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 0600: the key signs local write authorizations, so it must not be readable
        // by another user on a shared Mac.
        try? fresh.key.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return fresh
    }

    static func randomKey() -> Data {
        var buffer = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) != errSecSuccess {
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255) }
        }
        return Data(buffer)
    }

    public func receipt(id: String, verb: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(id)|\(verb)".utf8),
            using: SymmetricKey(data: key)
        )
        return String(TextKit.base64URL(Data(mac)).prefix(Self.receiptLength))
    }

    public func validate(_ candidate: String, id: String, verb: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Digest.matches(trimmed, receipt(id: id, verb: verb))
    }
}

// MARK: - Ledger

/// The proposal state machine: TTL, receipts, the booking ledger, and the audit
/// tail. Nothing in here touches EventKit or the filesystem outside its own file.
///
/// Proposals live in memory only. A restart therefore drops every pending
/// proposal, which is the intended consequence of "never modify the system
/// calendar without a confirmation": an unattended reboot must not leave a
/// writeable authorization lying around. Bookings and the audit log *are*
/// persisted — they describe work that already happened.
public actor PrivacyProposalLedger {
    /// The console shows twenty; more are kept so the log survives a busy session.
    public static let snapshotEntries = 20
    public static let maximumStoredEntries = 200

    public struct PrivacyDecision: Sendable, Equatable {
        public var ok: Bool
        public var proposal: PrivacyProposal?
        public var message: String
        public var eventIdentifier: String

        public init(ok: Bool, proposal: PrivacyProposal? = nil, message: String, eventIdentifier: String = "") {
            self.ok = ok
            self.proposal = proposal
            self.message = message
            self.eventIdentifier = eventIdentifier
        }
    }

    private struct Document: Codable {
        var schemaRevision: Int = 1
        var bookings: [PrivacyBooking] = []
        var audit: [PrivacyAuditEntry] = []
    }

    private var proposals: [String: PrivacyProposal] = [:]
    private var order: [String] = []
    private var bookings: [String: PrivacyBooking] = [:]
    private var audit: [PrivacyAuditEntry] = []
    private let signer: PrivacyApprovalSigner
    private let executor: any ProposalExecutor
    private let notifier: any ProposalNotifier
    private let fileURL: URL?
    private var notificationsEnabled = true

    public init(
        signer: PrivacyApprovalSigner,
        executor: any ProposalExecutor,
        notifier: any ProposalNotifier = SilentProposalNotifier(),
        fileURL: URL? = nil,
        loadFromDisk: Bool = true
    ) {
        self.signer = signer
        self.executor = executor
        self.notifier = notifier
        self.fileURL = fileURL
        if loadFromDisk, let fileURL, let data = try? Data(contentsOf: fileURL),
           let document = NodeJSON.decode(Document.self, from: data) {
            self.bookings = Dictionary(uniqueKeysWithValues: document.bookings.map { ($0.ref, $0) })
            self.audit = document.audit
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    // MARK: Proposals

    /// Registers a proposal as pending and reminds the owner. Returns the proposal
    /// with its receipt attached — the caller (console or phone) needs the receipt
    /// to approve it, and it is never written to the audit log.
    public func propose(_ proposal: PrivacyProposal) -> PrivacyProposal {
        var stored = proposal
        if stored.uid.isEmpty {
            stored.uid = "ppx-\(stored.id)@node.popopx.local"
        }
        if stored.bookingRef.isEmpty, stored.action == .create {
            stored.bookingRef = "ppx-bk-" + TextKit.randomToken(bytes: 5)
        }
        proposals[stored.id] = stored
        order.append(stored.id)
        // Proposals are in memory only, so the map cannot grow without bound while
        // a long-lived node is left unattended.
        trimProposals(keeping: 40)
        record(PrivacyAuditEntry(
            domain: stored.domain.rawValue,
            action: stored.action.rawValue,
            outcome: "proposed",
            detail: "ref \(stored.bookingRef)"
        ))
        Task { [notifier, notificationsEnabled] in
            if notificationsEnabled { await notifier.announce(stored) }
        }
        return stored
    }

    public func receipt(id: String, verb: String) -> String {
        signer.receipt(id: id, verb: verb)
    }

    public func proposal(id: String) -> PrivacyProposal? {
        proposals[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Prunes everything past its TTL and returns the still-approvable proposals,
    /// oldest first.
    public func pending(now: Date = Date()) -> [PrivacyProposal] {
        expire(now: now)
        return order.compactMap { proposals[$0] }.filter { $0.isPending }
    }

    public func expire(now: Date = Date()) {
        for (id, proposal) in proposals where proposal.isPending && now >= proposal.expiresAt {
            var expired = proposal
            expired.state = .expired
            expired.resolvedAt = now
            proposals[id] = expired
            record(PrivacyAuditEntry(
                at: now,
                domain: expired.domain.rawValue,
                action: expired.action.rawValue,
                outcome: "expired",
                detail: "ref \(expired.bookingRef)"
            ))
        }
        persist()
    }

    // MARK: Decisions

    public func approve(id: String, receipt: String, now: Date = Date()) async -> PrivacyDecision {
        await decide(id: id, verb: "approve", receipt: receipt, now: now)
    }

    public func reject(id: String, receipt: String, now: Date = Date()) async -> PrivacyDecision {
        await decide(id: id, verb: "reject", receipt: receipt, now: now)
    }

    /// The single gate in front of every write.
    ///
    /// Order matters and is the security argument: identity (does this proposal
    /// exist), then liveness (has it expired), then the signature, then the
    /// executor. A caller that reaches the executor has presented a receipt this
    /// process minted for exactly this proposal id and exactly this verb.
    public func decide(id: String, verb: String, receipt: String, now: Date = Date()) async -> PrivacyDecision {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var proposal = proposals[key] else {
            record(PrivacyAuditEntry(at: now, domain: "unknown", action: verb, outcome: "unknown_proposal"))
            return PrivacyDecision(ok: false, message: "提案不存在，或已随节点重启失效 / proposal is unknown or was lost with a restart")
        }
        guard proposal.isPending else {
            return PrivacyDecision(
                ok: false,
                proposal: proposal,
                message: "提案已是 \(proposal.state.rawValue) 状态，不能重复处理 / proposal already \(proposal.state.rawValue)",
                eventIdentifier: proposal.eventIdentifier
            )
        }
        if now >= proposal.expiresAt {
            proposal.state = .expired
            proposal.resolvedAt = now
            proposals[key] = proposal
            record(PrivacyAuditEntry(
                at: now, domain: proposal.domain.rawValue, action: proposal.action.rawValue,
                outcome: "expired", detail: "ref \(proposal.bookingRef)"
            ))
            persist()
            return PrivacyDecision(ok: false, proposal: proposal, message: "提案已过期（15 分钟）/ proposal expired")
        }
        guard signer.validate(receipt, id: key, verb: verb) else {
            // Recorded, because a rejected receipt on a live proposal is the event a
            // owner wants to see in the audit tail.
            record(PrivacyAuditEntry(
                at: now, domain: proposal.domain.rawValue, action: verb,
                outcome: "receipt_rejected", detail: "ref \(proposal.bookingRef)"
            ))
            persist()
            return PrivacyDecision(ok: false, message: "批准令牌无效 / approval receipt rejected")
        }

        if verb == "reject" {
            proposal.state = .rejected
            proposal.resolvedAt = now
            proposal.lastMessage = "已拒绝，系统日历与文件未发生任何改动 / rejected; nothing was written"
            proposals[key] = proposal
            record(PrivacyAuditEntry(
                at: now, domain: proposal.domain.rawValue, action: proposal.action.rawValue,
                outcome: "rejected", detail: "ref \(proposal.bookingRef)"
            ))
            persist()
            return PrivacyDecision(ok: true, proposal: proposal, message: proposal.lastMessage)
        }

        let execution = await executor.execute(proposal)
        proposal.resolvedAt = now
        proposal.lastMessage = execution.message
        if execution.ok {
            proposal.state = .executed
            if !execution.identifier.isEmpty, proposal.action == .create {
                proposal.eventIdentifier = execution.identifier
            }
            applyExecutedBooking(&proposal, execution: execution, at: now)
        } else {
            // Executable again after the owner fixes the cause (grant the
            // permission, authorize the directory); the receipt is bound to this id
            // so retrying cannot authorize anything else.
            proposal.state = .executionFailed
        }
        proposals[key] = proposal
        record(PrivacyAuditEntry(
            at: now,
            domain: proposal.domain.rawValue,
            action: proposal.action.rawValue,
            outcome: execution.ok ? "executed" : "execution_failed",
            detail: "ref \(proposal.bookingRef)"
        ))
        persist()
        return PrivacyDecision(
            ok: execution.ok,
            proposal: proposal,
            message: execution.message,
            eventIdentifier: proposal.eventIdentifier
        )
    }

    /// Moves the booking record to its post-execution state. The calendar actions
    /// are the only ones that own a booking.
    private func applyExecutedBooking(_ proposal: inout PrivacyProposal, execution: PrivacyExecution, at now: Date) {
        guard proposal.domain == .calendar else { return }
        switch proposal.action {
        case .create:
            let draft = proposal.draft
            let booking = PrivacyBooking(
                ref: proposal.bookingRef,
                eventIdentifier: execution.identifier,
                uid: proposal.uid,
                summary: draft?.summary ?? proposal.title,
                start: draft?.start ?? now,
                end: draft?.end ?? now,
                timeZoneIdentifier: draft?.timeZoneIdentifier ?? TimeZone.current.identifier,
                location: draft?.location ?? "",
                notes: draft?.notes ?? "",
                url: draft?.url ?? "",
                sequence: proposal.sequence,
                createdAt: now,
                updatedAt: now
            )
            bookings[booking.ref] = booking
        case .reschedule:
            guard var booking = bookings[proposal.bookingRef] else { return }
            booking.sequence = proposal.sequence
            booking.eventIdentifier = execution.identifier.isEmpty ? booking.eventIdentifier : execution.identifier
            if let draft = proposal.draft {
                booking.start = draft.start
                booking.end = draft.end
                booking.timeZoneIdentifier = draft.timeZoneIdentifier
            }
            booking.status = .active
            booking.updatedAt = now
            bookings[booking.ref] = booking
        case .cancel:
            guard var booking = bookings[proposal.bookingRef] else { return }
            booking.sequence = proposal.sequence
            booking.status = .cancelled
            booking.updatedAt = now
            bookings[booking.ref] = booking
        case .write, .organize:
            break
        }
    }

    // MARK: Bookings

    public func booking(ref: String) -> PrivacyBooking? {
        bookings[ref.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public func activeBookings(now: Date = Date()) -> [PrivacyBooking] {
        bookings.values
            .filter { $0.status == .active }
            .sorted { $0.start < $1.start }
    }

    public func allBookings() -> [PrivacyBooking] {
        bookings.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Audit and snapshot

    public func record(_ entry: PrivacyAuditEntry) {
        audit.append(entry)
        if audit.count > Self.maximumStoredEntries {
            audit.removeFirst(audit.count - Self.maximumStoredEntries)
        }
    }

    /// Newest first, capped at what the panel renders.
    public func auditLog(limit: Int = PrivacyProposalLedger.snapshotEntries) -> [PrivacyAuditEntry] {
        Array(audit.suffix(max(1, limit)).reversed())
    }

    public func pendingCards(now: Date = Date()) -> [PrivacyProposalCard] {
        pending(now: now).map { proposal in
            PrivacyProposalCard(
                id: proposal.id,
                domain: proposal.domain.rawValue,
                action: proposal.action.rawValue,
                title: proposal.title,
                detail: proposal.detail,
                startISO: PrivacyStamp.iso(proposal.draft?.start ?? proposal.expiresAt),
                endISO: PrivacyStamp.iso(proposal.draft?.end ?? proposal.expiresAt),
                bookingRef: proposal.bookingRef,
                path: AppPaths.anonymise(proposal.file?.path ?? ""),
                state: proposal.state.rawValue,
                expiresISO: PrivacyStamp.iso(proposal.expiresAt),
                secondsLeft: proposal.secondsLeft(at: now),
                canApprove: proposal.isLive(at: now)
            )
        }
    }

    public func bookingCards() -> [PrivacyBookingCard] {
        activeBookings().map { booking in
            PrivacyBookingCard(
                ref: booking.ref,
                action: booking.status.rawValue,
                title: booking.summary,
                startISO: PrivacyStamp.iso(booking.start),
                endISO: PrivacyStamp.iso(booking.end),
                sequence: booking.sequence
            )
        }
    }

    public func auditRows() -> [PrivacyAuditRow] {
        auditLog().map { entry in
            PrivacyAuditRow(
                at: PrivacyStamp.iso(entry.at),
                domain: entry.domain,
                action: entry.action,
                outcome: entry.outcome,
                detail: entry.detail
            )
        }
    }

    private func trimProposals(keeping limit: Int) {
        guard order.count > limit else { return }
        let drop = order.count - limit
        for id in order.prefix(drop) { proposals[id] = nil }
        order.removeFirst(drop)
    }

    /// Clears every proposal and returns how many were dropped. Used when the owner
    /// turns a bridge off: a proposal that can no longer be honored must not stay
    /// approvable.
    @discardableResult
    public func cancelPendingProposals(domain: PrivacyDomain? = nil, reason: String = "") -> Int {
        var dropped = 0
        for (id, proposal) in proposals where proposal.isPending {
            guard domain == nil || domain == proposal.domain else { continue }
            var closed = proposal
            closed.state = .rejected
            closed.resolvedAt = Date()
            closed.lastMessage = reason.isEmpty ? "桥接已关闭，提案作废 / bridge switched off, proposal voided" : reason
            proposals[id] = closed
            record(PrivacyAuditEntry(
                domain: closed.domain.rawValue, action: closed.action.rawValue,
                outcome: "voided", detail: "ref \(closed.bookingRef)"
            ))
            dropped += 1
        }
        persist()
        return dropped
    }

    public func clearAll() {
        proposals.removeAll()
        order.removeAll()
        bookings.removeAll()
        audit.removeAll()
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let document = Document(
            bookings: bookings.values.sorted { $0.updatedAt > $1.updatedAt },
            audit: audit
        )
        guard let data = NodeJSON.encodeLine(document) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

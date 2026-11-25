import Foundation

// MARK: - Tool surface
//
// One dispatch table, two entry points. `POST /v1/tools/{domain}/{action}` on the
// loopback console serves Bot Studio; the same domain and action names arrive over
// the paired-phone encrypted command channel as
// `::popopx_sys::NODE_CMD::{domain}::{action}::{json}`. Both land in `handle(_:)`,
// so a capability can never be reachable from one entry point and hidden from the
// other, and the authorization switches are enforced in exactly one place.

/// A tool namespace, spelled identically in the HTTP path and in the command channel.
public enum PrivacyToolNamespace: String, Codable, Sendable, CaseIterable {
    case calendar
    case workspace

    public var domain: PrivacyDomain {
        switch self {
        case .calendar: return .calendar
        case .workspace: return .workspace
        }
    }
}

public enum PrivacyToolAction {
    public static let availability = "availability"
    public static let proposals = "proposals"
    public static let approve = "approve"
    public static let reject = "reject"
    public static let inspect = "inspect"
    public static let summarize = "summarize"
    public static let bookings = "bookings"

    /// Actions addressed by a proposal id.
    public static let idBearing = [approve, reject, inspect]
    /// Every action either entry point may use, so a phone cannot reach an endpoint
    /// the HTTP layer does not already have.
    public static let all = [availability, proposals, approve, reject, inspect, summarize, bookings]
}

public struct PrivacyToolCall: Sendable, Equatable {
    public var namespace: PrivacyToolNamespace
    public var action: String
    /// Proposal id, when the action is addressed by one.
    public var id: String
    public var payload: [String: JSONValue]
    /// Which entry point asked. Recorded in the audit trail; never a user name.
    public var source: String

    public init(
        namespace: PrivacyToolNamespace,
        action: String,
        id: String = "",
        payload: [String: JSONValue] = [:],
        source: String = "bot-studio"
    ) {
        self.namespace = namespace
        self.action = action
        self.id = id
        self.payload = payload
        self.source = source
    }
}

public struct PrivacyToolResponse: Sendable, Equatable {
    public var ok: Bool
    /// HTTP status for the loopback side. The command channel reads `ok` and ignores
    /// this, which is why the two are always set together.
    public var status: Int
    public var fields: [String: JSONValue]

    public init(ok: Bool, status: Int = 200, fields: [String: JSONValue] = [:]) {
        self.ok = ok
        self.status = status
        self.fields = fields
    }

    public var body: String { JSONValue.object(fields).serialized() }

    public static func failure(_ status: Int, _ reason: String, extra: [String: JSONValue] = [:]) -> PrivacyToolResponse {
        var fields = extra
        fields["ok"] = .bool(false)
        fields["refusal"] = .string(reason)
        return PrivacyToolResponse(ok: false, status: status, fields: fields)
    }

    /// Where the guarantee is written down once instead of in every handler: a tool
    /// response carries no calendar text, and no tool response leaves the Mac.
    public static func redactionFields() -> [String: JSONValue] {
        [
            "redaction": .string("原始日程文本在生成本响应前已丢弃 / titles, locations, attendees and notes were discarded before this response"),
            "egress": .string("仅回环 / loopback only (127.0.0.1)")
        ]
    }
}

// MARK: - Routing

/// Turns a path or a command-channel triple into one call shape.
public enum PrivacyToolRoute {
    /// Rejects anything that is not a ledger-shaped id, so a path like
    /// `/v1/tools/calendar/proposals/../../etc/approve` cannot reach the ledger.
    /// The empty string is refused too: `allSatisfy` is vacuously true for it, and an
    /// id-bearing action that names no proposal is a caller that should not reach the
    /// state machine at all.
    static func isSafeId(_ candidate: String) -> Bool {
        !candidate.isEmpty
            && candidate.count <= 64
            && candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// `nil` when the path is not a tool path or names an action that does not exist.
    public static func parse(path: String, source: String = "bot-studio") -> PrivacyToolCall? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.hasPrefix(ConsoleRoute.toolPrefix) else { return nil }
        let pieces = trimmed.dropFirst(ConsoleRoute.toolPrefix.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pieces.count >= 2, let namespace = PrivacyToolNamespace(rawValue: pieces[0]) else { return nil }
        if pieces.count == 4, pieces[1] == PrivacyToolAction.proposals {
            let candidate = pieces[2]
            let verb = pieces[3]
            guard isSafeId(candidate), PrivacyToolAction.idBearing.contains(verb) else { return nil }
            return PrivacyToolCall(namespace: namespace, action: verb, id: candidate, source: source)
        }
        guard pieces.count == 2, PrivacyToolAction.all.contains(pieces[1]) else { return nil }
        return PrivacyToolCall(namespace: namespace, action: pieces[1], source: source)
    }

    /// The command-channel form. An unparsable payload is not a refusal: the action
    /// may legitimately need no arguments.
    public static func parseCommand(serviceId: String, action: String, payload: String) -> PrivacyToolCall? {
        guard let namespace = PrivacyToolNamespace(rawValue: serviceId) else { return nil }
        guard PrivacyToolAction.all.contains(action) else { return nil }
        var fields: [String: JSONValue] = [:]
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // `JSONValue.parse` keeps non-JSON text as a `.string`, which is why an
            // unparsable payload is not a refusal — some actions need no arguments.
            fields = JSONValue.parse(text).objectValue ?? ["raw": .string(String(text.prefix(NodeWire.maxSignalPayloadCharacters)))]
        }
        let id = (fields["proposalId"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if PrivacyToolAction.idBearing.contains(action), !isSafeId(id) { return nil }
        return PrivacyToolCall(namespace: namespace, action: action, id: id, payload: fields, source: "phone")
    }

    /// The command line a paired phone sends back to approve or reject. It rides in
    /// the confirmation card so a client never has to guess a path or mint a token,
    /// and the approval travels the same authenticated channel as the request.
    public static func commandLine(namespace: PrivacyToolNamespace, action: String, id: String, receipt: String) -> String {
        let payload = JSONValue.object([
            "proposalId": .string(id),
            "receipt": .string(receipt)
        ]).serialized()
        return "\(NodeWire.commandPrefix)\(namespace.rawValue)::\(action)::\(payload)"
    }
}

// MARK: - Confirmation card

/// The `::POPOPX_ECO::` dynamic confirmation card payload.
///
/// One marker line plus `key=value` fields separated by `|`, mirroring how
/// `NodeWire` already frames its signals: nothing to escape, and a receiver that has
/// never seen this kind still renders a readable line. The card carries both command
/// lines, so approval is a copy, not a construction.
///
/// Capped at `NodeWire.maxSignalPayloadCharacters`, the ceiling the iOS parser
/// accepts for everything after the marker.
public struct PrivacyCard: Sendable, Equatable {
    public static let marker = "::POPOPX_ECO::"
    public static let version = "v1"

    public var kind: String
    public var action: String
    public var proposalId: String
    public var bookingRef: String
    public var title: String
    public var window: String
    public var expires: String
    public var receipt: String
    public var state: String
    public var approveCommand: String
    public var rejectCommand: String

    public init(
        kind: String,
        action: String,
        proposalId: String,
        bookingRef: String = "",
        title: String = "",
        window: String = "",
        expires: String = "",
        receipt: String = "",
        state: String = PrivacyProposalState.pendingUserApproval.rawValue,
        approveCommand: String = "",
        rejectCommand: String = ""
    ) {
        self.kind = kind
        self.action = action
        self.proposalId = proposalId
        self.bookingRef = bookingRef
        self.title = title
        self.window = window
        self.expires = expires
        self.receipt = receipt
        self.state = state
        self.approveCommand = approveCommand
        self.rejectCommand = rejectCommand
    }

    /// Field order is fixed; a receiver splits on `|` and reads by key.
    public var text: String {
        var fields: [(String, String)] = [
            ("k", kind), ("a", action), ("id", proposalId), ("st", state)
        ]
        if !bookingRef.isEmpty { fields.append(("ref", bookingRef)) }
        if !window.isEmpty { fields.append(("when", window)) }
        if !expires.isEmpty { fields.append(("exp", expires)) }
        if !receipt.isEmpty { fields.append(("rcp", receipt)) }
        var line = Self.marker + Self.version + "|" + fields.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        let suffix = "|approve=" + approveCommand + "|reject=" + rejectCommand
        // The commands are load-bearing: an oversized title is dropped before a
        // command is truncated, because a card that cannot approve anything is noise.
        let budget = NodeWire.maxSignalPayloadCharacters - line.count - suffix.count - 8
        if budget > 8, !title.isEmpty {
            line += "|t=" + String(title.prefix(budget))
        }
        let full = line + suffix
        return full.count <= NodeWire.maxSignalPayloadCharacters
            ? full
            : String(full.prefix(NodeWire.maxSignalPayloadCharacters))
    }
}

// MARK: - Executor

/// Applies approved proposals. Sits behind the ledger's receipt check, so reaching
/// any method here means a click or a signed card already authorized it.
public actor PrivacyExecutorHub: ProposalExecutor {
    private var gateway: any CalendarGateway
    private var sandbox: WorkspaceSandbox

    public init(gateway: any CalendarGateway, sandbox: WorkspaceSandbox) {
        self.gateway = gateway
        self.sandbox = sandbox
    }

    public func update(gateway: any CalendarGateway, sandbox: WorkspaceSandbox) {
        self.gateway = gateway
        self.sandbox = sandbox
    }

    public func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        switch proposal.domain {
        case .calendar:
            return await executeCalendar(proposal)
        case .workspace:
            guard let payload = proposal.file else {
                return .failed("提案缺少文件内容 / the proposal carries no file payload")
            }
            return sandbox.apply(payload)
        }
    }

    private func executeCalendar(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        switch proposal.action {
        case .create:
            guard let draft = proposal.draft else {
                return .failed("提案缺少事件内容 / the proposal carries no event draft")
            }
            let outcome = await gateway.commit(draft)
            if let identifier = outcome.identifier {
                return .succeeded(identifier, "已写入系统日历 / created in the system calendar")
            }
            return .failed(outcome.refusal ?? "写入失败 / the write failed")
        case .reschedule:
            guard !proposal.eventIdentifier.isEmpty else {
                return .failed("缺少系统日历引用 / the booking has no calendar reference")
            }
            guard let draft = proposal.draft else {
                return .failed("提案缺少新时间 / the proposal carries no new window")
            }
            let outcome = await gateway.reschedule(
                identifier: proposal.eventIdentifier,
                start: draft.start,
                end: draft.end
            )
            if let identifier = outcome.identifier {
                return .succeeded(identifier, "已改期 / rescheduled in the system calendar")
            }
            return .failed(outcome.refusal ?? "改期失败 / the update failed")
        case .cancel:
            guard !proposal.eventIdentifier.isEmpty else {
                return .failed("缺少系统日历引用 / the booking has no calendar reference")
            }
            let outcome = await gateway.remove(identifier: proposal.eventIdentifier)
            if outcome.identifier != nil {
                return .succeeded(proposal.eventIdentifier, "已从系统日历移除 / removed from the system calendar")
            }
            return .failed(outcome.refusal ?? "移除失败 / the removal failed")
        default:
            return .failed("不支持的日历动作 / unsupported calendar action")
        }
    }
}

// MARK: - Engine

/// The privacy-bridge tool engine: switches in front, redaction on the way out, and
/// the proposal ledger as the only road to a write.
public actor PrivacyToolEngine {
    /// Short node fingerprint, used only inside call links and UIDs.
    private var nodeReference: String
    private var config: PrivacyBridgeConfig
    private var gateway: any CalendarGateway
    private var sandbox: WorkspaceSandbox
    private let hub: PrivacyExecutorHub
    private let ledger: PrivacyProposalLedger

    public init(
        config: PrivacyBridgeConfig,
        gateway: any CalendarGateway,
        ledger: PrivacyProposalLedger,
        hub: PrivacyExecutorHub,
        sandbox: WorkspaceSandbox,
        nodeReference: String
    ) {
        self.config = config.normalised
        self.gateway = gateway
        self.ledger = ledger
        self.hub = hub
        self.sandbox = sandbox
        self.nodeReference = nodeReference
    }

    /// Settings changed: re-derive the sandbox, hand it to the hub, and void any
    /// pending proposal whose capability was just switched off — a proposal the node
    /// could no longer lawfully honor must not stay approvable.
    public func applyConfig(_ config: PrivacyBridgeConfig, sandbox: WorkspaceSandbox) async {
        let previous = self.config
        self.config = config.normalised
        self.sandbox = sandbox
        await hub.update(gateway: gateway, sandbox: sandbox)
        await ledger.setNotificationsEnabled(self.config.notifyOnProposal)
        if previous.allowCalendarAccess, !self.config.allowCalendarAccess {
            await ledger.cancelPendingProposals(domain: .calendar, reason: "日历桥接已关闭 / calendar bridge switched off")
        }
        if previous.allowWorkspaceWrite, !self.config.allowWorkspaceWrite {
            await ledger.cancelPendingProposals(domain: .workspace, reason: "工作区写入已关闭 / workspace write switched off")
        }
    }

    public func currentConfig() -> PrivacyBridgeConfig { config }
    public func currentSandbox() -> WorkspaceSandbox { sandbox }

    // MARK: Dispatch

    public func handle(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard PrivacyToolAction.all.contains(call.action) else {
            return .failure(404, "未知工具动作 / unknown tool action")
        }
        switch (call.namespace, call.action) {
        case (.calendar, PrivacyToolAction.availability):
            return await availability(call)
        case (.calendar, PrivacyToolAction.proposals):
            return await proposeCalendar(call)
        case (.calendar, PrivacyToolAction.bookings):
            return await bookings()
        case (.workspace, PrivacyToolAction.summarize):
            return await summarize(call)
        case (.workspace, PrivacyToolAction.proposals):
            return await proposeWorkspace(call)
        case (_, PrivacyToolAction.approve):
            return await decide(call, verb: "approve")
        case (_, PrivacyToolAction.reject):
            return await decide(call, verb: "reject")
        case (_, PrivacyToolAction.inspect):
            return await inspect(call)
        default:
            return .failure(405, "该入口不支持此动作 / this action is not available in that namespace")
        }
    }

    // MARK: Calendar — availability

    private func availability(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard config.allowCalendarAccess else {
            return .failure(
                403,
                "日历桥接未开启：请在控制台「隐私授权与协作桥接」中显式授权 / calendar bridge is off; enable it in the Privacy Bridges panel",
                extra: ["switch": .string("allowCalendarAccess")]
            )
        }
        guard let start = PrivacyStamp.parse(call.payload["startIso"]?.stringValue ?? ""),
              let end = PrivacyStamp.parse(call.payload["endIso"]?.stringValue ?? "") else {
            return .failure(400, "startIso 与 endIso 需为 ISO-8601 / startIso and endIso must be ISO-8601")
        }
        let probe = CalendarProbe(
            start: start,
            end: end,
            durationMinutes: call.payload["durationMinutes"]?.intValue ?? config.defaultDurationMinutes,
            timeZoneIdentifier: zone(from: call),
            workingStartHour: call.payload["workingStartHour"]?.intValue ?? config.workingStartHour,
            workingEndHour: call.payload["workingEndHour"]?.intValue ?? config.workingEndHour,
            workdays: call.payload["workdays"]?.arrayValue?.compactMap { $0.intValue } ?? config.workdays,
            blockLunch: call.payload["blockLunch"]?.boolValue ?? config.blockLunch,
            lunchStartHour: call.payload["lunchStartHour"]?.intValue ?? config.lunchStartHour,
            lunchEndHour: call.payload["lunchEndHour"]?.intValue ?? config.lunchEndHour,
            bufferMinutes: call.payload["bufferMinutes"]?.intValue ?? config.bufferMinutes
        )
        let outcome = await gateway.availability(probe)
        guard outcome.ok else {
            let status: Int
            switch outcome.refusal {
            case .deniedBySystem: status = 403
            case .some: status = 503
            case nil: status = 400
            }
            return .failure(
                status,
                outcome.probeRefused ?? "无空闲结果 / the gateway returned nothing",
                extra: [
                    "refusal": .string(outcome.refusal?.rawValue ?? "invalidWindow"),
                    "requested": .object(requested(probe))
                ]
            )
        }
        // The controlled-reference index: only bookings POPOPX minted, and only their
        // status. The owner's other events are represented by aggregate counts alone.
        let index: [JSONValue] = await ledger.activeBookings().map { booking in
            .object([
                "bookingRefId": .string(booking.ref),
                "status": .string(booking.status.rawValue),
                "start": .string(PrivacyStamp.iso(booking.start)),
                "end": .string(PrivacyStamp.iso(booking.end))
            ])
        }
        var fields: [String: JSONValue] = [
            "ok": .bool(true),
            "timezone": .string(probe.timeZoneIdentifier),
            "durationMinutes": .int(probe.durationMinutes),
            "window": .object([
                "start": .string(PrivacyStamp.iso(probe.start)),
                "end": .string(PrivacyStamp.iso(probe.end))
            ]),
            // The response contract, exactly: freeSlots: [{ start, end }].
            "freeSlots": .array(outcome.freeSlots.map { slot in
                .object([
                    "start": .string(PrivacyStamp.iso(slot.start)),
                    "end": .string(PrivacyStamp.iso(slot.end))
                ])
            }),
            "slotCount": .int(outcome.freeSlots.count),
            "busyCount": .int(outcome.busyCount),
            "busyMinutes": .int(outcome.busyMinutes),
            "popopxBookings": .array(index)
        ]
        fields.merge(PrivacyToolResponse.redactionFields()) { current, _ in current }
        await ledger.record(PrivacyAuditEntry(
            domain: PrivacyDomain.calendar.rawValue,
            action: PrivacyToolAction.availability,
            outcome: "answered",
            detail: "\(outcome.freeSlots.count) slots / \(outcome.busyCount) busy"
        ))
        return PrivacyToolResponse(ok: true, fields: fields)
    }

    /// The caller's timezone, falling back to the configured one and then to the
    /// Mac's own zone — never to UTC, which would silently move every working hour.
    func zone(from call: PrivacyToolCall) -> String {
        if let text = call.payload["timezone"]?.stringValue, TimeZone(identifier: text) != nil {
            return text
        }
        return config.timezoneIdentifier.isEmpty ? TimeZone.current.identifier : config.timezoneIdentifier
    }

    func requested(_ probe: CalendarProbe) -> [String: JSONValue] {
        [
            "durationMinutes": .int(probe.durationMinutes),
            "workingStartHour": .int(probe.workingStartHour),
            "workingEndHour": .int(probe.workingEndHour),
            "bufferMinutes": .int(probe.bufferMinutes),
            "blockLunch": .bool(probe.blockLunch)
        ]
    }

    // MARK: Calendar — proposals

    private func proposeCalendar(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard config.allowCalendarAccess else {
            return .failure(403, "日历桥接未开启 / calendar bridge is off", extra: ["switch": .string("allowCalendarAccess")])
        }
        guard let raw = call.payload["action"]?.stringValue?.lowercased(),
              let action = PrivacyProposalAction(rawValue: raw),
              action == .create || action == .reschedule || action == .cancel else {
            return .failure(400, "action 需为 create / reschedule / cancel / action must be create, reschedule or cancel")
        }
        if action == .create { return await proposeCreate(call) }
        return await proposeAgainstBooking(call, action: action)
    }

    private func proposeCreate(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        let summary = (call.payload["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return .failure(400, "缺少 title / missing title") }
        guard let start = PrivacyStamp.parse(call.payload["startIso"]?.stringValue ?? "") else {
            return .failure(400, "startIso 需为 ISO-8601 / startIso must be ISO-8601")
        }
        let zone = zone(from: call)
        let timeZone = TimeZone(identifier: zone) ?? .autoupdatingCurrent
        var end = PrivacyStamp.parse(call.payload["endIso"]?.stringValue ?? "")
        if end == nil, let minutes = call.payload["durationMinutes"]?.intValue ?? Optional(config.defaultDurationMinutes) {
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        }
        guard let finished = end, finished > start else {
            return .failure(400, "需给出 endIso 或 durationMinutes，且结束需晚于开始 / endIso or durationMinutes is required, and the end must follow the start")
        }
        // Minted here rather than in the ledger so the call link and the UID can both
        // carry it.
        let ref = "ppx-bk-" + TextKit.randomToken(bytes: 5)
        let id = "ppx-pr-" + TextKit.randomToken(bytes: 6)
        let link = call.payload["callLink"]?.stringValue ?? callLink(ref: ref, start: start)
        var notes = call.payload["note"]?.stringValue ?? ""
        if !link.isEmpty {
            notes = (notes.isEmpty ? "" : notes + "\n")
                + "POPOPX 端到端加密通话 / POPOPX end-to-end encrypted call: \(link)"
        }
        let location = (call.payload["location"]?.stringValue ?? link).trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = CalendarEventDraft(
            summary: String(summary.prefix(240)),
            start: start,
            end: finished,
            timeZoneIdentifier: zone,
            location: String(location.prefix(240)),
            notes: String(notes.prefix(2_000)),
            url: link.isEmpty ? nil : String(link.prefix(500))
        )
        var proposal = PrivacyProposal(
            id: id,
            domain: .calendar,
            action: .create,
            source: call.source,
            title: draft.summary,
            detail: "将在系统日历中新增 1 条事件 / one event will be written to the system calendar",
            bookingRef: ref,
            uid: "ppx-\(id)@node.popopx.local",
            sequence: 0,
            draft: draft
        )
        proposal = await ledger.propose(proposal)
        return await proposalResponse(
            proposal,
            method: .publish,
            status: 201,
            timeZone: timeZone
        )
    }

    /// Reschedule and cancel both act on a ledgered booking, and both must find it —
    /// in the ledger first, then in the system calendar.
    private func proposeAgainstBooking(_ call: PrivacyToolCall, action: PrivacyProposalAction) async -> PrivacyToolResponse {
        let ref = (call.payload["bookingRefId"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            return .failure(
                400,
                "缺少 bookingRefId：本桥接只操作 POPOPX 创建的预订 / missing bookingRefId; this bridge only addresses POPOPX-created bookings"
            )
        }
        guard let booking = await ledger.booking(ref: ref) else {
            // An id this node never minted is not reported as existing or not
            // existing; it is simply not addressable.
            return .failure(404, "本地受控台账中找不到该预订 / no such POPOPX booking in the local ledger")
        }
        guard await gateway.exists(identifier: booking.eventIdentifier) else {
            return .failure(409, "该预订已不在系统日历中 / the booking is no longer in the system calendar")
        }
        let zone = booking.timeZoneIdentifier
        let timeZone = TimeZone(identifier: zone) ?? .autoupdatingCurrent
        var draft: CalendarEventDraft?
        if action == .reschedule {
            guard let start = PrivacyStamp.parse(call.payload["startIso"]?.stringValue ?? "") else {
                return .failure(400, "reschedule 需要 startIso / reschedule needs startIso")
            }
            let length = booking.end.timeIntervalSince(booking.start)
            let end = PrivacyStamp.parse(call.payload["endIso"]?.stringValue ?? "")
                ?? start.addingTimeInterval(length > 0 ? length : TimeInterval(config.defaultDurationMinutes * 60))
            guard end > start else { return .failure(400, "结束时间需晚于开始时间 / the end must follow the start") }
            draft = CalendarEventDraft(
                summary: booking.summary,
                start: start,
                end: end,
                timeZoneIdentifier: zone,
                location: booking.location,
                notes: booking.notes,
                url: booking.url.isEmpty ? nil : booking.url
            )
        }
        var proposal = PrivacyProposal(
            domain: .calendar,
            action: action,
            source: call.source,
            title: booking.summary,
            detail: action == .reschedule
                ? "将改动 1 条已有事件的时间 / one existing event changes time"
                : "将从系统日历移除 1 条事件 / one event will be removed from the system calendar",
            bookingRef: booking.ref,
            eventIdentifier: booking.eventIdentifier,
            uid: booking.uid,
            sequence: booking.sequence + 1,
            draft: draft
        )
        proposal = await ledger.propose(proposal)
        return await proposalResponse(
            proposal,
            method: action == .cancel ? .cancel : .request,
            status: 201,
            timeZone: timeZone
        )
    }

    /// Empty strings become `nil` so the generator omits the property instead of
    /// emitting an empty one. `String.flatMap` cannot do this — it maps characters.
    static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The RFC 5545 payload, assembled in memory from the proposal. `SEQUENCE` comes
    /// from the ledger, which is what makes a reschedule or cancel legible to a
    /// receiver that already holds the original.
    func ics(for proposal: PrivacyProposal, method: ICSMethod) -> String {
        let event = ICSEvent(
            uid: proposal.uid,
            sequence: proposal.sequence,
            status: proposal.action == .cancel ? .cancelled : .confirmed,
            start: proposal.draft?.start ?? proposal.createdAt,
            end: proposal.draft?.end ?? proposal.createdAt,
            timeZoneIdentifier: proposal.draft?.timeZoneIdentifier ?? config.timezoneIdentifier,
            summary: proposal.draft?.summary ?? proposal.title,
            location: proposal.draft.flatMap { Self.text($0.location) },
            note: proposal.draft.flatMap { Self.text($0.notes) },
            url: proposal.draft?.url,
            bookingReference: proposal.bookingRef,
            created: proposal.createdAt,
            lastModified: proposal.resolvedAt ?? proposal.createdAt
        )
        return ICalendar.document(events: [event], method: method, style: .timeZoneId)
    }

    func callLink(ref: String, start: Date) -> String {
        guard !config.callLinkTemplate.isEmpty else { return "" }
        let compact = PrivacyStamp.iso(start).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        return config.callLinkTemplate
            .replacingOccurrences(of: "{ref}", with: ref)
            .replacingOccurrences(of: "{node}", with: nodeReference)
            .replacingOccurrences(of: "{utc}", with: compact)
    }

    private func proposalResponse(
        _ proposal: PrivacyProposal,
        method: ICSMethod,
        status: Int,
        timeZone: TimeZone
    ) async -> PrivacyToolResponse {
        let approveReceipt = await ledger.receipt(id: proposal.id, verb: "approve")
        let rejectReceipt = await ledger.receipt(id: proposal.id, verb: "reject")
        let namespace = PrivacyToolNamespace(rawValue: proposal.domain.rawValue) ?? .calendar
        let window = proposal.draft.map { draft in
            "\(PrivacyStamp.display(draft.start, timeZone: timeZone)) → \(PrivacyStamp.display(draft.end, timeZone: timeZone))"
        } ?? ""
        let card = PrivacyCard(
            kind: proposal.domain.rawValue,
            action: proposal.action.rawValue,
            proposalId: proposal.id,
            bookingRef: proposal.bookingRef,
            title: proposal.title,
            window: window,
            expires: PrivacyStamp.iso(proposal.expiresAt),
            receipt: approveReceipt,
            state: proposal.state.rawValue,
            approveCommand: PrivacyToolRoute.commandLine(
                namespace: namespace, action: PrivacyToolAction.approve, id: proposal.id, receipt: approveReceipt
            ),
            rejectCommand: PrivacyToolRoute.commandLine(
                namespace: namespace, action: PrivacyToolAction.reject, id: proposal.id, receipt: rejectReceipt
            )
        )
        var fields: [String: JSONValue] = [
            "ok": .bool(true),
            "proposalId": .string(proposal.id),
            "domain": .string(proposal.domain.rawValue),
            "action": .string(proposal.action.rawValue),
            "state": .string(proposal.state.rawValue),
            "requiresUserConfirmation": .bool(true),
            "calendarWritten": .bool(false),
            "fileWritten": .bool(false),
            "createdAt": .string(PrivacyStamp.iso(proposal.createdAt)),
            "expiresAt": .string(PrivacyStamp.iso(proposal.expiresAt)),
            "secondsLeft": .int(proposal.secondsLeft()),
            "bookingRefId": .string(proposal.bookingRef),
            "title": .string(proposal.title),
            "detail": .string(proposal.detail),
            "approvalReceipt": .string(approveReceipt),
            "rejectReceipt": .string(rejectReceipt),
            "approvePath": .string(ConsoleRoute.proposalDecision(proposal.domain.rawValue, id: proposal.id, verb: "approve")),
            "rejectPath": .string(ConsoleRoute.proposalDecision(proposal.domain.rawValue, id: proposal.id, verb: "reject")),
            "ics": .string(ics(for: proposal, method: method)),
            "card": .string(card.text)
        ]
        if let draft = proposal.draft {
            fields["event"] = .object([
                "start": .string(PrivacyStamp.iso(draft.start)),
                "end": .string(PrivacyStamp.iso(draft.end)),
                "timezone": .string(draft.timeZoneIdentifier),
                "startLocal": .string(PrivacyStamp.display(draft.start, timeZone: timeZone)),
                "endLocal": .string(PrivacyStamp.display(draft.end, timeZone: timeZone))
            ])
        }
        if let file = proposal.file {
            fields["target"] = .string(file.path)
            fields["overwrites"] = .bool(file.overwrites)
            fields["bytes"] = .int(file.content.utf8.count)
            fields["preview"] = .string(String(file.content.prefix(600)))
        }
        return PrivacyToolResponse(ok: true, status: status, fields: fields)
    }

    // MARK: Decisions

    private func decide(_ call: PrivacyToolCall, verb: String) async -> PrivacyToolResponse {
        guard !call.id.isEmpty else { return .failure(400, "缺少 proposalId / missing proposalId") }
        let receipt = (call.payload["receipt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receipt.isEmpty else {
            // No receipt, no write, and no "approve anyway" branch anywhere else
            // either: this is the only road to the executor.
            return .failure(403, "缺少批准令牌 / an approval receipt is required")
        }
        let decision = await ledger.decide(id: call.id, verb: verb, receipt: receipt)
        guard decision.ok, let proposal = decision.proposal else {
            let status = verb == "approve" && decision.message.contains("令牌无效") ? 403 : 409
            var fields: [String: JSONValue] = [
                "ok": .bool(false),
                "proposalId": .string(call.id),
                "refusal": .string(decision.message)
            ]
            if let state = decision.proposal?.state.rawValue { fields["state"] = .string(state) }
            return PrivacyToolResponse(ok: false, status: status, fields: fields)
        }
        let timeZone = TimeZone(identifier: proposal.draft?.timeZoneIdentifier ?? config.timezoneIdentifier)
            ?? .autoupdatingCurrent
        let method: ICSMethod
        switch proposal.action {
        case .cancel: method = .cancel
        case .reschedule: method = .request
        default: method = .publish
        }
        var fields: [String: JSONValue] = [
            "ok": .bool(true),
            "proposalId": .string(proposal.id),
            "domain": .string(proposal.domain.rawValue),
            "action": .string(proposal.action.rawValue),
            "state": .string(proposal.state.rawValue),
            "verb": .string(verb),
            "message": .string(proposal.lastMessage),
            "bookingRefId": .string(proposal.bookingRef),
            "calendarWritten": .bool(proposal.domain == .calendar && verb == "approve"),
            "fileWritten": .bool(proposal.domain == .workspace && verb == "approve"),
            "sequence": .int(proposal.sequence),
            "executedAt": .string(PrivacyStamp.iso(proposal.resolvedAt ?? Date())),
            "ics": .string(ics(for: proposal, method: method))
        ]
        if !proposal.eventIdentifier.isEmpty { fields["eventIdentifier"] = .string(proposal.eventIdentifier) }
        if let file = proposal.file { fields["target"] = .string(file.path) }
        _ = timeZone
        return PrivacyToolResponse(ok: true, fields: fields)
    }

    private func inspect(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard let proposal = await ledger.proposal(id: call.id) else {
            return .failure(404, "提案不存在，或已随节点重启失效 / proposal is unknown or was lost with a restart")
        }
        let method: ICSMethod
        switch proposal.action {
        case .cancel: method = .cancel
        case .reschedule: method = .request
        default: method = .publish
        }
        let timeZone = TimeZone(identifier: proposal.draft?.timeZoneIdentifier ?? config.timezoneIdentifier)
            ?? .autoupdatingCurrent
        return await proposalResponse(proposal, method: method, status: 200, timeZone: timeZone)
    }

    // MARK: Bookings

    private func bookings() async -> PrivacyToolResponse {
        let cards = await ledger.bookingCards()
        let rows = cards.map { card -> JSONValue in
            .object([
                "bookingRefId": .string(card.ref),
                "status": .string(card.action),
                "title": .string(card.title),
                "start": .string(card.startISO),
                "end": .string(card.endISO),
                "sequence": .int(card.sequence)
            ])
        }
        var fields: [String: JSONValue] = [
            "ok": .bool(true),
            "bookings": .array(rows),
            "count": .int(rows.count)
        ]
        fields.merge(PrivacyToolResponse.redactionFields()) { current, _ in current }
        return PrivacyToolResponse(ok: true, fields: fields)
    }

    // MARK: Workspace

    private func summarize(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard config.allowWorkspaceRead else {
            return .failure(403, "工作区读取未开启 / workspace read is off", extra: ["switch": .string("allowWorkspaceRead")])
        }
        guard let path = call.payload["path"]?.stringValue, !path.isEmpty else {
            return .failure(400, "缺少 path / missing path")
        }
        var reader = sandbox
        if let model = call.payload["model"]?.stringValue, !model.isEmpty { reader.model = model }
        switch await reader.digest(path) {
        case .failure(let error):
            return .failure(
                error.status,
                error.message,
                extra: ["refusal": .string(error.refusalValue?.rawValue ?? "failed"),
                        "path": .string(AppPaths.anonymise(path))]
            )
        case .success(let digest):
            return PrivacyToolResponse(ok: true, fields: [
                "ok": .bool(true),
                "path": .string(digest.path),
                "name": .string(digest.name),
                "kind": .string(digest.kind),
                "bytes": .int(digest.bytes),
                "lines": .int(digest.lines),
                "headings": .array(digest.headings.map { JSONValue.string($0) }),
                "bullets": .array(digest.bullets.map { JSONValue.string($0) }),
                "summary": .string(digest.summary),
                "summarySource": .string(digest.source),
                "truncated": .bool(digest.truncated),
                "note": .string(digest.note),
                // Stated as data rather than as marketing: the file is read on this
                // Mac and only its digest is returned. No handler here opens a socket
                // to anything that is not loopback.
                "uploadedToCloud": .bool(false),
                "egress": .string("仅回环 / loopback only (127.0.0.1)")
            ])
        }
    }

    private func proposeWorkspace(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        guard config.allowWorkspaceRead else {
            return .failure(403, "工作区读取未开启 / workspace read is off", extra: ["switch": .string("allowWorkspaceRead")])
        }
        guard config.allowWorkspaceWrite else {
            return .failure(403, "工作区写入未开启 / workspace write is off", extra: ["switch": .string("allowWorkspaceWrite")])
        }
        guard let raw = call.payload["action"]?.stringValue?.lowercased() else {
            return .failure(400, "action 需为 write / append / organize / action must be write, append or organize")
        }
        switch raw {
        case "write", "append":
            guard let path = call.payload["path"]?.stringValue, !path.isEmpty else {
                return .failure(400, "缺少 path / missing path")
            }
            let content = call.payload["content"]?.stringValue ?? ""
            guard !content.isEmpty else { return .failure(400, "缺少 content / missing content") }
            let mode: WorkspaceFilePayload.Mode = raw == "append" ? .append : .write
            switch sandbox.payload(for: path, content: content, mode: mode) {
            case .failure(let error):
                return .failure(error.status, error.message, extra: ["refusal": .string(error.refusalValue?.rawValue ?? "failed")])
            case .success(let payload):
                var proposal = PrivacyProposal(
                    domain: .workspace,
                    action: .write,
                    source: call.source,
                    title: (mode == .append ? "追加 " : "写入 ") + payload.path,
                    detail: payload.overwrites
                        ? "目标已存在，批准后将被覆盖 / the target exists and would be replaced"
                        : "新建 1 个文件 / one new file",
                    file: payload
                )
                proposal = await ledger.propose(proposal)
                return await proposalResponse(proposal, method: .publish, status: 201, timeZone: .autoupdatingCurrent)
            }
        case "organize", "move":
            guard let from = call.payload["path"]?.stringValue, let to = call.payload["to"]?.stringValue else {
                return .failure(400, "organize 需要 path 与 to / organize needs path and to")
            }
            switch sandbox.movePayload(from: from, to: to) {
            case .failure(let error):
                return .failure(error.status, error.message, extra: ["refusal": .string(error.refusalValue?.rawValue ?? "failed")])
            case .success(let payload):
                var proposal = PrivacyProposal(
                    domain: .workspace,
                    action: .organize,
                    source: call.source,
                    title: "移动至 " + payload.path,
                    detail: "移动文件，内容不变 / moves the file without changing its contents",
                    file: payload
                )
                proposal = await ledger.propose(proposal)
                return await proposalResponse(proposal, method: .publish, status: 201, timeZone: .autoupdatingCurrent)
            }
        default:
            return .failure(400, "action 需为 write / append / organize / action must be write, append or organize")
        }
    }

    // MARK: Console support

    /// The panel's data, built from the same objects the tools read.
    public func snapshot() async -> PrivacyBridgeSnapshot {
        var reachable: [String] = []
        for directory in config.workspaceDirectories {
            guard let url = AppPaths.resolve(userPath: directory) else { continue }
            var isDirectory: ObjCBool = false
            if AppPaths.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                reachable.append(AppPaths.anonymise(url.path))
            }
        }
        return PrivacyBridgeSnapshot(
            calendarAllowed: config.allowCalendarAccess,
            workspaceReadAllowed: config.allowWorkspaceRead,
            workspaceWriteAllowed: config.allowWorkspaceWrite,
            eventAuthorization: config.allowCalendarAccess
                ? await gateway.authorizationState()
                : PrivacyAuthorization.notDetermined,
            directories: config.workspaceDirectories.map { AppPaths.anonymise($0) },
            reachableDirectories: reachable,
            pendingProposals: await ledger.pendingCards(),
            bookings: await ledger.bookingCards(),
            auditLog: await ledger.auditRows(),
            notifyOnProposal: config.notifyOnProposal,
            bridges: config
        )
    }

    /// Raises the TCC dialog. Only the console may call this — there is no tool path
    /// to it, because an authorization grant must not be reachable from a caller.
    public func requestCalendarAccess() async -> String {
        await gateway.requestFullAccess()
    }
}

// MARK: - Errors into HTTP

public extension WorkspaceError {
    var refusalValue: WorkspaceRefusal? {
        if case .refusal(let refusal, _) = self { return refusal }
        return nil
    }

    var message: String {
        switch self {
        case .refusal(let refusal, let detail):
            return detail.isEmpty ? refusal.message : "\(refusal.message) · \(detail)"
        }
    }

    /// Traversal and deny-list hits carry a security meaning, so they read as 403
    /// rather than as a generic bad request.
    var status: Int {
        switch refusalValue {
        case .readDisabled, .writeDisabled, .bridgeDisabled, .sensitivePath: return 403
        case .noDirectories: return 503
        case .notFound, .sourceMissing: return 404
        case .tooLarge: return 413
        default: return 400
        }
    }
}

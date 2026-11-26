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
    /// The MCP bridge. Named `mcp` on the wire because that is what the owner reads in the
    /// console, and because a namespace is also the audit `domain` string.
    case mcp
    /// Home Assistant and the MQTT broker, which share one switch and one entity whitelist.
    case home
    /// CalDAV. Read-only, so it borrows the calendar audit domain: a remote free/busy lookup
    /// and a local one are the same kind of fact, and the ledger should not pretend otherwise.
    case calDav = "caldav"

    public var domain: PrivacyDomain {
        switch self {
        case .calendar: return .calendar
        case .workspace: return .workspace
        case .mcp: return .mcp
        case .home: return .smartHome
        case .calDav: return .calendar
        }
    }
}

extension PrivacyDomain {
    /// The namespace a command line carries for this domain. Not a `rawValue` round-trip:
    /// `smartHome` is the audit and console key, `home` is what the owner types, and a phone
    /// that was handed `…::smartHome::approve::…` would find no namespace and no approval.
    public var toolNamespace: PrivacyToolNamespace {
        switch self {
        case .calendar: return .calendar
        case .workspace: return .workspace
        case .mcp: return .mcp
        case .smartHome: return .home
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
    // Hub bridge actions. Every one of them is in `PrivacyToolAction.all`, so a paired phone
    // can address exactly what the loopback console can — including the three write-shaped ones
    // (`invoke`, `control`, `publish`), each of which can only ever produce a proposal.
    public static let status = "status"
    public static let servers = "servers"
    public static let tools = "tools"
    public static let invoke = "invoke"
    public static let entities = "entities"
    public static let control = "control"
    public static let publish = "publish"

    /// Actions addressed by a proposal id.
    public static let idBearing = [approve, reject, inspect]
    /// Every action either entry point may use, so a phone cannot reach an endpoint
    /// the HTTP layer does not already have.
    public static let all = [
        availability, proposals, approve, reject, inspect, summarize, bookings,
        status, servers, tools, invoke, entities, control, publish
    ]
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

    /// Either name a caller can legitimately hold. `home` is the namespace an owner types into
    /// a path; `smartHome` is the audit domain the ledger stores, so it is what a proposal card
    /// carries back when the console posts a click.
    ///
    /// This is a name reconciliation, not a widening: both spellings resolve to the same
    /// `PrivacyDomain`, so an alias reaches no capability the canonical name could not, and a
    /// write is still gated by the `id + verb` receipt rather than by this string.
    public static func namespace(accepting text: String) -> PrivacyToolNamespace? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = PrivacyToolNamespace(rawValue: wanted) { return direct }
        guard let domain = PrivacyDomain(rawValue: wanted) else { return nil }
        let resolved = domain.toolNamespace
        return resolved.rawValue == wanted ? nil : resolved
    }

    /// `nil` when the path is not a tool path or names an action that does not exist.
    public static func parse(path: String, source: String = "bot-studio") -> PrivacyToolCall? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.hasPrefix(ConsoleRoute.toolPrefix) else { return nil }
        let pieces = trimmed.dropFirst(ConsoleRoute.toolPrefix.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pieces.count >= 2, let namespace = namespace(accepting: pieces[0]) else { return nil }
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
    ///
    /// `parse` accepts either name and this does not, on purpose: the path side is the
    /// owner's own loopback, while `serviceId` arrives from a peer, so the peer gets the one
    /// spelling this node minted in `commandLine(namespace:)` and nothing else.
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
    /// Attached after construction, not built here: a bridge needs the ledger, the ledger
    /// needs an executor, and this type *is* the executor. `nil` means the hub domains are
    /// unattachable, which is a refusal rather than a silent no-op.
    private var mcp: MCPBridge?
    private var smartHome: SmartHomeBridge?

    public init(gateway: any CalendarGateway, sandbox: WorkspaceSandbox) {
        self.gateway = gateway
        self.sandbox = sandbox
    }

    public func update(gateway: any CalendarGateway, sandbox: WorkspaceSandbox) {
        self.gateway = gateway
        self.sandbox = sandbox
    }

    public func attachHub(mcp: MCPBridge?, smartHome: SmartHomeBridge?) {
        self.mcp = mcp
        self.smartHome = smartHome
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
        case .mcp:
            guard let mcp else {
                return .failed("MCP 桥接未装配 / the MCP bridge is not attached to this node")
            }
            // Every admission decision — switch, allow-list, tool whitelist, high-risk
            // entity — is re-checked inside the bridge, because the proposal may have been
            // created before the owner changed the config.
            return await mcp.executeApproved(proposal)
        case .smartHome:
            guard let smartHome else {
                return .failed("家居桥接未装配 / the smart-home bridge is not attached to this node")
            }
            return await smartHome.executeApproved(proposal)
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
    /// The hub switches, mirrored from `NodeSettings` so one authorization table governs both
    /// the privacy bridges and the protocol bridges. The bridges hold their own copy for their
    /// own admission checks; this one is what the dispatch reads first.
    private var hubConfig: HubConfig = .disabled
    private var mcpBridge: MCPBridge?
    private var homeBridge: SmartHomeBridge?
    private var calDavBridge: CalDavBridge?

    public init(
        config: PrivacyBridgeConfig,
        gateway: any CalendarGateway,
        ledger: PrivacyProposalLedger,
        hub: PrivacyExecutorHub,
        sandbox: WorkspaceSandbox,
        nodeReference: String,
        mcp: MCPBridge? = nil,
        smartHome: SmartHomeBridge? = nil,
        calDav: CalDavBridge? = nil
    ) {
        self.config = config.normalised
        self.gateway = gateway
        self.ledger = ledger
        self.hub = hub
        self.sandbox = sandbox
        self.nodeReference = nodeReference
        self.mcpBridge = mcp
        self.homeBridge = smartHome
        self.calDavBridge = calDav
    }

    /// Hands the bridges to the executor, which is the only road from an approved proposal to
    /// a device. Called once at startup, after the ledger has been given this executor.
    public func attachHubBridges() async {
        await hub.attachHub(mcp: mcpBridge, smartHome: homeBridge)
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

    /// The hub switches changed: forward to both bridges, which re-derive their own endpoints,
    /// then void any proposal whose bridge was just switched off. An approval the node may no
    /// longer honor must not stay clickable on the phone.
    public func applyHubConfig(_ next: HubConfig) async {
        let previous = hubConfig
        hubConfig = next.normalised
        await mcpBridge?.update(config: hubConfig)
        await homeBridge?.update(config: hubConfig)
        await calDavBridge?.update(config: hubConfig)
        if previous.allowMcpBridge, !hubConfig.allowMcpBridge {
            await ledger.cancelPendingProposals(domain: .mcp, reason: "MCP 桥接已关闭 / the MCP bridge was switched off")
        }
        if previous.allowSmartHomeBridge, !hubConfig.allowSmartHomeBridge {
            await ledger.cancelPendingProposals(domain: .smartHome, reason: "家居桥接已关闭 / the smart-home bridge was switched off")
        }
        // No CalDAV branch: that bridge is free/busy only, so it never creates a proposal —
        // cancelling the calendar domain here would void real bookings.
    }

    public func currentHubConfig() -> HubConfig { hubConfig }

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
        // The hub bridges. Read-shaped actions answer from the bridge's own cards; every
        // write-shaped one can only produce a proposal, and the refusal text says which switch
        // is missing rather than pretending the call was malformed.
        case (.mcp, PrivacyToolAction.status):
            return await mcpStatus(call)
        case (.mcp, PrivacyToolAction.servers):
            return await mcpServers()
        case (.mcp, PrivacyToolAction.tools):
            return await mcpTools(call)
        case (.mcp, PrivacyToolAction.invoke):
            return await mcpInvoke(call)
        case (.home, PrivacyToolAction.status):
            return await homeStatus(call)
        case (.home, PrivacyToolAction.entities):
            return await homeEntities(call)
        case (.home, PrivacyToolAction.control):
            return await homeControl(call)
        case (.home, PrivacyToolAction.publish):
            return await homePublish(call)
        case (.calDav, PrivacyToolAction.status):
            return await calDavStatus(call)
        case (.mcp, PrivacyToolAction.proposals), (.home, PrivacyToolAction.proposals):
            return await hubProposals(call)
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
        // Remote calendars, asked *after* the local answer so a CalDAV host that is down cannot
        // stall an EventKit result the node already has. The merge happens on the free side:
        // the gateway's own busy intervals never leave the calendar layer, and this bridge must
        // not become the reason they do.
        let remote: ICalendarFreeBusy
        if hubConfig.allowCalDavBridge, let calDavBridge {
            remote = await calDavBridge.read(
                window: DateInterval(start: probe.start, end: probe.end),
                zone: TimeZone(identifier: probe.timeZoneIdentifier) ?? .autoupdatingCurrent
            ).freeBusy
        } else {
            remote = .empty
        }
        let slots = remote.busy.isEmpty
            ? outcome.freeSlots
            : CalDavBridge.subtract(busy: remote.busy, from: outcome.freeSlots)
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
            "freeSlots": .array(slots.map { slot in
                .object([
                    "start": .string(PrivacyStamp.iso(slot.start)),
                    "end": .string(PrivacyStamp.iso(slot.end))
                ])
            }),
            "slotCount": .int(slots.count),
            "busyCount": .int(outcome.busyCount),
            "busyMinutes": .int(outcome.busyMinutes),
            "popopxBookings": .array(index)
        ]
        if !remote.busy.isEmpty {
            // Reported separately rather than folded into `busyCount`, which is an EventKit
            // event count: the two sources are not the same unit, and adding them would be a
            // number that means nothing.
            fields["remoteBusyCount"] = .int(remote.busy.count)
            fields["remoteBusyMinutes"] = .int(CalDavBridge.busyMinutes(remote.busy))
            fields["remoteApproximated"] = .bool(remote.approximated)
            fields["sources"] = .array([.string("eventkit"), .string("caldav")])
        } else {
            fields["sources"] = .array([.string("eventkit")])
        }
        fields.merge(PrivacyToolResponse.redactionFields()) { current, _ in current }
        await ledger.record(PrivacyAuditEntry(
            domain: PrivacyDomain.calendar.rawValue,
            action: PrivacyToolAction.availability,
            outcome: "answered",
            detail: "\(slots.count) slots / \(outcome.busyCount) busy"
                + (remote.busy.isEmpty ? "" : " / \(remote.busy.count) remote busy")
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
        let namespace = proposal.domain.toolNamespace
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
            "card": .string(card.text)
        ]
        // Only a calendar proposal has an iCalendar object to carry. Emitting one for an MCP or
        // device call would describe a booking that does not exist.
        if proposal.domain == .calendar {
            fields["ics"] = .string(ics(for: proposal, method: method))
        }
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

    // MARK: Hub bridges
    //
    // These handlers are thin on purpose: every admission decision lives in the bridge, so the
    // console and a paired phone cannot disagree about whether a call was allowed. What this
    // layer adds is the switch check in front, the card shape on the way out, and the rule
    // that a write-shaped action ends in a proposal and nothing else.

    private func requireMCP() -> PrivacyToolResponse? {
        guard hubConfig.allowMcpBridge else {
            return .failure(
                403,
                "MCP 桥接未开启：请在控制台「协议桥接」中显式授权 / the MCP bridge is off; enable it in the Protocol Bridges panel",
                extra: ["switch": .string("allowMcpBridge")]
            )
        }
        guard mcpBridge != nil else {
            return .failure(503, "本节点未装配 MCP 桥接 / this node has no MCP bridge attached")
        }
        return nil
    }

    private func requireHome() -> PrivacyToolResponse? {
        guard hubConfig.allowSmartHomeBridge else {
            return .failure(
                403,
                "家居桥接未开启：请在控制台「协议桥接」中显式授权 / the smart-home bridge is off; enable it in the Protocol Bridges panel",
                extra: ["switch": .string("allowSmartHomeBridge")]
            )
        }
        guard homeBridge != nil else {
            return .failure(503, "本节点未装配家居桥接 / this node has no smart-home bridge attached")
        }
        return nil
    }

    private func mcpStatus(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireMCP() { return refusal }
        let cards = await mcpBridge?.serverCards() ?? []
        var fields: [String: JSONValue] = [
            "ok": .bool(true),
            "allowMcpBridge": .bool(true),
            "servers": .array(cards.map { Self.json($0) }),
            "serverCount": .int(cards.count),
            "connectedCount": .int(cards.filter { $0.connected }.count),
            "toolCount": .int(cards.reduce(0) { $0 + $1.toolCount }),
            "mutatingToolCount": .int(cards.reduce(0) { $0 + $1.mutatingCount }),
            "gate": .string("只读工具直接执行，变更类工具进入待确认提案队列 / read-only tools run, mutating tools wait for the owner"),
            "source": .string("config/mcp_servers.json")
        ]
        if let bridge = mcpBridge { fields.merge(await bridge.registrySummary()) { current, _ in current } }
        return Self.hubResponse(fields)
    }

    private func mcpServers() async -> PrivacyToolResponse {
        if let refusal = requireMCP() { return refusal }
        let cards = await mcpBridge?.serverCards() ?? []
        return Self.hubResponse([
            "ok": .bool(true),
            "servers": .array(cards.map { Self.json($0) }),
            "count": .int(cards.count)
        ])
    }

    private func mcpTools(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireMCP() { return refusal }
        guard let serverID = value(call, "serverId", "server") else {
            return .failure(400, "缺少 serverId / missing serverId")
        }
        let cards = await mcpBridge?.toolCards(serverID: serverID) ?? []
        return Self.hubResponse([
            "ok": .bool(true),
            "serverId": .string(serverID),
            "tools": .array(cards.map { Self.json($0) }),
            "count": .int(cards.count),
            "approvalRequired": .int(cards.filter { $0.requiresApproval }.count),
            "refusal": .string(cards.isEmpty ? "该服务器没有可用工具 / this server advertised no usable tools" : "")
        ])
    }

    private func mcpInvoke(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireMCP() { return refusal }
        guard let bridge = mcpBridge else { return .failure(503, "本节点未装配 MCP 桥接 / no MCP bridge") }
        guard let serverID = value(call, "serverId", "server") else {
            return .failure(400, "缺少 serverId / missing serverId")
        }
        guard let tool = value(call, "tool", "toolName", "name") else {
            return .failure(400, "缺少 tool / missing tool name")
        }
        let arguments = call.payload["arguments"]?.objectValue ?? [:]
        switch await bridge.invoke(serverID: serverID, toolName: tool, arguments: arguments, source: call.source) {
        case .executed(let text, let truncated):
            return Self.hubResponse([
                "ok": .bool(true),
                "executed": .bool(true),
                "requiresUserConfirmation": .bool(false),
                "serverId": .string(serverID),
                "tool": .string(tool),
                "result": .string(text),
                "truncated": .bool(truncated)
            ])
        case .proposed(let proposal):
            return await hubProposalResponse(proposal, status: 201)
        case .refused(let reason):
            await ledger.record(PrivacyAuditEntry(
                domain: PrivacyDomain.mcp.rawValue,
                action: PrivacyToolAction.invoke,
                outcome: "refused",
                detail: "\(serverID)/\(tool): \(reason)"
            ))
            return .failure(403, reason)
        }
    }

    private func homeStatus(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireHome() { return refusal }
        let status = await homeBridge?.status() ?? SmartHomeStatusCard(enabled: false)
        let telemetry = await homeBridge?.telemetryCards() ?? []
        let entities = await homeBridge?.entityCards() ?? []
        let fields: [String: JSONValue] = [
            "ok": .bool(true),
            "allowSmartHomeBridge": .bool(true),
            "status": Self.json(status),
            "entities": .array(entities.map { Self.json($0) }),
            "entityCount": .int(entities.count),
            "telemetry": .array(telemetry.map { Self.json($0) }),
            "telemetryCount": .int(telemetry.count),
            "credentialNote": .string("凭据存于 macOS 钥匙串，配置文件与日志中均无明文 / credentials live in the macOS Keychain; never in a file or a log"),
            "gate": .string("只读模式仅取状态；任何控制动作进入待确认提案队列 / read-only mode reports state; every control action waits for the owner")
        ]
        return Self.hubResponse(fields)
    }

    private func homeEntities(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireHome() { return refusal }
        let cards = await homeBridge?.entityCards() ?? []
        let telemetry = await homeBridge?.telemetryCards() ?? []
        return Self.hubResponse([
            "ok": .bool(true),
            "entities": .array(cards.map { Self.json($0) }),
            "count": .int(cards.count),
            "exposedOnly": .bool(true),
            "highRiskCount": .int(cards.filter { $0.highRisk }.count),
            "telemetry": .array(telemetry.map { Self.json($0) })
        ])
    }

    private func homeControl(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireHome() { return refusal }
        guard let bridge = homeBridge else { return .failure(503, "本节点未装配家居桥接 / no smart-home bridge") }
        guard let entity = value(call, "entity", "entityId") else {
            return .failure(400, "缺少 entity / missing entity id")
        }
        guard let service = value(call, "service", "action") else {
            return .failure(400, "缺少 service / missing service name")
        }
        let data = call.payload["data"]?.objectValue ?? call.payload["serviceData"]?.objectValue ?? [:]
        switch await bridge.call(entity: entity, service: service, data: data, source: call.source) {
        case .executed(let text, let truncated):
            // Reachable only when the bridge's own read-only path allows it; the proposal is
            // still the normal answer for anything that moves a device.
            return Self.hubResponse([
                "ok": .bool(true),
                "executed": .bool(true),
                "entity": .string(entity),
                "service": .string(service),
                "result": .string(text),
                "truncated": .bool(truncated)
            ])
        case .proposed(let proposal):
            return await hubProposalResponse(proposal, status: 201)
        case .refused(let reason):
            return .failure(403, reason)
        }
    }

    private func homePublish(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireHome() { return refusal }
        guard let bridge = homeBridge else { return .failure(503, "本节点未装配家居桥接 / no smart-home bridge") }
        guard let entity = value(call, "entity", "entityId") else {
            return .failure(400, "缺少 entity / missing entity id")
        }
        let data = call.payload["payload"]?.objectValue ?? call.payload["data"]?.objectValue ?? [:]
        guard !data.isEmpty else { return .failure(400, "缺少下发内容 / missing payload") }
        switch await bridge.publish(entity: entity, payload: data, source: call.source) {
        case .executed(let text, let truncated):
            return Self.hubResponse([
                "ok": .bool(true), "executed": .bool(true), "entity": .string(entity),
                "result": .string(text), "truncated": .bool(truncated)
            ])
        case .proposed(let proposal):
            return await hubProposalResponse(proposal, status: 201)
        case .refused(let reason):
            return .failure(403, reason)
        }
    }

    private func requireCalDav() -> PrivacyToolResponse? {
        guard hubConfig.allowCalDavBridge else {
            return .failure(
                403,
                "CalDAV 桥接未开启：请在控制台「协议桥接」中显式授权 / the CalDAV bridge is off; enable it in the Protocol Bridges panel",
                extra: ["switch": .string("allowCalDavBridge")]
            )
        }
        guard calDavBridge != nil else {
            return .failure(503, "本节点未装配 CalDAV 桥接 / this node has no CalDAV bridge attached")
        }
        return nil
    }

    /// Probes the configured servers once and answers with what the *windows* said. There is no
    /// event list in this response by construction — `ICalendarFreeBusy` has no field that
    /// could carry a title, so the redaction claim here is a type fact, not a promise.
    private func calDavStatus(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        if let refusal = requireCalDav() { return refusal }
        let days = max(1, min(hubConfig.calDav.normalised.lookaheadDays, CalDav.maximumWindowDays))
        let now = Date()
        let window = DateInterval(start: now, end: now.addingTimeInterval(TimeInterval(days * 86_400)))
        let zone = TimeZone(identifier: zone(from: call)) ?? .autoupdatingCurrent
        let reading = await calDavBridge?.read(window: window, zone: zone) ?? CalDavReading()
        let fields: [String: JSONValue] = [
            "ok": .bool(true),
            "allowCalDavBridge": .bool(true),
            "servers": .array(reading.cards.map { Self.json($0) }),
            "serverCount": .int(reading.cards.count),
            "serversReached": .int(reading.serversAsked),
            "lookaheadDays": .int(days),
            "busyCount": .int(reading.freeBusy.busy.count),
            "busyMinutes": .int(CalDavBridge.busyMinutes(reading.freeBusy.busy)),
            "eventCount": .int(reading.freeBusy.eventCount),
            "discardedCount": .int(reading.freeBusy.discardedCount),
            "approximated": .bool(reading.freeBusy.approximated),
            "unknownTimeZone": .bool(reading.freeBusy.unknownTimeZone),
            "windows": .array(reading.freeBusy.busy.map {
                .object(["start": .string(PrivacyStamp.iso($0.start)), "end": .string(PrivacyStamp.iso($0.end))])
            }),
            "redaction": .string("仅保留起止时间：SUMMARY、DESCRIPTION、LOCATION、ATTENDEE 在解析当场丢弃 / only the windows survive parsing; titles, notes, places and attendees are dropped inside the parser")
        ]
        return Self.hubResponse(fields)
    }

    /// Stores one bridge credential. Console-only by construction: there is no
    /// `PrivacyToolAction` for it, so neither a `/v1/tools/` path nor a phone command can name
    /// this, and the response carries the Keychain *reference* rather than the value.
    ///
    /// The switches are deliberately not checked here. Storing a token is the setup act that
    /// comes before a switch can be honored at all — `HubConfig.normalised` turns
    /// `allowSmartHomeBridge` off while the credential reference is missing.
    public func storeHubCredential(bridge: String, serverID: String, secret: String) async -> PrivacyToolResponse {
        let kind = bridge.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !secret.isEmpty, secret.utf8.count <= HubSecrets.maximumSecretLength else {
            return .failure(400, "凭据为空或过长 / the credential is empty or too long")
        }
        let outcome: HubSecretOutcome
        switch kind {
        case "hometoken":
            guard let homeBridge else { return .failure(503, "请先保存家居桥接设置 / save the smart-home settings first") }
            outcome = await homeBridge.storeHomeAssistantToken(secret)
        case "mqttpassword":
            guard let homeBridge else { return .failure(503, "请先保存家居桥接设置 / save the smart-home settings first") }
            outcome = await homeBridge.storeBrokerPassword(secret)
        case "caldav":
            guard let calDavBridge else { return .failure(503, "请先保存 CalDAV 服务器 / save the CalDAV server first") }
            outcome = await calDavBridge.storePassword(secret, for: serverID)
        default:
            return .failure(400, "未知的凭据类别 / unknown credential kind")
        }
        guard let reference = outcome.reference else {
            var reason = "钥匙串写入失败 / the credential store refused"
            if case .refused(let text) = outcome { reason = text }
            return .failure(500, reason)
        }
        return .init(ok: true, status: 200, fields: [
            "ok": .bool(true),
            "reference": .string(reference),
            "stored": .bool(true),
            "bridge": .string(kind),
            "detail": .string("已加密存入 macOS 钥匙串；设置文件与本响应均不含明文 / stored encrypted in the macOS Keychain; neither the settings document nor this reply contains the value")
        ])
    }

    /// Pending proposals for one hub domain. Deliberately not the whole ledger: a phone
    /// asking about `home` must not be handed the owner's calendar bookings.
    private func hubProposals(_ call: PrivacyToolCall) async -> PrivacyToolResponse {
        let domain = call.namespace.domain
        let rows = await ledger.pending().filter { $0.domain == domain }
        return Self.hubResponse([
            "ok": .bool(true),
            "domain": .string(domain.rawValue),
            "proposals": .array(rows.map { .object(Self.proposalJSON($0)) }),
            "count": .int(rows.count)
        ])
    }

    /// The answer to "I asked the bridge to change something": a proposal, receipts, and the
    /// two command lines — the same contract a calendar booking gives the phone, minus the
    /// iCalendar payload, because there is no event to describe.
    private func hubProposalResponse(_ proposal: PrivacyProposal, status: Int) async -> PrivacyToolResponse {
        let approveReceipt = await ledger.receipt(id: proposal.id, verb: "approve")
        let rejectReceipt = await ledger.receipt(id: proposal.id, verb: "reject")
        let namespace = proposal.domain.toolNamespace
        let card = PrivacyCard(
            kind: proposal.domain.rawValue,
            action: proposal.action.rawValue,
            proposalId: proposal.id,
            title: proposal.title,
            window: proposal.hubCall?.destination ?? "",
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
        var fields = Self.proposalJSON(proposal)
        fields["ok"] = .bool(true)
        fields["requiresUserConfirmation"] = .bool(true)
        fields["executed"] = .bool(false)
        fields["approvalReceipt"] = .string(approveReceipt)
        fields["rejectReceipt"] = .string(rejectReceipt)
        fields["approvePath"] = .string(ConsoleRoute.proposalDecision(proposal.domain.rawValue, id: proposal.id, verb: "approve"))
        fields["rejectPath"] = .string(ConsoleRoute.proposalDecision(proposal.domain.rawValue, id: proposal.id, verb: "reject"))
        fields["card"] = .string(card.text)
        return PrivacyToolResponse(ok: true, status: status, fields: Self.boundary(fields))
    }

    /// One proposal as fields, for both the list and the answer. `hubCall` is included because
    /// its `preview` is already the redacted, bounded description of the write.
    static func proposalJSON(_ proposal: PrivacyProposal) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "proposalId": .string(proposal.id),
            "domain": .string(proposal.domain.rawValue),
            "action": .string(proposal.action.rawValue),
            "state": .string(proposal.state.rawValue),
            "title": .string(proposal.title),
            "detail": .string(proposal.detail),
            "createdAt": .string(PrivacyStamp.iso(proposal.createdAt)),
            "expiresAt": .string(PrivacyStamp.iso(proposal.expiresAt)),
            "secondsLeft": .int(proposal.secondsLeft()),
            "source": .string(proposal.source)
        ]
        if let payload = proposal.hubCall {
            fields["preview"] = .string(payload.preview)
            fields["target"] = .string(payload.destination)
            fields["argumentCount"] = .int(payload.arguments.count)
        }
        if !proposal.lastMessage.isEmpty { fields["message"] = .string(proposal.lastMessage) }
        return fields
    }

    /// First payload key that holds usable text. A phone and the console do not have to agree
    /// on one spelling of an argument for the call to be understood.
    private func value(_ call: PrivacyToolCall, _ keys: String...) -> String? {
        for key in keys {
            if let text = Self.text(call.payload[key]?.stringValue ?? "") { return text }
        }
        return nil
    }

    /// Adds the two promises every hub answer owes the owner, in one place.
    static func boundary(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var merged = fields
        merged.merge([
            "boundary": .string("仅回环与内网 / loopback, RFC 1918 and .local addresses only"),
            "egress": .string("公网地址由代码拒绝，不是策略提示 / public addresses are refused in code, not by convention")
        ]) { current, _ in current }
        return merged
    }

    static func hubResponse(_ fields: [String: JSONValue]) -> PrivacyToolResponse {
        let merged = boundary(fields)
        return PrivacyToolResponse(ok: merged["ok"]?.boolValue ?? true, fields: merged)
    }

    /// An `Encodable` card becomes JSON here rather than field by field: the card type is
    /// already the console's contract, and restating its fields is how a row goes stale.
    static func json<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = NodeJSON.encodeLine(value), let parsed = NodeJSON.decode(JSONValue.self, from: data) else {
            return .null
        }
        return parsed
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
            "executedAt": .string(PrivacyStamp.iso(proposal.resolvedAt ?? Date()))
        ]
        if proposal.domain == .calendar {
            fields["ics"] = .string(ics(for: proposal, method: method))
        }
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

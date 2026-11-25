//
//  PrivacyBridgeTests.swift
//  The privacy calendar and controlled-workspace executor.
//
//  Four groups, in the order the feature is dangerous:
//
//  * `RFC 5545` — the one artifact this node sends outside the Mac.
//  * redaction — the response that must not contain a title, a location, an
//    attendee or a note, asserted against a busy calendar that is full of them.
//  * the proposal state machine — including the rule that nothing reaches
//    `EventKit` before a human approves.
//  * the workspace sandbox — path containment, the denylist, and the same
//    approval gate around a file write.
//
//  Every case runs against a fake event store: a real `EKEventStore` cannot be
//  granted access in a test host, and a test that needs a TCC dialog is a test
//  that silently skips.
//

import XCTest
@testable import PopopxMacNode

final class PrivacyBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ text: String) -> Date {
        guard let value = Date.ppxFromISO8601(text) else {
            XCTFail("test fixture date \(text) did not parse")
            return Date(timeIntervalSince1970: 0)
        }
        return value
    }

    private var shanghai: String { "Asia/Shanghai" }

    // MARK: - RFC 5545

    func testICSDocumentEndsEveryLineWithCRLFAndFoldsAt75Octets() {
        let event = ICSEvent(
            uid: "booking-1@popopx",
            start: date("2026-03-08T01:00:00Z"),
            end: date("2026-03-08T02:00:00Z"),
            timeZoneIdentifier: shanghai,
            summary: "季度复盘与隐私边界评审，参会人包括产品、法务与基础设施团队负责人代表",
            location: "https://meet.popopx.chat/r/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            note: String(repeating: "备注", count: 60)
        )
        let text = ICalendar.document(events: [event])

        XCTAssertTrue(text.hasSuffix(ICalendar.crlf), "the document must end with CRLF")
        XCTAssertFalse(text.containsBareLineFeed, "a bare LF splits a content line for a strict parser")

        for line in text.components(separatedBy: ICalendar.crlf) where !line.isEmpty {
            XCTAssertLessThanOrEqual(line.utf8.count, ICalendar.maximumLineOctets, "unfolded line: \(line)")
        }
        let continuation = text.components(separatedBy: ICalendar.crlf).filter { $0.hasPrefix(" ") }
        XCTAssertFalse(continuation.isEmpty, "this fixture is long enough that folding must have happened")
    }

    func testICSEscapesTextPropertyDelimiters() {
        let event = ICSEvent(
            uid: "booking-2@popopx",
            start: date("2026-01-15T01:00:00Z"),
            end: date("2026-01-15T02:00:00Z"),
            timeZoneIdentifier: shanghai,
            summary: "a;b,c\\d",
            note: "line one\nline two"
        )
        let lines = ICalendar.document(events: [event]).components(separatedBy: ICalendar.crlf)
        XCTAssertTrue(lines.contains { $0.hasPrefix("SUMMARY:a\\;b\\,c\\\\d") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("DESCRIPTION:line one\\nline two") }, "\(lines)")
    }

    func testICSTimeZoneIdFormDefinesTheZoneItUses() {
        let event = ICSEvent(
            uid: "booking-3@popopx",
            start: date("2026-03-08T06:00:00Z"),
            end: date("2026-03-08T07:00:00Z"),
            timeZoneIdentifier: "America/New_York",
            summary: "Standup"
        )
        let text = ICalendar.document(events: [event])
        let lines = text.components(separatedBy: ICalendar.crlf)

        // Every TZID a document uses must be a TZID the document defines.
        XCTAssertTrue(lines.contains("TZID:America/New_York"))
        XCTAssertEqual(lines.filter { $0 == "BEGIN:VTIMEZONE" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "END:VTIMEZONE" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "BEGIN:DAYLIGHT" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "BEGIN:STANDARD" }.count, 1)
        XCTAssertTrue(lines.contains("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"),
                      "2026 DST starts Sunday 8 March, the second Sunday")
        XCTAssertTrue(lines.contains("RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"),
                      "2026 DST ends Sunday 1 November, the first Sunday")
        XCTAssertTrue(lines.contains("TZOFFSETFROM:-0500"))
        XCTAssertTrue(lines.contains("TZOFFSETTO:-0400"))
        XCTAssertTrue(lines.contains("TZNAME:EDT"))
        XCTAssertTrue(lines.contains("TZNAME:EST"))
        XCTAssertTrue(lines.contains("DTSTART;TZID=America/New_York:20260308T010000"),
                      "06:00Z is still 01:00 EST, one hour before the switch")
        XCTAssertTrue(lines.contains("DTEND;TZID=America/New_York:20260308T030000"),
                      "07:00Z is 03:00 EDT: the event straddles the spring-forward gap, "
                    + "and wall-clock stamps must show both sides of it")
    }

    func testICSSouthernHemisphereZoneStillDerivesBothRules() {
        // Sydney switches on the first Sunday of April (out) and the first Sunday
        // of October (in). A derivation that only understood the northern pattern
        // would emit one block and leave the other undefined.
        let rules = ICalendar.observerRules(
            for: TimeZone(identifier: "Australia/Sydney") ?? .autoupdatingCurrent,
            around: date("2026-06-01T00:00:00Z")
        )
        XCTAssertNotNil(rules)
        let kinds = Set((rules ?? []).map { $0.kind })
        XCTAssertEqual(kinds, ["DAYLIGHT", "STANDARD"])
        XCTAssertTrue((rules ?? []).contains { $0.recurrence?.contains("BYMONTH=4") == true })
        XCTAssertTrue((rules ?? []).contains { $0.recurrence?.contains("BYMONTH=10") == true })
    }

    func testICSFixedOffsetZoneGetsASingleStandardBlockAndNoRecurrence() {
        let event = ICSEvent(
            uid: "booking-4@popopx",
            start: date("2026-01-15T01:00:00Z"),
            end: date("2026-01-15T02:00:00Z"),
            timeZoneIdentifier: shanghai,
            summary: "周会"
        )
        let lines = ICalendar.document(events: [event]).components(separatedBy: ICalendar.crlf)
        XCTAssertEqual(lines.filter { $0 == "BEGIN:STANDARD" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "BEGIN:DAYLIGHT" }.count, 0)
        XCTAssertFalse(lines.contains { $0.hasPrefix("RRULE:") }, "a zone that never switches has no rule")
        XCTAssertTrue(lines.contains("TZOFFSETTO:+0800"))
        XCTAssertTrue(lines.contains("DTSTART;TZID=Asia/Shanghai:20260115T090000"))
        XCTAssertTrue(lines.contains("DTEND;TZID=Asia/Shanghai:20260115T100000"))
    }

    func testICSUnknownZoneFallsBackToUTCWithoutAnUndefinedTZID() {
        let event = ICSEvent(
            uid: "booking-5@popopx",
            start: date("2026-01-15T01:00:00Z"),
            end: date("2026-01-15T02:00:00Z"),
            timeZoneIdentifier: "Mars/Olympus",
            summary: "Remote"
        )
        let text = ICalendar.document(events: [event])
        XCTAssertFalse(text.contains("TZID="), "an undefined TZID is invalid RFC 5545")
        XCTAssertFalse(text.contains("BEGIN:VTIMEZONE"))
        XCTAssertTrue(text.components(separatedBy: ICalendar.crlf).contains("DTSTART:20260115T010000Z"))
    }

    func testICSCancelAndRescheduleCarryMethodStatusAndSequence() {
        let original = ICSEvent(
            uid: "booking-6@popopx",
            start: date("2026-02-01T06:00:00Z"),
            end: date("2026-02-01T07:00:00Z"),
            timeZoneIdentifier: shanghai,
            summary: "Design review"
        )
        let moved = ICSEvent(uid: original.uid, sequence: 1, start: original.end,
                             end: original.end.addingTimeInterval(3600),
                             timeZoneIdentifier: shanghai, summary: original.summary)
        let dropped = ICSEvent(uid: original.uid, sequence: 2, status: .cancelled,
                               start: moved.start, end: moved.end,
                               timeZoneIdentifier: shanghai, summary: original.summary)

        let created = ICalendar.document(events: [original])
        XCTAssertTrue(created.contains("METHOD:PUBLISH"))
        XCTAssertFalse(created.components(separatedBy: ICalendar.crlf).contains("SEQUENCE:0"),
                       "SEQUENCE is optional at zero, and an absent one means zero")

        let rescheduled = ICalendar.document(events: [moved], method: .request)
        XCTAssertTrue(rescheduled.contains("METHOD:REQUEST"))
        XCTAssertTrue(rescheduled.components(separatedBy: ICalendar.crlf).contains("SEQUENCE:1"))

        let cancelled = ICalendar.document(events: [dropped], method: .cancel)
        // METHOD names the operation (§3.2.1: CANCEL); STATUS names the event's
        // state (§3.2.12: CANCELLED). Only a receiver that reads both sees a cancel.
        XCTAssertTrue(cancelled.contains("METHOD:CANCEL"))
        XCTAssertTrue(cancelled.components(separatedBy: ICalendar.crlf).contains("STATUS:CANCELLED"))
        XCTAssertTrue(cancelled.components(separatedBy: ICalendar.crlf).contains("SEQUENCE:2"))
    }

    func testICSCarriesTheBookingReferenceAndCallLink() {
        let event = ICSEvent(
            uid: "booking-7@popopx",
            start: date("2026-02-02T06:00:00Z"),
            end: date("2026-02-02T06:30:00Z"),
            timeZoneIdentifier: shanghai,
            summary: "Kickoff",
            location: "https://call.popopx.im/j/abcdef",
            url: "https://call.popopx.im/j/abcdef",
            bookingReference: "bk_9Fj2-xQ10"
        )
        let lines = ICalendar.document(events: [event]).components(separatedBy: ICalendar.crlf)
        XCTAssertTrue(lines.contains("X-POPOPX-BOOKING-REF:bk_9Fj2-xQ10"))
        XCTAssertTrue(lines.contains("LOCATION:https://call.popopx.im/j/abcdef"))
        XCTAssertTrue(lines.contains("URL:https://call.popopx.im/j/abcdef"))
        XCTAssertTrue(lines.contains("UID:booking-7@popopx"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("DTSTAMP:") && $0.hasSuffix("Z") })
    }

    func testICSOffsetStampAndUTCStamp() {
        XCTAssertEqual(ICalendar.offsetStamp(-8 * 3600 - 1800), "-0830")
        XCTAssertEqual(ICalendar.offsetStamp(0), "+0000")
        XCTAssertEqual(ICalendar.offsetStamp(35 * 60), "+0035")
        XCTAssertEqual(ICalendar.utcStamp(date("2026-01-15T01:02:03Z")), "20260115T010203Z")
    }
}

private extension String {
    /// A `\n` that is not preceded by `\r`: legal inside a folded value only as an
    /// escape sequence, never as a line ending.
    var containsBareLineFeed: Bool {
        var previous: Character?
        for character in self {
            if character == "\n", previous != "\r" { return true }
            previous = character
        }
        return false
    }
}

// MARK: - Receipts, the gate, and the sandbox

/// Records what the ledger let through to the calendar.
private final class FakeGateway: CalendarGateway, @unchecked Sendable {
    private(set) var commits: [CalendarEventDraft] = []
    private(set) var availabilityCalls = 0
    var commitSucceeds = true

    func authorizationState() async -> String { "fullAccess" }
    func requestFullAccess() async -> String { "fullAccess" }
    func availability(_ probe: CalendarProbe) async -> AvailabilityOutcome {
        availabilityCalls += 1
        return AvailabilityOutcome(freeSlots: [FreeSlot(start: Date(), end: Date().addingTimeInterval(1800))])
    }
    func commit(_ draft: CalendarEventDraft) async -> CalendarCommitOutcome {
        commits.append(draft)
        return commitSucceeds ? .committed(identifier: "evt-1") : .refused("EventKit refused the write")
    }
    func reschedule(identifier: String, start: Date, end: Date) async -> CalendarCommitOutcome {
        .committed(identifier: identifier)
    }
    func remove(identifier: String) async -> CalendarCommitOutcome {
        .committed(identifier: identifier)
    }
    func exists(identifier: String) async -> Bool { !commits.isEmpty }
}

private struct RecordingExecutor: ProposalExecutor {
    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        .succeeded("evt-\(proposal.id)", "written")
    }
}

/// A proposal id, so the tests never depend on `TextKit.randomToken`.
private let probeId = "ppx-pr-test-0001"

private func makeLedger(
    executor: any ProposalExecutor = RecordingExecutor()
) -> (PrivacyProposalLedger, PrivacyApprovalSigner) {
    let signer = PrivacyApprovalSigner(key: Data("test-signing-key-0123456789".utf8))
    let ledger = PrivacyProposalLedger(signer: signer, executor: executor, fileURL: nil, loadFromDisk: false)
    return (ledger, signer)
}

extension PrivacyBridgeTests {
    func testReceiptIsBoundToItsIdAndVerb() async {
        let (ledger, _) = makeLedger()
        let mine = await ledger.receipt(id: probeId, verb: "approve")
        XCTAssertEqual(mine.count, PrivacyApprovalSigner.receiptLength)
        let other = await ledger.receipt(id: "ppx-pr-other", verb: "approve")
        XCTAssertNotEqual(mine, other, "a receipt must not authorize a different proposal")
        let reject = await ledger.receipt(id: probeId, verb: "reject")
        XCTAssertNotEqual(mine, reject, "an approve token must not double as a reject token")
    }

    func testFirstApprovedWriteReachesTheGatewayAndTheSecondIsRefused() async {
        let (ledger, _) = makeLedger()
        _ = await ledger.propose(PrivacyProposal(id: probeId, domain: .calendar, action: .create))
        let receipt = await ledger.receipt(id: probeId, verb: "approve")

        let first = await ledger.approve(id: probeId, receipt: receipt)
        XCTAssertTrue(first.ok, first.message)
        XCTAssertEqual(first.proposal?.state, .executed)

        // Same token, same proposal: the state machine, not the signature, says no.
        let second = await ledger.approve(id: probeId, receipt: receipt)
        XCTAssertFalse(second.ok)
        XCTAssertTrue(second.message.contains("不能重复处理") || second.message.contains("already"),
                      "the refusal should name the reason: \(second.message)")
    }

    func testApproveWithoutAValidReceiptNeverReachesTheExecutor() async {
        var made = false
        let gate = BlockExecutor { made = true; return .succeeded("evt-x", "written") }
        let (ledger, _) = makeLedger(executor: gate)
        _ = await ledger.propose(PrivacyProposal(id: probeId, domain: .calendar, action: .create))
        for candidate in ["", "   ", "garbage", await ledger.receipt(id: probeId, verb: "reject")] {
            let outcome = await ledger.approve(id: probeId, receipt: candidate)
            XCTAssertFalse(outcome.ok, "receipt \(candidate.isEmpty ? "<empty>" : candidate) must not approve")
        }
        XCTAssertFalse(made, "the executor is the only road to a write, and it stayed closed")
        let proposal = await ledger.proposal(id: probeId)
        XCTAssertEqual(proposal?.state, .pendingUserApproval, "a refused decision must not consume the proposal")
    }

    func testDecisionAfterTheTTLExpiresIsRefusedEvenWithAValidReceipt() async {
        let (ledger, _) = makeLedger()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await ledger.propose(PrivacyProposal(id: probeId, domain: .calendar, action: .create,
                                                 createdAt: created, lifetime: 60))
        let receipt = await ledger.receipt(id: probeId, verb: "approve")
        let outcome = await ledger.approve(id: probeId, receipt: receipt, now: created.addingTimeInterval(61))
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.proposal?.state, .expired)
    }

    func testSwitchingTheCalendarBridgeOffVoidsPendingProposals() async {
        let gateway = FakeGateway()
        let (ledger, _) = makeLedger()
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(allowCalendarAccess: true),
            gateway: gateway, ledger: ledger,
            hub: PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox()),
            sandbox: WorkspaceSandbox(), nodeReference: "n1"
        )
        _ = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "proposals",
                                                payload: ["action": .string("create"),
                                                          "title": .string("standup"),
                                                          "startIso": .string("2026-01-05T09:00:00Z"),
                                                          "endIso": .string("2026-01-05T09:30:00Z")]))
        let pending = await ledger.pending()
        XCTAssertEqual(pending.count, 1)

        await engine.applyConfig(PrivacyBridgeConfig(allowCalendarAccess: false), sandbox: WorkspaceSandbox())
        let receipt = await ledger.receipt(id: pending[0].id, verb: "approve")
        let outcome = await ledger.approve(id: pending[0].id, receipt: receipt)
        XCTAssertFalse(outcome.ok, "a proposal the node can no longer honor must not stay approvable")
        XCTAssertNotEqual(outcome.proposal?.state, .executed)
    }

    func testAvailabilityIsRefusedAndSendsNoQueryWhileTheBridgeIsOff() async {
        let gateway = FakeGateway()
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(allowCalendarAccess: false),
            gateway: gateway, ledger: PrivacyProposalLedger(signer: PrivacyApprovalSigner(key: Data("k".utf8)),
                                                            executor: RecordingExecutor(), loadFromDisk: false),
            hub: PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox()),
            sandbox: WorkspaceSandbox(), nodeReference: "n1"
        )
        let reply = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "availability",
                                                        payload: ["startIso": .string("2026-01-05T09:00:00Z"),
                                                                  "endIso": .string("2026-01-06T09:00:00Z")]))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.status, 403)
        XCTAssertEqual(gateway.availabilityCalls, 0,
                       "a disabled bridge must not touch EventKit at all")
    }

    func testAvailabilityResponseCarriesTimesAndCountsButNoEventText() async {
        let gateway = FakeGateway()
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(allowCalendarAccess: true),
            gateway: gateway, ledger: PrivacyProposalLedger(signer: PrivacyApprovalSigner(key: Data("k".utf8)),
                                                            executor: RecordingExecutor(), loadFromDisk: false),
            hub: PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox()),
            sandbox: WorkspaceSandbox(), nodeReference: "n1"
        )
        let reply = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "availability",
                                                        payload: ["startIso": .string("2026-01-05T09:00:00Z"),
                                                                  "endIso": .string("2026-01-06T09:00:00Z")]))
        XCTAssertTrue(reply.ok, reply.body)
        guard case .array(let slots)? = reply.fields["freeSlots"], let first = slots.first else {
            return XCTFail("no freeSlots in \(reply.body)")
        }
        // The structural claim: a slot is two timestamps. Any third key, or a value
        // that is not a timestamp, would mean original calendar text got this far.
        XCTAssertEqual(Set(first.objectValue?.keys.map { $0 } ?? []), Set(["start", "end"]))
        for key in ["title", "summary", "location", "notes", "attendees", "calendar"] {
            XCTAssertNil(reply.fields[key], "\(key) must never appear in an availability reply")
        }
        XCTAssertEqual(reply.fields.keys.contains("redaction"), true,
                       "the reply states its own redaction guarantee")
    }

    func testFreeSlotsSkipBusyTimeWeekendsAndLunch() {
        func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int) -> Date {
            var components = DateComponents()
            components.year = year; components.month = month; components.day = dayOfMonth
            components.hour = hour; components.minute = 0
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: components)!
        }
        // Monday 5 January 2026.
        let probe = CalendarProbe(start: day(2026, 1, 5, 0), end: day(2026, 1, 6, 0),
                                  durationMinutes: 30, timeZoneIdentifier: "UTC",
                                  workingStartHour: 9, workingEndHour: 18, workdays: [1, 2, 3, 4, 5])
        let open = AvailabilityEngine.freeSlots(probe: probe, busy: [])
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].start, day(2026, 1, 5, 9))
        XCTAssertEqual(open[0].end, day(2026, 1, 5, 18))

        // A busy hour in the middle splits the window into two candidate slots.
        let split = AvailabilityEngine.freeSlots(probe: probe, busy: [
            RedactedBusyInterval(start: day(2026, 1, 5, 12), end: day(2026, 1, 5, 13))
        ])
        XCTAssertEqual(split.count, 2)

        // Sunday is not a workday, so the same window yields nothing.
        let weekend = CalendarProbe(start: day(2026, 1, 4, 0), end: day(2026, 1, 5, 0),
                                    timeZoneIdentifier: "UTC", workdays: [1, 2, 3, 4, 5])
        XCTAssertTrue(AvailabilityEngine.freeSlots(probe: weekend, busy: []).isEmpty)

        // Lunch blocked inside working hours leaves a morning and an afternoon run.
        let lunch = CalendarProbe(start: day(2026, 1, 5, 0), end: day(2026, 1, 6, 0),
                                  timeZoneIdentifier: "UTC", blockLunch: true,
                                  lunchStartHour: 12, lunchEndHour: 13)
        XCTAssertEqual(AvailabilityEngine.freeSlots(probe: lunch, busy: []).count, 2)
    }

    func testProbeValidationRefusesInsteadOfClamping() {
        var probe = CalendarProbe(start: Date(timeIntervalSince1970: 1_767_000_000),
                                  end: Date(timeIntervalSince1970: 1_767_086_400))
        XCTAssertNil(probe.validated())
        probe.durationMinutes = 3
        XCTAssertNotNil(probe.validated())
        probe.durationMinutes = 30
        probe.workdays = [8]
        XCTAssertNotNil(probe.validated())
        probe.workdays = [1]
        probe.workingEndHour = probe.workingStartHour
        XCTAssertNotNil(probe.validated())
    }

    func testConfigNormalisationCapsTheAuthorizedDirectories() {
        var config = PrivacyBridgeConfig(allowWorkspaceRead: true)
        config.workspaceDirectories = ["~/a", "~/b", "~/c", "~/d", "~/e"]
        XCTAssertEqual(config.normalised.workspaceDirectories.count, PrivacyBridgeConfig.maximumDirectories,
                       "a hand-edited settings document must not widen the readable set past the ceiling")
    }

    func testSandboxRefusalsNameTheReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppx-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("notes.md").path

        let closed = WorkspaceSandbox(readAllowed: false, writeAllowed: false, directoryPaths: [root.path])
        XCTAssertEqual(closed.guardPath(inside, writing: false), .readDisabled)
        XCTAssertEqual(closed.guardPath(inside, writing: true), .readDisabled)

        let readOnly = WorkspaceSandbox(readAllowed: true, writeAllowed: false, directoryPaths: [root.path])
        XCTAssertNil(readOnly.guardPath(inside, writing: false))
        XCTAssertEqual(readOnly.guardPath(inside, writing: true), .writeDisabled)

        XCTAssertEqual(WorkspaceSandbox(readAllowed: true, writeAllowed: true).guardPath(inside, writing: false),
                       .noDirectories)
        let open = WorkspaceSandbox(readAllowed: true, writeAllowed: true, directoryPaths: [root.path])
        XCTAssertEqual(open.guardPath(root.appendingPathComponent("..").path, writing: false), .pathTraversal)
        XCTAssertEqual(open.guardPath("~/Documents/elsewhere.md", writing: false), .outsideSandbox)
        XCTAssertEqual(open.guardPath("", writing: false), .emptyPath)

        // Authorizing the home directory must still keep the keychain out of reach.
        let home = WorkspaceSandbox(readAllowed: true, writeAllowed: true,
                                    directoryPaths: [NSHomeDirectory()])
        XCTAssertEqual(home.guardPath("Library/Keychains/local", writing: false), .sensitivePath)
        XCTAssertEqual(home.guardPath(".ssh/id_ed25519", writing: false), .sensitivePath)
    }

    func testSandboxWritesOnlyAfterTheGateAndReChecksTheDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppx-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("out.md")
        let payload = WorkspaceFilePayload(path: target.path, content: "hello", mode: .write,
                                           canonicalPath: target.path)

        let readOnly = WorkspaceSandbox(readAllowed: true, writeAllowed: false, directoryPaths: [root.path])
        let refused = readOnly.apply(payload)
        XCTAssertFalse(refused.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "a refused write must not even create the file")

        let writable = WorkspaceSandbox(readAllowed: true, writeAllowed: true, directoryPaths: [root.path])
        let accepted = writable.apply(payload)
        XCTAssertTrue(accepted.ok, accepted.message)
        XCTAssertEqual(try? String(contentsOf: target, encoding: .utf8), "hello")

        // The directories moved under the proposal: execution re-guards, so the stale
        // authorization dies instead of writing into a now-unauthorized path.
        let revoked = WorkspaceSandbox(readAllowed: true, writeAllowed: true, directoryPaths: [])
        XCTAssertFalse(revoked.apply(payload).ok)
    }

    func testExecutorHubWritesToTheGatewayOnlyForAnApprovedProposal() async {
        let gateway = FakeGateway()
        let hub = PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox())
        let created = PrivacyProposal(id: probeId, domain: .calendar, action: .create,
                                      draft: CalendarEventDraft(summary: "standup",
                                                                start: Date(),
                                                                end: Date().addingTimeInterval(900)))
        let outcome = await hub.execute(created)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(gateway.commits.count, 1)

        // A reschedule with no calendar reference cannot invent one.
        let orphan = PrivacyProposal(id: "ppx-pr-orphan", domain: .calendar, action: .reschedule,
                                     draft: CalendarEventDraft(summary: "standup", start: Date(),
                                                               end: Date().addingTimeInterval(900)))
        let orphanOutcome = await hub.execute(orphan)
        XCTAssertFalse(orphanOutcome.ok)
        XCTAssertEqual(gateway.commits.count, 1, "the failed action must not have written either")

        gateway.commitSucceeds = false
        let denied = PrivacyProposal(id: "ppx-pr-denied", domain: .calendar, action: .create,
                                     draft: CalendarEventDraft(summary: "standup", start: Date(),
                                                               end: Date().addingTimeInterval(900)))
        let failed = await hub.execute(denied)
        XCTAssertFalse(failed.ok)
        let stored = await makeLedger().0.approve(id: "x", receipt: "y")
        XCTAssertFalse(stored.ok, "an unknown proposal is still unknown")
    }
}

/// An executor that reports back whether the ledger let it run.
private struct BlockExecutor: ProposalExecutor {
    let body: () -> PrivacyExecution
    init(_ body: @escaping () -> PrivacyExecution) { self.body = body }
    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution { body() }
}

// MARK: - The two entry points against one gate

extension PrivacyBridgeTests {
    /// The chain a caller cannot shorten: propose, then approve, and EventKit is only
    /// ever reached with a receipt this ledger minted for this id and this verb.
    func testApprovalWithoutAReceiptNeverReachesEventKit() async {
        let gateway = FakeGateway()
        let hub = PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox())
        let signer = PrivacyApprovalSigner(key: Data("chain-test-key-0123456789abc".utf8))
        let ledger = PrivacyProposalLedger(signer: signer, executor: hub, fileURL: nil, loadFromDisk: false)
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(allowCalendarAccess: true),
            gateway: gateway, ledger: ledger, hub: hub,
            sandbox: WorkspaceSandbox(), nodeReference: "n1"
        )
        let proposed = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "proposals",
                                                           payload: ["action": .string("create"),
                                                                     "title": .string("standup"),
                                                                     "startIso": .string("2026-01-05T09:00:00Z"),
                                                                     "endIso": .string("2026-01-05T09:30:00Z")]))
        XCTAssertTrue(proposed.ok, proposed.body)
        guard let proposal = await ledger.pending().first else { return XCTFail("nothing was proposed") }
        XCTAssertEqual(gateway.commits.isEmpty, true, "a proposal alone must never write")

        // The shape a phone sends when it only knows the id, and the shape a forged
        // body takes: both stop at the gate.
        let noReceipts: [[String: JSONValue]] = [[:], ["receipt": .string("")], ["receipt": .string("   ")],
                                                 ["receipt": .string("guess")]]
        for payload in noReceipts {
            let refused = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "approve",
                                                             id: proposal.id, payload: payload))
            XCTAssertFalse(refused.ok, "payload \(payload) must not approve")
            XCTAssertEqual(refused.status, 403)
        }
        XCTAssertTrue(gateway.commits.isEmpty, "every refusal above had to leave the calendar alone")

        let receipt = await ledger.receipt(id: proposal.id, verb: "approve")
        let applied = await engine.handle(PrivacyToolCall(namespace: .calendar, action: "approve",
                                                          id: proposal.id,
                                                          payload: ["receipt": .string(receipt)]))
        XCTAssertTrue(applied.ok, applied.body)
        XCTAssertEqual(gateway.commits.count, 1, "exactly one write, for exactly one click")
    }

    func testAReceiptFromAnotherInstallIsRefused() async {
        let (ledger, _) = makeLedger()
        _ = await ledger.propose(PrivacyProposal(id: probeId, domain: .calendar, action: .create))
        // Same algorithm, different key: what a copied or re-derived token looks like.
        let foreign = PrivacyApprovalSigner(key: Data("some-other-nodes-key-98765432".utf8))
        let outcome = await ledger.approve(id: probeId, receipt: foreign.receipt(id: probeId, verb: "approve"))
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("令牌无效") || outcome.message.contains("receipt"),
                      outcome.message)
    }

    func testToolRouteParsesTheApprovalPathTheNodeItselfAdvertises() {
        // `approvePath`/`rejectPath` in a tool reply are built by a function, not a
        // literal, so the console route census cannot see them. If the parser and the
        // builder ever disagree, a phone taps a card and gets a 404 — this is the seam.
        let id = "ppx-pr-7f3a91"
        let path = ConsoleRoute.proposalDecision("calendar", id: id, verb: "approve")
        guard let call = PrivacyToolRoute.parse(path: path) else {
            return XCTFail("\(path) is advertised by the node but refused by its own parser")
        }
        XCTAssertEqual(call.namespace, .calendar)
        XCTAssertEqual(call.action, "approve")
        XCTAssertEqual(call.id, id)
        for refused in ["/v1/tools/calendar/proposals/../../etc/approve",
                        "/v1/tools/calendar/proposals//approve",
                        "/v1/tools/calendar/proposals/\(id)/delete",
                        "/v1/tools/secrets/proposals/\(id)/approve",
                        "/v1/tools/calendar/proposals/\(id)"] {
            XCTAssertNil(PrivacyToolRoute.parse(path: refused), "\(refused) should not parse")
        }
    }

    func testCommandChannelRefusesAnIdBearingActionThatNamesNoProposal() {
        XCTAssertNotNil(PrivacyToolRoute.parseCommand(serviceId: "calendar", action: "approve",
                                                     payload: "{\"proposalId\":\"\(probeId)\"}"))
        for payload in ["{}", "{\"proposalId\":\"\"}", "{\"proposalId\":\"../x\"}", ""] {
            XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "calendar", action: "approve", payload: payload),
                         "an approve that names no proposal is not a call: \(payload)")
        }
        // Actions that need no id still accept an empty payload.
        XCTAssertNotNil(PrivacyToolRoute.parseCommand(serviceId: "calendar", action: "availability", payload: ""))
    }

    /// The wire grammar and the tool table must agree, or a namespace exists that a
    /// phone can name but the node silently refuses to parse.
    func testEveryPrivacyNamespaceIsAServiceTheCommandParserAccepts() {
        for namespace in PrivacyToolNamespace.allCases {
            XCTAssertTrue(NodeWire.isKnownService(namespace.rawValue),
                          "\(namespace.rawValue) is a tool but not a service id")
            XCTAssertNotNil(PrivacyToolRoute.parseCommand(
                serviceId: namespace.rawValue, action: PrivacyToolAction.availability, payload: "{}"
            ), "\(namespace.rawValue) does not round-trip through the command grammar")
        }
        XCTAssertFalse(NodeWire.isKnownService("secrets"))
    }

    func testSnapshotCarriesTheCeilingsThePanelIsAllowedToAssume() {        // The page seeds its form from these two fields instead of restating Swift
        // defaults, so a drift here is a panel that lies about what can be configured.
        XCTAssertEqual(PrivacyBridgeSnapshot.empty.directoryCeiling, PrivacyBridgeConfig.maximumDirectories)
        XCTAssertEqual(PrivacyBridgeSnapshot.empty.bridges, PrivacyBridgeConfig())
    }
}

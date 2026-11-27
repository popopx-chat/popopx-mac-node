//
//  PersonalAssistantTests.swift
//  PopopxMacNode — the private assistant's approval contract.
//
//  Everything here runs against injected fakes: a fake IMAP/SMTP transport, a fake
//  smart-home provider and a manual clock. What is being proved is not that mail
//  arrives or a plug restarts, but that no write happens without an owner receipt
//  bound to the exact content, and that no credential or full mail body reaches a
//  snapshot, a phone card or the SQLite audit log.
//

import Foundation
import XCTest
@testable import PopopxMacNode

// MARK: - Fakes

private enum AssistantFakeError: Error {
    case mailFailed
}

private actor AssistantFakeMailTransport: MailTransporting {
    private var inbox: [MailFetchedMessage] = []
    private(set) var fetchCalls = 0
    private(set) var fetchPasswords: [String] = []
    private(set) var sent: [MailOutgoingDraft] = []
    private(set) var sentPasswords: [String] = []
    private var failFetch = false
    private var failSend = false

    func setInbox(_ messages: [MailFetchedMessage]) { inbox = messages }
    func setFailFetch(_ value: Bool) { failFetch = value }
    func setFailSend(_ value: Bool) { failSend = value }

    func fetchRecent(
        account: MailAssistantConfig,
        password: String,
        since: Date,
        limit: Int
    ) async throws -> [MailFetchedMessage] {
        fetchCalls += 1
        fetchPasswords.append(password)
        if failFetch { throw AssistantFakeError.mailFailed }
        return Array(inbox.prefix(limit))
    }

    func send(draft: MailOutgoingDraft, account: MailAssistantConfig, password: String) async throws {
        if failSend { throw AssistantFakeError.mailFailed }
        sent.append(draft)
        sentPasswords.append(password)
    }
}

private actor AssistantFakeSentinelProvider: HomeSentinelEntityProviding {
    private var entities: [SmartHomeEntityCard] = []
    private var readOnly = false
    private var outcome = HomeRepairOutcome(ok: true, detail: "已重启智能插座 / plug restarted")
    private(set) var repairs: [HubCallPayload] = []

    func set(entities: [SmartHomeEntityCard], readOnly: Bool = false) {
        self.entities = entities
        self.readOnly = readOnly
    }

    func setOutcome(_ value: HomeRepairOutcome) { outcome = value }

    func sentinelEntities() async -> [SmartHomeEntityCard] { entities }
    func sentinelReadOnly() async -> Bool { readOnly }

    func performSentinelRepair(_ payload: HubCallPayload) async -> HomeRepairOutcome {
        repairs.append(payload)
        return outcome
    }
}

private actor AssistantRecordingDelivery {
    private var results: [CommandResult] = []
    private var accept = true

    func setAccept(_ value: Bool) { accept = value }

    func deliver(_ result: CommandResult) async -> Bool {
        results.append(result)
        return accept
    }

    func all() -> [CommandResult] { results }
}

// MARK: - Fixtures

private let assistantImapPassword = "imap-secret-123"
private let assistantSMTPPassword = "smtp-secret-456"
private let assistantMailbox = "owner@example.com"
private let assistantFullBodyMarker = "FULL-BODY-MARKER-DO-NOT-LEAK"

private struct AssistantHarness {
    let root: URL
    let clock: ManualAssistantClock
    let store: AssistantAuditStore
    let gate: AssistantApprovalGate
    let scheduler: LocalTaskScheduler
    let mail: MailAssistantBridge
    let sentinel: HomeSentinelLoop
    let delivery: AssistantRecordingDelivery
    let secrets: VolatileSecretStore
    let transport: AssistantFakeMailTransport
    let provider: AssistantFakeSentinelProvider
    let manager: PersonalAssistantManager

    var databaseURL: URL { root.appendingPathComponent("ledger/assistant.sqlite3") }
}

private func makeMailConfig(enabled: Bool = true) -> MailAssistantConfig {
    MailAssistantConfig(
        enabled: enabled,
        imapHost: "imap.example.com",
        imapPort: 993,
        smtpHost: "smtp.example.com",
        smtpPort: 465,
        username: assistantMailbox,
        fromAddress: assistantMailbox
    )
}

private func storedMailSecrets() -> [String: String] {
    [
        "assistant/mail/imap-password": assistantImapPassword,
        "assistant/mail/smtp-password": assistantSMTPPassword
    ]
}

private func makeAssistantHarness(
    config: AssistantConfig,
    now: Date,
    inbox: [MailFetchedMessage] = [],
    entities: [SmartHomeEntityCard] = [],
    readOnly: Bool = false,
    secrets: [String: String] = [:]
) async -> AssistantHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ppx-assistant-\(UUID().uuidString)", isDirectory: true)
    let clock = ManualAssistantClock(now)
    let store = AssistantAuditStore(path: root.appendingPathComponent("ledger/assistant.sqlite3").path)
    let gate = AssistantApprovalGate(
        signer: AssistantApprovalSigner(key: Data((0..<32).map { UInt8($0) })),
        clock: clock,
        audit: store
    )
    let transport = AssistantFakeMailTransport()
    await transport.setInbox(inbox)
    let provider = AssistantFakeSentinelProvider()
    await provider.set(entities: entities, readOnly: readOnly)
    let secretStore = VolatileSecretStore(secrets: secrets)
    let scheduler = LocalTaskScheduler(config: config, clock: clock, store: store)
    let mail = MailAssistantBridge(
        config: config.mail,
        secrets: secretStore,
        transport: transport,
        gate: gate,
        store: store,
        clock: clock
    )
    let sentinel = HomeSentinelLoop(
        config: config,
        provider: provider,
        gate: gate,
        store: store,
        clock: clock
    )
    let delivery = AssistantRecordingDelivery()
    let manager = PersonalAssistantManager(
        config: config,
        privacy: PrivacyBridgeConfig.disabled,
        hub: HubConfig.disabled,
        godsEyeEnabled: false,
        secrets: secretStore,
        gate: gate,
        store: store,
        scheduler: scheduler,
        mail: mail,
        sentinel: sentinel,
        clock: clock
    ) { result in
        await delivery.deliver(result)
    }
    // Deliberately not `manager.apply`: that is the production entry point that
    // starts the background loop, and a manual-clock test drives `tickNow` itself.
    return AssistantHarness(
        root: root,
        clock: clock,
        store: store,
        gate: gate,
        scheduler: scheduler,
        mail: mail,
        sentinel: sentinel,
        delivery: delivery,
        secrets: secretStore,
        transport: transport,
        provider: provider,
        manager: manager
    )
}

private func localMorning(
    year: Int = 2026,
    month: Int = 11,
    day: Int = 27,
    hour: Int = 8,
    minute: Int = 0
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    return Calendar.current.date(from: components)!
}

private func fixtureMessages(now: Date) -> [MailFetchedMessage] {
    let padded = String(repeating: "a", count: 400) + assistantFullBodyMarker
    return [
        MailFetchedMessage(
            id: "m1",
            subject: "Question about the proposal?",
            from: "Alice <alice@example.com>",
            receivedAt: now.addingTimeInterval(-600),
            body: "Could you please reply with the numbers? " + padded
        ),
        MailFetchedMessage(
            id: "m2",
            subject: "Invoice INV-2026-12-05",
            from: "billing@vendor.example",
            receivedAt: now.addingTimeInterval(-500),
            body: "Amount due: USD 1,234.56"
        ),
        MailFetchedMessage(
            id: "m3",
            subject: "Calendar invite: project sync",
            from: "bob@example.com",
            receivedAt: now.addingTimeInterval(-400),
            body: "Team meeting on Zoom."
        ),
        MailFetchedMessage(
            id: "m4",
            subject: "Security alert",
            from: "no-reply@alerts.example",
            receivedAt: now.addingTimeInterval(-300),
            body: "A new sign-in was recorded."
        )
    ]
}

private func assistantApprovalFields(from body: String, action: String) -> [String: String]? {
    let marker = "assistant::\(action)::"
    guard let line = body.split(separator: "\n").first(where: { $0.contains(marker) }),
          let range = line.range(of: marker) else { return nil }
    let payload = String(line[range.upperBound...])
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let fields = object as? [String: String] else { return nil }
    return fields
}

private func encodedText<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Tests

final class PersonalAssistantTests: XCTestCase {

    // MARK: Configuration and persistence

    func testAssistantConfigDefaultsOffAndNormalisationClosesEveryWrite() {
        let off = AssistantConfig()
        XCTAssertFalse(off.enabled)
        XCTAssertFalse(off.briefing.enabled)
        XCTAssertFalse(off.patrol.enabled)
        XCTAssertFalse(off.mail.enabled)
        XCTAssertTrue(off.repairs.isEmpty)
        XCTAssertFalse(off.anyLoopEnabled)

        let switchedOff = AssistantConfig(
            enabled: false,
            briefing: AssistantBriefingConfig(enabled: true),
            patrol: AssistantPatrolConfig(enabled: true),
            mail: makeMailConfig(),
            repairs: [SentinelRepairRule(watchEntity: "sensor.gateway", repairEntity: "switch.plug")]
        ).normalised
        XCTAssertFalse(switchedOff.briefing.enabled, "a master switch off must close the briefing")
        XCTAssertFalse(switchedOff.patrol.enabled, "a master switch off must close the patrol")
        XCTAssertFalse(switchedOff.mail.enabled, "a master switch off must close mail")

        let downgraded = MailAssistantConfig(
            enabled: true,
            imapHost: "imap.example.com",
            imapPort: 143,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            username: assistantMailbox,
            fromAddress: assistantMailbox
        ).normalised
        XCTAssertEqual(downgraded.imapPort, 0, "IMAP 143 is a STARTTLS downgrade this node does not offer")
        XCTAssertEqual(downgraded.smtpPort, 0, "SMTP 587 is a STARTTLS downgrade this node does not offer")
        XCTAssertFalse(downgraded.usable)

        XCTAssertEqual(MailAssistantConfig(imapHost: "https://imap.example.com").normalised.imapHost, "")
        XCTAssertEqual(MailAssistantConfig(username: " Owner@Example.com ").normalised.username, "Owner@Example.com")
        XCTAssertEqual(MailAssistantConfig(fromAddress: " Owner@Example.com ").normalised.fromAddress, "owner@example.com")
        XCTAssertTrue(makeMailConfig().usable, "the 993/465 pair is a writable account")

        let repair = SentinelRepairRule(watchEntity: "sensor.gateway", repairEntity: "switch.plug")
        XCTAssertTrue(repair.usable, "homeassistant.turn_on is a valid service even without a second dot")
        XCTAssertFalse(
            SentinelRepairRule(
                watchEntity: "sensor.gateway",
                repairEntity: "switch.plug",
                repairService: "turn.on"
            ).usable,
            "a dotted service would make the HA executor split three path segments"
        )
        XCTAssertFalse(
            SentinelRepairRule(watchEntity: "sensor.gateway", repairEntity: "switch.plug#x").usable
        )
    }

    func testAssistantSettingsRoundTripAndLegacyDocumentStaysOff() throws {
        let plain = NodeSettings()
        XCTAssertNil(plain.assistant)
        XCTAssertFalse(plain.assistantConfig.enabled)
        let legacyData = try XCTUnwrap(NodeJSON.encodePretty(plain))
        XCTAssertFalse(String(data: legacyData, encoding: .utf8)?.contains("\"assistant\"") == true,
                       "a document written before this feature has no assistant section")
        let legacy = try XCTUnwrap(NodeJSON.decode(NodeSettings.self, from: legacyData))
        XCTAssertFalse(legacy.assistantConfig.enabled, "an older document must decode with the assistant off")

        let config = AssistantConfig(
            enabled: true,
            briefing: AssistantBriefingConfig(enabled: true, hour: 8, minute: 0),
            patrol: AssistantPatrolConfig(enabled: true, intervalMinutes: 30, offlineMinutes: 15),
            mail: makeMailConfig(),
            repairs: [SentinelRepairRule(
                watchEntity: "sensor.gateway",
                repairEntity: "switch.plug",
                repairDomain: "homeassistant",
                repairService: "turn_on",
                offlineMinutes: 15,
                enabled: true
            )]
        )
        let settings = plain.withAssistant(config)
        let data = try XCTUnwrap(NodeJSON.encodePretty(settings))
        let reread = try XCTUnwrap(NodeJSON.decode(NodeSettings.self, from: data))
        XCTAssertEqual(reread.assistantConfig, config, "the owner's switches must survive a save/load cycle")
        XCTAssertTrue(reread.assistantConfig.briefing.enabled)
        XCTAssertEqual(reread.assistantConfig.mail.imapPort, 993)
        XCTAssertEqual(reread.assistantConfig.repairs.first?.repairEntity, "switch.plug")
    }

    func testApprovalSignerPersistsAnOwnerOnlyKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppx-assistant-key-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("vault/assistant-approval.key")

        let first = AssistantApprovalSigner.loadOrCreate(at: url)
        XCTAssertEqual(first.key.count, 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600,
                       "the approval key must not be readable by other accounts")

        let second = AssistantApprovalSigner.loadOrCreate(at: url)
        XCTAssertEqual(first.key, second.key, "a restart must keep the same approval key")
    }

    func testAuditRedactionScrubsCredentialShapes() {
        let scrubbed = AssistantRedaction.scrub(
            "login failed password: hunter2 token=abc Authorization: Bearer sk-live-123"
        )
        XCTAssertFalse(scrubbed.contains("hunter2"))
        XCTAssertFalse(scrubbed.contains("token=abc"))
        XCTAssertFalse(scrubbed.contains("sk-live-123"))
        XCTAssertTrue(scrubbed.contains("password: •"))

        let json = AssistantRedaction.scrub("{\"api_key\":\"sk-live-123\",\"note\":\"ok\"}")
        XCTAssertFalse(json.contains("sk-live-123"))
        XCTAssertTrue(json.contains("\"api_key\":\"•\""))
    }

    // MARK: The gate itself

    func testGateBindsKindTargetDigestAndIsSingleUse() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppx-assistant-gate-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AssistantAuditStore(path: root.appendingPathComponent("audit.sqlite3").path)
        let gate = AssistantApprovalGate(
            signer: AssistantApprovalSigner(key: Data(repeating: 0x7B, count: 32)),
            clock: ManualAssistantClock(now),
            audit: store
        )
        let digest = AssistantDigest.sha256("the approved content")
        let ticket = try await gate.propose(
            kind: .mailSend,
            target: "alice@example.com",
            digest: digest,
            title: "发送邮件",
            ttl: 60,
            now: now
        )
        XCTAssertEqual(ticket.receipt.count, AssistantApprovalSigner.receiptLength)
        XCTAssertFalse(encodedText(ticket.card).contains(ticket.receipt),
                       "a poll card must never carry the capability")

        do {
            _ = try await gate.validateExecution(
                id: ticket.proposalID,
                receipt: ticket.receipt,
                kind: .mailSend,
                target: "alice@example.com",
                digest: digest,
                now: now
            )
            XCTFail("a pending proposal must not authorize execution")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .notApproved)
        }

        _ = try await gate.decide(id: ticket.proposalID, verb: "approve", receipt: ticket.receipt, now: now)

        do {
            _ = try await gate.validateExecution(
                id: ticket.proposalID, receipt: ticket.receipt,
                kind: .homeService, target: "alice@example.com", digest: digest, now: now
            )
            XCTFail("a mail receipt must not authorize a home write")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .bindingMismatch("kind"))
        }

        do {
            _ = try await gate.validateExecution(
                id: ticket.proposalID, receipt: ticket.receipt,
                kind: .mailSend, target: "bob@example.com", digest: digest, now: now
            )
            XCTFail("a changed recipient must be refused")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .bindingMismatch("target"))
        }

        do {
            _ = try await gate.validateExecution(
                id: ticket.proposalID, receipt: ticket.receipt,
                kind: .mailSend, target: "alice@example.com",
                digest: AssistantDigest.sha256("changed content"), now: now
            )
            XCTFail("changed content must be refused")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .bindingMismatch("digest"))
        }

        let authorization = try await gate.validateExecution(
            id: ticket.proposalID, receipt: ticket.receipt,
            kind: .mailSend, target: "alice@example.com", digest: digest, now: now
        )
        XCTAssertEqual(authorization.digest, digest)
        XCTAssertEqual(authorization.target, "alice@example.com")

        do {
            _ = try await gate.validateExecution(
                id: ticket.proposalID, receipt: ticket.receipt,
                kind: .mailSend, target: "alice@example.com", digest: digest, now: now
            )
            XCTFail("one receipt must authorize exactly one write")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .alreadyExecuted)
        }

        do {
            _ = try await gate.decide(id: ticket.proposalID, verb: "approve", receipt: ticket.receipt, now: now)
            XCTFail("an approved proposal must not be decided twice")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .notPending)
        }
        await store.close()
    }

    func testGateRefusesAForgedReceiptExpiryAndCancellation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppx-assistant-gate2-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AssistantAuditStore(path: root.appendingPathComponent("audit.sqlite3").path)
        let clock = ManualAssistantClock(now)
        let gate = AssistantApprovalGate(
            signer: AssistantApprovalSigner(key: Data(repeating: 0x11, count: 32)),
            clock: clock,
            audit: store
        )
        let digest = AssistantDigest.sha256("body")

        let expiring = try await gate.propose(
            kind: .mailSend, target: "alice@example.com", digest: digest,
            title: "expiring", ttl: 60, now: now
        )
        do {
            _ = try await gate.decide(
                id: expiring.proposalID, verb: "approve",
                receipt: "forged-receipt", now: now
            )
            XCTFail("a forged receipt must not approve")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .receiptInvalid)
        }
        _ = try await gate.decide(
            id: expiring.proposalID, verb: "approve",
            receipt: expiring.receipt, now: now
        )
        clock.advance(61)
        do {
            _ = try await gate.validateExecution(
                id: expiring.proposalID, receipt: expiring.receipt,
                kind: .mailSend, target: "alice@example.com", digest: digest, now: clock.now
            )
            XCTFail("an approval must expire with its binding")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .expired)
        }

        let cancellable = try await gate.propose(
            kind: .homeService, target: "homeassistant.turn_on#switch.plug",
            digest: digest, title: "cancellable", ttl: 600, now: clock.now
        )
        let cancelled = await gate.cancelPending(reason: "owner switched the assistant off", now: clock.now)
        XCTAssertGreaterThanOrEqual(cancelled, 1)
        let state = await gate.state(id: cancellable.proposalID, now: clock.now)
        XCTAssertEqual(state, .rejected)
        let receipt = await gate.receipt(id: cancellable.proposalID, now: clock.now)
        XCTAssertNil(receipt, "a cancelled proposal must not mint a console receipt")
        do {
            _ = try await gate.validateExecution(
                id: cancellable.proposalID, receipt: cancellable.receipt,
                kind: .homeService, target: "homeassistant.turn_on#switch.plug",
                digest: digest, now: clock.now
            )
            XCTFail("a cancelled authorization must not execute")
        } catch let error as AssistantGateError {
            XCTAssertEqual(error, .rejected)
        }
        await store.close()
    }

    // MARK: Scheduler

    func testManagerDoesNotStartTheLoopWhenSwitchedOff() async {
        let harness = await makeAssistantHarness(config: .disabled, now: localMorning(hour: 7, minute: 59))
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await harness.manager.start()
        let status = await harness.manager.schedulerStatus(now: harness.clock.now)
        XCTAssertFalse(status.running)
        XCTAssertFalse(status.briefingEnabled)
        await harness.manager.stop()
        let delivered = await harness.delivery.all()
        XCTAssertTrue(delivered.isEmpty)
        await harness.store.close()
    }

    func testDailyBriefingFiresOnceAtEightAndPersistsItsAudit() async throws {
        let before = localMorning(hour: 7, minute: 59)
        let eight = localMorning()
        let config = AssistantConfig(
            enabled: true,
            briefing: AssistantBriefingConfig(enabled: true, hour: 8, minute: 0)
        )
        let harness = await makeAssistantHarness(config: config, now: before)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        await harness.manager.tickNow(now: before)
        var delivered = await harness.delivery.all()
        XCTAssertTrue(delivered.isEmpty, "07:59 is before the configured 08:00")

        await harness.manager.tickNow(now: eight)
        delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 1)
        let briefing = try XCTUnwrap(delivered.first)
        XCTAssertTrue(briefing.headline.contains("私人助手简报"))
        XCTAssertTrue(briefing.body.contains("邮件：未启用"))
        XCTAssertEqual(briefing.metrics["briefing"], .bool(true))
        XCTAssertEqual(briefing.cardLabel, "POPOPX 私人助手 / Private Assistant")

        let status = await harness.scheduler.status(now: eight)
        XCTAssertTrue(status.briefingEnabled)
        XCTAssertFalse(status.running, "the manual tick path must not rely on a background loop")
        let last = try XCTUnwrap(status.lastBriefingAt)
        XCTAssertEqual(last.timeIntervalSince1970, eight.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(status.nextBriefingAt)

        await harness.manager.tickNow(now: eight.addingTimeInterval(3_600))
        delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 1, "a later tick on the same day must not repeat the briefing")

        let persisted = await harness.store.stateDate(AssistantAuditStore.stateKeyBriefing)
        XCTAssertEqual(persisted?.timeIntervalSince1970 ?? 0, eight.timeIntervalSince1970, accuracy: 1)

        let tomorrow = localMorning(day: 28)
        await harness.manager.tickNow(now: tomorrow)
        delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 2, "the next day gets its own briefing")

        await harness.store.close()
        let reopened = AssistantAuditStore(url: harness.databaseURL)
        let events = await reopened.recent(limit: 100).map { $0.event }
        XCTAssertTrue(events.contains("briefing"), "the run is a durable audit row")
        XCTAssertTrue(events.contains("briefing.done"))
        let tomorrowState = await reopened.stateDate(AssistantAuditStore.stateKeyBriefing)
        XCTAssertEqual(tomorrowState?.timeIntervalSince1970 ?? 0, tomorrow.timeIntervalSince1970, accuracy: 1)
        await reopened.close()
    }

    func testPatrolRespectsTheConfiguredInterval() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(
            enabled: true,
            patrol: AssistantPatrolConfig(enabled: true, intervalMinutes: 30, offlineMinutes: 15)
        )
        let harness = await makeAssistantHarness(config: config, now: start)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        await harness.manager.tickNow(now: start)
        var delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 1, "the first tick runs the patrol")
        let firstReport = try XCTUnwrap(delivered.first)
        XCTAssertTrue(firstReport.headline.contains("家庭设备"))

        await harness.manager.tickNow(now: start.addingTimeInterval(60))
        delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 1, "a tick inside the interval must not run the patrol again")

        await harness.manager.tickNow(now: start.addingTimeInterval(31 * 60))
        delivered = await harness.delivery.all()
        XCTAssertEqual(delivered.count, 2, "the patrol runs again after its interval")
        await harness.store.close()
    }

    // MARK: Mail read path

    func testMailTriageClassifiesExtractsAndDraftsWithoutLeaking() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(enabled: true, mail: makeMailConfig())
        let harness = await makeAssistantHarness(
            config: config,
            now: now,
            inbox: fixtureMessages(now: now),
            secrets: storedMailSecrets()
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        let triage = await harness.mail.triage(now: now)
        XCTAssertEqual(triage.messages.count, 4)
        let byID = Dictionary(uniqueKeysWithValues: triage.messages.map { ($0.id, $0) })
        XCTAssertEqual(byID["m1"]?.category, .needsReply)
        XCTAssertEqual(byID["m1"]?.needsReply, true)
        XCTAssertEqual(byID["m2"]?.category, .bill)
        XCTAssertTrue(byID["m2"]?.amount.contains("1,234.56") == true)
        XCTAssertEqual(byID["m2"]?.deadline, "2026-12-05")
        XCTAssertEqual(byID["m3"]?.category, .invitation)
        XCTAssertEqual(byID["m4"]?.category, .notification)
        XCTAssertFalse(triage.messages.contains { $0.snippet.contains(assistantFullBodyMarker) },
                       "the snapshot snippet is bounded and cannot carry the full body")

        XCTAssertEqual(triage.drafts.count, 1, "only the needs-reply message produces a draft")
        let draft = try XCTUnwrap(triage.drafts.first)
        XCTAssertEqual(draft.to, "alice@example.com")
        XCTAssertTrue(draft.subject.hasPrefix("Re: "))
        XCTAssertFalse(draft.body.isEmpty)

        let fetchPasswords = await harness.transport.fetchPasswords
        XCTAssertEqual(fetchPasswords, [assistantImapPassword], "the IMAP password comes from the injected secret store")
        let fetchCalls = await harness.transport.fetchCalls
        XCTAssertEqual(fetchCalls, 1)

        let cards = await harness.mail.draftCards()
        XCTAssertTrue(cards.isEmpty, "triage alone drafts; only propose creates an approval card")

        let mailCard = await harness.mail.status()
        XCTAssertTrue(mailCard.imapStored)
        XCTAssertTrue(mailCard.smtpStored)
        XCTAssertEqual(mailCard.credentialBacking, "memory")
        let encodedCard = encodedText(mailCard)
        XCTAssertFalse(encodedCard.contains(assistantImapPassword))
        XCTAssertFalse(encodedCard.contains(assistantSMTPPassword))
        XCTAssertFalse(encodedCard.contains(assistantFullBodyMarker))

        let rows = await harness.store.recent(limit: 100)
        let auditText = rows.map { $0.detail }.joined(separator: "\n")
        XCTAssertFalse(auditText.contains(assistantImapPassword))
        XCTAssertFalse(auditText.contains(assistantSMTPPassword))
        XCTAssertFalse(auditText.contains(assistantFullBodyMarker))
        await harness.store.close()
    }

    func testMailCredentialIsStoredByReferenceAndNeverEchoed() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(enabled: true, mail: makeMailConfig())
        let harness = await makeAssistantHarness(config: config, now: now)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        let report = await harness.manager.storeMailCredential(kind: "imap", secret: assistantImapPassword, now: now)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.reference, "assistant/mail/imap-password")
        XCTAssertFalse(report.detail.contains(assistantImapPassword))
        XCTAssertEqual(harness.secrets.secret(for: "assistant/mail/imap-password"), assistantImapPassword)
        XCTAssertFalse(encodedText(report).contains(assistantImapPassword))

        let refused = await harness.manager.storeMailCredential(kind: "other", secret: assistantImapPassword, now: now)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.reference.isEmpty)

        let snapshot = await harness.manager.snapshot(now: now)
        XCTAssertTrue(snapshot.mail.imapStored)
        let encodedSnapshot = encodedText(snapshot)
        XCTAssertFalse(encodedSnapshot.contains(assistantImapPassword))
        XCTAssertFalse(encodedSnapshot.contains(assistantSMTPPassword))
        await harness.store.close()
    }

    // MARK: Mail write path

    func testMailApprovalCardCarriesTheReceiptAndSendsOnlyAfterTheClick() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(enabled: true, mail: makeMailConfig())
        let harness = await makeAssistantHarness(
            config: config,
            now: now,
            inbox: fixtureMessages(now: now),
            secrets: storedMailSecrets()
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        let control = await harness.manager.control(verb: "refreshMail", now: now)
        XCTAssertTrue(control.ok)
        let pending = await harness.gate.pending(now: now)
        XCTAssertEqual(pending.count, 1)
        let card = try XCTUnwrap(pending.first)
        XCTAssertEqual(card.kind, .mailSend)
        XCTAssertEqual(card.target, "alice@example.com")
        XCTAssertEqual(card.digest.count, 64)
        XCTAssertEqual(card.state, .pendingUserApproval)

        let pushed = await harness.delivery.all().filter { $0.body.contains("assistant::approve::") }
        let approvalCard = try XCTUnwrap(pushed.last)
        XCTAssertTrue(approvalCard.headline.contains("待批准"))
        XCTAssertTrue(approvalCard.body.contains(card.id))
        XCTAssertFalse(approvalCard.body.contains(assistantFullBodyMarker))
        let fields = try XCTUnwrap(assistantApprovalFields(from: approvalCard.body, action: "approve"))
        XCTAssertEqual(fields["id"], card.id)
        let receipt = try XCTUnwrap(fields["receipt"])
        XCTAssertEqual(receipt.count, AssistantApprovalSigner.receiptLength)

        let forged = await harness.manager.decide(
            proposalID: card.id, verb: "approve", receipt: "forged-receipt", now: now
        )
        XCTAssertFalse(forged.ok)
        let afterForged = await harness.transport.sent
        XCTAssertTrue(afterForged.isEmpty, "a forged receipt must not reach SMTP")

        let approved = await harness.manager.decide(
            proposalID: card.id, verb: "approve", receipt: receipt, now: now
        )
        XCTAssertTrue(approved.ok)
        XCTAssertEqual(approved.outcome, "executed")
        let sent = await harness.transport.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].to, "alice@example.com")
        XCTAssertTrue(sent[0].subject.hasPrefix("Re: Question about the proposal?"))
        let sentPasswords = await harness.transport.sentPasswords
        XCTAssertEqual(sentPasswords, [assistantSMTPPassword], "SMTP uses the Keychain-held password")

        let snapshot = await harness.manager.snapshot(now: now)
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertTrue(snapshot.drafts.isEmpty)
        let encodedSnapshot = encodedText(snapshot)
        XCTAssertFalse(encodedSnapshot.contains(receipt), "a snapshot must never carry a receipt")
        XCTAssertFalse(encodedSnapshot.contains(assistantSMTPPassword))
        XCTAssertFalse(encodedSnapshot.contains(assistantFullBodyMarker))

        let replay = await harness.manager.decide(
            proposalID: card.id, verb: "approve", receipt: receipt, now: now
        )
        XCTAssertFalse(replay.ok)
        let afterReplay = await harness.transport.sent
        XCTAssertEqual(afterReplay.count, 1, "an executed proposal cannot authorize a second send")
        await harness.store.close()
    }

    func testMailExecutorRefusesUnapprovedTamperedAndExpiredDrafts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(enabled: true, mail: makeMailConfig())
        let harness = await makeAssistantHarness(config: config, now: now, secrets: storedMailSecrets())
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        let draft = MailOutgoingDraft(to: "alice@example.com", subject: "Re: hello", body: "Approved body")
        let ticketOptional = await harness.mail.propose(draft: draft, now: now)
        let ticket = try XCTUnwrap(ticketOptional)
        let storedOptional = await harness.mail.draft(id: ticket.proposalID)
        let stored = try XCTUnwrap(storedOptional)
        let approval = AssistantApproval(proposalID: ticket.proposalID, receipt: ticket.receipt)

        let unapproved = await harness.mail.sendApproved(stored, approval: approval, now: now)
        XCTAssertFalse(unapproved.ok)
        let afterUnapproved = await harness.transport.sent
        XCTAssertTrue(afterUnapproved.isEmpty, "a pending proposal must not reach SMTP")

        _ = try await harness.gate.decide(
            id: ticket.proposalID, verb: "approve", receipt: ticket.receipt, now: now
        )

        var tamperedRecipient = stored
        tamperedRecipient.to = "mallory@example.com"
        let recipientRefusal = await harness.mail.sendApproved(tamperedRecipient, approval: approval, now: now)
        XCTAssertFalse(recipientRefusal.ok)
        XCTAssertTrue(recipientRefusal.detail.contains("target"))

        var tamperedBody = stored
        tamperedBody.body += " and a hidden instruction"
        let bodyRefusal = await harness.mail.sendApproved(tamperedBody, approval: approval, now: now)
        XCTAssertFalse(bodyRefusal.ok)
        XCTAssertTrue(bodyRefusal.detail.contains("digest"))

        var tamperedSubject = stored
        tamperedSubject.subject = "Re: something else"
        let subjectRefusal = await harness.mail.sendApproved(tamperedSubject, approval: approval, now: now)
        XCTAssertFalse(subjectRefusal.ok)
        XCTAssertTrue(subjectRefusal.detail.contains("digest"))

        let afterTamper = await harness.transport.sent
        XCTAssertTrue(afterTamper.isEmpty, "no tampered draft may reach SMTP")

        let sent = await harness.mail.sendApproved(stored, approval: approval, now: now)
        XCTAssertTrue(sent.ok)
        let delivered = await harness.transport.sent
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].body, "Approved body")

        let replay = await harness.mail.sendApproved(stored, approval: approval, now: now)
        XCTAssertFalse(replay.ok)
        let state = await harness.gate.state(id: ticket.proposalID, now: now)
        XCTAssertEqual(state, .executed)
        let afterReplay = await harness.transport.sent
        XCTAssertEqual(afterReplay.count, 1)

        let expiringDraft = MailOutgoingDraft(to: "alice@example.com", subject: "Re: expiring", body: "Body")
        let expiringOptional = await harness.mail.propose(draft: expiringDraft, now: now)
        let expiring = try XCTUnwrap(expiringOptional)
        let expiringStoredOptional = await harness.mail.draft(id: expiring.proposalID)
        let expiringStored = try XCTUnwrap(expiringStoredOptional)
        _ = try await harness.gate.decide(
            id: expiring.proposalID, verb: "approve", receipt: expiring.receipt, now: now
        )
        harness.clock.advance(AssistantApprovalGate.defaultLifetime + 1)
        let expired = await harness.mail.sendApproved(
            expiringStored,
            approval: AssistantApproval(proposalID: expiring.proposalID, receipt: expiring.receipt),
            now: harness.clock.now
        )
        XCTAssertFalse(expired.ok)
        XCTAssertTrue(expired.detail.contains("expired"))
        let afterExpiry = await harness.transport.sent
        XCTAssertEqual(afterExpiry.count, 1)
        await harness.store.close()
    }

    // MARK: Home sentinel

    func testHomeSentinelWaitsForThresholdAndExecutesTheApprovedPayload() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(
            enabled: true,
            patrol: AssistantPatrolConfig(enabled: true, intervalMinutes: 5, offlineMinutes: 15),
            repairs: [SentinelRepairRule(
                watchEntity: "sensor.gateway",
                repairEntity: "switch.plug",
                repairDomain: "homeassistant",
                repairService: "turn_on",
                offlineMinutes: 15,
                enabled: true
            )]
        )
        let entities = [SmartHomeEntityCard(
            entityID: "sensor.gateway",
            display: "客厅网关",
            domain: "sensor",
            state: "unavailable",
            source: "homeassistant"
        )]
        let harness = await makeAssistantHarness(config: config, now: start, entities: entities)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        let first = await harness.manager.control(verb: "patrolNow", now: start)
        XCTAssertTrue(first.ok)
        let firstPending = await harness.gate.pending(now: start)
        XCTAssertTrue(firstPending.isEmpty, "one scan is not yet fifteen offline minutes")
        let firstScan = await harness.sentinel.lastScan()
        XCTAssertEqual(firstScan?.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 1)

        harness.clock.advance(16 * 60)
        let moment = harness.clock.now
        let second = await harness.manager.control(verb: "patrolNow", now: moment)
        XCTAssertTrue(second.ok)
        let pending = await harness.gate.pending(now: moment)
        XCTAssertEqual(pending.count, 1)
        let card = try XCTUnwrap(pending.first)
        XCTAssertEqual(card.kind, .homeService)
        XCTAssertEqual(card.target, "homeassistant.turn_on#switch.plug")
        XCTAssertEqual(card.digest.count, 64)
        XCTAssertTrue(card.title.contains("客厅网关"))
        let pushed = await harness.delivery.all().filter {
            $0.headline.contains("待批准") || $0.body.contains("assistant::approve::")
        }
        XCTAssertFalse(pushed.isEmpty, "the repair suggestion must be pushed as a phone card")

        let decision = await harness.manager.consoleDecide(
            proposalID: card.id, verb: "approve", now: moment
        )
        XCTAssertTrue(decision.ok)
        XCTAssertEqual(decision.outcome, "executed")

        let repairs = await harness.provider.repairs
        XCTAssertEqual(repairs.count, 1, "approval executes exactly one repair")
        let payload = try XCTUnwrap(repairs.first)
        XCTAssertEqual(payload.kind, .haService)
        XCTAssertEqual(payload.serverID, "homeassistant")
        XCTAssertEqual(payload.target, "homeassistant.turn_on")
        XCTAssertEqual(payload.arguments["entity_id"], .string("switch.plug"))
        XCTAssertEqual(payload.arguments["source"], .string("assistant.sentinel"))
        let state = await harness.gate.state(id: card.id, now: moment)
        XCTAssertEqual(state, .executed)

        let replay = await harness.manager.consoleDecide(
            proposalID: card.id, verb: "approve", now: moment
        )
        XCTAssertFalse(replay.ok)
        let afterReplay = await harness.provider.repairs
        XCTAssertEqual(afterReplay.count, 1)
        await harness.store.close()
    }

    func testHomeSentinelDoesNotProposeWhenTheBridgeIsReadOnly() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(
            enabled: true,
            patrol: AssistantPatrolConfig(enabled: true, intervalMinutes: 30, offlineMinutes: 15),
            repairs: [SentinelRepairRule(
                watchEntity: "sensor.gateway",
                repairEntity: "switch.plug",
                offlineMinutes: 15
            )]
        )
        let entities = [SmartHomeEntityCard(
            entityID: "sensor.gateway",
            display: "客厅网关",
            state: "unavailable"
        )]
        let harness = await makeAssistantHarness(
            config: config, now: start, entities: entities, readOnly: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        _ = await harness.sentinel.scan(now: start)
        harness.clock.advance(16 * 60)
        let report = await harness.sentinel.scan(now: harness.clock.now)
        XCTAssertEqual(report.anomalies.count, 1)
        XCTAssertEqual(report.proposed, 0)
        XCTAssertTrue(report.skipped.contains { $0.contains("只读模式") || $0.contains("read-only") })
        let pending = await harness.gate.pending(now: harness.clock.now)
        XCTAssertTrue(pending.isEmpty)
        let repairs = await harness.provider.repairs
        XCTAssertTrue(repairs.isEmpty, "a read-only bridge cannot be repaired even with a proposal")
        await harness.store.close()
    }

    func testHomeSentinelExecutorRefusesAForeignReceipt() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let config = AssistantConfig(
            enabled: true,
            patrol: AssistantPatrolConfig(enabled: true, intervalMinutes: 5, offlineMinutes: 15),
            repairs: [SentinelRepairRule(
                watchEntity: "sensor.gateway",
                repairEntity: "switch.plug",
                offlineMinutes: 15
            )]
        )
        let entities = [SmartHomeEntityCard(entityID: "sensor.gateway", state: "unavailable")]
        let harness = await makeAssistantHarness(config: config, now: start, entities: entities)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }

        _ = await harness.sentinel.scan(now: start)
        harness.clock.advance(16 * 60)
        _ = await harness.sentinel.scan(now: harness.clock.now)
        let pending = await harness.gate.pending(now: harness.clock.now)
        let card = try XCTUnwrap(pending.first)

        let foreign = await harness.sentinel.perform(
            proposalID: card.id,
            approval: AssistantApproval(proposalID: card.id, receipt: "not-the-owner"),
            now: harness.clock.now
        )
        XCTAssertFalse(foreign.ok)
        let repairs = await harness.provider.repairs
        XCTAssertTrue(repairs.isEmpty, "the executor must not touch the bridge without a valid receipt")
        let state = await harness.gate.state(id: card.id, now: harness.clock.now)
        XCTAssertEqual(state, .pendingUserApproval, "a refused receipt leaves the proposal pending")
        await harness.store.close()
    }
}
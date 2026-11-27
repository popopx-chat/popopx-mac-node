//
//  OperationsDoctorTests.swift
//  PopopxMacNode — the four operations seams, on fakes that can fail.
//
//  What is proved here is the part that can be proved without the owner's Mac:
//  * the episodic index answers from sealed rows and leaves no plaintext marker on
//    disk, even though the full-text index still matches;
//  * a voice file outside quarantine is refused, and an approved action is the only
//    road that writes a transcript into the index;
//  * the doctor turns every probe into a row, scrubs a credential-shaped detail and
//    never treats a volatile Keychain store as a persistent one;
//  * the watchdog's LaunchAgent uses fixed loopback argv, installs and removes the
//    same path, throttles its checks and dedupes an alert inside the cooldown.
//

import Foundation
import XCTest
@testable import PopopxMacNode

// MARK: - Helpers

private func makeTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ppx-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class PersistentTestSecrets: HubSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    let isPersistent = true
    let backingName = "test-keychain"

    func store(_ value: String, for reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[reference] = value
        return true
    }

    func secret(for reference: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[reference]
    }

    func delete(reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: reference)
        return true
    }
}

private struct FixedVoiceTranscriber: VoiceTranscribing {
    let engineName = "test-on-device"
    let isOnDevice = true
    let text: String

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, locale: Locale) async throws -> VoiceTranscript {
        VoiceTranscript(text: text, engine: engineName, onDevice: true)
    }
}

/// A notifying sink. `@unchecked Sendable` is honest here: every access is under
/// the lock, and the test reads it only after `check()` has returned.
private final class WatchdogDeliverySink: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [CommandResult] = []

    func append(_ result: CommandResult) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rows.append(result)
        return true
    }

    var delivered: [CommandResult] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
}

// MARK: - LocalEpisodicRAG

final class LocalEpisodicRAGTests: XCTestCase {
    func testSealedIndexAnswersWithCitationsAndLeavesNoPlaintextOnDisk() async throws {
        let dir = try makeTemporaryDirectory("rag")
        let database = dir.appendingPathComponent("rag.sqlite3")
        let key = dir.appendingPathComponent("rag.key")
        let rag = LocalEpisodicRAG(databaseURL: database, keyURL: key)
        let marker = "zebraquartz\(UUID().uuidString.prefix(6))"
        let stored = await rag.record(
            kind: .document,
            title: "Budget \(marker)",
            body: "The confidential \(marker) budget was 4321 dollars.",
            source: "workspace/budget.txt",
            occurredAt: Date()
        )
        XCTAssertNotNil(stored)

        let answer = await rag.ask("where is the \(marker) budget")
        XCTAssertTrue(answer.ok)
        let citation = try XCTUnwrap(answer.citations.first)
        XCTAssertTrue(citation.title.contains(marker))
        XCTAssertTrue(citation.snippet.contains(marker))

        let card = await rag.status()
        XCTAssertTrue(card.healthy)
        XCTAssertTrue(card.fts5)
        XCTAssertTrue(card.encrypted)
        XCTAssertEqual(card.entries, 1)
        XCTAssertEqual(card.documents, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: key.path))

        // The sealed bytes are the whole point: search the database and any
        // rollback journal for the private marker. FTS still matched above, so the
        // absence is not explained by an empty index.
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix(database.lastPathComponent) {
            let data = try Data(contentsOf: file)
            XCTAssertNil(data.range(of: Data(marker.utf8)), "\(file.lastPathComponent) leaked the body")
        }

        // A fresh actor with the persisted key must be able to open the same rows.
        let reopened = LocalEpisodicRAG(databaseURL: database, keyURL: key)
        let again = await reopened.ask(marker)
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.citations.first?.title, "Budget \(marker)")
    }

    func testScopeIndexingWalksOnlyAuthorizedTextFiles() async throws {
        let dir = try makeTemporaryDirectory("rag-scope")
        let root = dir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = "harvest\(UUID().uuidString.prefix(6))"
        try "A note about \(marker) and its renewal date.".write(
            to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8
        )
        try "binary-ish".write(
            to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8
        )
        let rag = LocalEpisodicRAG(
            databaseURL: dir.appendingPathComponent("rag.sqlite3"),
            keyURL: dir.appendingPathComponent("rag.key")
        )
        let report = await rag.indexScopeRoots([root.path])
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.indexed, 1, "only the .txt extension is indexable")
        let answer = await rag.ask(marker)
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertEqual(answer.citations.first?.kind, .document)
    }

    func testNoScopeRootsIsARefusalNotAnEmptySuccess() async throws {
        let dir = try makeTemporaryDirectory("rag-empty")
        let rag = LocalEpisodicRAG(
            databaseURL: dir.appendingPathComponent("rag.sqlite3"),
            keyURL: dir.appendingPathComponent("rag.key")
        )
        let report = await rag.indexScopeRoots([])
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.indexed, 0)
        XCTAssertTrue(report.detail.contains("没有授权目录"))
    }
}

// MARK: - LocalVoiceMemoPipeline

final class LocalVoiceMemoPipelineTests: XCTestCase {
    private func makePipeline(
        dir: URL,
        transcript: String,
        inbox: URL
    ) -> (pipeline: LocalVoiceMemoPipeline, rag: LocalEpisodicRAG, store: AssistantAuditStore) {
        let rag = LocalEpisodicRAG(
            databaseURL: dir.appendingPathComponent("rag.sqlite3"),
            keyURL: dir.appendingPathComponent("rag.key")
        )
        let store = AssistantAuditStore(url: dir.appendingPathComponent("audit.sqlite3"))
        let pipeline = LocalVoiceMemoPipeline(
            transcribers: [FixedVoiceTranscriber(text: transcript)],
            rag: rag,
            store: store,
            inboxRoots: [inbox]
        )
        return (pipeline, rag, store)
    }

    func testIngestKeepsTheTranscriptInMemoryUntilTheApprovedActionRuns() async throws {
        let dir = try makeTemporaryDirectory("voice")
        let inbox = dir.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let audio = inbox.appendingPathComponent("memo.m4a")
        try Data("fake audio \(UUID().uuidString)".utf8).write(to: audio)
        let marker = "dentist\(UUID().uuidString.prefix(5))"
        let harness = makePipeline(
            dir: dir,
            transcript: "Remind me to call the \(marker) tomorrow.",
            inbox: inbox
        )
        let report = await harness.pipeline.ingest(audioURL: audio)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.actions.count, 1)
        XCTAssertEqual(report.actions.first?.kind, .todo)
        let pendingAfterIngest = await harness.pipeline.pendingCount()
        XCTAssertEqual(pendingAfterIngest, 1)
        let before = await harness.rag.status()
        XCTAssertEqual(before.voices, 0, "transcription alone must not write the index")

        let item = try XCTUnwrap(report.actions.first)
        let binding = AssistantApprovalBinding(
            kind: .voiceTask,
            target: item.target,
            digest: item.digest,
            expiresAt: Date().addingTimeInterval(900)
        )
        let wrong = await harness.pipeline.perform(
            target: item.target,
            binding: AssistantApprovalBinding(
                kind: .voiceTask,
                target: item.target,
                digest: "not-the-digest",
                expiresAt: binding.expiresAt
            )
        )
        XCTAssertFalse(wrong.ok, "a changed digest must not authorize the write")
        let pendingAfterWrong = await harness.pipeline.pendingCount()
        XCTAssertEqual(pendingAfterWrong, 1)

        let applied = await harness.pipeline.perform(target: item.target, binding: binding)
        XCTAssertTrue(applied.ok)
        let pendingAfterApply = await harness.pipeline.pendingCount()
        XCTAssertEqual(pendingAfterApply, 0)
        let after = await harness.rag.status()
        XCTAssertEqual(after.voices, 1)
        let answer = await harness.rag.ask(marker)
        XCTAssertEqual(answer.citations.first?.kind, .voice)
    }

    func testAudioOutsideQuarantineIsRefusedBeforeTranscription() async throws {
        let dir = try makeTemporaryDirectory("voice-outside")
        let inbox = dir.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let outside = dir.appendingPathComponent("memo.m4a")
        try Data("not in quarantine".utf8).write(to: outside)
        let harness = makePipeline(dir: dir, transcript: "Remind me now.", inbox: inbox)
        let report = await harness.pipeline.ingest(audioURL: outside)
        XCTAssertFalse(report.ok)
        let pending = await harness.pipeline.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testUnsupportedExtensionIsRefused() async throws {
        let dir = try makeTemporaryDirectory("voice-extension")
        let inbox = dir.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("memo.exe")
        try Data("not audio".utf8).write(to: file)
        let harness = makePipeline(dir: dir, transcript: "Remind me now.", inbox: inbox)
        let report = await harness.pipeline.ingest(audioURL: file)
        XCTAssertFalse(report.ok)
        let pending = await harness.pipeline.pendingCount()
        XCTAssertEqual(pending, 0)
    }
}

// MARK: - LiveIntegrationDoctor

final class LiveIntegrationDoctorTests: XCTestCase {
    func testKeychainProbeDistinguishesPersistentAndVolatileStores() async {
        let persistent = LiveIntegrationDoctor.keychainProbe(PersistentTestSecrets())
        let report = await LiveIntegrationDoctor(probes: [persistent]).run()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.checks.first?.state, .ok)

        let volatile = LiveIntegrationDoctor.keychainProbe(VolatileSecretStore())
        let warning = await LiveIntegrationDoctor(probes: [volatile]).run()
        XCTAssertTrue(warning.ok, "a warning is not a failed probe")
        XCTAssertEqual(warning.checks.first?.state, .warning)
        XCTAssertTrue(warning.checks.first?.detail.contains("volatile") == true)
    }

    func testDoctorRedactsCredentialShapesAndKeepsAFailureRow() async {
        let probes = [
            DoctorProbe(id: "leak", title: "Leaky server") {
                .failed("password: hunter2 token=abc123 Authorization: Bearer sk-xyz")
            },
            DoctorProbe(id: "skipped", title: "Not configured") {
                .skipped("off")
            }
        ]
        let report = await LiveIntegrationDoctor(probes: probes).run()
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.checks.count, 2, "a thrown/refused probe still gets a row")
        let detail = report.checks.first?.detail ?? ""
        for secret in ["hunter2", "abc123", "sk-xyz"] {
            XCTAssertFalse(detail.contains(secret), "the doctor leaked \(secret)")
        }
        XCTAssertEqual(report.checks.last?.state, .skipped)
        XCTAssertTrue(report.headline.contains("1"))
    }

    func testMailProbeSkipsAnUnconfiguredAccountWithoutDialing() async {
        let probe = LiveIntegrationDoctor.mailProbe(
            MailAssistantConfig(),
            secrets: VolatileSecretStore()
        )
        let report = await LiveIntegrationDoctor(probes: [probe]).run()
        XCTAssertEqual(report.checks.first?.state, .skipped)
    }

    func testCalendarAndSmartHomeProbesReportOffRatherThanInventAConnection() async {
        let caldav = LiveIntegrationDoctor.calendarProbe(CalDavBridge())
        let home = LiveIntegrationDoctor.smartHomeProbe(nil)
        let report = await LiveIntegrationDoctor(probes: [caldav, home]).run()
        XCTAssertEqual(report.checks.first?.state, .skipped)
        XCTAssertEqual(report.checks.last?.state, .skipped)
        XCTAssertTrue(report.ok)
    }
}

// MARK: - SystemWatchdog

final class SystemWatchdogTests: XCTestCase {
    func testLaunchAgentUsesExactLoopbackArgumentsAndEscapes() {
        let args = LaunchAgentSpec.programArguments(executablePath: "/Applications/Node.app/Contents/MacOS/Node")
        XCTAssertEqual(args, [
            "/Applications/Node.app/Contents/MacOS/Node",
            "--loopback-only", "--console-host", "127.0.0.1", "--console-port", "18920"
        ])
        let plist = LaunchAgentSpec.plist(
            executablePath: "/tmp/Node & Co.app/Node",
            stdoutPath: "/tmp/out.log",
            stderrPath: "/tmp/err.log"
        )
        XCTAssertTrue(plist.contains("chat.popopx.mac-node"))
        XCTAssertTrue(plist.contains("Node &amp; Co"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("127.0.0.1"))
        XCTAssertFalse(plist.contains("0.0.0.0"))
    }

    func testInstallAndUninstallTouchOnlyTheLaunchAgentPath() async throws {
        let dir = try makeTemporaryDirectory("watchdog-install")
        let plist = dir.appendingPathComponent("chat.popopx.mac-node.plist")
        let watchdog = SystemWatchdog(
            plistURL: plist,
            executablePath: "/Applications/Node.app/Contents/MacOS/Node",
            probes: [],
            restart: { _ in true },
            deliver: { _ in true },
            auditURL: dir.appendingPathComponent("watchdog.jsonl")
        )
        let installed = await watchdog.install()
        XCTAssertTrue(installed.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        let text = try String(contentsOf: plist, encoding: .utf8)
        XCTAssertTrue(text.contains("--loopback-only"))
        XCTAssertTrue(text.contains("127.0.0.1"))
        let attributes = try FileManager.default.attributesOfItem(atPath: plist.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let removed = await watchdog.uninstall()
        XCTAssertTrue(removed.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testCheckFloorBackoffAndAlertDedupe() async throws {
        let dir = try makeTemporaryDirectory("watchdog-check")
        let sink = WatchdogDeliverySink()
        let probe = WatchdogProbe(target: .daemon) {
            WatchdogSample(target: .daemon, state: .failed, detail: "daemon down token=supersecret", restartable: true)
        }
        let watchdog = SystemWatchdog(
            plistURL: dir.appendingPathComponent("launch.plist"),
            executablePath: "/Applications/Node.app/Contents/MacOS/Node",
            probes: [probe],
            restart: { _ in false },
            deliver: { result in sink.append(result) },
            auditURL: dir.appendingPathComponent("watchdog.jsonl")
        )
        let start = Date()
        let first = await watchdog.check(now: start, force: true)
        XCTAssertTrue(first.checked)
        XCTAssertEqual(first.alerts.count, 1, "the first failure alerts once")
        XCTAssertEqual(sink.delivered.count, 1)
        var card = await watchdog.card()
        XCTAssertEqual(card.restartCount, 1)
        XCTAssertNotNil(card.pendingRestartAt)

        // Inside both the 30 s backoff and the 30 min alert cooldown: no restart,
        // no second card. The floor is bypassed because this check is forced, so the
        // assertions are about backoff/dedupe rather than about `checked`.
        let second = await watchdog.check(now: start.addingTimeInterval(10), force: true)
        XCTAssertTrue(second.checked)
        XCTAssertTrue(second.alerts.isEmpty)
        XCTAssertEqual(sink.delivered.count, 1)
        card = await watchdog.card()
        XCTAssertEqual(card.restartCount, 1)
        let pending = try XCTUnwrap(card.pendingRestartAt)
        XCTAssertGreaterThan(pending, start.addingTimeInterval(10))

        // The unforced floor is separate: a check 30 s after the last one does not run.
        let throttled = await watchdog.check(now: start.addingTimeInterval(30))
        XCTAssertFalse(throttled.checked)
        XCTAssertTrue(throttled.alerts.isEmpty)

        let audit = try String(
            contentsOf: dir.appendingPathComponent("watchdog.jsonl"),
            encoding: .utf8
        )
        XCTAssertFalse(audit.contains("supersecret"), "the watchdog audit leaked a token")
        XCTAssertTrue(audit.contains("restart_failed"))
    }
}
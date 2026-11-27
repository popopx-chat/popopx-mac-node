//
//  ExperienceTests.swift
//  PopopxMacNode — the zero-terminal experience layer, on fakes and pure values.
//
//  What is proved here:
//  * the `/api/pull` NDJSON grammar is decoded without trusting the last event,
//    the percent never walks backwards, and readiness compares canonical tags;
//  * `ModelPullCenter` reaches `ready` only after `/api/tags` lists the model,
//    reports a missing tag as failed, cancels cooperatively and refuses a
//    non-local reference before any stream is opened;
//  * the lightweight plan keeps every deterministic feature on and names the two
//    model-only rows it turns off;
//  * the wizard's four steps and the menu bar's light are resolved from the same
//    values, including the explicit skip-into-lightweight path;
//  * the six mail presets are inherent-TLS templates that survive the transport's
//    own `normalised` validator, and the console ships them.
//

import Foundation
import XCTest
@testable import PopopxMacNode

// MARK: - Pull fakes

private final class FakePullTransport: ModelPullTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: [String]
    private var requested: [String] = []
    private let lines: [String]
    private let tagsError: Bool
    private let lingers: Bool

    init(lines: [String], installed: [String], tagsError: Bool = false, lingers: Bool = false) {
        self.lines = lines
        self.installed = installed
        self.tagsError = tagsError
        self.lingers = lingers
    }

    var requestedRefs: [String] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func pullStream(ref: String) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        requested.append(ref)
        lock.unlock()
        let lines = self.lines
        let lingers = self.lingers
        return AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines { continuation.yield(line) }
                if lingers {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func installedRefs() async throws -> [String] {
        if tagsError { throw ModelPullError.http(500) }
        return installedSnapshot()
    }

    private func installedSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return installed
    }
}

// MARK: - Pull grammar and center

final class ExperiencePullTests: XCTestCase {
    func testParserDecodesLayerAndStatusOnlyLinesAndIgnoresNoise() throws {
        XCTAssertNil(ModelPullProgressParser.decode("pulling manifest"))
        XCTAssertNil(ModelPullProgressParser.decode(""))
        XCTAssertNil(ModelPullProgressParser.decode("  [keep-alive]  "))

        let statusOnly = try XCTUnwrap(
            ModelPullProgressParser.decode(#"{"status":"verifying sha256 digest"}"#)
        )
        XCTAssertEqual(statusOnly.status, "verifying sha256 digest")
        XCTAssertNil(statusOnly.fraction)

        let layer = try XCTUnwrap(
            ModelPullProgressParser.decode(#"{"status":"pulling","digest":"sha256:aa","total":200,"completed":50}"#)
        )
        XCTAssertEqual(layer.fraction, 0.25)
        XCTAssertEqual(layer.total, 200)
        XCTAssertEqual(layer.completed, 50)
    }

    func testPercentIsMonotonicAndCappedAtTheCeiling() throws {
        let quarter = try XCTUnwrap(ModelPullProgressParser.decode(#"{"total":200,"completed":50}"#))
        XCTAssertEqual(ModelPullProgressParser.percent(current: 0, event: quarter), 25)
        XCTAssertEqual(ModelPullProgressParser.percent(current: 80, event: quarter), 80,
                       "Ollama re-sends per-layer totals; the bar must never walk backwards")

        let complete = try XCTUnwrap(ModelPullProgressParser.decode(#"{"total":100,"completed":100}"#))
        XCTAssertEqual(ModelPullProgressParser.percent(current: 0, event: complete), 99,
                       "100 is reserved for a verified /api/tags listing")

        let statusOnly = try XCTUnwrap(ModelPullProgressParser.decode(#"{"status":"success"}"#))
        XCTAssertEqual(ModelPullProgressParser.percent(current: 42, event: statusOnly), 42)
        XCTAssertTrue(statusOnly.isSuccess)
    }

    func testReferenceMatchingTreatsAnUntaggedNameAsLatest() {
        XCTAssertTrue(ModelPullProgressParser.referenceMatches("inkling-2-mini:latest", "inkling-2-mini"))
        XCTAssertTrue(ModelPullProgressParser.referenceMatches(" qwen3.8:9b-q4_k_m ", "qwen3.8:9b-q4_k_m"))
        XCTAssertFalse(ModelPullProgressParser.referenceMatches("inkling-2-mini:q4_k_m", "inkling-2-mini"),
                       "a different tag is a different artifact")
        XCTAssertFalse(ModelPullProgressParser.referenceMatches("qwen3.8:27b-q8_0", "qwen3.8:9b-q4_k_m"))
    }

    func testPullCenterMapsACatalogIDAndBecomesReadyAfterVerify() async {
        let catalogID = ModelCatalog.qwen38_9b_q4.id
        let expected = ModelRefOverrides.resolve(option: ModelCatalog.qwen38_9b_q4, submitted: catalogID)
        let transport = FakePullTransport(
            lines: [
                #"{"status":"pulling manifest"}"#,
                #"{"status":"pulling 8c17","digest":"sha256:aa","total":1000,"completed":500}"#,
                #"{"status":"pulling 8c17","digest":"sha256:aa","total":1000,"completed":1000}"#,
                #"{"status":"success"}"#
            ],
            installed: [expected]
        )
        let center = ModelPullCenter(transport: transport)
        let started = await center.start(ref: catalogID)
        XCTAssertEqual(started.state, .pulling)
        XCTAssertEqual(started.modelRef, expected, "a catalog id is a UI token; the daemon gets its reference")

        let settled = await center.waitForCompletion(timeout: 5)
        XCTAssertEqual(settled.state, .ready)
        XCTAssertEqual(settled.percent, 100)
        XCTAssertEqual(settled.completedBytes, 1000)
        XCTAssertEqual(settled.totalBytes, 1000)
        XCTAssertEqual(transport.requestedRefs, [expected])
    }

    func testPullCenterFailsWhenTheTagIsAbsentFromTags() async {
        let transport = FakePullTransport(
            lines: [#"{"status":"success"}"#],
            installed: ["another-model:latest"]
        )
        let center = ModelPullCenter(transport: transport)
        await center.start(ref: "ppx-test-model:latest")
        let settled = await center.waitForCompletion(timeout: 5)
        XCTAssertEqual(settled.state, .failed)
        XCTAssertEqual(settled.status, "not-listed")
        XCTAssertNotEqual(settled.percent, 100, "a finished download is not a verified model")
    }

    func testPullCenterFailsWhenTagsCannotBeRead() async {
        let transport = FakePullTransport(
            lines: [#"{"status":"success"}"#],
            installed: ["ppx-test-model:latest"],
            tagsError: true
        )
        let center = ModelPullCenter(transport: transport)
        await center.start(ref: "ppx-test-model:latest")
        let settled = await center.waitForCompletion(timeout: 5)
        XCTAssertEqual(settled.state, .failed)
        XCTAssertEqual(settled.status, "verify-failed")
    }

    func testPullCenterCancelsCooperatively() async {
        let transport = FakePullTransport(
            lines: [#"{"status":"pulling","total":100,"completed":10}"#],
            installed: [],
            lingers: true
        )
        let center = ModelPullCenter(transport: transport)
        let started = await center.start(ref: "ppx-test-model:cancel")
        XCTAssertEqual(started.state, .pulling)

        let cancelled = await center.cancel()
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.status, "cancelled")
        let current = await center.current()
        XCTAssertEqual(current.state, .cancelled)
    }

    func testPullCenterIgnoresASecondStartWhileRunning() async {
        let transport = FakePullTransport(lines: [], installed: [], lingers: true)
        let center = ModelPullCenter(transport: transport)
        let first = await center.start(ref: "ppx-test-model:one")
        let second = await center.start(ref: "ppx-test-model:two")
        XCTAssertEqual(first.modelRef, "ppx-test-model:one")
        XCTAssertEqual(second.modelRef, "ppx-test-model:one",
                       "a second click must not spawn a second download")
        _ = await center.cancel()
    }

    func testPullCenterRefusesEmptyAndRemoteLookingReferences() async {
        let center = ModelPullCenter(transport: FakePullTransport(lines: [], installed: []))
        let empty = await center.start(ref: "   ")
        XCTAssertEqual(empty.state, .refused)

        let remote = await center.start(ref: "http://example.com/model")
        XCTAssertEqual(remote.state, .refused)
        XCTAssertTrue(remote.detail.contains("不合法") || remote.detail.contains("invalid"))
    }
}

// MARK: - Lightweight plan and node mode

final class ExperienceLightweightTests: XCTestCase {
    func testLightweightPlanKeepsDeterministicFeaturesAndNamesTheTwoModelRows() {
        let rows = LightweightModePlan.resolve(lightweight: true)
        XCTAssertEqual(rows.count, LightweightModePlan.features.count,
                       "a disabled capability stays visible; it must not vanish")
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for id in ["rag", "voice", "mail", "bridges", "sentinel", "watchdog", "pairing"] {
            XCTAssertEqual(byID[id]?.enabled, true, "\(id) is deterministic and must keep working")
        }
        XCTAssertEqual(byID["multimodal"]?.enabled, false)
        XCTAssertEqual(byID["structured"]?.enabled, false)
        XCTAssertEqual(
            LightweightModePlan.disabledByLightweight(rows).map(\.id).sorted(),
            ["multimodal", "structured"]
        )
        XCTAssertTrue(LightweightModePlan.resolve(lightweight: false).allSatisfy { $0.enabled })
    }

    func testLocalModelCardLightweightOverridesAReadyModel() {
        let enhanced = LocalModelCard.resolve(
            lightweight: false, modelRef: "inkling-2-mini", modelReady: true, pull: .idle
        )
        XCTAssertEqual(enhanced.mode.mode, .enhanced)
        XCTAssertEqual(enhanced.mode.health, "ok")
        XCTAssertTrue(enhanced.guidanceZh.contains("已就绪"))

        let lightweight = LocalModelCard.resolve(
            lightweight: true, modelRef: "inkling-2-mini", modelReady: true, pull: .idle
        )
        XCTAssertEqual(lightweight.mode.mode, .lightweight)
        XCTAssertEqual(lightweight.mode.health, "off")
        XCTAssertFalse(lightweight.mode.modelReady,
                       "a cached ready probe cannot contradict the owner's zero-model switch")
        XCTAssertTrue(lightweight.guidanceZh.contains("零模型"))
        XCTAssertFalse(lightweight.features.first { $0.id == "structured" }!.enabled)
    }

    func testIntelligenceModeHealthCoversAllThreeLights() {
        XCTAssertEqual(NodeIntelligenceMode.resolve(lightweight: false, modelReady: true).health, "ok")
        XCTAssertEqual(NodeIntelligenceMode.resolve(lightweight: false, modelReady: false).health, "warn")
        XCTAssertEqual(NodeIntelligenceMode.resolve(lightweight: true, modelReady: true).health, "off")
        XCTAssertTrue(NodeIntelligenceMode.resolve(lightweight: true, modelReady: true)
            .headlineZh.contains("纯轻量"))
        XCTAssertTrue(NodeIntelligenceMode.resolve(lightweight: false, modelReady: true)
            .headlineEn.contains("ready"))
    }

    func testMenuBarSummaryAggregatesTheSnapshot() {
        let summary = MenuBarSummary.resolve(
            lightweight: false,
            modelReady: false,
            daemonLive: true,
            pairedCount: 2,
            pendingCount: 3,
            watchdogInstalled: true,
            launchAtLogin: false
        )
        XCTAssertEqual(summary.mode.health, "warn")
        XCTAssertTrue(summary.daemonLive)
        XCTAssertEqual(summary.pairedCount, 2)
        XCTAssertEqual(summary.pendingCount, 3)
        XCTAssertTrue(summary.watchdogInstalled)
        XCTAssertEqual(summary.approvalBadge, "3")

        let quiet = MenuBarSummary.resolve(
            lightweight: true,
            modelReady: false,
            daemonLive: false,
            pairedCount: -1,
            pendingCount: -2,
            watchdogInstalled: false,
            launchAtLogin: true
        )
        XCTAssertEqual(quiet.mode.health, "off")
        XCTAssertEqual(quiet.pairedCount, 0)
        XCTAssertEqual(quiet.pendingCount, 0)
        XCTAssertEqual(quiet.approvalBadge, "—")
        XCTAssertTrue(quiet.launchAtLogin)
    }
}

// MARK: - Setup wizard state

final class ExperienceWizardTests: XCTestCase {
    func testSkipIntoLightweightMarksTheFirstTwoStepsWithoutAModel() {
        let skipped = SetupWizardState.resolve(
            installPhase: .idle,
            lightweight: true,
            modelReady: false,
            workspaceCount: 0,
            pairedCount: 0,
            testSent: false
        )
        XCTAssertTrue(skipped.hardwareDone)
        XCTAssertTrue(skipped.workspaceDone)
        XCTAssertFalse(skipped.pairingDone)
        XCTAssertEqual(skipped.completedSteps, 2)
        XCTAssertEqual(skipped.nextStep, 3)
        XCTAssertFalse(skipped.isComplete)
    }

    func testPairingAndTestBriefingCompleteTheWizard() {
        let paired = SetupWizardState.resolve(
            installPhase: .idle,
            lightweight: true,
            modelReady: false,
            workspaceCount: 0,
            pairedCount: 1,
            testSent: false
        )
        XCTAssertEqual(paired.nextStep, 4)
        XCTAssertFalse(paired.isComplete)

        let delivered = SetupWizardState.resolve(
            installPhase: .idle,
            lightweight: true,
            modelReady: false,
            workspaceCount: 0,
            pairedCount: 1,
            testSent: true
        )
        XCTAssertTrue(delivered.isComplete)
        XCTAssertEqual(delivered.completedSteps, 4)
    }

    func testARunningInstallDoesNotCheckTheModelStep() {
        let running = SetupWizardState.resolve(
            installPhase: .pullingLLM,
            lightweight: false,
            modelReady: false,
            workspaceCount: 3,
            pairedCount: 0,
            testSent: false
        )
        XCTAssertFalse(running.hardwareDone)
        XCTAssertEqual(running.nextStep, 1)

        let ready = SetupWizardState.resolve(
            installPhase: .ready,
            lightweight: false,
            modelReady: false,
            workspaceCount: 3,
            pairedCount: 0,
            testSent: false
        )
        XCTAssertTrue(ready.hardwareDone)
        XCTAssertEqual(ready.nextStep, 3)
    }
}

// MARK: - Settings compatibility

final class ExperienceSettingsTests: XCTestCase {
    func testASettingsDocumentWrittenBeforeLightweightStillDecodes() throws {
        let encoded = try JSONEncoder().encode(NodeSettings())
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "lightweight")
        fields.removeValue(forKey: "wizardCompletedAt")
        let legacy = try JSONSerialization.data(withJSONObject: fields)

        let decoded = try JSONDecoder().decode(NodeSettings.self, from: legacy)
        XCTAssertFalse(decoded.isLightweight, "absent reads as off")
        XCTAssertFalse(decoded.wizardCompleted, "absent means the wizard never completed")

        let switched = decoded.withLightweight(true, now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(switched.isLightweight)
        XCTAssertEqual(switched.updatedAt, Date(timeIntervalSince1970: 100))

        let finished = switched.withWizardCompleted(Date(timeIntervalSince1970: 200))
        XCTAssertTrue(finished.wizardCompleted)
        XCTAssertTrue(finished.isLightweight, "finishing the wizard must not undo the mode")
        XCTAssertEqual(finished.updatedAt, Date(timeIntervalSince1970: 200))
    }
}

// MARK: - Mail presets

final class ExperienceMailPresetTests: XCTestCase {
    func testTheSixRequestedProvidersAreInherentTLSAndPassTheTransportValidator() {
        XCTAssertEqual(
            MailProviderPresets.all.map(\.id),
            ["icloud", "gmail", "outlook", "qq", "163", "proton-bridge"]
        )
        for preset in MailProviderPresets.all {
            XCTAssertEqual(preset.imapPort, 993, "\(preset.id): the node speaks IMAPS only")
            XCTAssertEqual(preset.smtpPort, 465, "\(preset.id): the node speaks SMTPS only")
            XCTAssertFalse(MailAssistantConfig.host(preset.imapHost).isEmpty, "\(preset.id) IMAP host")
            XCTAssertFalse(MailAssistantConfig.host(preset.smtpHost).isEmpty, "\(preset.id) SMTP host")
            XCTAssertTrue(MailProviderPresets.isApplicable(preset), "\(preset.id) must survive normalised")
            XCTAssertFalse(preset.appPasswordZh.isEmpty)
            XCTAssertFalse(preset.appPasswordEn.isEmpty)
            XCTAssertFalse(preset.noteZh.isEmpty)
        }
    }

    func testProtonBridgeIsTheOnlyLoopbackTemplate() {
        XCTAssertTrue(MailProviderPresets.protonBridge.loopbackOnly)
        XCTAssertEqual(MailProviderPresets.protonBridge.imapHost, "127.0.0.1")
        XCTAssertEqual(MailProviderPresets.protonBridge.smtpHost, "127.0.0.1")
        for preset in MailProviderPresets.all where preset.id != "proton-bridge" {
            XCTAssertFalse(preset.loopbackOnly)
            XCTAssertNotEqual(preset.imapHost, "127.0.0.1")
            XCTAssertNotEqual(preset.smtpHost, "127.0.0.1")
        }
    }

    func testProviderPortLimitsAreDisclosedInsteadOfHidden() {
        XCTAssertEqual(MailProviderPresets.iCloud.officialSMTPPort, 587)
        XCTAssertEqual(MailProviderPresets.outlook.officialSMTPPort, 587)
        XCTAssertEqual(MailProviderPresets.protonBridge.officialSMTPPort, 1025)
        XCTAssertNil(MailProviderPresets.gmail.officialSMTPPort)
        XCTAssertNil(MailProviderPresets.qq.officialSMTPPort)
        XCTAssertNil(MailProviderPresets.netEase163.officialSMTPPort)
        XCTAssertTrue(MailProviderPresets.iCloud.noteZh.contains("587"))
        XCTAssertTrue(MailProviderPresets.protonBridge.noteZh.contains("1143"))
    }

    func testApplyWritesOnlyTheFourServerFields() {
        let config = MailAssistantConfig(
            enabled: true,
            username: "owner@example.com",
            fromAddress: "owner@example.com",
            imapPasswordRef: "assistant/mail/a",
            smtpPasswordRef: "assistant/mail/b",
            lookbackDays: 7,
            maxMessages: 20
        )
        let applied = MailProviderPresets.apply(MailProviderPresets.gmail, to: config)
        XCTAssertEqual(applied.imapHost, "imap.gmail.com")
        XCTAssertEqual(applied.imapPort, 993)
        XCTAssertEqual(applied.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(applied.smtpPort, 465)
        XCTAssertEqual(applied.username, config.username)
        XCTAssertEqual(applied.fromAddress, config.fromAddress)
        XCTAssertEqual(applied.imapPasswordRef, config.imapPasswordRef)
        XCTAssertEqual(applied.smtpPasswordRef, config.smtpPasswordRef)
        XCTAssertEqual(applied.lookbackDays, 7)
        XCTAssertEqual(applied.maxMessages, 20)
        XCTAssertTrue(applied.enabled)
        XCTAssertTrue(applied.usable)

        let normalised = MailProviderPresets.apply(MailProviderPresets.qq, to: config).normalised
        XCTAssertEqual(normalised.imapHost, "imap.qq.com")
        XCTAssertEqual(normalised.imapPort, 993)
        XCTAssertEqual(normalised.smtpPort, 465)
    }
}

// MARK: - Served page

final class ExperienceConsoleTests: XCTestCase {
    func testThePageShipsEveryMailPresetAndTheModelControls() {
        let html = WEBConsoleHTML.document
        XCTAssertFalse(html.contains("/*PPX_MAIL*/[]"), "the server must substitute the preset registry")
        for preset in MailProviderPresets.all {
            XCTAssertTrue(html.contains("id:\"\(preset.id)\""), "\(preset.id) is missing from the page")
            XCTAssertTrue(html.contains(preset.imapHost), "\(preset.id)'s host is missing from the page")
        }
        XCTAssertTrue(html.contains("/api/model/control"))
        XCTAssertTrue(html.contains("modelPull:"), "the exported PPX object must own the pull action")
        XCTAssertTrue(html.contains("modelLightweight:"))
        XCTAssertTrue(html.contains("lightweightOn"), "the mode button must send the server's verb")
        XCTAssertTrue(html.contains("modelModeLite"), "the card must name the zero-model mode")
    }
}
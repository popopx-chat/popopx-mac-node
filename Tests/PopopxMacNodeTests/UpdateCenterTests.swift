//
//  UpdateCenterTests.swift
//  PopopxMacNode — the signed-update contract.
//
//  Every case below corresponds to one sentence of the feature's promise:
//  detection never installs, the signature is the only thing that makes a
//  manifest worth reading, a version that is not strictly newer is not an
//  offer, and no package byte moves before an owner-signed decision. The
//  fakes count calls, because a test that only reads the outcome cannot see
//  the difference between "ignored" and "downloaded then ignored".
//

import Foundation
import XCTest
@testable import PopopxMacNode

private final class UpdateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.lock(); defer { lock.unlock() }; return value }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

private final class UpdateAuditBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UpdateAuditEntry] = []

    func add(_ entry: UpdateAuditEntry) {
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [UpdateAuditEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}

private actor RecordingUpdateTransport: UpdateTransport {
    var manifest = Data()
    var package = Data()
    var fetchFailure: Error?
    var downloadFailure: Error?
    private(set) var fetchCount = 0
    private(set) var downloadCount = 0
    private(set) var downloadedURL: URL?

    func set(manifest: Data) { self.manifest = manifest }
    func set(package: Data) { self.package = package }
    func failFetch(with error: Error) { fetchFailure = error }
    func failDownload(with error: Error) { downloadFailure = error }

    func fetch(_ url: URL, limit: Int) async throws -> Data {
        fetchCount += 1
        if let fetchFailure { throw fetchFailure }
        return manifest
    }

    func download(_ url: URL, limit: Int, to destination: URL) async throws {
        downloadCount += 1
        downloadedURL = url
        if let downloadFailure { throw downloadFailure }
        try package.write(to: destination)
    }
}

private actor RecordingUpdateInstaller: UpdateInstaller {
    var outcome = UpdateInstallOutcome(ok: true, message: "opened by macOS / 已交给 macOS")
    private(set) var installCount = 0
    private(set) var packages: [URL] = []
    private(set) var releases: [UpdateRelease] = []

    func setOutcome(_ value: UpdateInstallOutcome) { outcome = value }

    func install(package: URL, release: UpdateRelease) async -> UpdateInstallOutcome {
        installCount += 1
        packages.append(package)
        releases.append(release)
        return outcome
    }
}

final class UpdateCenterTests: XCTestCase {
    private let signer = PrivacyApprovalSigner(key: Data(repeating: 0x5a, count: 32))

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppx-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func newIdentity() throws -> SBSigning.Identity {
        try XCTUnwrap(SBSigning.generate(), "this Mac cannot mint an Ed25519 key")
    }

    private func release(
        version: String = "9.9.9",
        package: Data,
        host: String = "cdn.popopx.test",
        digest: String? = nil,
        size: Int? = nil
    ) -> UpdateRelease {
        UpdateRelease(
            version: version,
            build: 7,
            releasedAt: "2026-11-27T00:00:00Z",
            summary: ["第一项 / first", "second"],
            package: UpdatePackage(
                url: "https://\(host)/PopopxMacNode.dmg",
                sha256: digest ?? Digest.sha256Hex(package),
                size: size ?? package.count,
                format: "dmg"
            )
        )
    }

    private func manifestData(
        _ release: UpdateRelease,
        signedBy identity: SBSigning.Identity,
        signedRelease: UpdateRelease? = nil,
        schema: String = UpdateManifest.schemaIdentifier
    ) throws -> Data {
        // `signedRelease` lets a case sign one set of fields and ship another:
        // that is exactly the tamper a hostile host would attempt.
        let body = try XCTUnwrap(UpdateManifest.signingBody(schema: schema, release: signedRelease ?? release))
        let signature = try XCTUnwrap(identity.signature(for: body))
        let manifest = UpdateManifest(
            schema: schema, release: release, signature: TextKit.base64URL(signature)
        )
        return try XCTUnwrap(NodeJSON.encodeLine(manifest))
    }

    private func config(
        identity: SBSigning.Identity,
        enabled: Bool = true,
        intervalMinutes: Int = 15,
        snoozeHours: Int = 24
    ) -> UpdateConfig {
        UpdateConfig(
            enabled: enabled,
            manifestURL: "https://updates.popopx.test/manifest.json",
            publicKey: identity.publicKeyBase64URL,
            packageHosts: ["cdn.popopx.test"],
            intervalMinutes: intervalMinutes,
            snoozeHours: snoozeHours
        )
    }

    private func makeCenter(
        config: UpdateConfig,
        transport: RecordingUpdateTransport,
        installer: RecordingUpdateInstaller,
        directory: URL,
        clock: UpdateClock,
        audit: UpdateAuditBox? = nil,
        stateFile: URL? = nil
    ) -> UpdateCenter {
        UpdateCenter(
            config: config,
            transport: transport,
            installer: installer,
            signer: signer,
            stateStore: UpdateStateStore(url: stateFile ?? directory.appendingPathComponent("state.json")),
            stagingDirectory: directory.appendingPathComponent("staging", isDirectory: true),
            currentVersion: { NodeVersion(major: 1, minor: 0, patch: 2) },
            now: { clock.now },
            audit: { entry in audit?.add(entry) }
        )
    }

    // MARK: - Detection is automatic

    func testSignatureAloneMakesTheManifestAnOfferAndNothingIsDownloaded() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let outcome = await center.check()

        guard case let .available(offered) = outcome else {
            return XCTFail("a correctly signed newer release must be offered, got \(outcome)")
        }
        XCTAssertEqual(offered.version, "9.9.9")
        let fetches = await transport.fetchCount
        let downloads = await transport.downloadCount
        let installs = await installer.installCount
        XCTAssertEqual(fetches, 1, "the check fetches the manifest once")
        XCTAssertEqual(downloads, 0, "detection must never move a package byte")
        XCTAssertEqual(installs, 0, "detection must never install")

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.available?.version, "9.9.9")
        XCTAssertTrue(snapshot.usable)
        XCTAssertEqual(snapshot.keyFingerprint.count, 10)
    }

    func testTamperedReleaseFieldsAreIgnoredByTheSignature() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let honest = release(package: bytes)
        var tampered = honest
        tampered.summary = ["额外功能 / extra feature nobody signed"]
        await transport.set(manifest: try manifestData(tampered, signedBy: identity, signedRelease: honest))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let outcome = await center.check()

        guard case let .ignored(reason) = outcome else {
            return XCTFail("a tampered release must be ignored, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("签名"), "the console must say the signature failed: \(reason)")
        let downloads = await transport.downloadCount
        let installs = await installer.installCount
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(installs, 0)
        let snapshot = await center.snapshot()
        XCTAssertNil(snapshot.available, "a refused manifest must not become a pending offer")
    }

    func testManifestSignedByAnotherKeyIsIgnored() async throws {
        let identity = try newIdentity()
        let impostor = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: impostor))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let outcome = await center.check()

        guard case .ignored = outcome else {
            return XCTFail("a manifest signed by another key must be ignored, got \(outcome)")
        }
        let downloads = await transport.downloadCount
        let installs = await installer.installCount
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(installs, 0)
    }

    func testAVersionThatIsNotStrictlyNewerIsNotAnOffer() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(version: "1.0.2", package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let outcome = await center.check()

        guard case let .upToDate(version) = outcome else {
            return XCTFail("an equal version is up to date, got \(outcome)")
        }
        XCTAssertEqual(version, "1.0.2")
        let snapshot = await center.snapshot()
        XCTAssertNil(snapshot.available)
        let downloads = await transport.downloadCount
        XCTAssertEqual(downloads, 0)
    }

    func testPackageOutsideTheOwnerPinnedHostsIsRefusedBeforeTheSignature() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes, host: "mirror.example.com")
        // Signed correctly — the refusal is structural, so a valid signature
        // cannot make an unpinned package host admissible.
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let outcome = await center.check()

        guard case let .ignored(reason) = outcome else {
            return XCTFail("an unpinned package host must be ignored, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("主机"), reason)
        let downloads = await transport.downloadCount
        XCTAssertEqual(downloads, 0)
    }

    func testDisabledOrUnusableConfigNeverTouchesTheNetwork() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let release = release(package: Data("x".utf8))
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let disabled = makeCenter(
            config: config(identity: identity, enabled: false),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        let missingKey = makeCenter(
            config: UpdateConfig(
                enabled: true,
                manifestURL: "https://updates.popopx.test/manifest.json",
                publicKey: ""
            ),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )

        let off = await disabled.check()
        let incomplete = await missingKey.check()
        XCTAssertEqual(off, .disabled)
        XCTAssertEqual(incomplete, .disabled)
        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, 0, "a disabled or unusable feed must not dial out")
        let receipt = await missingKey.consoleReceipt(verb: "approve")
        XCTAssertNil(receipt)
    }

    // MARK: - Installation is not

    func testNoDecisionMeansNoDownloadAndInstall() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()
        let beforeDownloads = await transport.downloadCount
        let beforeInstalls = await installer.installCount
        XCTAssertEqual(beforeDownloads, 0)
        XCTAssertEqual(beforeInstalls, 0)

        let forged = await center.decision(verb: "approve", receipt: "not-a-receipt", source: "test")
        guard case .refused = forged else {
            return XCTFail("an invalid receipt must be refused, got \(forged)")
        }
        let afterDownloads = await transport.downloadCount
        let afterInstalls = await installer.installCount
        XCTAssertEqual(afterDownloads, 0, "a refused receipt must not start a download")
        XCTAssertEqual(afterInstalls, 0)
    }

    func testAReceiptIsBoundToItsVerb() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let release = release(package: Data("package-bytes".utf8))
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()
        let snoozeReceipt = await center.consoleReceipt(verb: "snooze")
        XCTAssertNotNil(snoozeReceipt)

        let misused = await center.decision(
            verb: "approve", receipt: snoozeReceipt ?? "", source: "test"
        )
        guard case .refused = misused else {
            return XCTFail("a snooze receipt must not approve a download, got \(misused)")
        }
        let downloads = await transport.downloadCount
        XCTAssertEqual(downloads, 0)

        let unknown = await center.decision(verb: "delete", receipt: "anything", source: "test")
        guard case .refused = unknown else {
            return XCTFail("an unknown verb must be refused, got \(unknown)")
        }
    }

    func testAnApprovedDecisionVerifiesTheBytesBeforeTheInstallerRuns() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("signed-package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))
        await transport.set(package: bytes)

        let clock = UpdateClock(Date())
        let audit = UpdateAuditBox()
        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: clock, audit: audit
        )
        _ = await center.check()
        let receipt = await center.consoleReceipt(verb: "approve")
        let decision = await center.decision(
            verb: "approve", receipt: try XCTUnwrap(receipt), source: "test"
        )

        guard case let .installed(version, _) = decision else {
            return XCTFail("a valid receipt must install, got \(decision)")
        }
        XCTAssertEqual(version, "9.9.9")
        let downloads = await transport.downloadCount
        let downloadedURL = await transport.downloadedURL
        let installs = await installer.installCount
        let installedReleases = await installer.releases
        let stagedPackages = await installer.packages
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(downloadedURL?.absoluteString, "https://cdn.popopx.test/PopopxMacNode.dmg")
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(installedReleases.first?.version, "9.9.9")
        let staged = try XCTUnwrap(stagedPackages.first)
        XCTAssertEqual(try Data(contentsOf: staged), bytes, "the installer receives the verified bytes")

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.installedVersion, "9.9.9")
        XCTAssertNil(snapshot.available, "a spent offer must not stay on the card")
        let spentReceipt = await center.consoleReceipt(verb: "approve")
        XCTAssertNil(spentReceipt)

        let outcomes = audit.all.map(\.outcome)
        XCTAssertTrue(outcomes.contains("available"))
        XCTAssertTrue(outcomes.contains("verified"))
        XCTAssertTrue(outcomes.contains("approved_installed"), "\(outcomes)")
    }

    func testADigestMismatchDropsTheOfferAndNeverInstalls() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        // Same size, different bytes: the download passes the byte-count check and
        // must die on the digest instead.
        let expected = Data(repeating: 0x41, count: 64)
        let served = Data(repeating: 0x42, count: 64)
        let release = release(package: expected)
        await transport.set(manifest: try manifestData(release, signedBy: identity))
        await transport.set(package: served)

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()
        let receipt = await center.consoleReceipt(verb: "approve")
        let decision = await center.decision(
            verb: "approve", receipt: try XCTUnwrap(receipt), source: "test"
        )

        guard case let .failed(detail) = decision else {
            return XCTFail("a digest mismatch must fail, got \(decision)")
        }
        XCTAssertTrue(detail.contains("SHA-256"), detail)
        let installs = await installer.installCount
        XCTAssertEqual(installs, 0, "unverified bytes must never reach the installer")
        let snapshot = await center.snapshot()
        XCTAssertNil(snapshot.available, "the manifest and the served bytes disagree, so the offer is dropped")
        let afterReceipt = await center.consoleReceipt(verb: "approve")
        XCTAssertNil(afterReceipt)
    }

    func testASizeMismatchNeverInstallsAndKeepsTheOfferRetryable() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))
        await transport.set(package: bytes + Data([0x00]))

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()
        let receipt = await center.consoleReceipt(verb: "approve")
        let decision = await center.decision(
            verb: "approve", receipt: try XCTUnwrap(receipt), source: "test"
        )

        guard case let .failed(detail) = decision else {
            return XCTFail("a short or long download must fail, got \(decision)")
        }
        XCTAssertTrue(detail.contains("大小"), detail)
        let installs = await installer.installCount
        XCTAssertEqual(installs, 0)
        let snapshot = await center.snapshot()
        XCTAssertNotNil(snapshot.available,
                        "a transfer error is retryable; only a digest mismatch drops the offer")
    }

    func testAnInstallerRefusalDoesNotMarkTheVersionInstalled() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        await installer.setOutcome(UpdateInstallOutcome(ok: false, message: "系统拒绝打开 / macOS refused to open"))
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))
        await transport.set(package: bytes)

        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()
        let receipt = await center.consoleReceipt(verb: "approve")
        let decision = await center.decision(
            verb: "approve", receipt: try XCTUnwrap(receipt), source: "test"
        )

        guard case let .failed(detail) = decision else {
            return XCTFail("a refused install is a failure, got \(decision)")
        }
        XCTAssertTrue(detail.contains("macOS"))
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.installedVersion, "", "a package that was only opened is not an installed version")
        XCTAssertNotNil(snapshot.available, "the owner can retry after macOS refuses")
    }

    // MARK: - Scheduling and the card

    func testSnoozeSuppressesTheTickUntilItsDeadline() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let bytes = Data("package-bytes".utf8)
        let release = release(package: bytes)
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let clock = UpdateClock(Date(timeIntervalSince1970: 1_800_000_000))
        let center = makeCenter(
            config: config(identity: identity, intervalMinutes: 15, snoozeHours: 24),
            transport: transport, installer: installer,
            directory: directory, clock: clock
        )

        let first = await center.tick()
        XCTAssertEqual(first?.version, "9.9.9")
        let immediate = await center.tick()
        XCTAssertNil(immediate, "an immediate second tick is inside the check interval")
        let fetchesAfterFirstTick = await transport.fetchCount

        let snoozeReceipt = await center.consoleReceipt(verb: "snooze")
        let snoozed = await center.decision(
            verb: "snooze", receipt: try XCTUnwrap(snoozeReceipt), source: "test"
        )
        guard case .snoozed = snoozed else {
            return XCTFail("snooze must be recorded, got \(snoozed)")
        }

        clock.advance(16 * 60)
        let suppressed = await center.tick()
        XCTAssertNil(suppressed, "a snoozed release must not be announced again")
        let fetchesDuringSnooze = await transport.fetchCount
        XCTAssertGreaterThan(fetchesDuringSnooze, fetchesAfterFirstTick,
                             "the tick still checks within the snooze window; it just does not announce")

        clock.advance(25 * 3600)
        let afterSnooze = await center.tick()
        XCTAssertEqual(afterSnooze?.version, "9.9.9", "after the snooze deadline the card is due again")

        await center.markNotified(version: "9.9.9")
        clock.advance(16 * 60)
        let announced = await center.tick()
        XCTAssertNil(announced, "a version already announced is not announced twice")
    }

    func testThePhoneCardCarriesBothCopyReadyCommands() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let release = release(package: Data("package-bytes".utf8))
        await transport.set(manifest: try manifestData(release, signedBy: identity))
        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date())
        )
        _ = await center.check()

        let maybeCommands = await center.cardCommands()
        let commands = try XCTUnwrap(maybeCommands)
        XCTAssertTrue(commands.approve.contains("updates::approve::"), commands.approve)
        XCTAssertTrue(commands.snooze.contains("updates::snooze::"), commands.snooze)
        let card = UpdateCard(release: release, approveCommand: commands.approve, snoozeCommand: commands.snooze)
        XCTAssertLessThanOrEqual(card.text.count, NodeWire.maxSignalPayloadCharacters)
        XCTAssertTrue(card.text.contains("approve="))
        XCTAssertTrue(card.text.contains("snooze="))
    }

    func testAPendingOfferSurvivesARestartAndIsReverified() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let release = release(package: Data("package-bytes".utf8))
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let first = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date()), stateFile: stateFile
        )
        _ = await first.check()

        let second = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date()), stateFile: stateFile
        )
        let restored = await second.snapshot()
        XCTAssertEqual(restored.available?.version, "9.9.9")

        // A hand-edited state file cannot stage a release the operator's key never
        // signed: `verifiedPending` re-decodes and re-verifies the stored bytes.
        let stored = try XCTUnwrap(
            NodeJSON.decode(UpdateState.self, from: Data(contentsOf: stateFile))
        )
        let text = try XCTUnwrap(stored.pendingManifest)
        var tampered = stored
        tampered.pendingManifest = text.replacingOccurrences(of: "9.9.9", with: "9.9.8")
        try XCTUnwrap(NodeJSON.encodeLine(tampered)).write(to: stateFile, options: .atomic)
        let third = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: UpdateClock(Date()), stateFile: stateFile
        )
        let refused = await third.snapshot()
        XCTAssertNil(refused.available, "a tampered stored manifest must not verify")
        let refusedReceipt = await third.consoleReceipt(verb: "approve")
        XCTAssertNil(refusedReceipt)
    }

    // MARK: - The egress validator

    func testTheUpdateURLPolicyAdmitsExactlyOnePinnedHTTPSHost() {
        let pin: Set<String> = ["updates.popopx.test"]
        XCTAssertNoThrow(
            try UpdateURLPolicy.validate("https://updates.popopx.test/manifest.json", pinnedHosts: pin),
            "control: the owner's own host must be admitted"
        )

        func refusal(_ text: String, pins: Set<String> = ["updates.popopx.test"]) -> UpdateURLPolicy.Failure? {
            do {
                _ = try UpdateURLPolicy.validate(text, pinnedHosts: pins)
                return nil
            } catch {
                return error as? UpdateURLPolicy.Failure
            }
        }

        XCTAssertEqual(refusal("http://updates.popopx.test/manifest.json"), .unsupportedScheme("http"))
        XCTAssertEqual(refusal("https://mirror.example.com/manifest.json"), .hostNotPinned("mirror.example.com"))
        XCTAssertEqual(refusal("https://updates.popopx.test:8443/manifest.json"), .nonDefaultPort(8443))
        XCTAssertEqual(refusal("https://user:secret@updates.popopx.test/manifest.json"), .credentialsInURL)
        XCTAssertEqual(refusal(""), .missingURL)
        XCTAssertNil(refusal("https://updates.popopx.test:443/manifest.json"),
                     "the explicit default port is the same port")
    }

    func testATransportFailureKeepsTheLastVerifiedOffer() async throws {
        let identity = try newIdentity()
        let directory = try makeDirectory()
        let transport = RecordingUpdateTransport()
        let installer = RecordingUpdateInstaller()
        let release = release(package: Data("package-bytes".utf8))
        await transport.set(manifest: try manifestData(release, signedBy: identity))

        let clock = UpdateClock(Date())
        let center = makeCenter(
            config: config(identity: identity),
            transport: transport, installer: installer,
            directory: directory, clock: clock
        )
        _ = await center.check()
        await transport.failFetch(with: UpdateTransportError.httpStatus(503))
        clock.advance(16 * 60)
        let outcome = await center.check()

        guard case let .failed(detail) = outcome else {
            return XCTFail("a fetch error is a failed check, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("503"), detail)
        let snapshot = await center.snapshot()
        XCTAssertNotNil(snapshot.available,
                        "a later outage does not invalidate an already-verified offer")
    }
}
//
//  UpdateCenter.swift
//  PopopxMacNode — detection is automatic, installation is not.
//
//  The actor has exactly two entry points that can fetch a package:
//  `decision(verb:receipt:source:)` with a validated receipt, and nothing else.
//  `check()` downloads only the signed manifest. The `UpdateInstaller` is called
//  at the end of an approved decision and nowhere else, which is what makes the
//  "never download or upgrade without approval" test a one-line assertion on a
//  fake's call count.
//

import Foundation

public actor UpdateCenter {
    public static let auditAction = "update"

    private let transport: any UpdateTransport
    private let installer: any UpdateInstaller
    private let stateStore: UpdateStateStore
    private let signer: PrivacyApprovalSigner
    private let stagingDirectory: URL
    private let currentVersion: @Sendable () -> NodeVersion
    private let now: @Sendable () -> Date
    private let audit: @Sendable (UpdateAuditEntry) async -> Void

    private var config: UpdateConfig
    private var state: UpdateState
    private var busy = false

    public init(
        config: UpdateConfig,
        transport: any UpdateTransport,
        installer: any UpdateInstaller,
        signer: PrivacyApprovalSigner,
        stateStore: UpdateStateStore,
        stagingDirectory: URL,
        currentVersion: @escaping @Sendable () -> NodeVersion = { NodeVersion.current },
        now: @escaping @Sendable () -> Date = { Date() },
        audit: @escaping @Sendable (UpdateAuditEntry) async -> Void = { _ in }
    ) {
        self.config = config.normalised
        self.transport = transport
        self.installer = installer
        self.signer = signer
        self.stateStore = stateStore
        self.stagingDirectory = stagingDirectory
        self.currentVersion = currentVersion
        self.now = now
        self.audit = audit
        self.state = stateStore.load()
    }

    // MARK: - Configuration

    public func update(config newConfig: UpdateConfig) {
        let normalised = newConfig.normalised
        let wasEnabled = config.enabled
        config = normalised
        if !normalised.enabled {
            state.pendingManifest = nil
            state.pendingVersion = ""
            if wasEnabled {
                state.lastError = ""
            }
            persist()
        }
    }

    

    // MARK: - Status

    public func snapshot() -> UpdateSnapshot {
        let pending = verifiedPending()
        return UpdateSnapshot(
            enabled: config.enabled,
            usable: config.usable,
            currentVersion: currentVersion().semanticString,
            manifestHost: config.manifestHost ?? "",
            pinnedHosts: config.pinnedHosts.sorted(),
            keyFingerprint: config.keyFingerprint,
            available: pending?.release,
            lastCheckAt: state.lastCheckAt,
            lastError: state.lastError,
            lastIgnored: state.lastIgnored,
            snoozedUntil: state.snoozedUntil,
            notified: !state.lastNotifiedVersion.isEmpty && state.lastNotifiedVersion == pending?.release.version,
            installedVersion: state.installedVersion,
            boundary: "https · 仅机主固定的主机 / https, owner-pinned hosts only"
        )
    }

    /// Test/debug view: the persisted document as it stands.
    func currentState() -> UpdateState { state }

    // MARK: - Checking

    /// Fetches and verifies the manifest. Version-not-newer and a bad signature
    /// are `.ignored`: no card, no download, nothing shown to the owner beyond a
    /// muted note in the console.
    @discardableResult
    public func check() async -> UpdateCheckOutcome {
        guard config.enabled, config.usable else { return .disabled }
        let pinned = config.pinnedHosts
        state.lastCheckAt = now()
        defer { persist() }

        let manifestURL: URL
        do {
            guard let host = config.manifestHost else { throw UpdateURLPolicy.Failure.missingURL }
            manifestURL = try UpdateURLPolicy.validate(config.manifestURL, pinnedHosts: [host])
        } catch {
            let detail = String(describing: error)
            state.lastError = detail
            await record("check", outcome: "refused", detail: detail)
            return .failed(detail)
        }

        let data: Data
        do {
            data = try await transport.fetch(manifestURL, limit: UpdateConfig.maximumManifestBytes)
        } catch {
            let detail = "无法读取更新清单 / could not fetch the manifest: \(error)"
            state.lastError = detail
            await record("check", outcome: "failed", detail: detail)
            return .failed(detail)
        }
        guard data.count <= UpdateConfig.maximumManifestBytes else {
            let detail = "更新清单过大 / manifest exceeded \(UpdateConfig.maximumManifestBytes) bytes"
            state.lastError = detail
            await record("check", outcome: "failed", detail: detail)
            return .failed(detail)
        }
        guard let manifest = NodeJSON.decode(UpdateManifest.self, from: data) else {
            return await ignore("更新清单无法解析 / the manifest is not valid JSON")
        }
        if let refusal = manifest.structuralRefusal(pinnedHosts: pinned) {
            return await ignore(refusal)
        }
        guard let body = manifest.signingBody else {
            return await ignore("无法重建签名体 / could not rebuild the signed body")
        }
        guard SBSigning.verify(
            publicKeyBase64URL: config.publicKey,
            signatureBase64URL: manifest.signature,
            body: body
        ) else {
            return await ignore("更新清单签名无效 / manifest signature did not verify")
        }
        guard let version = manifest.release.parsedVersion else {
            return await ignore("版本号不可解析 / release version is not major.minor.patch")
        }
        guard version.isNewer(than: currentVersion()) else {
            state.lastIgnored = ""
            state.lastError = ""
            if state.pendingManifest != nil {
                state.pendingManifest = nil
                state.pendingVersion = ""
            }
            await record("check", outcome: "up_to_date", detail: "current=\(currentVersion().semanticString)")
            return .upToDate(manifest.release.version)
        }

        state.pendingManifest = String(decoding: data, as: UTF8.self)
        state.pendingVersion = manifest.release.version
        state.lastError = ""
        state.lastIgnored = ""
        await record(
            "check",
            outcome: "available",
            detail: "\(manifest.release.version) build \(manifest.release.build) sha \(manifest.release.package.sha256.prefix(12))"
        )
        return .available(manifest.release)
    }

    /// The periodic path. Returns a release only when a card is due: a pending
    /// release that was not snoozed and was not already announced at this version.
    public func tick() async -> UpdateRelease? {
        guard config.enabled, config.usable else { return nil }
        let moment = now()
        if let last = state.lastCheckAt, moment.timeIntervalSince(last) < config.checkInterval {
            return nil
        }
        let outcome = await check()
        guard case let .available(release) = outcome else { return nil }
        if let until = state.snoozedUntil, until > moment { return nil }
        if state.lastNotifiedVersion == release.version { return nil }
        return release
    }

    private func ignore(_ reason: String) async -> UpdateCheckOutcome {
        state.lastIgnored = reason
        state.lastError = ""
        // A refused *new* manifest does not invalidate a pending release that
        // verified earlier; only approval re-verifies what is about to run.
        await record("check", outcome: "ignored", detail: reason)
        return .ignored(reason)
    }

    public func markNotified(version: String) {
        state.lastNotifiedVersion = version
        persist()
    }

    // MARK: - Approval

    /// The receipt a console button needs. Minted inside the node and never put
    /// into a snapshot or a poll payload; the console route calls this and hands
    /// the value straight back to `decision`.
    public func consoleReceipt(verb: String) -> String? {
        guard let pending = verifiedPending() else { return nil }
        guard verb == "approve" || verb == "snooze" else { return nil }
        return signer.receipt(id: identity(of: pending.release), verb: verb)
    }

    /// The two command lines carried by the phone card. Both are copy-ready; a
    /// phone that simply displays the marker still shows a readable line.
    public func cardCommands() -> (approve: String, snooze: String)? {
        guard let pending = verifiedPending() else { return nil }
        let id = identity(of: pending.release)
        let approve = command(action: "approve", release: pending.release,
                              receipt: signer.receipt(id: id, verb: "approve"))
        let snooze = command(action: "snooze", release: pending.release,
                             receipt: signer.receipt(id: id, verb: "snooze"))
        return (approve: approve, snooze: snooze)
    }

    public func decision(verb: String, receipt: String, source: String) async -> UpdateDecisionOutcome {
        guard config.enabled, config.usable else {
            return .refused("更新检查未启用 / the update feed is off")
        }
        guard verb == "approve" || verb == "snooze" else {
            return .refused("未知操作 / unknown update verb: \(verb)")
        }
        guard let pending = verifiedPending() else {
            return .refused("没有待批准的版本 / there is no verified pending release")
        }
        let id = identity(of: pending.release)
        guard signer.validate(receipt, id: id, verb: verb) else {
            await record("decision", outcome: "refused", detail: "bad receipt · \(source) · \(verb)")
            return .refused("回执无效或与版本不符 / the receipt is invalid for this release")
        }
        if verb == "snooze" {
            let until = now().addingTimeInterval(config.snoozeInterval)
            state.snoozedUntil = until
            persist()
            await record("snooze", outcome: "snoozed", detail: "until \(PrivacyStamp.iso(until)) · \(source)")
            return .snoozed(until: until)
        }
        guard !busy else { return .refused("已有一次更新正在处理 / an update is already in progress") }
        busy = true
        defer { busy = false }

        let release = pending.release
        let pinned = config.pinnedHosts
        let packageURL: URL
        do {
            packageURL = try UpdateURLPolicy.validate(release.package.url, pinnedHosts: pinned)
        } catch {
            let detail = String(describing: error)
            state.lastError = detail
            persist()
            await record("approve", outcome: "refused", detail: detail)
            return .refused(detail)
        }

        let format = release.package.format.lowercased()
        let safeVersion = TextKit.safeFileName(release.version, fallback: "release")
        let destination = stagingDirectory.appendingPathComponent(
            "\(safeVersion)-\(release.package.sha256.prefix(12)).\(format)"
        )
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try await transport.download(packageURL, limit: release.package.size, to: destination)
        } catch {
            let detail = "下载失败 / download failed: \(error)"
            state.lastError = detail
            persist()
            await record("download", outcome: "failed", detail: detail)
            return .failed(detail)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let written = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        guard written == release.package.size else {
            try? FileManager.default.removeItem(at: destination)
            let detail = "下载大小不符 / downloaded \(written) bytes, manifest says \(release.package.size)"
            state.lastError = detail
            persist()
            await record("download", outcome: "size_mismatch", detail: detail)
            return .failed(detail)
        }
        guard let digest = UpdateDigest.sha256Hex(ofFile: destination),
              Digest.matches(digest, release.package.sha256.lowercased()) else {
            try? FileManager.default.removeItem(at: destination)
            // A digest mismatch is not a retryable transfer error: the signed
            // manifest and the served bytes disagree, so the offer is dropped.
            state.pendingManifest = nil
            state.pendingVersion = ""
            state.lastError = "SHA-256 校验失败，已丢弃该更新 / digest mismatch, release dropped"
            persist()
            await record("download", outcome: "digest_mismatch", detail: "expected \(release.package.sha256.prefix(16))")
            return .failed(state.lastError)
        }

        let staged = destination
        state.stagedPath = staged.path
        persist()
        await record("download", outcome: "verified", detail: "\(release.version) · \(staged.lastPathComponent)")

        let install = await installer.install(package: staged, release: release)
        guard install.ok else {
            await record("install", outcome: "failed", detail: install.message)
            return .failed(install.message.isEmpty ? "安装包已校验但未能打开 / verified but could not be opened" : install.message)
        }
        state.pendingManifest = nil
        state.pendingVersion = ""
        state.installedVersion = release.version
        state.lastError = ""
        persist()
        await record("install", outcome: "approved_installed", detail: "\(release.version) · \(source)")
        return .installed(version: release.version, message: install.message)
    }

    // MARK: - Internals

    /// Decodes the stored document and re-verifies its signature and structure.
    /// A hand-edited state file therefore cannot stage a package the operator's
    /// key never signed.
    private func verifiedPending() -> UpdateManifest? {
        guard config.enabled, config.usable, let text = state.pendingManifest,
              let data = text.data(using: .utf8),
              let manifest = NodeJSON.decode(UpdateManifest.self, from: data),
              manifest.structuralRefusal(pinnedHosts: config.pinnedHosts) == nil,
              let body = manifest.signingBody,
              SBSigning.verify(
                publicKeyBase64URL: config.publicKey,
                signatureBase64URL: manifest.signature,
                body: body
              ) else {
            return nil
        }
        return manifest
    }

    private func identity(of release: UpdateRelease) -> String {
        "update|\(release.version)|\(release.package.sha256.prefix(12))"
    }

    private func command(action: String, release: UpdateRelease, receipt: String) -> String {
        let payload: [String: JSONValue] = [
            "v": .string(release.version),
            "rcp": .string(receipt)
        ]
        let encoded = NodeJSON.encodeLine(payload).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(NodeWire.commandPrefix)updates::\(action)::\(encoded)"
    }

    private func persist() {
        stateStore.save(state)
    }

    private func record(_ action: String, outcome: String, detail: String = "") async {
        await audit(UpdateAuditEntry(action: action, outcome: outcome, detail: detail, at: now()))
    }
}
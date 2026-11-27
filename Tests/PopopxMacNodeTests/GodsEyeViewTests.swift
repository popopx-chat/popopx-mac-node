//
//  GodsEyeViewTests.swift
//  PopopxMacNodeTests — the claims the God's Eye View bridge makes, measured.
//
//  Four groups, in the order the risk sits:
//
//  * the policy: loopback argv, install-path refusal, manifest verification, the
//    read/write classification and the gate that may only tighten it;
//  * the manager: every refusal happening *before* a launch, and a launch carrying
//    exactly the verified entry and the minimum environment;
//  * the MCP association: registration touching one entry, a read running, a canvas
//    write becoming a pending proposal, and a stop removing the registration;
//  * credentials: a value reaching the store and nothing else — not the snapshot,
//    not the audit file, not the Keychain reference.
//

import XCTest
@testable import PopopxMacNode

final class GodsEyeViewTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTemporaryRoot(_ tag: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ppx-godseye-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func makeInstall(
        version: String = "1.0.0",
        name: String = "gods-eye-view",
        complete: Bool = true
    ) throws -> URL {
        let root = try makeTemporaryRoot("install")
        let manifest = "{\"name\":\"\(name)\",\"version\":\"\(version)\",\"scripts\":{\"postinstall\":\"rm -rf /\"}}"
        try Data(manifest.utf8).write(to: root.appendingPathComponent("package.json"))
        if complete {
            try Data("console.log(1)\n".utf8).write(to: root.appendingPathComponent("server.js"))
            try Data("console.log(2)\n".utf8).write(to: root.appendingPathComponent("mcp-server.js"))
        }
        return root
    }

    private func makeConfig(root: URL, port: Int = 18_931, enabled: Bool = true) -> GodsEyeViewConfig {
        GodsEyeViewConfig(
            enabled: enabled,
            mode: .existing,
            installPath: root.path,
            pinnedVersion: "1.0.0",
            port: port
        )
    }

    // MARK: - A. The policy

    func testLaunchArgumentsForceLoopbackAndTheHealthURLIsLoopbackOnly() {
        XCTAssertEqual(
            GodsEyeViewPolicy.launchArguments(entryPath: "/tmp/install/server.js", port: 18_931),
            ["/tmp/install/server.js", "--host", "127.0.0.1", "--port", "18931"],
            "the host is a constant: no document, request or environment may steer this process onto the LAN"
        )
        XCTAssertEqual(
            GodsEyeViewPolicy.mcpArguments(mcpEntryPath: "/tmp/install/mcp-server.js", port: 18_931),
            ["/tmp/install/mcp-server.js", "--base-url", "http://127.0.0.1:18931"],
            "the MCP child is told which loopback instance it belongs to and never guesses a port"
        )
        XCTAssertEqual(GodsEyeViewPolicy.healthURL(port: 18_931)?.absoluteString, "http://127.0.0.1:18931/")
        XCTAssertNil(GodsEyeViewPolicy.healthURL(port: 80), "a privileged port is not an admitted value")
        XCTAssertNil(GodsEyeViewPolicy.healthURL(port: 70_000))
        XCTAssertNil(GodsEyeViewPolicy.origin(port: 0))
    }

    func testInstallPathRefusesSensitiveTreesAndTraversal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hostile = [
            "/", "/usr", "/usr/bin", "/System", "/System/Library", "/Library",
            "/etc", "/private", "/Volumes", home + "/.ssh", home + "/.ssh/keys",
            home + "/.gnupg", home + "/Library/Keychains", AppPaths.root.path,
            "relative/path", ""
        ]
        for path in hostile {
            XCTAssertNil(GodsEyeViewPolicy.resolveInstallPath(path), "\(path) must not be an install target")
        }
        XCTAssertEqual(
            GodsEyeViewPolicy.resolveInstallPath("~/Tools/../Tools/gods-eye-view")?.path,
            home + "/Tools/gods-eye-view",
            "an admitted path is standardised before use, so `..` cannot smuggle a sensitive tree in later"
        )
        XCTAssertNotNil(GodsEyeViewPolicy.resolveInstallPath("~/Tools/gods-eye-view"))
    }

    func testManifestVerificationProvesBothEntriesAndRefusesASymlinkEscape() throws {
        let root = try makeInstall()
        let verified = GodsEyeViewPolicy.verifyInstall(at: root, expectedVersion: "1.0.0")
        XCTAssertTrue(verified.ok, verified.detail)
        XCTAssertEqual(verified.packageName, "gods-eye-view")
        XCTAssertEqual(verified.version, "1.0.0")
        XCTAssertEqual(verified.entryPath, root.appendingPathComponent("server.js").path)
        XCTAssertEqual(verified.mcpEntryPath, root.appendingPathComponent("mcp-server.js").path)
        XCTAssertEqual(verified.entryDigest.count, 64, "the card's digest is a SHA-256 hex string")
        XCTAssertEqual(verified.mcpEntryDigest.count, 64)

        XCTAssertFalse(GodsEyeViewPolicy.verifyInstall(at: root, expectedVersion: "2.0.0").ok,
                       "a directory reporting another version is refused instead of run")
        XCTAssertFalse(GodsEyeViewPolicy.verifyInstall(at: try makeInstall(name: "not-it"), expectedVersion: "1.0.0").ok)
        XCTAssertFalse(GodsEyeViewPolicy.verifyInstall(at: try makeInstall(complete: false), expectedVersion: "1.0.0").ok,
                       "a missing mcp-server.js must fail verification, not fail later at a launch")

        let escaped = try makeInstall()
        try FileManager.default.removeItem(at: escaped.appendingPathComponent("server.js"))
        try FileManager.default.createSymbolicLink(
            at: escaped.appendingPathComponent("server.js"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        XCTAssertNil(GodsEyeViewPolicy.containedFile("server.js", in: escaped),
                     "a link inside the install pointing outside it is not contained after symlink resolution")
        XCTAssertFalse(GodsEyeViewPolicy.verifyInstall(at: escaped, expectedVersion: "1.0.0").ok)
        XCTAssertNil(GodsEyeViewPolicy.containedFile("../package.json", in: escaped))
        XCTAssertNil(GodsEyeViewPolicy.containedFile("a/b.js", in: escaped))
    }

    func testHTTPSourceAndToolClassificationAreDeliberatelyNarrow() {
        XCTAssertTrue(GodsEyeViewPolicy.isHTTPSource("https://github.com/example/gods-eye-view.git"))
        XCTAssertFalse(GodsEyeViewPolicy.isHTTPSource("http://github.com/example/gods-eye-view.git"))
        XCTAssertFalse(GodsEyeViewPolicy.isHTTPSource("https://user:pass@github.com/example/x.git"),
                       "a credentialed URL is a token in a field the log echoes")
        XCTAssertFalse(GodsEyeViewPolicy.isHTTPSource("https://github.com/example/x.git?token=abc"))
        XCTAssertFalse(GodsEyeViewPolicy.isHTTPSource("https://github.com/example/x.git#frag"))
        XCTAssertFalse(GodsEyeViewPolicy.isHTTPSource("ssh://git@github.com/example/x.git"))

        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "list_flights"), .readOnly)
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "get_aircraft"), .readOnly)
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "flights"), .readOnly)
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "mark_route"), .mutating,
                       "a shared-canvas marker is a write even when the server calls it harmless")
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "draw_route"), .mutating)
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "export_report"), .mutating)
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "list_and_delete"), .mutating,
                       "a write token anywhere in the name wins over a leading read verb")
        XCTAssertEqual(GodsEyeViewPolicy.classify(toolName: "route_between"), .mutating,
                       "an unrecognised name is a write, not a guess")
    }

    func testToolGateOnlyEverTightens() {
        let gate = GodsEyeViewToolGate()
        let disguisedWrite = MCPTool(name: "mark_route", readOnlyHint: true)
        XCTAssertEqual(
            gate.effectiveSafety(serverID: GodsEyeViewPolicy.serverID, tool: disguisedWrite),
            .mutating,
            "the gate exists for exactly this shape: a read-only hint on a canvas write"
        )
        XCTAssertEqual(
            gate.effectiveSafety(serverID: GodsEyeViewPolicy.serverID, tool: MCPTool(name: "list_flights", readOnlyHint: true)),
            .readOnly
        )
        XCTAssertEqual(
            gate.effectiveSafety(serverID: GodsEyeViewPolicy.serverID, tool: MCPTool(name: "list_flights", readOnlyHint: false)),
            .mutating,
            "a protocol-level mutation cannot be talked down by the gate"
        )
        XCTAssertEqual(
            gate.effectiveSafety(serverID: "someone-else", tool: disguisedWrite),
            .readOnly,
            "another server's tools are not this bridge's business"
        )
    }

    func testLaunchEnvironmentDropsAmbientSecretsAndCarriesOnlyEnabledKeys() {
        let host = [
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/someone",
            "LANG": "en_US.UTF-8",
            "TMPDIR": "/tmp/",
            "SECRET_TOKEN": "ambient-leak",
            "NODE_OPTIONS": "--require /tmp/evil.js",
            "HTTP_PROXY": "http://127.0.0.1:9"
        ]
        let environment = GodsEyeViewPolicy.launchEnvironment(
            host: host,
            secrets: [.aisStream: "ais-value", .openSkyClientSecret: "sky-value", .openSkyClientID: ""]
        )
        XCTAssertEqual(
            Set(environment.keys),
            Set(["PATH", "HOME", "LANG", "TMPDIR", "AISSTREAM_API_KEY", "OPENSKY_CLIENT_SECRET"]),
            "only four host variables and the enabled keys may cross into the local program"
        )
        XCTAssertEqual(environment["AISSTREAM_API_KEY"], "ais-value")
        XCTAssertNil(environment["OPENSKY_CLIENT_ID"], "an empty value is not exported")
        XCTAssertNil(environment["SECRET_TOKEN"])
        XCTAssertNil(environment["NODE_OPTIONS"], "the program runs with the environment it was verified as")
        XCTAssertNil(environment["HTTP_PROXY"])
        XCTAssertTrue(environment["PATH"]?.contains("/usr/local/bin") == true)
    }

    // MARK: - B. The manager

    func testStartRefusesDisabledBeforeTouchingAnything() async {
        let runtime = GodsEyeTestRuntime()
        let manager = GodsEyeViewManager(
            config: .disabled, secrets: VolatileSecretStore(), runtime: runtime,
            auditURL: nil, logURL: nil, startupProbeInterval: 0
        )
        let result = await manager.start()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(runtime.launches.isEmpty, "an off switch means no process, not a quiet one")
        XCTAssertTrue(runtime.runs.isEmpty, "not even the Node probe runs when the bridge is off")
    }

    func testStartRefusesAnOldNodeAnUnverifiedInstallAMissingKeyAndABusyPort() async throws {
        // Node too old.
        let oldRuntime = GodsEyeTestRuntime(nodeBanner: "v18.19.0")
        let root = try makeInstall()
        let oldManager = GodsEyeViewManager(
            config: makeConfig(root: root), secrets: VolatileSecretStore(), runtime: oldRuntime,
            auditURL: nil, logURL: nil, startupProbeInterval: 0
        )
        let old = await oldManager.start()
        XCTAssertFalse(old.ok)
        XCTAssertTrue(old.detail.contains("过旧"), old.detail)
        XCTAssertTrue(oldRuntime.launches.isEmpty)

        // A directory that reports another version.
        let badVersion = GodsEyeViewManager(
            config: GodsEyeViewConfig(
                enabled: true, mode: .existing, installPath: root.path,
                pinnedVersion: "9.9.9", port: 18_941
            ),
            secrets: VolatileSecretStore(), runtime: GodsEyeTestRuntime(),
            auditURL: nil, logURL: nil, startupProbeInterval: 0
        )
        let unverified = await badVersion.start()
        XCTAssertFalse(unverified.ok)
        XCTAssertTrue(unverified.detail.contains("版本不符"), unverified.detail)

        // An enabled feed with no Keychain value.
        let missingKeyConfig = GodsEyeViewConfig(
            enabled: true, mode: .existing, installPath: root.path,
            pinnedVersion: "1.0.0", port: 18_942,
            credentials: ["aisstream": GodsEyeCredentialSlot(enabled: true, reference: "godseye/aisstream")]
        )
        let missingRuntime = GodsEyeTestRuntime()
        let missingKey = GodsEyeViewManager(
            config: missingKeyConfig, secrets: VolatileSecretStore(), runtime: missingRuntime,
            auditURL: nil, logURL: nil, startupProbeInterval: 0
        )
        let noKey = await missingKey.start()
        XCTAssertFalse(noKey.ok)
        XCTAssertTrue(noKey.detail.contains("AISSTREAM_API_KEY"), noKey.detail)
        XCTAssertTrue(missingRuntime.launches.isEmpty, "a refused start never reaches the launcher")

        // Somebody else already answers on the port.
        let busyRuntime = GodsEyeTestRuntime(probes: [200])
        let busy = GodsEyeViewManager(
            config: makeConfig(root: root, port: 18_943), secrets: VolatileSecretStore(),
            runtime: busyRuntime, auditURL: nil, logURL: nil, startupProbeInterval: 0
        )
        let occupied = await busy.start()
        XCTAssertFalse(occupied.ok)
        XCTAssertTrue(occupied.detail.contains("已有服务响应"), occupied.detail)
        XCTAssertTrue(busyRuntime.launches.isEmpty,
                      "reporting another program's listener as this process would make every later health check a lie")
    }

    func testStartLaunchesTheVerifiedEntryOnLoopbackAndStopsWithSigterm() async throws {
        let root = try makeInstall()
        let auditRoot = try makeTemporaryRoot("audit")
        let audit = auditRoot.appendingPathComponent("godseyeview-audit.jsonl")
        let value = "sk-live-abcdef123456"
        let secrets = VolatileSecretStore(secrets: ["godseye/aisstream": value])
        let runtime = GodsEyeTestRuntime()
        var config = makeConfig(root: root, port: 18_944)
        config.credentials["aisstream"] = GodsEyeCredentialSlot(enabled: true, reference: "godseye/aisstream")
        let manager = GodsEyeViewManager(
            config: config, secrets: secrets, runtime: runtime,
            auditURL: audit, logURL: nil, startupProbeInterval: 0
        )

        let started = await manager.start()
        XCTAssertTrue(started.ok, started.detail)
        guard let launch = runtime.launches.first else { return XCTFail("no launch was recorded") }
        XCTAssertEqual(
            launch.arguments,
            [root.appendingPathComponent("server.js").path, "--host", "127.0.0.1", "--port", "18944"],
            "the launched entry is the file verification proved, on the constant host"
        )
        XCTAssertEqual(launch.environment["AISSTREAM_API_KEY"], value)
        XCTAssertNil(launch.environment["NODE_OPTIONS"])
        XCTAssertNil(launch.environment["HTTP_PROXY"])

        let snapshot = await manager.snapshot()
        XCTAssertTrue(snapshot.running)
        XCTAssertEqual(snapshot.pid, 777)
        XCTAssertEqual(snapshot.healthStatus, 200)
        XCTAssertEqual(snapshot.bindHost, "127.0.0.1")
        XCTAssertTrue(snapshot.installVerified)
        XCTAssertEqual(snapshot.installedVersion, "1.0.0")

        let encoded = String(data: NodeJSON.encodePretty(snapshot) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(value), "the snapshot is served to a browser; a credential must never be in it")

        let auditText = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertTrue(auditText.contains("\"start\""), "a transition is a row, not a memory")
        XCTAssertTrue(auditText.contains("127.0.0.1:18944"))
        XCTAssertFalse(auditText.contains(value), "the audit names references, never values")
        let attributes = try FileManager.default.attributesOfItem(atPath: audit.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600,
                       "the chronology lives beside bug reports and must not be world-readable")

        let stopped = await manager.stop()
        XCTAssertTrue(stopped.ok)
        XCTAssertEqual(runtime.process.terminateCount, 1, "a polite SIGTERM is the first stop")
        XCTAssertEqual(runtime.process.killCount, 0)
        let after = await manager.isRunning()
        XCTAssertFalse(after)
    }

    func testPinnedInstallIsRefusedWithoutThePullSwitchOrAMatchingHead() async throws {
        let root = try makeTemporaryRoot("pinned")
        let target = root.appendingPathComponent("gods-eye-view", isDirectory: true)
        let commit = String(repeating: "a", count: 40)
        var config = GodsEyeViewConfig(
            enabled: true, mode: .pinnedSource, installPath: target.path,
            pinnedVersion: "1.0.0", port: 18_945,
            allowSourcePull: false, repositoryURL: "https://github.com/example/gods-eye-view.git",
            pinnedRef: "v1.0.0", pinnedCommit: commit
        )
        XCTAssertFalse(config.sourcePullReady, "the switch defaults off even with everything else filled")

        let runtime = GodsEyeTestRuntime()
        let manager = GodsEyeViewManager(
            config: config, secrets: VolatileSecretStore(), runtime: runtime,
            auditURL: nil, logURL: nil
        )
        let off = await manager.install()
        XCTAssertFalse(off.ok)
        XCTAssertTrue(off.detail.contains("拉取"), off.detail)
        XCTAssertTrue(runtime.runs.isEmpty, "a refused install never dials")

        config.allowSourcePull = true
        XCTAssertTrue(config.sourcePullReady)
        let mismatched = GodsEyeViewManager(
            config: config, secrets: VolatileSecretStore(), runtime: GodsEyeTestRuntime(),
            auditURL: nil, logURL: nil
        )
        let result = await mismatched.install()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(
            result.detail.contains("HEAD") || result.detail.contains("git clone"),
            "a clone whose HEAD is not the pinned commit is discarded, never moved into place: \(result.detail)"
        )
    }

    // MARK: - C. The MCP association

    func testAdapterOwnsOneEntryAndMergesTheCommandAllowList() async throws {
        let root = try makeTemporaryRoot("adapter")
        let entry = root.appendingPathComponent("mcp-server.js")
        try Data("console.log(1)\n".utf8).write(to: entry)
        let other = MCPServerConfig(
            id: "other", label: "Other", transport: .stdio,
            command: "/usr/local/bin/other", allowedTools: ["read_notes"], enabled: true
        )
        let registry = MCPServerRegistry(
            fileURL: nil,
            boot: MCPServersDocument(allowedCommands: ["/usr/local/bin/other"], servers: [other])
        )
        let adapter = GodsEyeViewMCPAdapter(registry: registry)

        let first = await adapter.register(nodePath: "/bin/sh", mcpEntryPath: entry.path, port: 18_946)
        XCTAssertTrue(first.ok, first.detail)
        let spec = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertEqual(spec?.command, "/bin/sh")
        XCTAssertEqual(spec?.arguments, [entry.path, "--base-url", "http://127.0.0.1:18946"])
        XCTAssertEqual(spec?.allowedTools, [], "an empty list is read-only-only, which is the safe first state")
        let commands = await registry.allowedCommands
        XCTAssertTrue(commands.contains("/bin/sh"), "the command has to be allow-listed or the entry is inert")
        XCTAssertTrue(commands.contains("/usr/local/bin/other"))
        let kept = await registry.server(id: "other")
        XCTAssertNotNil(kept, "another server must survive this bridge's registration")

        let synced = await adapter.syncTools([
            "mark_route", "list_flights", "LIST_FLIGHTS", String(repeating: "x", count: 200)
        ])
        XCTAssertTrue(synced.ok, synced.detail)
        let own = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertEqual(own?.allowedTools, ["list_flights", "mark_route"],
                       "names are trimmed, de-duplicated case-insensitively, capped and sorted")
        let otherAfter = await registry.server(id: "other")
        XCTAssertEqual(otherAfter?.allowedTools, ["read_notes"], "only this bridge's entry may change")

        let moved = await adapter.register(nodePath: "/bin/sh", mcpEntryPath: entry.path, port: 18_947)
        XCTAssertTrue(moved.ok)
        let reRegistered = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertEqual(reRegistered?.allowedTools, ["list_flights", "mark_route"],
                       "re-registering after a restart keeps the names the owner already synced")
        XCTAssertEqual(reRegistered?.arguments.last, "http://127.0.0.1:18947")

        let removed = await adapter.unregister()
        XCTAssertTrue(removed.ok)
        let gone = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertNil(gone)
        let survivors = await registry.server(id: "other")
        XCTAssertNotNil(survivors)
        let commandsAfter = await registry.allowedCommands
        XCTAssertTrue(commandsAfter.contains("/bin/sh"),
                      "removing a registration is not consent to shorten the operator's command list")
    }

    func testAdapterRefusesAnEntryThatCouldNotRun() async throws {
        let registry = MCPServerRegistry(fileURL: nil)
        let adapter = GodsEyeViewMCPAdapter(registry: registry)
        let relative = await adapter.register(nodePath: "node", mcpEntryPath: "/tmp/mcp-server.js", port: 18_948)
        XCTAssertFalse(relative.ok)
        let missing = await adapter.register(nodePath: "/bin/sh", mcpEntryPath: "/tmp/definitely-not-there.js", port: 18_948)
        XCTAssertFalse(missing.ok)
        let badPort = await adapter.register(nodePath: "/bin/sh", mcpEntryPath: "/bin/sh", port: 1)
        XCTAssertFalse(badPort.ok)
        let none = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertNil(none, "a refused registration writes nothing")
    }

    func testReadRunsWhileACanvasWriteBecomesAPendingProposal() async throws {
        let serverID = GodsEyeViewPolicy.serverID
        let command = "/usr/local/bin/godseye-node"
        let spec = MCPServerConfig(
            id: serverID, label: "God's Eye View", transport: .stdio,
            command: command, allowedTools: ["list_flights", "mark_route", "export_report"], enabled: true
        )
        let registry = MCPServerRegistry(
            fileURL: nil,
            boot: MCPServersDocument(allowedCommands: [command], servers: [spec])
        )
        let tools = [
            godsEyeToolJSON("list_flights", readOnly: true),
            godsEyeToolJSON("mark_route", readOnly: true),
            godsEyeToolJSON("export_report", readOnly: true)
        ]
        let link = GodsEyeTestLink(serverID: serverID, tools: tools, callText: "the map says 42")
        let executor = GodsEyeTestExecutor()
        let ledger = PrivacyProposalLedger(
            signer: PrivacyApprovalSigner(key: Data("godseye-test-signing-key-0001".utf8)),
            executor: executor, notifier: SilentProposalNotifier(), fileURL: nil, loadFromDisk: false
        )
        let mcp = MCPBridge(
            registry: registry, ledger: ledger,
            config: HubConfig(allowMcpBridge: true),
            toolGate: GodsEyeViewToolGate()
        ) { _, _ in link }

        let read = await mcp.invoke(
            serverID: serverID, toolName: "list_flights",
            arguments: ["bbox": .string("LSZH")]
        )
        guard case .executed(let text, _) = read else { return XCTFail("a read-only tool must run: \(read)") }
        XCTAssertEqual(text, "the map says 42")
        XCTAssertEqual(link.callDocuments.count, 1)

        let write = await mcp.invoke(
            serverID: serverID, toolName: "mark_route",
            arguments: ["points": .string("LSZH,EDDF")]
        )
        guard case .proposed(let proposal) = write else {
            return XCTFail("a canvas write must be queued for the owner: \(write)")
        }
        XCTAssertEqual(proposal.state, .pendingUserApproval)
        XCTAssertEqual(proposal.hubCall?.target, "mark_route")
        XCTAssertEqual(link.callDocuments.count, 1, "the mutating tool never reached the transport")
        XCTAssertTrue(executor.executions.isEmpty)
        let pending = await ledger.pending()
        XCTAssertEqual(pending.count, 1)

        let cards = await mcp.toolCards(serverID: serverID)
        let readCard = cards.first { $0.name == "list_flights" }
        let writeCard = cards.first { $0.name == "mark_route" }
        XCTAssertEqual(readCard?.safety, MCPToolSafety.readOnly.rawValue)
        XCTAssertEqual(writeCard?.safety, MCPToolSafety.mutating.rawValue,
                       "the console row shows the tightened tier, not the server's hint")
        XCTAssertEqual(writeCard?.requiresApproval, true)
    }

    func testBridgeStartRegistersSyncsAndStopRemovesTheEntry() async throws {
        let root = try makeInstall()
        let entry = root.appendingPathComponent("mcp-server.js")
        let auditRoot = try makeTemporaryRoot("bridge-audit")
        let audit = auditRoot.appendingPathComponent("godseyeview-audit.jsonl")
        let registry = MCPServerRegistry(fileURL: nil)
        let link = GodsEyeTestLink(
            serverID: GodsEyeViewPolicy.serverID,
            tools: [
                godsEyeToolJSON("list_flights", readOnly: true),
                godsEyeToolJSON("mark_route", readOnly: true)
            ],
            callText: "the map says 42"
        )
        let executor = GodsEyeTestExecutor()
        let ledger = PrivacyProposalLedger(
            signer: PrivacyApprovalSigner(key: Data("godseye-test-signing-key-0002".utf8)),
            executor: executor, notifier: SilentProposalNotifier(), fileURL: nil, loadFromDisk: false
        )
        let mcp = MCPBridge(
            registry: registry, ledger: ledger,
            config: HubConfig(allowMcpBridge: true),
            toolGate: GodsEyeViewToolGate()
        ) { _, _ in link }
        let runtime = GodsEyeTestRuntime(nodeExecutable: "/bin/sh", probes: [nil, 200])
        let secrets = VolatileSecretStore()
        let bridge = GodsEyeViewBridge(
            config: makeConfig(root: root, port: 18_949),
            registry: registry, mcp: mcp, secrets: secrets, runtime: runtime,
            auditURL: audit, logURL: nil, startupProbeAttempts: 1, startupProbeInterval: 0
        )

        let started = await bridge.control(verb: "start")
        XCTAssertTrue(started.ok, started.detail)
        XCTAssertTrue(started.godsEye.running)
        XCTAssertTrue(started.godsEye.mcpRegistered, "starting the instance registers the verified MCP entry")
        let names = started.godsEye.mcpTools.map(\.name).sorted()
        XCTAssertEqual(names, ["list_flights", "mark_route"])
        XCTAssertEqual(started.godsEye.mcpTools.first { $0.name == "mark_route" }?.safety,
                       MCPToolSafety.mutating.rawValue)
        let registeredSpec = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertEqual(
            registeredSpec?.arguments.last,
            "http://127.0.0.1:18949",
            "the child is associated with the instance this node started, not one it guessed"
        )
        XCTAssertNotNil(registeredSpec)
        XCTAssertTrue(entry.path.hasSuffix("mcp-server.js"))

        let snapshot = await bridge.snapshot()
        XCTAssertTrue(snapshot.mcpRegistered)
        XCTAssertFalse(snapshot.mcpDetail.isEmpty)

        let stopped = await bridge.control(verb: "stop")
        XCTAssertTrue(stopped.ok, stopped.detail)
        XCTAssertFalse(stopped.godsEye.running)
        XCTAssertFalse(stopped.godsEye.mcpRegistered)
        let after = await registry.server(id: GodsEyeViewPolicy.serverID)
        XCTAssertNil(after, "a stopped instance must not leave a registration pointing at a dead port")
        XCTAssertEqual(runtime.process.terminateCount, 1)

        let registered = await mcp.isEnabled()
        XCTAssertTrue(registered)
    }

    // MARK: - D. Credentials and documents

    func testCredentialValueReachesOnlyTheStore() async throws {
        let registry = MCPServerRegistry(fileURL: nil)
        let store = VolatileSecretStore()
        let auditRoot = try makeTemporaryRoot("cred-audit")
        let audit = auditRoot.appendingPathComponent("godseyeview-audit.jsonl")
        let bridge = GodsEyeViewBridge(
            config: GodsEyeViewConfig(credentials: [
                "aisstream": GodsEyeCredentialSlot(enabled: true, reference: "godseye/aisstream")
            ]),
            registry: registry, mcp: nil, secrets: store,
            runtime: GodsEyeTestRuntime(), auditURL: audit, logURL: nil
        )
        let value = "sk-live-abcdef123456"
        let outcome = await bridge.storeCredential(sourceID: "aisstream", secret: "  \(value)  ")
        guard case .stored(let reference) = outcome else {
            return XCTFail("a valid value must be stored: \(outcome)")
        }
        XCTAssertEqual(reference, "godseye/aisstream")
        XCTAssertEqual(store.secret(for: reference), value, "the value is trimmed before it is stored")
        XCTAssertTrue(store.references().contains(reference))

        let snapshot = await bridge.snapshot()
        let row = snapshot.credentials.first { $0.id == "aisstream" }
        XCTAssertEqual(row?.stored, true)
        XCTAssertEqual(row?.display, "已存入钥匙串 / stored")
        XCTAssertFalse(row?.display.contains(value) == true)
        let encoded = String(data: NodeJSON.encodePretty(snapshot) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(value), "a console snapshot is served over TCP to a browser")
        let auditText = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertTrue(auditText.contains("credential"))
        XCTAssertFalse(auditText.contains(value))

        let unknown = await bridge.storeCredential(sourceID: "nope", secret: "x")
        XCTAssertFalse(unknown.isStored)
        let empty = await bridge.storeCredential(sourceID: "aisstream", secret: "   ")
        XCTAssertFalse(empty.isStored)
        let huge = await bridge.storeCredential(
            sourceID: "aisstream", secret: String(repeating: "x", count: HubSecrets.maximumSecretLength + 1)
        )
        XCTAssertFalse(huge.isStored)
        XCTAssertEqual(store.secret(for: reference), value, "a refused store leaves the previous value alone")
    }

    func testTwoVolatileStoresDoNotShareValuesAndDisplayNeverShowsAPrefix() {
        let first = VolatileSecretStore(secrets: ["godseye/aisstream": "one"])
        let second = VolatileSecretStore(secrets: ["godseye/aisstream": "two"])
        XCTAssertEqual(first.secret(for: "godseye/aisstream"), "one")
        XCTAssertEqual(second.secret(for: "godseye/aisstream"), "two")
        XCTAssertNil(first.secret(for: "godseye/opensky-client-secret"))
        XCTAssertEqual(HubSecrets.display("godseye/aisstream", stored: true),
                       "godseye/aisstream · 已存入钥匙串 / stored")
        XCTAssertEqual(HubSecrets.display("godseye/aisstream", stored: false),
                       "godseye/aisstream · 未存入 / not stored")
        XCTAssertEqual(HubSecrets.display("../../etc/passwd", stored: true), "—",
                       "an unsafe reference is not echoed back into the page")
        XCTAssertFalse(HubSecrets.isSafeReference("../token"))
        XCTAssertFalse(HubSecrets.isSafeReference("has space"))
        XCTAssertTrue(HubSecrets.isSafeReference("godseye/aisstream"))
    }

    func testConfigDefaultsToOffNormalisesOnceAndNeverPullsByDefault() throws {
        let raw = """
        {"port":99999,"pinnedVersion":"v1.2.3","pinnedCommit":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
         "credentials":{"aisstream":{"enabled":true,"reference":"../evil"},
         "opensky-client-id":{"enabled":true,"reference":"godseye/opensky-client-id"},
         "opensky-client-secret":{"enabled":false,"reference":"godseye/opensky-client-secret"},
         "not-a-source":{"enabled":true,"reference":"godseye/x"}}}
        """
        let decoded = try XCTUnwrap(NodeJSON.decode(GodsEyeViewConfig.self, from: Data(raw.utf8)))
        XCTAssertFalse(decoded.enabled, "an absent switch is off")
        XCTAssertEqual(decoded.mode, .existing)
        XCTAssertFalse(decoded.allowSourcePull)
        XCTAssertEqual(decoded.installPath, "")

        let cleaned = decoded.normalised
        XCTAssertEqual(cleaned.pinnedVersion, "1.2.3", "a leading v is not part of the reported version")
        XCTAssertEqual(cleaned.port, GodsEyeViewPolicy.defaultPort, "an invalid port falls back, it is never clamped silently")
        XCTAssertEqual(cleaned.pinnedCommit, String(repeating: "a", count: 40))
        XCTAssertNil(cleaned.credentials["aisstream"], "an unsafe reference disables its slot instead of reaching the Keychain")
        XCTAssertNil(cleaned.credentials["not-a-source"], "only the fixed source ids may hold a slot")
        XCTAssertEqual(cleaned.credentials["opensky-client-id"]?.enabled, true)
        XCTAssertNil(cleaned.credentials["opensky-client-secret"], "a disabled slot is not routed at launch")
        XCTAssertFalse(cleaned.sourcePullReady)

        var ready = GodsEyeViewConfig(
            enabled: true, mode: .pinnedSource, installPath: "/tmp/x",
            allowSourcePull: true, repositoryURL: "https://github.com/example/x.git",
            pinnedRef: "v1.0.0", pinnedCommit: String(repeating: "b", count: 40)
        )
        XCTAssertTrue(ready.sourcePullReady)
        ready.allowSourcePull = false
        XCTAssertFalse(ready.sourcePullReady)
    }

    func testSettingsRoundTripKeepsGodsEyeOptionalAndDefaultsToOff() throws {
        let plain = NodeSettings()
        XCTAssertNil(plain.godsEye)
        XCTAssertFalse(plain.godsEyeConfig.enabled)
        let withBridge = plain.withGodsEye(GodsEyeViewConfig(enabled: true, installPath: "/tmp/x"))
        let encoded = String(data: NodeJSON.encodePretty(withBridge) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains("\"godsEye\""), "the saved document has a place for the bridge")
        let reread = try XCTUnwrap(NodeJSON.decode(NodeSettings.self, from: NodeJSON.encodePretty(withBridge) ?? Data()))
        XCTAssertTrue(reread.godsEyeConfig.enabled)
        XCTAssertEqual(reread.godsEyeConfig.installPath, "/tmp/x")

        let legacyData = try XCTUnwrap(NodeJSON.encodePretty(NodeSettings()))
        XCTAssertFalse(String(data: legacyData, encoding: .utf8)?.contains("godsEye") == true,
                       "a document written before this feature has no godsEye section")
        let legacy = try XCTUnwrap(NodeJSON.decode(NodeSettings.self, from: legacyData))
        XCTAssertFalse(legacy.godsEyeConfig.enabled, "an older document must decode with the bridge off")
    }

    func testConsoleCardIsCataloguedRoutedAndOffByDefault() {
        let page = WEBConsoleHTML.document
        XCTAssertTrue(page.contains("data-i18n=\"geTitle\""))
        XCTAssertTrue(page.contains("id=\"ge-start\""))
        XCTAssertTrue(page.contains("onclick=\"PPX.geControl('verify')\""))
        XCTAssertTrue(page.contains("godsEyeControl: \"/api/godseye/control\""))
        XCTAssertTrue(page.contains("godsEyeCredential: \"/api/godseye/credential\""))
        XCTAssertTrue(ConsoleRoute.all.contains(ConsoleRoute.godsEyeControl))
        XCTAssertTrue(ConsoleRoute.all.contains(ConsoleRoute.godsEyeCredential))
        XCTAssertEqual(ConsoleRoute.all.count, 29)
        XCTAssertFalse(GodsEyeViewSnapshot.disabled.enabled)
        XCTAssertFalse(GodsEyeViewSnapshot.disabled.running)
        XCTAssertEqual(GodsEyeViewSnapshot.disabled.bindHost, "127.0.0.1")
        XCTAssertEqual(GodsEyeViewSnapshot.disabled.port, 18_931)
        XCTAssertTrue(GodsEyeViewSnapshot.disabled.boundary.contains("127.0.0.1"))
        XCTAssertTrue(GodsEyeViewSnapshot.disabled.dataPolicy.contains("God's Eye View"))
        XCTAssertTrue(GodsEyeViewSnapshot.disabled.licence.contains("第三方"))
    }
}

// MARK: - Fakes

/// An in-memory MCP peer, the same shape the hub tests use: it records what the
/// client wrote and answers each request from the fixture.
private final class GodsEyeTestLink: MCPLink, @unchecked Sendable {
    let serverID: String

    private let tools: [JSONValue]
    private let callText: String
    private let lock = NSLock()
    private var inbound: [String] = []
    private var written: [JSONValue] = []
    private var closed = false

    init(serverID: String, tools: [JSONValue], callText: String) {
        self.serverID = serverID
        self.tools = tools
        self.callText = callText
    }

    func start(timeout: TimeInterval) async throws {}

    func writeLine(_ line: String) async throws {
        let document = JSONValue.parse(line)
        mutating { self.written.append(document) }
        guard case .object(let fields) = document,
              let method = fields["method"]?.stringValue,
              let id = fields["id"]?.intValue else { return }
        let answer: JSONValue
        switch method {
        case MCPProtocol.methodInitialize:
            answer = .object([
                "protocolVersion": .string(MCPProtocol.clientVersion),
                "serverInfo": .object(["name": .string("gods-eye-view"), "title": .string("God's Eye View")]),
                "capabilities": .object(["tools": .object([:])])
            ])
        case MCPProtocol.methodToolsList:
            answer = .object(["tools": .array(tools)])
        case MCPProtocol.methodToolsCall:
            answer = .object([
                "content": .array([.object(["type": .string("text"), "text": .string(callText)])]),
                "isError": .bool(false)
            ])
        default:
            answer = .object(["code": .int(MCPProtocol.codeMethodNotFound), "message": .string("no such method")])
        }
        let isErrorAnswer = method != MCPProtocol.methodInitialize
            && method != MCPProtocol.methodToolsList && method != MCPProtocol.methodToolsCall
        var envelopeFields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .int(id)]
        envelopeFields[isErrorAnswer ? "error" : "result"] = answer
        let envelope = JSONValue.object(envelopeFields)
        mutating { self.inbound.append(envelope.serialized()) }
    }

    func readLine(timeout: TimeInterval) async throws -> String? {
        syncing { self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
    }

    func finish() async { mutating { self.closed = true } }

    var callDocuments: [JSONValue] {
        syncing { self.written.filter { $0.objectValue?["method"]?.stringValue == MCPProtocol.methodToolsCall } }
    }

    private func mutating(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    private func syncing<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class GodsEyeTestExecutor: ProposalExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyProposal] = []

    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        record(proposal)
        return PrivacyExecution(ok: true, identifier: proposal.id, message: "must-not-happen")
    }

    private func record(_ proposal: PrivacyProposal) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(proposal)
    }

    var executions: [PrivacyProposal] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class GodsEyeTestProcess: GodsEyeProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminates = 0
    private var kills = 0

    var pid: Int32 { 777 }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        terminates += 1
        running = false
        lock.unlock()
    }

    func forceKill() {
        lock.lock()
        kills += 1
        running = false
        lock.unlock()
    }

    var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminates
    }

    var killCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return kills
    }
}

private final class GodsEyeTestRuntime: GodsEyeRuntime, @unchecked Sendable {
    struct Launch {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: URL
    }

    private let lock = NSLock()
    private var storedLaunches: [Launch] = []
    private var storedRuns: [[String]] = []
    private var storedProbes: [URL] = []
    private var probeResults: [Int?]
    private let executablePath: String?
    private let banner: String
    let process = GodsEyeTestProcess()

    init(nodeExecutable: String? = "/usr/local/bin/node", nodeBanner: String = "v22.11.0", probes: [Int?] = [nil, 200]) {
        self.executablePath = nodeExecutable
        self.banner = nodeBanner
        self.probeResults = probes
    }

    var launches: [Launch] {
        lock.lock()
        defer { lock.unlock() }
        return storedLaunches
    }

    var runs: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedRuns
    }

    var probes: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedProbes
    }

    func which(_ executable: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return executablePath
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> GodsEyeCommandResult {
        recordRun(arguments)
        if arguments == ["--version"] {
            return GodsEyeCommandResult(exitCode: 0, stdout: banner + "\n", stderr: "")
        }
        return GodsEyeCommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL?
    ) throws -> any GodsEyeProcessHandle {
        lock.lock()
        storedLaunches.append(Launch(
            executable: executable, arguments: arguments,
            environment: environment, workingDirectory: workingDirectory
        ))
        lock.unlock()
        return process
    }

    func probe(_ url: URL, timeout: TimeInterval) async -> Int? {
        nextProbe(url)
    }

    private func recordRun(_ arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        storedRuns.append(arguments)
    }

    private func nextProbe(_ url: URL) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        storedProbes.append(url)
        if probeResults.count > 1 { return probeResults.removeFirst() }
        return probeResults.first ?? nil
    }
}

private func godsEyeToolJSON(_ name: String, readOnly: Bool) -> JSONValue {
    .object([
        "name": .string(name),
        "title": .string(name),
        "description": .string("fixture"),
        "inputSchema": .object(["type": .string("object")]),
        "annotations": .object(["readOnlyHint": .bool(readOnly)])
    ])
}
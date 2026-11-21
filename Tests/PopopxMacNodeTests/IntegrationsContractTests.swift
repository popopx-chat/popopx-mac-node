//
//  IntegrationsContractTests.swift
//  Tests that `integrations/` still says what the Swift node does.
//
//  The TypeScript bridge is a second implementation of a contract it does not own. It parses the
//  same `::popopx_sys::NODE_CMD::` line, routes onto the same `dispatch` switch, and is allowed to
//  be stricter than the node but never more permissive. Compiling cannot tell those two runtimes
//  apart, so every assertion here reads artefacts that already exist: the node's own parser grades
//  the shared corpus (`testTheSharedCorpusGradesTheNodesOwnParser`), and the node's own source file
//  grades the shared routing table (`testTheBridgeRoutingTableMatchesTheNodesDispatchSwitch`).
//
//  The remaining cases are the red lines a plugin could cross without noticing: a listener, a
//  second port, a third-party dependency, a hard-coded token, a developer path, a placeholder, or a
//  document translated into only one language.
//
//  Nothing here runs npm, opens a socket, or needs a node to be reachable.
//

import Foundation
import XCTest

@testable import PopopxMacNode

final class IntegrationsContractTests: XCTestCase {

    // MARK: Ground truth the bridge claims to mirror

    /// The counts this gate was written against, measured from `TenBusinessEngines.swift` and
    /// `service-table.json` on the day it landed. They are literals on purpose: if the reader below
    /// quietly stops finding arms, the totals move, so the parity assertions cannot pass by both
    /// sides coming back empty.
    private static let expectedEngineCount = 10
    private static let expectedCanonicalGroupCount = 35
    /// Spellings the node accepts, the nine empty-action defaults included.
    private static let expectedNodeSpellingCount = 117
    /// How many arms also answer the empty action. The bridge refuses an empty action everywhere, so
    /// the parity assertion subtracts it — nine, not ten, because `zero_trust_warroom` has no default.
    private static let expectedEmptyActionArms = 9
    /// Spellings the bridge accepts: the node's, minus the empty actions it refuses.
    private static let expectedBridgeSpellingCount = 108

    private static let bridgePackages = ["shared", "linger-skill", "openclaw-skill"]

    private static var engineIDByCaseName: [String: String] {
        Dictionary(uniqueKeysWithValues: EngineKind.allCases.map { (String(describing: $0), $0.rawValue) })
    }

    // MARK: Corpus — the node's own parser grades the shared vectors

    /// `integrations/shared/test/fixtures/wire-vectors.json` carries two verdict columns: what
    /// `NodeWire.parseCommand` says, and what the bridge says. `npm test` grades the bridge column,
    /// so this is the half that keeps the corpus honest about the node. The disagreements between the
    /// columns are deliberate and documented; what may never happen is the `nodeParse` column lying.
    func testTheSharedCorpusGradesTheNodesOwnParser() throws {
        let corpus = try decode(WireVectors.self, at: bridge("shared/test/fixtures/wire-vectors.json"))
        XCTAssertEqual(corpus.maxSignalPayloadCharacters, NodeWire.maxSignalPayloadCharacters)
        XCTAssertGreaterThanOrEqual(corpus.vectors.count, 25, "the corpus is supposed to be a corpus")

        var accepted = 0
        var rejected = 0
        for vector in corpus.vectors {
            let parsed = NodeWire.parseCommand(vector.line)
            switch vector.nodeParse {
            case "accept":
                XCTAssertNotNil(parsed, "\(vector.name): the node now rejects a line the corpus calls accept")
                guard let parsed else { continue }
                accepted += 1
                XCTAssertNotNil(
                    EngineKind(rawValue: parsed.serviceId),
                    "\(vector.name): the node accepted \(parsed.serviceId), which is not an EngineKind rawValue"
                )
                XCTAssertFalse(parsed.action.isEmpty, "\(vector.name): an empty action was accepted")
                XCTAssertFalse(parsed.payload.isEmpty, "\(vector.name): an empty payload was accepted")
                if vector.bridge.ok, let expected = vector.bridge.payload {
                    XCTAssertEqual(parsed.payload, expected, "\(vector.name): the two parsers disagree about the payload")
                }
            case "reject":
                XCTAssertNil(parsed, "\(vector.name): the node accepts a line the corpus calls reject")
                rejected += 1
            default:
                XCTFail("\(vector.name): nodeParse must be accept or reject, got \(vector.nodeParse)")
            }
        }
        XCTAssertGreaterThanOrEqual(accepted, 15, "the corpus stopped covering the accepted side")
        XCTAssertGreaterThanOrEqual(rejected, 10, "the corpus stopped covering the rejected side")
    }

    // MARK: Routing table — the node's own source grades the bridge

    /// `service-table.json` is generated from `ROUTES`, which is generated from one `SPEC` literal in
    /// `src/wireCommand.ts`. Reading the node's `dispatch` switch out of its source and comparing the
    /// two is what turns that chain into evidence: any drift on either side lands here.
    func testTheBridgeRoutingTableMatchesTheNodesDispatchSwitch() throws {
        let table = try decode(ServiceTable.self, at: bridge("shared/test/fixtures/service-table.json"))
        let node = try parseDispatchSwitch()

        XCTAssertEqual(commandPrefix(of: table), NodeWire.commandPrefix)
        XCTAssertEqual(table.maxSignalPayloadCharacters, NodeWire.maxSignalPayloadCharacters)
        XCTAssertEqual(Set(table.services.keys), Set(node.groups.keys), "the two sides name different services")
        XCTAssertEqual(node.groups.count, Self.expectedEngineCount)
        XCTAssertEqual(table.services.count, Self.expectedEngineCount)
        XCTAssertEqual(
            node.groups.values.map(\.count).reduce(0, +), Self.expectedCanonicalGroupCount,
            "the number of action arms the node declares has moved; re-measure before touching this literal"
        )
        XCTAssertEqual(
            node.groups.values.flatMap { $0 }.reduce(0) { $0 + $1.spellings.count }, Self.expectedNodeSpellingCount,
            "the number of spellings the node accepts has moved; re-measure before touching this literal"
        )
        XCTAssertEqual(
            table.services.values.flatMap(\.actions.values).reduce(0) { $0 + $1.count }, Self.expectedBridgeSpellingCount,
            "the bridge table and its fixture no longer agree with themselves"
        )

        for (id, exported) in table.services {
            guard let arms = node.groups[id] else {
                XCTFail("\(id): the bridge routes a service the node does not have"); continue
            }
            let nodeCanonicals = arms.map(\.canonical).sorted()
            XCTAssertEqual(
                nodeCanonicals, (exported.canonical + exported.denied).sorted(),
                "\(id): the bridge's canonical actions are not the node's"
            )
            // The node's own `unsupported(…)` hint list is a third witness of the same set.
            XCTAssertEqual(
                nodeCanonicals, (node.declared[id] ?? []).sorted(),
                "\(id): the arms read out of dispatch disagree with its unsupported() list"
            )
            XCTAssertEqual(Set(exported.actions.keys), Set(nodeCanonicals), "\(id): the action keys drifted")
            for arm in arms {
                guard let bridgeSpellings = exported.actions[arm.canonical] else {
                    XCTFail("\(id): the node routes \(arm.canonical), the bridge does not list it"); continue
                }
                XCTAssertEqual(
                    Set(bridgeSpellings), arm.spellings.subtracting([""]),
                    "\(id).\(arm.canonical): the accepted spellings drifted"
                )
                XCTAssertFalse(
                    bridgeSpellings.contains(""),
                    "\(id): the bridge must refuse an empty action whatever the node does with it"
                )
            }
        }
    }

    /// The one denial the bridge carries, stated as a literal. This is the assertion that fails if
    /// anyone widens `denied` — including by moving an existing name into it.
    func testTheBridgeDeniesOnlyTheSentinelLockdown() throws {
        let table = try decode(ServiceTable.self, at: bridge("shared/test/fixtures/service-table.json"))
        let node = try parseDispatchSwitch()

        XCTAssertEqual(
            table.services.values.flatMap(\.denied).sorted(), ["lockdown"],
            "the bridge denies more than the physical lockdown, or has stopped denying it"
        )
        let sentinel = try XCTUnwrap(table.services["phantom_sentinel"])
        XCTAssertEqual(sentinel.denied, ["lockdown"])
        XCTAssertEqual(sentinel.canonical, ["status"], "the sentinel must keep an action that is allowed by default")
        XCTAssertEqual(
            Set(sentinel.actions["lockdown"] ?? []),
            ["lockdown", "lock", "lock_all", "sentinel", "\u{1F512}"],
            "the lockdown spellings drifted from the node's arm"
        )
        let lockdownArm = try XCTUnwrap(
            node.groups["phantom_sentinel"]?.first { $0.canonical == "lockdown" },
            "the node no longer routes a lockdown arm the bridge knows about"
        )
        XCTAssertEqual(
            lockdownArm.spellings, Set(sentinel.actions["lockdown"] ?? []).union([""]),
            "the node routes a lockdown spelling the bridge would send as something else"
        )
        for (id, exported) in table.services where id != "phantom_sentinel" {
            XCTAssertTrue(exported.denied.isEmpty, "\(id) declares denials it should not")
        }
        // `offered` is what a plugin sees, so the denial must be absent from it and named beside it.
        let offered = try XCTUnwrap(table.offered.first { $0.id == "phantom_sentinel" })
        XCTAssertEqual(offered.actions, ["status"])
        XCTAssertEqual(offered.denied, ["lockdown"])
    }

    // MARK: Red lines a plugin can cross without noticing

    /// Zero third-party dependencies is a red line of this repository and the bridge inherits it: the
    /// console is `Network.framework` with no web framework, so a plugin that pulls in a server or a
    /// WebSocket client has found a second port whether the node wanted one or not.
    func testTheBridgeAddsNoThirdPartyDependency() throws {
        let allowedDevDependencies: Set<String> = ["typescript", "@types/node"]
        var manifests = 0
        for url in try bridgeFiles(extensions: ["json"]) where url.lastPathComponent == "package.json" {
            manifests += 1
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any],
                "\(path(of: url)) is not a JSON object"
            )
            XCTAssertEqual(json["license"] as? String, "AGPL-3.0-only", "\(path(of: url)): wrong licence")
            XCTAssertEqual(json["type"] as? String, "module", "\(path(of: url)): the bridge is ESM")
            let engines = try XCTUnwrap(json["engines"] as? [String: String], "\(path(of: url)): no engines field")
            XCTAssertNotNil(engines["node"], "\(path(of: url)): no Node floor")
            for (name, requirement) in try XCTUnwrap(json["dependencies"] as? [String: String] ?? [:]) {
                XCTAssertTrue(name.hasPrefix("@popopx/"), "\(path(of: url)): runtime dependency \(name)")
                XCTAssertTrue(requirement.hasPrefix("file:"), "\(path(of: url)): \(name) is not linked from this tree")
            }
            for name in try XCTUnwrap(json["devDependencies"] as? [String: String] ?? [:]).keys {
                XCTAssertTrue(allowedDevDependencies.contains(name), "\(path(of: url)): dev dependency \(name)")
            }
        }
        XCTAssertEqual(manifests, Self.bridgePackages.count, "exactly one package.json per bridge package")

        // An import is the other half of the claim, and a bare specifier is the only way to reach a
        // package that is not in this tree.
        let specifier = #"(?:from|import)\s+["']([^"']+)["']|require\(\s*["']([^"']+)["']"#
        for url in try bridgeFiles(extensions: ["ts", "mjs", "js"]) {
            for name in Self.captures(in: try read(url), pattern: specifier) {
                let allowed = name.hasPrefix(".") || name.hasPrefix("node:") || name == "@popopx/node-bridge"
                XCTAssert(allowed, "\(path(of: url)): imports \(name), which is not in this tree")
            }
        }
    }

    /// The bridge is a client. It must never bind a socket, and every console URL it can build has to
    /// name the one port the node listens on. `127.0.0.1:5225` in prose is the relay the *node* dials
    /// out to, which is why the port rule is written against URLs rather than against digits. A plugin
    /// that documents why it must not touch a socket has to spell the scheme in pieces: exempting the
    /// files that warn about a marker would exempt exactly the place a marker gets written.
    func testTheBridgeOpensNoListenerAndSpeaksToNoOtherPort() throws {
        let listenerMarkers = ["createServer", "listen(", "NWListener", "NWConnectionParameters", "net.connect", "dgram"]
        let socketMarkers = ["new WebSocket", "wss://", "ws://", "io.connect", "socket.io", "new EventSource"]
        var scanned = 0
        for url in try bridgeFiles(extensions: ["ts", "mjs", "js", "sh", "json", "plist", "template"]) {
            let text = try read(url)
            scanned += 1
            for marker in listenerMarkers {
                XCTAssertFalse(text.contains(marker), "\(path(of: url)): the bridge must not listen (\(marker))")
            }
            for marker in socketMarkers {
                XCTAssertFalse(text.contains(marker), "\(path(of: url)): 18920 carries HTTP and SSE only (\(marker))")
            }
            for port in Self.captures(in: text, pattern: #"https?://(?:127\.0\.0\.1|localhost):(\d+)"#) {
                XCTAssertEqual(port, "18920", "\(path(of: url)): a console URL on port \(port)")
            }
        }
        XCTAssertGreaterThan(scanned, 12, "the transport scan found almost nothing to read")
    }

    /// No developer-machine path, no committed credential, no placeholder body. `TODO` is matched
    /// case-sensitively, because prose says "to do" far more often than a source file means it.
    func testTheBridgeCarriesNoDeveloperPathsSecretsOrPlaceholders() throws {
        let secrets = [
            "-----BEGIN",
            #"\?t=[A-Za-z0-9]{12,}"#,
            #"X-PPX-Token["']?\s*[:,]\s*["'][A-Za-z0-9]{12,}"#,
            #"PPX_(?:CONSOLE_TOKEN|BRIDGE_SECRET)=["'][^"']{12,}["']"#
        ]
        var scanned = 0
        for url in try bridgeFiles(extensions: ["ts", "mjs", "js", "json", "md", "sh", "template", "plist", "service"]) {
            let text = try read(url)
            scanned += 1
            for marker in ["/Users/", "/home/", "C:\\", "TODO", "FIXME", "simplex-chat"] {
                XCTAssertFalse(text.contains(marker), "\(path(of: url)): carries \(marker)")
            }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(
                    trimmed == "..." || trimmed == "// ..." || trimmed == "/* ... */",
                    "\(path(of: url)): an ellipsis where a body should be"
                )
            }
            // A lockfile's whole content is registry URLs and integrity digests, so it is read for the
            // checks above and skipped for the credential shapes.
            if url.lastPathComponent == "package-lock.json" { continue }
            for pattern in secrets {
                XCTAssertTrue(
                    Self.captures(in: text, pattern: pattern).isEmpty,
                    "\(path(of: url)): looks like it embeds a credential (\(pattern))"
                )
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost nothing to read")
        for url in try allBridgeFiles() {
            XCTAssertFalse(url.lastPathComponent.hasPrefix(".env"), "\(path(of: url)): a .env file must never be committed")
        }
    }

    // MARK: Documentation

    /// `CONTRACT.md` is what a plugin author reads before writing code, so both languages have to
    /// carry the same citations. Structure is compared between the files rather than against a
    /// literal, except for the citation set, which must be identical and non-trivial.
    func testTheIntegrationContractStaysBilingual() throws {
        let english = try MarkdownProbe(path: bridge("CONTRACT.md"))
        let chinese = try MarkdownProbe(path: bridge("CONTRACT.zh-CN.md"))
        XCTAssertEqual(english.levelTwoCount, 10, "the contract has ten numbered sections")
        XCTAssertEqual(english.levelTwoCount, chinese.levelTwoCount)
        XCTAssertEqual(english.levelThreeCount, chinese.levelThreeCount)
        XCTAssertEqual(english.fenceCount, chinese.fenceCount, "one language shows commands the other hides")
        XCTAssertEqual(english.tableRowCount, chinese.tableRowCount, "the tables no longer have the same rows")
        XCTAssertEqual(english.linkTargets, chinese.linkTargets)
        XCTAssertEqual(english.citations, chinese.citations, "one contract cites Swift where the other does not")
        XCTAssertGreaterThanOrEqual(english.citations.count, 40, "the contract stopped citing source")
        XCTAssertEqual(english.sectionNumbers, chinese.sectionNumbers, "the sections are numbered differently")
        XCTAssertEqual(english.serviceIDs, chinese.serviceIDs)
        XCTAssertFalse(english.serviceIDs.isEmpty, "the contract does not name the services")
        XCTAssertTrue(english.text.contains("18920"), "the contract does not name the port")
        XCTAssertTrue(chinese.text.contains("18920"), "the Chinese contract does not name the port")
        XCTAssertTrue(english.text.contains("X-PPX-Token"), "the contract does not name the header")
        XCTAssertTrue(english.text.contains("allowLockdown"), "the denial policy is missing from the English contract")
        XCTAssertTrue(chinese.text.contains("allowLockdown"), "the denial policy is missing from the Chinese contract")
    }

    /// Each package ships one document in two languages, and each offers the same ten services, so a
    /// language pair has to agree about what exists at all.
    func testEveryBridgePackageDocumentsBothLanguages() throws {
        for package in Self.bridgePackages {
            let english = try MarkdownProbe(path: bridge("\(package)/README.md"))
            let chinese = try MarkdownProbe(path: bridge("\(package)/README.zh-CN.md"))
            XCTAssertGreaterThan(english.levelTwoCount, 2, "\(package)/README.md is a stub")
            XCTAssertEqual(english.levelTwoCount, chinese.levelTwoCount, "\(package): a section exists in one language only")
            XCTAssertEqual(english.fenceCount, chinese.fenceCount, "\(package): the commands differ by language")
            XCTAssertEqual(english.tableRowCount, chinese.tableRowCount, "\(package): the tables differ by language")
            XCTAssertEqual(english.linkTargets, chinese.linkTargets, "\(package): one language links elsewhere")
            XCTAssertEqual(
                english.serviceIDs, Set(EngineKind.allCases.map(\.rawValue)),
                "\(package)/README.md does not document all ten services"
            )
            XCTAssertEqual(chinese.serviceIDs, english.serviceIDs, "\(package): the service list differs by language")
            XCTAssertTrue(english.text.contains("18920"), "\(package)/README.md does not name the port")
            XCTAssertTrue(english.text.contains("allowLockdown"), "\(package): the lockdown denial is undocumented")
            XCTAssertTrue(chinese.text.contains("allowLockdown"), "\(package): the denial is undocumented in Chinese")
        }
    }

    /// `dist/` was already ignored; the Node artefacts are not, and a committed `node_modules` would
    /// contradict the zero-dependency red line louder than any test can.
    func testTheGitignoreCoversTheBridgeArtifacts() throws {
        let lines = try read(repoRoot.appendingPathComponent(".gitignore"))
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for pattern in ["node_modules/", "dist/", "coverage/", "*.tsbuildinfo", ".env"] {
            XCTAssertTrue(lines.contains(pattern), ".gitignore does not cover \(pattern)")
        }
        XCTAssertTrue(lines.contains("prompt.md"), "the operator's prompt.md must stay out of the tree")
    }

    /// The bridge is advertised from the front page in both languages, with the denial policy next to
    /// it. `testTheTwoReadmeLanguagesStayInLockstep` keeps the structure; this keeps the promise.
    func testTheReadmeBridgeSectionSurvivesInBothLanguages() throws {
        let english = try MarkdownProbe(path: repoRoot.appendingPathComponent("README.md"))
        let chinese = try MarkdownProbe(path: repoRoot.appendingPathComponent("README.zh-CN.md"))
        XCTAssertTrue(english.text.contains("## Ecosystem bridges"), "README.md lost the bridge section")
        XCTAssertTrue(chinese.text.contains("## 生态桥接"), "README.zh-CN.md lost the bridge section")
        for probe in [english, chinese] {
            XCTAssertTrue(probe.text.contains("integrations/shared"), "\(probe.name): no path to the kernel")
            XCTAssertTrue(probe.text.contains("allowLockdown"), "\(probe.name): the denial is undocumented")
            XCTAssertTrue(probe.text.contains("PPX_BRIDGE_SECRET"), "\(probe.name): the second opt-in is undocumented")
            XCTAssertTrue(probe.text.contains("IntegrationsContractTests"), "\(probe.name): the gate is not advertised")
            XCTAssertTrue(probe.linkTargets.contains("integrations/CONTRACT.md"), "\(probe.name): no link to the contract")
            XCTAssertTrue(probe.linkTargets.contains("integrations/CONTRACT.zh-CN.md"), "\(probe.name): no link to 中文契约")
        }
    }

    /// A citation is the only reason a document about code is worth reading, and a line number is the
    /// first thing a refactor invalidates. Every `File.swift:NN-MM` in either contract language must
    /// name a Swift file that exists in this tree, be resolvable without a second candidate of the
    /// same name, and stay inside that file's line count.
    func testEveryContractCitationResolvesToRealCode() throws {
        let candidates = try swiftFileIndex()
        var checked = 0
        for document in ["CONTRACT.md", "CONTRACT.zh-CN.md"] {
            let text = try read(bridge(document))
            for row in Self.rows(in: text, pattern: #"([A-Za-z0-9_./-]+\.swift):([0-9]+)(?:-([0-9]+))?"#) {
                guard row.count >= 2, !row[0].isEmpty, let low = Int(row[1]) else {
                    throw ContractViolation(description: "\(document): a citation the reader could not parse")
                }
                let high = row.count > 2 && !row[2].isEmpty ? (Int(row[2]) ?? low) : low
                let name = row[0]
                let path: String
                if name.contains("/") {
                    guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(name).path) else {
                        XCTFail("\(document): cites \(name), which is not in the tree"); continue
                    }
                    path = name
                } else {
                    let matches = candidates[name] ?? []
                    guard matches.count == 1 else {
                        XCTFail("\(document): cites \(name), which resolves to \(matches.count) files"); continue
                    }
                    path = matches[0]
                }
                let lines = try read(repoRoot.appendingPathComponent(path)).components(separatedBy: "\n").count
                XCTAssertGreaterThan(high, 0, "\(document): \(name) cites line 0")
                XCTAssertLessThanOrEqual(
                    high, lines,
                    "\(document): \(name):\(low)-\(high) is past the end of a \(lines)-line file — the citation is stale"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 90, "the two contracts together stopped carrying citations");
    }

    /// Every Swift file in the tree, keyed by its last path component, so a bare citation name can be
    /// resolved — or rejected for being ambiguous.
    private func swiftFileIndex() throws -> [String: [String]] {
        var index: [String: [String]] = [:]
        for directory in ["Sources", "Tests"] {
            let base = repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: []) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                index[url.lastPathComponent, default: []].append(path(of: url))
            }
        }
        index["Package.swift"] = ["Package.swift"]
        return index
    }

    // MARK: Reading the node's dispatch switch

    private struct NodeActionGroup: Equatable {
        let canonical: String
        let spellings: Set<String>
    }

    private struct NodeDispatch {
        var groups: [String: [NodeActionGroup]] = [:]
        var declared: [String: [String]] = [:]
    }

    private struct ContractViolation: Error, CustomStringConvertible {
        let description: String
    }

    /// Walks `private func dispatch(_ kind: EngineKind, action: …)` and returns, per service raw
    /// value, every action arm. The node reports no action string in the arm itself — each one awaits
    /// a method, and one method can serve two arms (`morningBroadcast` answers both `broadcast` and
    /// `scheduled`) — so an arm's canonical action is the name from that engine's own
    /// `unsupported(kind, action: […])` list that the arm also spells. That is unique today, and the
    /// uniqueness is asserted rather than assumed: an arm that binds to two names, or to none, throws.
    /// A shape this reader cannot follow throws too, so a reformat fails loudly instead of silently
    /// shrinking the table.
    private func parseDispatchSwitch() throws -> NodeDispatch {
        let source = repoRoot.appendingPathComponent("Sources/PopopxMacNode/Engines/TenBusinessEngines.swift")
        let lines = try read(source).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("    private func dispatch(") })
        else { throw ContractViolation(description: "dispatch(_ kind: EngineKind …) is gone from TenBusinessEngines.swift") }
        var end = start + 1
        while end < lines.endIndex, lines[end] != "    }" { end += 1 }
        guard end < lines.endIndex else { throw ContractViolation(description: "dispatch(…) never closes") }

        var arms: [String: [[String]]] = [:]
        var declared: [String: [String]] = [:]
        var engine: String?
        var index = start + 1
        while index < end {
            let line = lines[index]
            if line.hasPrefix("        case ") {
                if let name = Self.firstCapture(in: line, pattern: #"case \.([A-Za-z][A-Za-z0-9_]*)"#) {
                    guard let id = Self.engineIDByCaseName[name] else {
                        throw ContractViolation(description: "dispatch: \(name) is not an EngineKind case")
                    }
                    engine = id
                } else if let raw = Self.firstCapture(in: line, pattern: #"case "([a-z_]+)""#), EngineKind(rawValue: raw) != nil {
                    engine = raw
                } else {
                    throw ContractViolation(
                        description: "dispatch: cannot read a service out of \(line.trimmingCharacters(in: .whitespaces))"
                    )
                }
                index += 1
                continue
            }
            if line.hasPrefix("            case \"") {
                guard let engine else { throw ContractViolation(description: "an action arm appears before any service case") }
                var chunk = String(line.dropFirst("            case ".count))
                var cursor = index + 1
                while !chunk.hasSuffix(":") {
                    guard cursor < end else { throw ContractViolation(description: "\(engine): an arm runs past the end of dispatch") }
                    let continuation = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard continuation.hasPrefix("\"") else {
                        throw ContractViolation(description: "\(engine): unexpected line inside a multi-line case: \(continuation)")
                    }
                    chunk += " " + continuation
                    cursor += 1
                }
                arms[engine, default: []].append(Self.quoted(in: chunk))
                index = cursor
                continue
            }
            if line.hasPrefix("                return unsupported(") {
                guard let engine else { throw ContractViolation(description: "an unsupported() list appears before any service case") }
                let names = Self.quoted(in: line)
                guard names.isEmpty == false else {
                    throw ContractViolation(description: "\(engine): its unsupported() list names no action")
                }
                declared[engine] = names
                index += 1
                continue
            }
            index += 1
        }

        var result = NodeDispatch(declared: declared)
        for (id, armsOfEngine) in arms {
            guard let vocabulary = declared[id] else {
                throw ContractViolation(description: "\(id): no unsupported() list to name its actions")
            }
            let known = Set(vocabulary)
            var seen: Set<String> = []
            for spellings in armsOfEngine {
                let matches = known.intersection(spellings)
                guard let canonical = matches.first, matches.count == 1 else {
                    throw ContractViolation(
                        description: "\(id): the arm \(spellings.sorted()) binds to \(matches.sorted()) — one arm, one action"
                    )
                }
                seen.insert(canonical)
                result.groups[id, default: []].append(
                    NodeActionGroup(canonical: canonical, spellings: Set(spellings))
                )
            }
            if seen != known {
                throw ContractViolation(description: "\(id): \(known.subtracting(seen).sorted()) is listed but never routed")
            }
            result.groups[id]?.sort { $0.canonical < $1.canonical }
        }
        XCTAssertEqual(result.groups.count, Self.expectedEngineCount, "dispatch stopped covering all ten engines")
        XCTAssertEqual(
            result.groups.values.flatMap { $0 }.filter { $0.spellings.contains("") }.count,
            Self.expectedEmptyActionArms,
            "the number of arms answering an empty action changed; the bridge must keep refusing all of them"
        )
        return result
    }

    // MARK: Readers and probes

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Tests/PopopxMacNodeTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // repository root
    }

    private var bridgeRoot: URL { repoRoot.appendingPathComponent("integrations") }

    private func bridge(_ relative: String) -> URL { bridgeRoot.appendingPathComponent(relative) }

    private func path(of url: URL) -> String {
        url.path.hasPrefix(repoRoot.path) ? String(url.path.dropFirst(repoRoot.path.count + 1)) : url.path
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: try Data(contentsOf: url))
    }

    private func commandPrefix(of table: ServiceTable) -> String { table.commandPrefix }

    /// Every regular file under `integrations/`, with build and install output left out.
    private func allBridgeFiles() throws -> [URL] {
        let skipped: Set<String> = ["node_modules", "dist", "coverage", ".git"]
        guard let enumerator = FileManager.default.enumerator(
            at: bridgeRoot, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { throw ContractViolation(description: "integrations/ is missing") }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(where: skipped.contains) { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    private func bridgeFiles(extensions: [String]) throws -> [URL] {
        let wanted = Set(extensions)
        return try allBridgeFiles().filter { wanted.contains($0.pathExtension.lowercased()) }
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var out: [String] = []
        expression.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                out.append(String(text[range]))
            }
        }
        return out
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern).first
    }

    /// One row per match, holding every group in order; a group that did not participate is `""`.
    private static func rows(in text: String, pattern: String) -> [[String]] {
        let expression = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var out: [[String]] = []
        expression.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            var row: [String] = []
            for group in 1..<match.numberOfRanges {
                row.append(Range(match.range(at: group), in: text).map { String(text[$0]) } ?? "")
            }
            out.append(row)
        }
        return out
    }

    private static func quoted(in text: String) -> [String] {
        captures(in: text, pattern: #""((?:[^"\\]|\\.)*)""#)
    }

    /// The structural facts a Markdown document is expected to keep in both languages.
    private struct MarkdownProbe {
        let name: String
        let text: String
        let lines: [String]

        init(path: URL) throws {
            name = path.lastPathComponent
            text = try String(contentsOf: path, encoding: .utf8)
            lines = text.components(separatedBy: "\n")
        }

        var levelTwoCount: Int { lines.filter { $0.hasPrefix("## ") }.count }
        var levelThreeCount: Int { lines.filter { $0.hasPrefix("### ") }.count }
        var tableRowCount: Int { trimmed.filter { $0.hasPrefix("|") }.count }
        var fenceCount: Int { trimmed.filter { $0.hasPrefix("```") }.count / 2 }

        /// `## 7 · …` → 7, so the two languages have to number their sections alike.
        var sectionNumbers: [Int] {
            lines.filter { $0.hasPrefix("## ") }.compactMap { Int($0.dropFirst(3).prefix { $0.isNumber }) }
        }

        var linkTargets: Set<String> {
            Set(IntegrationsContractTests.captures(in: text, pattern: #"\]\(([^)\s]+)"#))
        }

        /// `Foo.swift:12-40` — the citation form the contract uses for every claim about the node.
        var citations: Set<String> {
            Set(IntegrationsContractTests.captures(in: text, pattern: #"([A-Za-z0-9_./-]+\.swift:[0-9]+(?:-[0-9]+)?)"#))
        }

        var serviceIDs: Set<String> {
            Set(EngineKind.allCases.map(\.rawValue).filter { text.contains($0) })
        }

        private var trimmed: [String] { lines.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    // MARK: Fixtures

    private struct WireVectors: Decodable {
        let maxSignalPayloadCharacters: Int
        let vectors: [Vector]

        struct Vector: Decodable {
            let name: String
            let line: String
            let nodeParse: String
            let bridge: Bridge
            let note: String?

            struct Bridge: Decodable {
                let ok: Bool
                let code: String?
                let serviceId: String?
                let action: String?
                let payload: String?
                let denied: Bool?
            }
        }
    }

    private struct ServiceTable: Decodable {
        let commandPrefix: String
        let maxSignalPayloadCharacters: Int
        let services: [String: ExportedService]
        let offered: [Offered]

        struct ExportedService: Decodable {
            let canonical: [String]
            let denied: [String]
            let actions: [String: [String]]
        }

        struct Offered: Decodable {
            let id: String
            let actions: [String]
            let denied: [String]
        }
    }
}

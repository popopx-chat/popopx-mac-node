//
//  HubMCPTests.swift
//  The hub: the JSON-RPC 2.0 wire format, the MCP address/command allow-list, and the
//  write-tool confirmation gate.
//
//  Four groups, in the order the feature is dangerous:
//
//  * `MCPProtocol` — the grammar. A bridge that relaxes JSON-RPC lets whatever owns that
//    pipe claim a call succeeded: a reply carrying both `result` and `error`, an answer to
//    an id that was never asked with, a notification that grew an `id`. And the read/mutate
//    decision is made *here*, from the server's own document, so default-deny is the
//    difference between a confirmation card and an unprompted `delete_file`.
//  * the allow-list — the only reason "zero cloud dependency" is still true once an MCP
//    client exists. Public, link-local, LAN and *parsed-as-something-else* addresses must be
//    refused while the config is admitted, before a socket or a `Process` is created. The
//    userinfo form (`http://127.0.0.1@evil.example.com/`) is the classic parser-confusion
//    bypass and is asserted against the security property, not against the implementation.
//  * the proposal gate — a mutating MCP tool must never run on the strength of a request.
//    Every case that could execute one asserts that the fake transport was handed zero
//    `tools/call` documents, so "pending" is proven rather than implied by a status code.
//  * `PrivacyToolRoute` — two entry points (the owner's loopback path, a peer's `serviceId`
//    command) that must not disagree about which namespaces exist, and a path that must not
//    be able to walk out of one with `..`.
//
//  No case opens a socket, spawns a process, touches the Keychain, reads
//  `~/Library/Application Support/PopopxMacNode` or raises a notification. Config documents
//  go under `NSTemporaryDirectory()` in a unique subdirectory that teardown removes, and
//  `MCPServerRegistry` is always handed that `fileURL` explicitly rather than defaulted.
//  The gate is driven through `MCPBridge`'s injected link factory, so the whole protocol
//  conversation happens in memory.
//

import XCTest
@testable import PopopxMacNode

final class HubMCPTests: XCTestCase {

    private let nestedSecret = "NESTED-SECRET-4e11"
    private let sentinel = "SENDER-KEY-8f2b1c-DO-NOT-LEAK"

    // MARK: - Fixtures

    /// An MCP `tools/list` entry, as a server would send it.
    private func toolDocument(
        name: String,
        annotations: [String: JSONValue]? = nil,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name),
            "description": .string("fixture tool \(name)"),
            "inputSchema": .object([:])
        ]
        if let annotations { fields["annotations"] = .object(annotations) }
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }

    private func readOnlyTool() -> JSONValue {
        toolDocument(name: "read_notes", annotations: [
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false), "openWorldHint": .bool(false)
        ])
    }

    private func mutatingTool() -> JSONValue {
        toolDocument(name: "drop_table", annotations: [
            "readOnlyHint": .bool(false), "destructiveHint": .bool(true)
        ])
    }

    private func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private func rpcResult(_ value: JSONValue, id: Int) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .int(id), "result": value])
    }

    /// The refusal reason a URL got from the loopback-only guard, or nil when it was admitted.
    private func loopbackRefusal(for url: String) -> String? {
        do {
            _ = try EdgeBoundary.resolve(url: url, policy: .loopbackOnly)
            return nil
        } catch let error as EdgeBoundaryError {
            return error.description
        } catch {
            return "unexpected error type: \(error)"
        }
    }

    private func httpSpec(_ url: String, id: String = "probe") -> MCPServerConfig {
        MCPServerConfig(id: id, transport: .http, url: url)
    }

    private func stdioSpec(_ command: String, id: String = "probe", arguments: [String] = []) -> MCPServerConfig {
        MCPServerConfig(id: id, transport: .stdio, command: command, arguments: arguments)
    }

    /// Writes a document into a throwaway directory that teardown removes.
    private func temporaryMCPFile(contents: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ppx-hub-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mcp_servers.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private struct HubStack {
        let engine: PrivacyToolEngine
        let ledger: PrivacyProposalLedger
        let link: FakeMCPLink
        let gateway: HubProbeGateway
    }

    /// Engine + ledger + bridge, with the bridge's link seam replaced by an in-memory peer.
    private func makeHubStack(
        tools: [JSONValue],
        allowedTools: [String],
        enableBridge: Bool = true
    ) async -> HubStack {
        let command = "/usr/local/bin/fake-mcp-server"
        let spec = MCPServerConfig(id: "fake", label: "Fake MCP", transport: .stdio,
                                   command: command, allowedTools: allowedTools, enabled: true)
        let document = MCPServersDocument(allowedCommands: [command], servers: [spec])
        let registry = MCPServerRegistry(fileURL: nil, boot: document)

        let link = FakeMCPLink(serverID: "fake", tools: tools, callText: "the notes say 42")
        let gateway = HubProbeGateway()
        let hub = PrivacyExecutorHub(gateway: gateway, sandbox: WorkspaceSandbox())
        let ledger = PrivacyProposalLedger(
            signer: PrivacyApprovalSigner(key: Data("hub-mcp-test-signing-key-0123".utf8)),
            executor: hub, notifier: SilentProposalNotifier(), fileURL: nil, loadFromDisk: false
        )
        let bridge = MCPBridge(registry: registry, ledger: ledger, config: .disabled) { _, _ in link }
        let engine = PrivacyToolEngine(
            config: PrivacyBridgeConfig(notifyOnProposal: false), gateway: gateway, ledger: ledger,
            hub: hub, sandbox: WorkspaceSandbox(), nodeReference: "node-1", mcp: bridge
        )
        // Attaching before the switches are applied is the running node's order: the executor
        // reaches the bridge through the hub, and `applyHubConfig` normalises the switches.
        await engine.attachHubBridges()
        await engine.applyHubConfig(HubConfig(allowMcpBridge: enableBridge, mcpServers: document))
        return HubStack(engine: engine, ledger: ledger, link: link, gateway: gateway)
    }

    // MARK: - A. JSON-RPC 2.0 wire format

    func testInitializeRequestCarriesTheGrammarAndThisNodesIdentity() {
        let document = MCPRequest.initialize(id: 7).payload
        guard case .object(let fields) = document else { return XCTFail("initialize must serialize as an object") }

        XCTAssertEqual(fields["jsonrpc"]?.stringValue, "2.0",
                       "an envelope without the version tag is not a JSON-RPC request a server has to answer")
        XCTAssertEqual(fields["method"]?.stringValue, "initialize")
        XCTAssertEqual(fields["id"]?.intValue, 7,
                       "the id this node allocates is the only thing that later proves an answer belongs to this call")
        XCTAssertEqual(MCPProtocol.clientVersion, "2025-06-18",
                       "the offered revision is a wire contract; bumping it must be a deliberate, reviewable edit")

        guard case .object(let params)? = fields["params"] else { return XCTFail("initialize must send params") }
        XCTAssertEqual(params["protocolVersion"]?.stringValue, MCPProtocol.clientVersion,
                       "the handshake offers exactly the revision MCPClient implements, not a hardcoded twin of it")
        XCTAssertEqual(params["capabilities"]?.objectValue?.count, 0,
                       "the node is a tool client: offering roots, sampling or elicitation would let a server call back into this Mac")
        guard case .object(let info)? = params["clientInfo"] else { return XCTFail("clientInfo is required by the handshake") }
        XCTAssertEqual(info["name"]?.stringValue, "popopx-mac-node",
                       "a server operator reading their log must see which program knocked, not a generic name")
        XCTAssertEqual(info["version"]?.stringValue, NodeVersion.current.semanticString,
                       "the advertised version must be the running one, or a bug report points at the wrong build")
    }

    func testToolsListAndToolsCallEnvelopesHaveTheShapesTheServerParses() {
        let listed = MCPRequest.toolsList(id: 3).payload.objectValue ?? [:]
        XCTAssertEqual(listed["method"]?.stringValue, "tools/list", "the listing method is spelled on the wire")
        XCTAssertNil(listed["params"],
                     "an empty params object makes a server log a cursor it was never given; the field is optional")

        let paged = MCPRequest.toolsList(id: 3, cursor: "abc").payload.objectValue ?? [:]
        XCTAssertEqual(paged["params"]?.objectValue?["cursor"]?.stringValue, "abc",
                       "pagination is how a server with more tools than maximumPages still gets enumerated")

        let call = MCPRequest.toolsCall(id: 4, name: "read_notes",
                                        arguments: ["path": .string("a.md"), "n": .int(2)]).payload.objectValue ?? [:]
        XCTAssertEqual(call["method"]?.stringValue, "tools/call")
        let params = call["params"]?.objectValue ?? [:]
        XCTAssertEqual(params["name"]?.stringValue, "read_notes",
                       "the tool name lives under params.name; anywhere else the server sees an empty call")
        let arguments = params["arguments"]?.objectValue ?? [:]
        XCTAssertEqual(Set(arguments.keys), Set(["path", "n"]),
                       "arguments must arrive as one object, not flattened into params — flattened keys lose the schema")
        XCTAssertEqual(arguments["path"]?.stringValue, "a.md")
        XCTAssertEqual(arguments["n"]?.intValue, 2)
    }

    func testInitializedNotificationCarriesNoIdentifierSoNoAnswerIsOwed() {
        let fields = MCPNotification.initialized.payload.objectValue ?? [:]
        XCTAssertEqual(fields["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(fields["method"]?.stringValue, "notifications/initialized")
        XCTAssertNil(fields["id"],
                     "a notification that grew an id is a request: the client would wait for an answer that never arrives")
        XCTAssertNil(fields["params"], "the initialized notification has no params in the 2025-06-18 revision")
    }

    func testWellFormedResultDecodesAndUnwrappedKeepsTheValue() throws {
        let value = JSONValue.object(["protocolVersion": .string("2025-06-18"), "tools": .array([readOnlyTool()])])
        let response = try MCPResponse.parse(rpcResult(value, id: 11), expecting: 11)
        XCTAssertEqual(response.id, 11)
        XCTAssertFalse(response.isError, "a result document must not read as a failure")
        guard case .success(let decoded) = response.unwrapped() else { return XCTFail("a result must unwrap to success") }
        XCTAssertEqual(decoded.objectValue?["protocolVersion"]?.stringValue, "2025-06-18",
                       "the server's chosen revision has to survive parsing or MCPServerInfo reports a blank version")
        XCTAssertEqual(decoded.objectValue?["tools"]?.arrayValue?.count, 1,
                       "a nested array must not be flattened away — it is the tool list the gate is built from")
    }

    func testReservedErrorCodesBecomeServerCasesNotGenericFailures() throws {
        let codes = [
            MCPProtocol.codeParseError, MCPProtocol.codeInvalidRequest, MCPProtocol.codeMethodNotFound,
            MCPProtocol.codeInvalidParams, MCPProtocol.codeInternalError
        ]
        XCTAssertEqual(codes, [-32_700, -32_600, -32_601, -32_602, -32_603],
                       "these five are the reserved JSON-RPC codes a tool bridge can actually meet, and the audit row keys off them")

        for code in codes {
            let errorObject = JSONValue.object([
                "code": .int(code), "message": .string("no"), "data": .string("detail from the server")
            ])
            let document = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(5), "error": errorObject
            ])
            let response = try MCPResponse.parse(document, expecting: 5)
            XCTAssertTrue(response.isError, "an error object must never read as a success with an extra field")
            guard case .failure(let error) = response.unwrapped() else { return XCTFail("code \(code) must fail") }
            guard case .server(let found, let message, let data) = error else {
                return XCTFail("code \(code) arrived as \(error) instead of a server error")
            }
            XCTAssertEqual(found, code, "the wire code must be preserved, not collapsed into a generic malformed")
            XCTAssertEqual(message, "no")
            XCTAssertEqual(data?.stringValue, "detail from the server", "the server's own detail is kept for the console row")
            XCTAssertEqual(error.auditCode, "rpc_\(code)",
                           "the audit log greps a stable token; embedding somebody's error prose would make rows unsearchable")
        }
    }

    func testAnswerToADifferentIdIsRefusedAsFrameMixing() {
        // The whole protection: a reply meant for request 8 must not satisfy a waiter for 7.
        do {
            _ = try MCPResponse.parse(rpcResult(.object([:]), id: 8), expecting: 7)
            XCTFail("a response whose id is not the one asked with must be refused")
        } catch let error as MCPRpcError {
            guard case .mismatchedIdentifier(let expected, let found) = error else {
                return XCTFail("expected an id mismatch, got \(error)")
            }
            XCTAssertEqual(expected, 7, "the refusal must name what was asked …")
            XCTAssertEqual(found, "8", "… and what answered, so a mixed-up pipe is diagnosable from the log alone")
            XCTAssertEqual(error.auditCode, "id_mismatch")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testMalformedResponseDocumentsThrowInsteadOfLookingPlausible() {
        let cases: [(String, JSONValue, String)] = [
            ("array instead of an object", .array([.int(1)]), "malformed"),
            ("bare string", .string("{\"id\":9,\"result\":{}}"), "malformed"),
            ("null", .null, "malformed"),
            ("no jsonrpc tag", .object(["id": .int(9), "result": .object([:])]), "invalid_response"),
            ("wrong version", .object(["jsonrpc": .string("1.0"), "id": .int(9), "result": .object([:])]), "invalid_response"),
            ("no id at all", .object(["jsonrpc": .string("2.0"), "result": .object([:])]), "invalid_response"),
            ("both result and error", .object([
                "jsonrpc": .string("2.0"), "id": .int(9), "result": .object([:]), "error": .object([:])
            ]), "invalid_response"),
            ("neither result nor error", .object(["jsonrpc": .string("2.0"), "id": .int(9)]), "invalid_response"),
            ("error without code or message", .object([
                "jsonrpc": .string("2.0"), "id": .int(9), "error": .object(["detail": .string("nope")])
            ]), "invalid_response"),
            ("error as a bare string", .object([
                "jsonrpc": .string("2.0"), "id": .int(9), "error": .string("boom")
            ]), "invalid_response")
        ]

        for (label, document, expectedAudit) in cases {
            do {
                _ = try MCPResponse.parse(document, expecting: 9)
                XCTFail("\(label): parsed as if it were an answer")
            } catch let error as MCPRpcError {
                XCTAssertEqual(error.auditCode, expectedAudit, "\(label) reported as \(error)")
            } catch {
                XCTFail("\(label) threw \(error), not an MCPRpcError")
            }
        }
    }

    func testIdentifierCheckRefusesANonNumericId() {
        // Measured laxness, pinned so a future tightening shows up here: `JSONValue.intValue`
        // reads the string "7" as 7, so a server may answer a numeric request id with a string.
        // The frame-mixing requirement is that a *different* id never satisfies the waiter.
        let asText = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string("7"), "result": .object([:])])
        XCTAssertEqual(try MCPResponse.parse(asText, expecting: 7).id, 7,
                       "a string \"7\" currently passes the id check — legal ids in JSON-RPC, but it widens what a hostile pipe can pass")

        XCTAssertThrowsError(try MCPResponse.parse(
            .object(["jsonrpc": .string("2.0"), "id": .string("seven"), "result": .object([:])]), expecting: 7
        ), "an id that is not a number cannot be matched against the one this node allocated") { thrown in
            guard let rpc = thrown as? MCPRpcError else { return XCTFail("expected an MCPRpcError, got \(thrown)") }
            guard case .invalidResponse(let detail) = rpc else {
                return XCTFail("expected invalidResponse, got \(rpc)")
            }
            XCTAssertTrue(detail.contains("id"), "the refusal should say which field broke: \(detail)")
        }
    }

    func testToolSafetyDefaultsToMutatingWhenTheServerSaysNothing() {
        // Default-deny is the gate. A server that omits `annotations`, sends it empty, or sends
        // hints of the wrong type gets its tool treated as a write.
        let silent = MCPTool.parse(toolDocument(name: "list_devices"))
        XCTAssertNotNil(silent)
        XCTAssertEqual(silent?.safety, .mutating, "no annotations must not read as read-only")
        XCTAssertFalse(silent?.isReadOnly ?? true, "isReadOnly has to agree with safety, or a card and a gate disagree")

        let empty = MCPTool.parse(toolDocument(name: "list_devices", annotations: [:]))
        XCTAssertNil(empty?.readOnlyHint, "an empty annotations object leaves every hint unset rather than false-but-declared")
        XCTAssertEqual(empty?.safety, .mutating)

        let stringy = MCPTool.parse(toolDocument(name: "list_devices", annotations: ["readOnlyHint": .string("true")]))
        XCTAssertEqual(stringy?.safety, .mutating,
                       "a hint that is not a boolean is not a hint: coercing \"true\" would let a server opt its deletes out of the gate")

        let missing = MCPTool.parse(toolDocument(name: "list_devices", extra: ["annotations": .string("readOnlyHint=true")]))
        XCTAssertEqual(missing?.safety, .mutating, "an annotations field that is not an object carries no declarations")
    }

    func testToolSafetyHonoursReadOnlyOnlyForANameThatClaimsNoWrite() {
        let readOnly = MCPTool.parse(toolDocument(name: "read_notes", annotations: [
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false), "openWorldHint": .bool(false)
        ]))
        XCTAssertEqual(readOnly?.safety, .readOnly,
                       "a declared read-only tool with a non-writing name is the only case that runs without asking the owner")
        XCTAssertTrue(readOnly?.isReadOnly ?? false)
        XCTAssertEqual(readOnly?.destructiveHint, false, "the declared hints are kept, not collapsed into the verdict")

        let contradicted = MCPTool.parse(toolDocument(name: "fetch_weather", annotations: [
            "readOnlyHint": .bool(true), "destructiveHint": .bool(true)
        ]))
        XCTAssertEqual(contradicted?.safety, .mutating,
                       "readOnlyHint:true with destructiveHint:true is a contradiction, and the safe reading of a contradiction is a human ask")

        let openWorld = MCPTool.parse(toolDocument(name: "fetch_weather", annotations: [
            "readOnlyHint": .bool(true), "openWorldHint": .bool(true)
        ]))
        XCTAssertEqual(openWorld?.safety, .mutating,
                       "openWorldHint means the call reaches outside the Mac, which is exactly what the zero-cloud rule cares about")
    }

    func testMutatingNameOverridesAReadOnlyClaim() {
        // The name table may only widen the deny set. `name` is the one field a server must
        // send, so it is the one a lying annotation cannot launder.
        for name in ["delete_file", "write_notes", "send_message", "exec_command", "remove_calendar", "kill_task"] {
            let tool = MCPTool.parse(toolDocument(name: name, annotations: ["readOnlyHint": .bool(true)]))
            XCTAssertEqual(tool?.safety, .mutating, "\(name) claims read-only but its identifier says otherwise")
            XCTAssertTrue(tool?.mutatingNameHint ?? false, "\(name) should be caught by the name table")
        }
        let innocent = MCPTool.parse(toolDocument(name: "read_notes", annotations: ["readOnlyHint": .bool(true)]))
        XCTAssertFalse(innocent?.mutatingNameHint ?? true,
                       "a name that only reads must not be swept up by the table, or every read gets a card and the owner stops reading them")
    }

    func testServerSuppliedSafetyLabelCannotReplaceTheAnnotationReading() {
        // The brief describes an explicit `_popopx.safety` override. There is no such field:
        // nothing in the package reads `_popopx` at all. Asserted as the security property — a
        // server-authored label has no power over the tier, in either direction.
        let smuggled = MCPTool.parse(toolDocument(
            name: "delete_file",
            annotations: ["readOnlyHint": .bool(false), "destructiveHint": .bool(true)],
            extra: [
                "_popopx": .object(["safety": .string("readOnly")]),
                "safety": .string("readOnly"),
                "isReadOnly": .bool(true)
            ]
        ))
        XCTAssertEqual(smuggled?.safety, .mutating,
                       "the tier comes from annotations plus the identifier; a self-declared readOnly must not open the gate")
        let favourable = MCPTool.parse(toolDocument(
            name: "list_devices", extra: ["_popopx": .object(["safety": .string("mutating")])]
        ))
        XCTAssertEqual(favourable?.safety, .mutating, "an undeclared tool stays a write; the override cannot make it read-only either")
    }

    func testToolParseRefusesAnEntryWithoutAUsableName() {
        XCTAssertNil(MCPTool.parse(.object(["inputSchema": .object([:])])),
                     "a tool with no name can be neither called nor matched against allowedTools")
        XCTAssertNil(MCPTool.parse(toolDocument(name: "")), "an empty name would list and match nothing, yet still render")
        XCTAssertNil(MCPTool.parse(.string("delete_file")), "a bare string is not a tool document")
        XCTAssertNil(MCPTool.parse(.null), "null is not a tool document")
    }

    func testToolResultTextIsCappedAndSaysSo() {
        // A head the cap keeps and a tail the cap drops, in distinguishable characters —
        // otherwise "the tail is gone" is unfalsifiable.
        let head = String(repeating: "h", count: MCPToolResult.maximumCharacters)
        let tail = String(repeating: "z", count: 1_000)
        let parsed = MCPToolResult.parse(.object([
            "content": .array([textBlock(head + tail)]), "isError": .bool(false)
        ]))
        XCTAssertTrue(parsed.truncated,
                      "a tool that prints a whole log file must not be pasted into the owner's console panel and an audit row")
        let marker = "\n… (已截断 / truncated)"
        XCTAssertEqual(parsed.text.count, MCPToolResult.maximumCharacters + marker.count,
                       "the cap is exactly maximumCharacters of content plus the marker")
        XCTAssertTrue(parsed.text.hasPrefix(head), "the head is what survives, so the beginning of a log is still readable")
        XCTAssertFalse(parsed.text.contains("z"), "the tail is gone, not the head")
        // The cap covers `text` only: `blocks` still holds the untouched server payload, so
        // anything that ever forwards `blocks` would side-step the ceiling entirely.
        XCTAssertEqual(parsed.blocks.first?.objectValue?["text"]?.stringValue?.count, (head + tail).count,
                       "pinning that blocks is NOT capped; it is internal today and must stay that way")

        let exact = MCPToolResult.parse(.object([
            "content": .array([textBlock(String(repeating: "q", count: MCPToolResult.maximumCharacters))])
        ]))
        XCTAssertFalse(exact.truncated, "exactly at the ceiling is not over it")

        let empty = MCPToolResult.parse(.object([:]))
        XCTAssertEqual(empty.text, "", "a result with no content array is an empty answer, not a crash and not the word nil")
        XCTAssertFalse(empty.isError, "isError is absent, so the call is not a failure")
        XCTAssertEqual(MCPToolResult.parse(.array([])).text, "", "a non-object result is empty rather than a description of the value")
    }

    func testToolResultCarriesTheErrorFlagAndNamesNonTextBlocks() {
        let parsed = MCPToolResult.parse(.object([
            "content": .array([
                textBlock("first"),
                .object(["type": .string("image"), "data": .string("base64blob")]),
                .object(["text": .string("no type field")])
            ]),
            "isError": .bool(true)
        ]))
        XCTAssertTrue(parsed.isError, "a server that says isError must not be reported as a success with sad text")
        XCTAssertTrue(parsed.text.contains("first"))
        XCTAssertTrue(parsed.text.contains("[image]"), "a non-text block is named so the owner sees that something was dropped")
        XCTAssertFalse(parsed.text.contains("base64blob"), "binary never rides onto a poll payload or an audit row")
        XCTAssertTrue(parsed.text.contains("no type field"), "a block with no type defaults to text, per the schema")
    }

    func testEventStreamBodiesYieldOneDocumentPerDataEvent() {
        let body = """
        event: message
        id: 42
        data: {"jsonrpc":"2.0","id":1,"result":{}}

        data: {"jsonrpc":"2.0","id":2
        data: ,"result":{}}

        : keep-alive comment
        event: endpoint
        id: 43

        """
        let frames = MCPHTTPLink.eventStreamData(body)
        XCTAssertEqual(frames.count, 2, "two events were delimited by blank lines; a comment and a bare event:/id: pair are not messages")
        XCTAssertEqual(frames[0], "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
        XCTAssertEqual(frames[1], "{\"jsonrpc\":\"2.0\",\"id\":2\n,\"result\":{}}",
                       "SSE joins an event's data lines with a newline, and JSON tolerates it, so a body split across events survives")
        XCTAssertEqual(JSONValue.parse(frames[1]).objectValue?["id"]?.intValue, 2,
                       "the joined frame must still be one parseable document, not two halves")
        XCTAssertTrue(MCPHTTPLink.eventStreamData("").isEmpty, "an empty SSE body holds no documents")
    }

    // MARK: - B. Address and command allow-list

    func testLoopbackOnlyPolicyAdmitsLiteralLoopbackAndRefusesEverythingElse() {
        let admitted: [(String, Int)] = [
            ("http://127.0.0.1:8080/mcp", 8_080),
            ("http://127.0.0.1:9000", 9_000),
            ("http://127.0.0.1", 80),
            ("http://localhost:8080/", 8_080)
        ]
        for (url, port) in admitted {
            guard let endpoint = try? EdgeBoundary.resolve(url: url, policy: .loopbackOnly) else {
                return XCTFail("\(url) should be admissible on a loopback-only bridge")
            }
            XCTAssertEqual(endpoint.hostClass, .loopback, "\(url) was admitted without being classed loopback")
            XCTAssertEqual(endpoint.port, port, "\(url) must default to the scheme's port, not an arbitrary one")
            XCTAssertNil(httpSpec(url).acceptance(inside: []), "\(url) is loopback, so the config gate must accept it")
        }

        let refused: [(String, EdgeHostClass, String)] = [
            ("https://evil.example.com/mcp", .unresolvedName, "evil.example.com"),
            ("http://8.8.8.8:8080/", .publicAddress, "8.8.8.8"),
            ("http://[2001:db8::1]/", .publicAddress, "2001:db8::1"),
            ("http://192.168.1.5:8080/", .privateNetwork, "192.168.1.5"),
            ("http://169.254.1.1/", .linkLocal, "169.254.1.1")
        ]
        for (url, classification, named) in refused {
            let reason = loopbackRefusal(for: url)
            guard let reason else { return XCTFail("\(url) was admitted on a loopback-only bridge") }
            XCTAssertTrue(reason.contains(named),
                          "the refusal must name the offending value or the audit row cannot say what the node did not do: \(reason)")
            XCTAssertTrue(reason.contains(classification.rawValue),
                          "the refusal must say which class it found: \(reason)")
            XCTAssertNotNil(httpSpec(url).acceptance(inside: []), "\(url) must not pass the config gate")
        }

        // The LAN address is *private*: right for MQTT and Home Assistant, wrong here.
        XCTAssertTrue(loopbackRefusal(for: "http://192.168.1.5:8080/")?.contains("loopback-only") == true,
                      "MCP is loopbackOnly; a 192.168 address is refused for this bridge and only this bridge")
        XCTAssertTrue(loopbackRefusal(for: "http://[2001:db8::1]/")?.contains("2001:db8::1") == true,
                      "a bracketed v6 literal must be refused by its own address, not reported as a generic parse failure")
    }

    func testNonCanonicalLoopbackSpellingsAreDeniedRatherThanGuessedAt() {
        // Each of these is 127.0.0.1 to some resolver and something else to another. `inet_aton`
        // would read the octal form as 8.0.0.1 and the hex form as loopback.
        for sneaky in [
            "http://0177.0.0.1/", "http://0x7f000001/", "http://127.1/", "http://2130706433/",
            "http://0.0.0.0:8080/", "http://127.0.0.1.evil.example.com/"
        ] {
            let reason = loopbackRefusal(for: sneaky)
            XCTAssertNotNil(reason, "\(sneaky) was admitted: an address the classifier cannot place must never connect")
            XCTAssertFalse(EdgeBoundary.isAllowed(sneaky, policy: .loopbackOnly), "\(sneaky) must not be usable")
            XCTAssertNotNil(httpSpec(sneaky).acceptance(inside: []), "\(sneaky) must not pass the config gate")
        }

        // A percent-decoded Unicode digit host is *not* refused: `URLComponents.host` hands the
        // guard ASCII, and the guard admits `127.0.0.1`. That is only safe because the transport
        // rebuilds its request URL from the parsed endpoint instead of the owner's raw string, so
        // the socket can only go where the classification said. That rebuild is the property.
        let confusable = "http://①②⑦.0.0.1/"
        guard let folded = try? EdgeBoundary.resolve(url: confusable, policy: .loopbackOnly) else {
            return // refusal would also be correct; this branch pins what actually happens
        }
        XCTAssertEqual(folded.host, "127.0.0.1",
                       "the admitted host has to be the ASCII address the guard classified, not the spelling in the file")
        let foldedLink = MCPHTTPLink(spec: httpSpec(confusable))
        XCTAssertEqual(foldedLink?.requestURL, "http://127.0.0.1:80/",
                       "the URL the node will dial is rebuilt from origin+path; keeping the raw string here would let a normalised host be refused by the guard and connected anyway")
        XCTAssertTrue(EdgeBoundary.isAllowed(foldedLink?.requestURL ?? "", policy: .loopbackOnly),
                      "what is dialled must pass the same guard that admitted it")

        // Bracketed IPv6 loopback genuinely is local and must survive the round trip.
        guard let v6 = try? EdgeBoundary.resolve(url: "http://[::1]:8080/mcp", policy: .loopbackOnly) else {
            return XCTFail("::1 is loopback and must be admissible")
        }
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.hostHeader, "[::1]", "an unbracketed v6 literal inside a URL would be read as a port separator")
        XCTAssertTrue(EdgeBoundary.isAllowed(v6.origin + "/mcp", policy: .loopbackOnly),
                      "the origin this node rebuilds must re-pass the same guard, or the request-time check is decoration")
    }

    func testUserinfoTrickIsNotReadAsLoopback() {
        // `http://127.0.0.1@evil.example.com/` connects to evil.example.com. The brief calls
        // this the classic parser-confusion bypass, so it is asserted against the property.
        for trick in [
            "http://127.0.0.1@evil.example.com/",
            "http://127.0.0.1:8080@evil.example.com/mcp",
            "http://admin:pw@127.0.0.1:8080/",
            "http://127.0.0.1:8080:9999@",
            "http://evil.example.com\\@127.0.0.1/"
        ] {
            let reason = loopbackRefusal(for: trick)
            XCTAssertNotNil(reason, "\(trick) was admitted: userinfo must not be able to move the host the guard checks")
            XCTAssertFalse(EdgeBoundary.isAllowed(trick, policy: .loopbackOnly), "\(trick) must not read as allowed")
            XCTAssertNil(MCPHTTPLink(spec: httpSpec(trick)), "\(trick) must not get as far as building a transport")
            XCTAssertNotNil(httpSpec(trick).acceptance(inside: []), "\(trick) must not pass the config gate either")
        }
        // Credentials belong in a header, so even loopback-with-a-password is refused.
        XCTAssertTrue(loopbackRefusal(for: "http://admin:pw@127.0.0.1:8080/")?.contains("credentials") == true,
                      "the refusal should say why, or an owner keeps retrying the same URL")
        // A query is not an authority: a public host with a loopback-looking query is still public.
        XCTAssertNotNil(loopbackRefusal(for: "http://evil.example.com/?next=http://127.0.0.1/"))
    }

    func testATransportIsOnlyBuiltForAnAdmittedTarget() async {
        // Rule 1 and rule 3 meet here: the decision happens in `init`, so no object exists that
        // could open a socket for a refused address.
        guard let link = MCPHTTPLink(spec: httpSpec("http://127.0.0.1:8080/mcp")) else {
            return XCTFail("a loopback MCP endpoint must be reachable")
        }
        XCTAssertEqual(link.requestURL, "http://127.0.0.1:8080/mcp",
                       "the admitted origin plus the configured path is the URL the guard is re-run on at request time")
        do {
            try await link.start(timeout: 2) // re-admits, sends nothing
        } catch {
            XCTFail("start() on an admitted loopback target must not refuse: \(error)")
        }
        await link.finish()

        for rejected in ["https://mcp.example.com/sse", "http://8.8.8.8:8080/",
                         "http://192.168.1.5:8080/", "http://localhost.example.com/"] {
            XCTAssertNil(MCPHTTPLink(spec: httpSpec(rejected)), "\(rejected) must never produce a transport")
            XCTAssertNil(MCPBridge.defaultLink(spec: httpSpec(rejected), allowedCommands: []),
                         "the production factory is the last gate before a socket, and it must refuse too")
        }
        XCTAssertNil(MCPBridge.defaultLink(spec: stdioSpec("/bin/sh", id: "s"), allowedCommands: []),
                     "the production stdio factory must refuse an un-listed command without reaching Process")

        // `.sse` is not a transport this node has: `Transport` is stdio and http only.
        // Measured: an unknown spelling makes the *whole document* fail to decode, because the
        // synthesised Decodable for a raw-value enum throws instead of falling back. The security
        // property survives (nothing is launchable) but the owner loses the other registrations
        // with no per-entry reason — reported, not asserted as intended behaviour.
        let decoded = NodeJSON.decode(MCPServersDocument.self, from: Data(
            #"{"allowedCommands":[],"servers":[{"id":"old","transport":"sse","url":"https://mcp.example.com/sse"}]}"#
                .utf8
        ))
        XCTAssertTrue(decoded == nil || decoded!.usableServers.isEmpty,
                      "an `.sse` entry must never be launchable, whatever the decoder makes of the spelling")
        let carried = decoded?.servers.first?.acceptance(inside: decoded?.allowedCommands ?? [])
        XCTAssertTrue(decoded == nil || carried != nil,
                      "if the document did decode, the bad entry still has to be refused with a reason")
    }

    func testCommandAllowListIsExactAndNeverResolvesABasename() async {
        let listed = "/usr/local/bin/fake-mcp-server"
        let registry = MCPServerRegistry(fileURL: nil, boot: MCPServersDocument(
            allowedCommands: [listed], servers: [stdioSpec(listed, id: "one")]
        ))
        let commands = await registry.allowedCommands
        XCTAssertEqual(commands, [listed])
        let exact = await registry.isAllowed(command: listed)
        XCTAssertTrue(exact, "the absolute path the owner wrote is what may be executed")
        let basename = await registry.isAllowed(command: "fake-mcp-server")
        XCTAssertFalse(basename,
                       "a bare name is found on PATH, and PATH may hold somebody else's copy of that program in /tmp")
        let shell = await registry.isAllowed(command: "/bin/sh")
        XCTAssertFalse(shell, "/bin/sh is the reason this list exists at all")
        let traversed = await registry.isAllowed(command: "\(listed)/../../sh")
        XCTAssertFalse(traversed, "a traversal-suffixed allow-list entry must not be matchable")

        let empty = MCPServerRegistry(fileURL: nil)
        let emptyCommands = await empty.allowedCommands
        XCTAssertTrue(emptyCommands.isEmpty, "a registry with no file trusts no executable")
        let emptyAllowed = await empty.isAllowed(command: listed)
        XCTAssertFalse(emptyAllowed, "an empty allow-list admits nothing, not everything")
        let emptyEnabled = await empty.isEnabled
        XCTAssertFalse(emptyEnabled, "no usable servers means the bridge reports itself unusable")
    }

    func testStdioLinkRefusesAnUnlistedOrShellShapedCommandWithoutSpawning() {
        // Construction is the entire admission; a nil link means no `Process` is ever created.
        let listed = "/bin/echo"
        XCTAssertNotNil(MCPStdioLink(spec: stdioSpec(listed, id: "ok"), allowedCommands: [listed]),
                        "an allow-listed absolute path the filesystem reports executable must build")
        XCTAssertNil(MCPStdioLink(spec: stdioSpec("/bin/sh", id: "x"), allowedCommands: [listed]),
                     "/bin/sh is not on the list: anything else is arbitrary code execution")
        XCTAssertNil(MCPStdioLink(spec: stdioSpec(listed, id: "x"), allowedCommands: []),
                     "an empty allow-list admits no command, however ordinary the binary")
        XCTAssertNil(MCPStdioLink(spec: stdioSpec("node", id: "x"), allowedCommands: ["node"]),
                     "a relative command is refused even when listed: it has to be an absolute path")
        XCTAssertNil(MCPStdioLink(spec: stdioSpec("/nonexistent/ppx-mcp", id: "x"),
                                  allowedCommands: ["/nonexistent/ppx-mcp"]),
                     "the filesystem must report the path executable, or a listed-but-missing binary is a spawn the owner did not sanction")

        for shell in ["/bin/echo; rm -rf ~", "/bin/echo | tee /dev/stdout", "/bin/echo `id`",
                      "/bin/echo $HOME", "/bin/echo *", "/bin/echo >/tmp/x"] {
            XCTAssertNotNil(stdioSpec(shell, id: "x").acceptance(inside: [shell]),
                            "a command needing a shell is not a command; it is a way to run something else")
            XCTAssertNil(MCPStdioLink(spec: stdioSpec(shell, id: "x"), allowedCommands: [shell]),
                         "the link must refuse the same shapes the config gate refuses")
        }
        XCTAssertNotNil(stdioSpec(listed, id: "x").acceptance(inside: []),
                        "an allow-listed path outside the list is still refused — the list is the argument, not the file")
    }

    func testRegistryReadsCapsFromATemporaryDocument() async throws {
        // 40 servers and 31 commands: `normalised` is the only thing standing between a
        // hand-edited file and an unbounded spawn surface, and `reload()` is the road in.
        // The filler commands are named `z-*` so the sorted clamp keeps the one command the
        // servers actually point at — the clamp itself is what is under test, not the order.
        let command = "/usr/local/bin/fake-mcp-server"
        let serverLines = (0..<40).map {
            "{\"id\":\"s\($0)\",\"transport\":\"stdio\",\"command\":\"\(command)\",\"enabled\":true}"
        }.joined(separator: ",")
        let commandLines = ((0..<30).map { "\"/usr/local/bin/z-cmd-\($0)\"" } + ["\"\(command)\""]).joined(separator: ",")
        let file = try temporaryMCPFile(
            contents: "{\"allowedCommands\":[\(commandLines)],\"servers\":[\(serverLines)]}"
        )
        let registry = MCPServerRegistry(fileURL: file)

        let count = await registry.reload()
        XCTAssertEqual(count, MCPServersDocument.maximumServers,
                       "reload must clamp to the ceiling instead of honoring 40 registrations")
        let servers = await registry.servers
        XCTAssertEqual(servers.count, MCPServersDocument.maximumServers)
        let commands = await registry.allowedCommands
        XCTAssertLessThanOrEqual(commands.count, MCPServersDocument.maximumAllowedCommands,
                                 "the list of programs this Mac will execute is capped, and a file that ignores the cap is clamped on load")
        XCTAssertTrue(commands.contains(command), "the clamped list must still hold the entry the servers point at")
        let usable = await registry.usableServers
        XCTAssertEqual(usable.count, count,
                       "every clamped server must still name a surviving allow-list entry, or the count drops with no explanation")
        let failure = await registry.loadFailure
        XCTAssertNil(failure, "a well-formed document must not report a load failure")

        let saved = await registry.save(MCPServersDocument(allowedCommands: [command], servers: [stdioSpec(command, id: "one")]))
        XCTAssertNil(saved, "saving a valid document must not refuse: \(saved ?? "nil")")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(mode, 0o600,
                       "the allow-list says what this Mac is willing to execute; world-readable hands that map to every local account")

        let reread = MCPServerRegistry(fileURL: file)
        let rereadCount = await reread.reload()
        XCTAssertEqual(rereadCount, 1, "what was written must be what comes back, or the console displays a document that is not on disk")

        // Measured: `save` normalises the candidate *before* comparing it to the ceiling, so
        // its own "too many servers" refusal is unreachable and an over-sized document is
        // written as a silently truncated one. The truncation narrows the spawn surface, so it
        // fails safe — but the owner's 9th registration disappears with no reason string.
        let overCapacity = await registry.save(MCPServersDocument(
            allowedCommands: [command],
            servers: (0...MCPServersDocument.maximumServers).map { stdioSpec(command, id: "s\($0)") }
        ))
        XCTAssertNil(overCapacity, "the refusal branch never fires; reported rather than asserted as intended behaviour")
        let afterOver = MCPServerRegistry(fileURL: file)
        let afterCount = await afterOver.reload()
        XCTAssertEqual(afterCount, MCPServersDocument.maximumServers,
                       "what did land is still bounded by the ceiling, which is the part that keeps the allow-list small")
    }

    func testRegistrySurfacesPerEntryRejectionsRatherThanASilentDrop() async throws {
        // An over-long argument list is *refused*, not truncated: truncating arguments would
        // start a server with a command line the owner never wrote.
        let command = "/usr/local/bin/fake-mcp-server"
        let longArguments = (0..<(MCPServersDocument.maximumArguments + 3))
            .map { "\"arg\($0)\"" }.joined(separator: ",")
        let json = """
        {"allowedCommands":["\(command)"],"servers":[
        {"id":"fat","transport":"stdio","command":"\(command)","arguments":[\(longArguments)],"enabled":true},
        {"id":"shaped","transport":"stdio","command":"node","enabled":true},
        {"id":"","transport":"stdio","command":"\(command)","enabled":true},
        {"id":"off","transport":"stdio","command":"\(command)","enabled":false},
        {"id":"remote","transport":"http","url":"https://mcp.example.com/sse","enabled":true}
        ]}
        """
        let registry = MCPServerRegistry(fileURL: try temporaryMCPFile(contents: json))
        _ = await registry.reload()

        let usable = await registry.usableServers
        XCTAssertTrue(usable.isEmpty,
                      "none of these may start: over-long args, relative path, empty id, disabled, public URL — got \(usable.map { $0.id })")
        let ids = await registry.rejections.map { $0.id }
        XCTAssertTrue(ids.contains("fat"), "the over-sized entry must be named: \(ids)")
        XCTAssertTrue(ids.contains("shaped"), "a relative command must be named: \(ids)")
        XCTAssertTrue(ids.contains("remote"), "a public MCP url must be named: \(ids)")
        let reasons = await registry.rejections.map { $0.reason }
        XCTAssertTrue(reasons.contains { $0.contains("参数过多") || $0.contains("too many") },
                      "the reason text is what the console renders; a bare 'invalid' leaves the owner editing the wrong field: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("loopback") || $0.contains("回环") },
                      "the http refusal must name the loopback policy it broke: \(reasons)")
        XCTAssertFalse(ids.contains("off"), "a disabled server is the owner's own choice, not a rejection")
        let enabled = await registry.isEnabled
        XCTAssertFalse(enabled, "a document whose entries are all refused must not report the bridge as usable")
    }

    func testRegistryFailsClosedOnACorruptDocumentAndKeepsTheReason() async throws {
        for corrupt in [
            "{\"allowedCommands\":[\"/usr/local/bin/x\"",
            "[1,2,3]",
            "{\"allowedCommands\":\"not-a-list\"}",
            "{\"servers\":{\"not\":\"an array\"}}",
            "",
            "not json at all"
        ] {
            let registry = MCPServerRegistry(fileURL: try temporaryMCPFile(contents: corrupt))
            let count = await registry.reload()
            XCTAssertEqual(count, 0, "\(corrupt.prefix(24)): a document that does not parse must leave zero usable servers, not a partial read")
            let survivors = await registry.servers
            XCTAssertTrue(survivors.isEmpty, "nothing may survive a corrupt load: \(survivors.map { $0.id })")
            let commands = await registry.allowedCommands
            XCTAssertTrue(commands.isEmpty, "a corrupt load must not keep a previously-widened allow-list in memory")
            let failure = await registry.loadFailure
            XCTAssertNotNil(failure, "the owner needs to see why the bridge went silent instead of guessing")
            let allowed = await registry.isAllowed(command: "/usr/local/bin/x")
            XCTAssertFalse(allowed, "fail-closed means the answer after a bad load is 'no', for every command")
        }
    }

    func testSharedHTTPSessionCarriesNoCookiesNoCacheAndFollowsNoRedirect() {
        // A redirect is the cheapest way to turn an allow-listed loopback answer into a public
        // connection made *by this node*, carrying its own session id.
        var handedDown: URLRequest? = URLRequest(url: URL(string: "http://127.0.0.1:1/never")!)
        let delegate = HubNoRedirectDelegate()
        let session = HubHTTP.session(timeout: 3, delegate: delegate)
        addTeardownBlock { session.finishTasksAndInvalidate() }
        let target = URL(string: "http://127.0.0.1:1/never")!
        let task = session.dataTask(with: target) // never resumed: no socket is opened
        let response = HTTPURLResponse(
            url: target, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://203.0.113.9/steal"]
        )!
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://203.0.113.9/steal")!)) { request in
            handedDown = request
        }
        XCTAssertNil(handedDown, "the delegate must hand back nil so the task fails instead of dialing a public address")

        let configuration = session.configuration
        XCTAssertNil(configuration.urlCache, "a cached MCP response could be replayed into a later proposal card")
        XCTAssertNil(configuration.httpCookieStorage, "cookies would let one server recognise the owner across another")
        XCTAssertEqual(configuration.httpShouldSetCookies, false)
        XCTAssertEqual(configuration.waitsForConnectivity, false,
                       "waiting for connectivity turns a refused bridge into a hung loopback console request")
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 3, "an unbounded read is an unbounded hung request on the console")
    }

    func testRequestPathSegmentsCannotCarryTraversalIntoAURL() {
        // The path is the one part of an admitted origin this node assembles itself.
        XCTAssertEqual(HubHTTP.segment("light.desk"), "light.desk",
                       "an ordinary entity id has to survive, or the guard is only decoration on a broken bridge")
        for hostile in ["..", "../etc/passwd", "a/..", "%2e%2e", "a%2Fb", "a?x=1", "a#f",
                        "/abs", "with space", ""] {
            XCTAssertNil(HubHTTP.segment(hostile), "\(hostile) must not be interpolated into a request path")
        }
        XCTAssertNil(HubHTTP.segment(String(repeating: "a", count: 200), maximumLength: 128),
                     "a segment past the ceiling is refused, not truncated into something else")
    }

    // MARK: - C. The write-tool second-confirmation gate

    func testReadOnlyToolRunsAndReturnsItsTextWithoutAProposal() async {
        let stack = await makeHubStack(tools: [readOnlyTool()], allowedTools: [])
        let reply = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("read_notes"),
                      "arguments": .object(["path": .string("notes.md")])],
            source: "console"
        ))
        XCTAssertTrue(reply.ok, reply.body)
        XCTAssertEqual(reply.status, 200, "a read-only call completes, so it is the one case that answers 200")
        XCTAssertEqual(reply.fields["executed"]?.boolValue, true)
        XCTAssertEqual(reply.fields["requiresUserConfirmation"]?.boolValue, false)
        XCTAssertEqual(reply.fields["result"]?.stringValue, "the notes say 42",
                       "the tool's own text is the answer; a missing result would mean the call never happened")
        XCTAssertTrue(stack.link.writtenMethods.contains(MCPProtocol.methodToolsCall))
        let sent = stack.link.callDocuments.first?.objectValue?["params"]?.objectValue
        XCTAssertEqual(sent?["name"]?.stringValue, "read_notes", "the name on the wire is the tool the listing showed")
        XCTAssertEqual(sent?["arguments"]?.objectValue?["path"]?.stringValue, "notes.md")
        let pending = await stack.ledger.pending()
        XCTAssertTrue(pending.isEmpty, "a read must not queue a card: that trains the owner to approve noise")
        XCTAssertEqual(stack.gateway.commits.count, 0, "a hub call never goes through the calendar gateway")
    }

    func testMutatingToolIsQueuedAndTheTransportNeverSeesACall() async {
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"])
        let reply = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table"),
                      "arguments": .object(["table": .string("users")])],
            source: "console"
        ))

        XCTAssertEqual(reply.status, 201,
                       "measured contract: a queued write answers 201 Created here, not the 202 Accepted the brief names")
        XCTAssertNotEqual(reply.status, 200, "a queued write must never look like a completed call")
        XCTAssertEqual(reply.fields["state"]?.stringValue, PrivacyProposalState.pendingUserApproval.rawValue,
                       "pending_user_approval is the only state a mutating call may report")
        XCTAssertEqual(reply.fields["executed"]?.boolValue, false, "the response must not claim it ran")
        XCTAssertEqual(reply.fields["requiresUserConfirmation"]?.boolValue, true)
        XCTAssertNil(reply.fields["result"], "there is no result text for a call that did not run")
        XCTAssertNil(reply.fields["text"], "there is no result text for a call that did not run")

        let receipt = reply.fields["approvalReceipt"]?.stringValue ?? ""
        XCTAssertFalse(receipt.isEmpty, "the card is unusable without the receipt the ledger minted for it")
        XCTAssertNotEqual(receipt, reply.fields["rejectReceipt"]?.stringValue ?? "",
                          "an approve token must not double as a reject token")
        let stored = await stack.ledger.pending()
        XCTAssertEqual(reply.fields["proposalId"]?.stringValue, stored.first?.id,
                       "the id handed back is the stored one, or a click approves a different proposal")

        XCTAssertTrue(stack.link.callDocuments.isEmpty,
                      "THE rule: a mutating MCP tool must never execute on the strength of a request")
        XCTAssertFalse(stack.link.writtenMethods.contains(MCPProtocol.methodToolsCall),
                       "no tools/call document may reach the pipe before a human answers")
        XCTAssertEqual(stack.gateway.commits.count, 0, "an MCP write must not leak into the calendar gateway either")
    }

    func testForgedOrMismatchedReceiptIsRefusedAndTheProposalStaysPending() async {
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"])
        let reply = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "console"
        ))
        let proposalId = reply.fields["proposalId"]?.stringValue ?? ""
        XCTAssertFalse(proposalId.isEmpty)
        let otherProposalReceipt = await stack.ledger.receipt(id: "ppx-pr-somewhere-else", verb: "approve")

        let forgeries: [(String, String)] = [
            ("the reject receipt used as an approve token", reply.fields["rejectReceipt"]?.stringValue ?? "x"),
            ("garbage", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"),
            ("a receipt minted for a different proposal", otherProposalReceipt)
        ]
        for (label, forged) in forgeries {
            let attempt = await stack.engine.handle(PrivacyToolCall(
                namespace: .mcp, action: PrivacyToolAction.approve, id: proposalId,
                payload: ["receipt": .string(forged)], source: "console"
            ))
            XCTAssertFalse(attempt.ok, "\(label) must not approve")
            XCTAssertEqual(attempt.status, 403, "\(label) must read as forbidden, not as a server error: \(attempt.body)")
            let stored = await stack.ledger.proposal(id: proposalId)
            XCTAssertEqual(stored?.state, .pendingUserApproval, "\(label) must not consume the proposal")
            XCTAssertTrue(stack.link.callDocuments.isEmpty, "\(label) must not have run the tool")
        }

        // No receipt at all is refused before the ledger is even consulted.
        let noToken = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.approve, id: proposalId, payload: [:], source: "console"
        ))
        XCTAssertFalse(noToken.ok, "an approval with no receipt is the bypass this gate exists to stop")
        XCTAssertEqual(noToken.status, 403)
        XCTAssertTrue((noToken.fields["refusal"]?.stringValue ?? "").contains("receipt")
                      || (noToken.fields["refusal"]?.stringValue ?? "").contains("令牌"), noToken.body)
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "no receipt, no call, ever")

        // A proposal id nobody minted cannot be approved either, and does not become one.
        let ghost = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.approve, id: "ppx-pr-ghost",
            payload: ["receipt": .string(otherProposalReceipt)], source: "phone"
        ))
        XCTAssertFalse(ghost.ok, "an unknown proposal id must not reach the executor")
        XCTAssertTrue(stack.link.callDocuments.isEmpty)
    }

    func testCorrectReceiptApprovesOnceAndRunsTheQueuedPayload() async {
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"])
        let queued = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table"),
                      "arguments": .object(["table": .string("users")])], source: "console"
        ))
        let proposalId = queued.fields["proposalId"]?.stringValue ?? ""
        let receipt = queued.fields["approvalReceipt"]?.stringValue ?? ""
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "nothing ran before the click")

        let approved = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.approve, id: proposalId,
            payload: ["receipt": .string(receipt)], source: "console"
        ))
        XCTAssertTrue(approved.ok, approved.body)
        // Measured: there is no `.approved` state. Approval *is* the execution attempt, so a
        // proposal can never sit half-authorized; `executed` is this node's success spelling.
        XCTAssertEqual(approved.fields["state"]?.stringValue, PrivacyProposalState.executed.rawValue,
                       "after a valid receipt the proposal leaves pending and reports the execution result")
        XCTAssertEqual(stack.link.callDocuments.count, 1, "the approved payload runs exactly once")
        let sent = stack.link.callDocuments.first?.objectValue?["params"]?.objectValue
        XCTAssertEqual(sent?["name"]?.stringValue, "drop_table")
        XCTAssertEqual(sent?["arguments"]?.objectValue?["table"]?.stringValue, "users",
                       "what ran is the payload the owner was shown, not one the executor re-built")
        XCTAssertEqual(stack.gateway.commits.count, 0, "the hub path and the calendar path stay separate")

        let replay = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.approve, id: proposalId,
            payload: ["receipt": .string(receipt)], source: "console"
        ))
        XCTAssertFalse(replay.ok, "the same receipt cannot authorize a second drop")
        XCTAssertEqual(replay.status, 409, "a spent proposal is a conflict, not a forged token")
        XCTAssertEqual(stack.link.callDocuments.count, 1, "the replay must not have called the tool again")
    }

    func testRejectedProposalNeverRunsAndCannotBeApprovedAfterwards() async {
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"])
        let queued = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "console"
        ))
        let proposalId = queued.fields["proposalId"]?.stringValue ?? ""
        let rejected = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.reject, id: proposalId,
            payload: ["receipt": .string(queued.fields["rejectReceipt"]?.stringValue ?? "")], source: "console"
        ))
        XCTAssertTrue(rejected.ok, rejected.body)
        XCTAssertEqual(rejected.fields["state"]?.stringValue, PrivacyProposalState.rejected.rawValue)
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "「拒绝」 has to be the end of the road for that payload")

        let later = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.approve, id: proposalId,
            payload: ["receipt": .string(queued.fields["approvalReceipt"]?.stringValue ?? "")], source: "console"
        ))
        XCTAssertFalse(later.ok, "a rejected proposal must not be approvable afterwards")
        XCTAssertTrue(stack.link.callDocuments.isEmpty)
    }

    func testExpiredProposalIsRefusedEvenWithAValidReceipt() async {
        // The TTL is the second half of "the owner said yes to this, now".
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"])
        let queued = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "console"
        ))
        let proposalId = queued.fields["proposalId"]?.stringValue ?? ""
        let receipt = queued.fields["approvalReceipt"]?.stringValue ?? ""
        let farFuture = Date().addingTimeInterval(60 * 60 * 24)
        let late = await stack.ledger.approve(id: proposalId, receipt: receipt, now: farFuture)
        XCTAssertFalse(late.ok, "a receipt minted for a live proposal must not survive its TTL")
        XCTAssertEqual(late.proposal?.state, .expired)
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "an expired card cannot be stamped back to life")
    }

    func testInvokeIsRefusedWhileTheMcpSwitchIsOff() async {
        let stack = await makeHubStack(tools: [mutatingTool()], allowedTools: ["drop_table"], enableBridge: false)
        for action in [PrivacyToolAction.invoke, PrivacyToolAction.status,
                       PrivacyToolAction.servers, PrivacyToolAction.tools] {
            let reply = await stack.engine.handle(PrivacyToolCall(
                namespace: .mcp, action: action,
                payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "phone"
            ))
            XCTAssertFalse(reply.ok, "\(action) must be refused while the bridge is off")
            XCTAssertEqual(reply.status, 403, "\(action) is a policy refusal, not a malformed call")
            XCTAssertEqual(reply.fields["switch"]?.stringValue, "allowMcpBridge",
                           "the refusal names the switch, or an owner hunts through five panels for it")
        }
        XCTAssertTrue(stack.link.writtenMethods.isEmpty, "a switched-off bridge must not be handed a single byte, handshake included")
    }

    func testUnlistedOrUnpermittedToolIsRefusedBeforeAnyProposalExists() async {
        let stack = await makeHubStack(tools: [mutatingTool(), readOnlyTool()], allowedTools: ["read_notes"])
        // `drop_table` is listed by the server but not ticked in allowedTools.
        let unpermitted = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "console"
        ))
        XCTAssertFalse(unpermitted.ok)
        XCTAssertEqual(unpermitted.status, 403, "an unticked tool is a policy refusal")
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "the tool whitelist runs before the transport, so nothing executed")

        // A tool the server never listed is refused rather than escalated into a proposal.
        let unknown = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("rm_rf")], source: "console"
        ))
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.status, 403)
        let pending = await stack.ledger.pending()
        XCTAssertTrue(pending.isEmpty,
                      "a card for a tool nobody listed shows the owner a name they cannot verify — refuse it instead")

        // An empty allowedTools means "read-only tools only", never "everything".
        let wide = await makeHubStack(tools: [mutatingTool()], allowedTools: [])
        let offList = await wide.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("drop_table")], source: "console"
        ))
        XCTAssertFalse(offList.ok, "an empty allow-list must not widen the bridge to every mutating tool")
        XCTAssertTrue(wide.link.callDocuments.isEmpty)
    }

    func testUnregisteredServerAndOverLargeArgumentSetAreRefused() async {
        let stack = await makeHubStack(tools: [readOnlyTool()], allowedTools: [])
        let ghost = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("not-registered"), "tool": .string("read_notes")], source: "console"
        ))
        XCTAssertFalse(ghost.ok, "a server id that is not in the registry cannot be called at all")
        XCTAssertEqual(ghost.status, 403)
        XCTAssertTrue(stack.link.writtenMethods.isEmpty, "an unregistered server must not even be handed a handshake")

        var huge: [String: JSONValue] = [:]
        for index in 0...MCPBridge.maximumArguments { huge["k\(index)"] = .int(index) }
        let flooded = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.invoke,
            payload: ["serverId": .string("fake"), "tool": .string("read_notes"), "arguments": .object(huge)],
            source: "console"
        ))
        XCTAssertFalse(flooded.ok, "the argument ceiling bounds what can reach a third-party server")
        XCTAssertEqual(flooded.status, 403)
        XCTAssertTrue(stack.link.callDocuments.isEmpty, "an over-large call is refused before the transport, not after")
    }

    func testBridgeRefusedWhenTheServerItWouldUseIsNotUsable() async {
        // A registry that says "no servers" must not let the bridge hand out a proposal at all,
        // and the console rows have to say why rather than rendering blank.
        let command = "/usr/local/bin/fake-mcp-server"
        let registry = MCPServerRegistry(fileURL: nil, boot: MCPServersDocument(
            allowedCommands: [], servers: [stdioSpec(command, id: "unlisted")]
        ))
        let ledger = PrivacyProposalLedger(
            signer: PrivacyApprovalSigner(key: Data("hub-mcp-test-signing-key-0123".utf8)),
            executor: SilentExecutor(), notifier: SilentProposalNotifier(), fileURL: nil, loadFromDisk: false
        )
        // The factory is the seam where a subprocess would be spawned. Handing back a
        // pre-built link and checking `didStart` afterwards proves the gate closed before
        // anything that could launch a process was ever consulted.
        let link = FakeMCPLink(serverID: "unlisted", tools: [], callText: "")
        let bridge = MCPBridge(registry: registry, ledger: ledger, config: HubConfig(allowMcpBridge: true)) { _, _ in link }
        let outcome = await bridge.invoke(serverID: "unlisted", toolName: "read_notes")
        switch outcome {
        case .executed, .proposed:
            XCTFail("a server outside the command allow-list must not run or be proposed: \(outcome)")
        case .refused(let reason):
            XCTAssertTrue(reason.contains("白名单") || reason.contains("allowCommands"), reason)
        }
        XCTAssertFalse(link.didStart, "the refusal came before `start()`, i.e. before a process was spawned")
        XCTAssertEqual(link.writtenMethods, [], "not even `initialize` was written to the pipe")
        let cards = await bridge.serverCards()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].toolCount, 0, "an entry the node may not start has listed no tools")
        XCTAssertFalse(cards[0].connected, "a row must not claim a session it cannot open")
        // Measured: `enabled` mirrors the owner's checkbox and the bridge switch, not whether the
        // command is allow-listed, so this row reads "on" next to a refusal reason. Reported.
        XCTAssertTrue(cards[0].enabled, "the console's only warning for this row is `reason` — see the finding")
        XCTAssertTrue(cards[0].reason.contains("白名单") || cards[0].reason.contains("allowCommands"), cards[0].reason)
    }

    func testPayloadPreviewNeverCarriesARedactedArgumentValue() {
        let destination = "stdio /usr/local/bin/fake-mcp-server"
        for key in HubCallPayload.redactedArgumentKeys {
            let payload = HubCallPayload(
                kind: .mcpTool, serverID: "fake", target: "send_mail",
                arguments: [key: .string(sentinel), "entity_id": .string("light.desk")],
                destination: destination
            )
            XCTAssertFalse(payload.preview.contains(sentinel),
                           "a value under the redacted key \(key) reached the preview, which is rendered on a card and written to the audit log")
            XCTAssertTrue(payload.preview.contains("\(key)="), "the argument key must still be shown, or the owner sees nothing to recognise")
            XCTAssertTrue(payload.preview.contains("light.desk"), "a non-redacted scalar stays visible so the call is recognisable")
        }
        // Case is normalised, so `Token` cannot smuggle itself past the set.
        let cased = HubCallPayload(kind: .mcpTool, serverID: "fake", target: "auth",
                                   arguments: ["Token": .string(sentinel), "API_KEY": .string(sentinel)],
                                   destination: destination)
        XCTAssertFalse(cased.preview.contains(sentinel), "a capitalised spelling of a redacted key must not bypass the list")
        // `MCPBridge.invoke` builds the card as `detail: payload.preview`, so the same rule
        // has to hold on the object the owner actually reads.
        let proposal = PrivacyProposal(domain: .mcp, action: .invoke, detail: cased.preview, hubCall: cased)
        XCTAssertFalse(proposal.detail.contains(sentinel), "the proposal detail is the preview verbatim; a secret in it is on screen and in the audit row")
        XCTAssertTrue(proposal.detail.contains("Token=") && proposal.detail.contains("API_KEY="),
                      "the redaction still has to name the fields it hid, or the owner approves a shape they cannot inspect: \(proposal.detail)")
    }

    func testPayloadPreviewIsBoundedAndCountsWhatItHides() {
        // Short values, so the whole line fits inside the ceiling and the "+N more" tail is
        // checkable. This is the case where the notice is supposed to appear.
        var small: [String: JSONValue] = [:]
        for index in 0..<30 { small["f\(index)"] = .string("v\(index)") }
        let bulk = HubCallPayload(kind: .mcpTool, serverID: "fake", target: "bulk",
                                  arguments: small, destination: "stdio /usr/local/bin/fake-mcp-server")
        XCTAssertLessThanOrEqual(bulk.preview.count, HubCallPayload.maximumPreviewCharacters,
                                 "a preview lands in a notification banner and an audit row; it must not be able to carry a document")
        XCTAssertTrue(bulk.preview.contains("f0=v0"), "the shown arguments are the first \(HubCallPayload.maximumShownArguments) in sorted order")
        XCTAssertFalse(bulk.preview.contains("f29"),
                       "past maximumShownArguments the extra keys must not be listed, only counted")
        XCTAssertTrue(bulk.preview.contains("+\(30 - HubCallPayload.maximumShownArguments) 项 / more"),
                      "a 30-argument call has to say that 24 more exist, or the owner reads six and approves thirty: \(bulk.preview)")

        // Bulky values: `preview` joins first and truncates last, so the same count notice is
        // pushed past the 180-character ceiling and disappears. Measured — the owner sees six
        // "已截断 300 字符" pairs and no statement that 24 more arguments were hidden. Reported
        // as a finding; the values themselves still never leak, which is the part that matters.
        var bulky: [String: JSONValue] = [:]
        for index in 0..<30 { bulky["field\(index)"] = .string(String(repeating: "x", count: 300)) }
        let payload = HubCallPayload(kind: .mcpTool, serverID: "fake", target: "bulk",
                                     arguments: bulky, destination: "stdio /usr/local/bin/fake-mcp-server")
        XCTAssertLessThanOrEqual(payload.preview.count, HubCallPayload.maximumPreviewCharacters,
                                 "the ceiling is the ceiling whatever the arguments hold")
        XCTAssertFalse(payload.preview.contains(String(repeating: "x", count: 41)),
                       "a scalar longer than 40 characters is replaced by a length notice, never shown")
        XCTAssertTrue(payload.preview.contains("已截断") || payload.preview.contains("truncated")
                      || payload.preview.contains("已隐藏") || payload.preview.contains("hidden"),
                      "the owner should still see that something was hidden: \(payload.preview)")

        let seven = HubCallPayload(kind: .mcpTool, serverID: "fake", target: "seven",
                                   arguments: (0..<7).reduce(into: [:] as [String: JSONValue]) { acc, i in acc["k\(i)"] = .bool(true) })
        XCTAssertTrue(seven.preview.contains("+1 项 / more"),
                      "one argument over the display limit is still worth counting: \(seven.preview)")
        let nested = HubCallPayload(kind: .mcpTool, serverID: "fake", target: "write_file",
                                    arguments: ["path": .string("a.md"), "body": .object(["secret": .string(nestedSecret)])])
        XCTAssertFalse(nested.preview.contains(nestedSecret),
                       "a container argument is never rendered: an object's fields are the same leak with a nicer name")
        XCTAssertTrue(nested.preview.contains("write_file"), "the target itself stays readable, or the card is unrecognisable")
    }

    // MARK: - D. PrivacyToolRoute

    func testInvokePathResolvesToTheMcpNamespaceAndService() throws {
        let call = try XCTUnwrap(PrivacyToolRoute.parse(path: "/v1/tools/mcp/invoke"))
        XCTAssertEqual(call.namespace, .mcp, "the path namespace maps to the MCP tool surface")
        XCTAssertEqual(call.action, PrivacyToolAction.invoke, "the second piece is the service, and invoke is a write-shaped one")
        XCTAssertEqual(call.namespace.domain, .mcp, "the audit domain matches, so the ledger row lands where the console reads it")
        XCTAssertFalse(call.source.isEmpty, "the entry point is recorded, or an audit row cannot say who asked")

        for path in ["/v1/tools/mcp/status", "/v1/tools/mcp/servers", "/v1/tools/mcp/tools"] {
            let resolved = try XCTUnwrap(PrivacyToolRoute.parse(path: path), "\(path) must resolve")
            XCTAssertEqual(resolved.namespace, .mcp)
            XCTAssertFalse(PrivacyToolAction.idBearing.contains(resolved.action), "\(path) is read-shaped, so it needs no proposal id")
        }
        let trailing = try XCTUnwrap(PrivacyToolRoute.parse(path: "/v1/tools/mcp/invoke/"))
        XCTAssertEqual(trailing.action, "invoke", "a trailing slash is the same path, not an unknown service")

        let decision = try XCTUnwrap(PrivacyToolRoute.parse(path: "/v1/tools/mcp/proposals/ppx-pr-7/approve"))
        XCTAssertEqual(decision.action, "approve")
        XCTAssertEqual(decision.id, "ppx-pr-7", "the proposal id comes out of the path intact")
    }

    func testSmartHomeAliasIsAcceptedOnThePathSideAndRefusedOnTheCommandSide() {
        // `smartHome` is the audit domain the ledger stores; `home` is what an owner types and
        // what this node mints into a command line. The asymmetry is deliberate, so it is
        // pinned in both directions: widening the command side would hand a peer a second
        // spelling to aim at the same namespace.
        XCTAssertEqual(PrivacyToolRoute.namespace(accepting: "smartHome"), .home,
                       "a proposal card carries the audit domain, so the owner's path side must accept it")
        XCTAssertEqual(PrivacyToolRoute.namespace(accepting: "home"), .home)
        XCTAssertEqual(PrivacyToolRoute.parse(path: "/v1/tools/smartHome/control")?.namespace, .home,
                       "the alias reaches the same capability as the canonical name and no more")
        XCTAssertEqual(PrivacyToolRoute.parse(path: "/v1/tools/home/control")?.namespace, .home)

        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "smartHome", action: "control", payload: "{}"),
                     "a peer's serviceId is not the owner's path: only the spelling this node minted is accepted")
        let command = PrivacyToolRoute.parseCommand(serviceId: "home", action: "control", payload: "{}")
        XCTAssertEqual(command?.namespace, .home, "the minted spelling works from the phone too")
        XCTAssertEqual(command?.source, "phone", "the channel is recorded, so an audit row can tell peer from owner")

        // The alias is a reconciliation, not a skeleton key.
        XCTAssertEqual(PrivacyToolRoute.namespace(accepting: "calendar"), .calendar,
                       "a same-spelled namespace resolves to itself rather than through the alias branch")
        XCTAssertEqual(PrivacyToolRoute.namespace(accepting: "caldav"), .calDav,
                       "caldav borrows the calendar audit domain but keeps its own namespace")
        XCTAssertNil(PrivacyToolRoute.namespace(accepting: "Calendar"),
                     "namespace matching is case-sensitive: a case-insensitive lookup would silently widen the surface")
        XCTAssertNil(PrivacyToolRoute.namespace(accepting: " bolton "))

        // The command side, both directions: only spellings that are `PrivacyToolNamespace`
        // raw values parse, and every audit-domain spelling that differs from one is refused.
        for minted in ["calendar", "workspace", "mcp", "home", "caldav"] {
            XCTAssertNotNil(PrivacyToolRoute.parseCommand(serviceId: minted, action: "status", payload: "{}"),
                            "\(minted) is what `commandLine(namespace:)` emits, so it must parse")
        }
        for notANamespace in ["smartHome", "Calendar", "files", ""] {
            XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: notANamespace, action: "status", payload: "{}"),
                         "only the five namespace spellings exist on this channel: \(notANamespace) was accepted")
        }
        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "mcp ", action: "status", payload: "{}"),
                     "a padded serviceId must not resolve: the command side trims nothing, unlike the path side")
        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "bolton", action: "status", payload: "{}"),
                     "an unknown namespace is unknown on both channels")
    }

    func testTraversalAndUnknownServicesResolveToNothing() {
        let hostile = [
            "/v1/tools/mcp/../invoke", "/v1/tools/../../etc/passwd",
            "/v1/tools/calendar/proposals/../../etc/approve",
            "/v1/tools/mcp/proposals/../approve", "/v1/tools/mcp/proposals/a.b/approve",
            "/v1/tools/mcp/nuke", "/v1/tools/bolton/status", "/v1/tools/mcp",
            "/v1/tools/", "/v1/toolz/mcp/invoke", "tools/mcp/invoke",
            "/v1/tools/mcp/proposals/ppx-pr-7/bogus",
            "/v1/tools/mcp/proposals/\(String(repeating: "x", count: 70))/approve"
        ]
        for path in hostile {
            XCTAssertNil(PrivacyToolRoute.parse(path: path),
                         "\(path) resolved: a `..`, a dotted id or an over-long id reaching the ledger would let one click name a different proposal")
        }

        // The command channel: an action outside the tool surface is refused, so a peer can
        // never reach an endpoint the HTTP layer does not already have.
        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "mcp", action: "nuke", payload: "{}"))
        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "mcp", action: "approve", payload: "{}"),
                     "an approve with no proposalId must not reach the state machine")
        XCTAssertNil(PrivacyToolRoute.parseCommand(serviceId: "mcp", action: "approve", payload: "{\"proposalId\":\"..\"}"))
        let listed = PrivacyToolRoute.parseCommand(serviceId: "mcp", action: "invoke",
                                                   payload: "{\"serverId\":\"fake\",\"tool\":\"x\"}")
        XCTAssertEqual(listed?.payload["serverId"]?.stringValue, "fake", "a well-formed payload survives parsing")
        let sloppy = PrivacyToolRoute.parseCommand(serviceId: "mcp", action: "status", payload: "not json")
        XCTAssertNotNil(sloppy, "status needs no arguments, so unparsable text is not a refusal")
        XCTAssertEqual(sloppy?.payload["raw"]?.stringValue, "not json")
    }

    func testDispatchRefusesAnActionTheNamespaceDoesNotExpose() async {
        // `availability` is a real tool action but only for the calendar namespace, so the MCP
        // namespace must end in a refusal rather than falling through to a hub call.
        let stack = await makeHubStack(tools: [readOnlyTool()], allowedTools: [])
        let mismatched = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: PrivacyToolAction.availability, payload: [:], source: "console"
        ))
        XCTAssertFalse(mismatched.ok)
        XCTAssertEqual(mismatched.status, 405, "an action that exists but not in this namespace is not available here")
        XCTAssertTrue(stack.link.writtenMethods.isEmpty, "a 405 must be decided before anything is dialed")

        let unknown = await stack.engine.handle(PrivacyToolCall(
            namespace: .mcp, action: "nuke", payload: [:], source: "console"
        ))
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.status, 404, "an action outside the tool surface is not found in either entry point")
        XCTAssertTrue(stack.link.writtenMethods.isEmpty)
    }

    func testApprovalCommandLineCarriesTheNamespaceThisNodeMints() {
        let line = PrivacyToolRoute.commandLine(namespace: .home, action: PrivacyToolAction.approve,
                                                id: "ppx-pr-9", receipt: "rcpt")
        XCTAssertTrue(line.contains("::home::approve::"),
                      "the card must hand back the spelling parseCommand accepts, or an approval from the phone silently resolves to nil")
        XCTAssertFalse(line.contains("smartHome"), "minting the audit-domain spelling here would break the round trip")
        let roundTrip = PrivacyToolRoute.parseCommand(
            serviceId: "home", action: "approve", payload: "{\"proposalId\":\"ppx-pr-9\",\"receipt\":\"rcpt\"}"
        )
        XCTAssertEqual(roundTrip?.id, "ppx-pr-9", "the command line and the parser agree without anybody guessing")
        XCTAssertEqual(roundTrip?.payload["receipt"]?.stringValue, "rcpt",
                       "the receipt survives the wire intact; losing it means no write is authorized, which is the safe direction")
    }
}

// MARK: - Fakes

/// An in-memory MCP peer. Records every document the client writes and answers each request
/// with a canned result, so the whole gate is provable without a process or a socket.
private final class FakeMCPLink: MCPLink, @unchecked Sendable {
    let serverID: String

    private let tools: [JSONValue]
    private let callText: String
    private let lock = NSLock()
    private var inbound: [String] = []
    private var written: [JSONValue] = []
    private var startCount = 0
    private var closed = false

    init(serverID: String, tools: [JSONValue], callText: String) {
        self.serverID = serverID
        self.tools = tools
        self.callText = callText
    }

    func start(timeout: TimeInterval) async throws {
        mutating { self.startCount += 1 }
    }

    func writeLine(_ line: String) async throws {
        let document = JSONValue.parse(line)
        mutating { self.written.append(document) }
        guard case .object(let fields) = document,
              let method = fields["method"]?.stringValue,
              let id = fields["id"]?.intValue else { return } // a notification is never answered
        let answer: JSONValue
        switch method {
        case MCPProtocol.methodInitialize:
            answer = .object([
                "protocolVersion": .string(MCPProtocol.clientVersion),
                "serverInfo": .object(["name": .string("fake-mcp"), "title": .string("Fake")]),
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
        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(id),
            isErrorAnswer ? "error" : "result": answer
        ])
        mutating { self.inbound.append(envelope.serialized()) }
    }

    func readLine(timeout: TimeInterval) async throws -> String? {
        syncing { () -> String? in self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
    }

    func finish() async {
        mutating { self.closed = true }
    }

    var writtenMethods: [String] {
        syncing { self.written.compactMap { $0.objectValue?["method"]?.stringValue } }
    }

    /// The `tools/call` documents this peer was handed. Empty means nothing executed.
    var callDocuments: [JSONValue] {
        syncing { self.written.filter { $0.objectValue?["method"]?.stringValue == MCPProtocol.methodToolsCall } }
    }

    var didStart: Bool { syncing { self.startCount > 0 } }
    var isClosed: Bool { syncing { self.closed } }

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

/// A gateway that records whether it was touched at all: an MCP write reaching the calendar
/// side would mean one gate had leaked into the other.
private final class HubProbeGateway: CalendarGateway, @unchecked Sendable {
    private(set) var commits: [CalendarEventDraft] = []

    func authorizationState() async -> String { "denied" }
    func requestFullAccess() async -> String { "denied" }
    func availability(_ probe: CalendarProbe) async -> AvailabilityOutcome { AvailabilityOutcome() }
    func commit(_ draft: CalendarEventDraft) async -> CalendarCommitOutcome {
        commits.append(draft)
        return .committed(identifier: "must-not-happen")
    }
    func reschedule(identifier: String, start: Date, end: Date) async -> CalendarCommitOutcome {
        .committed(identifier: identifier)
    }
    func remove(identifier: String) async -> CalendarCommitOutcome { .committed(identifier: identifier) }
    func exists(identifier: String) async -> Bool { false }
}

/// Used by the case that builds a bridge on its own, where no approval is ever reached.
private struct SilentExecutor: ProposalExecutor {
    func execute(_ proposal: PrivacyProposal) async -> PrivacyExecution {
        .failed("this test never approves")
    }
}

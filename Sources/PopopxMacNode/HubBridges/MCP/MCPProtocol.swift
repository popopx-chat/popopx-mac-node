//
//  MCPProtocol.swift
//  PopopxMacNode — the JSON-RPC 2.0 and Model Context Protocol message shapes.
//
//  Two things make this file exist separately from the client that speaks them.
//
//  * **JSON-RPC 2.0 has a strict grammar and a bridge that relaxes it is unsafe.**
//    A response with both `result` and `error`, a request whose `id` is not the one
//    it asked with, or a notification that grew an `id` are all ways for a server —
//    or whatever has written to that pipe since — to make the node believe a call
//    succeeded. So decoding here refuses those cases instead of tolerating them, and
//    `MCPRpcError` distinguishes "malformed" from "the server said no".
//  * **Whether a tool may write is decided from the protocol document, not from a
//    caller's claim.** `MCPTool.safety` is the single place that reads
//    `annotations.readOnlyHint`, and it is default-deny: a server that says nothing
//    about a tool is a server that might delete something.
//

import Foundation

// MARK: - Constants

public enum MCPProtocol {
    /// The revision this client implements. A server answers with its own, and the
    /// client keeps working rather than pretending to negotiate a version it has no
    /// tests for.
    public static let clientVersion = "2025-06-18"
    public static let jsonrpc = "2.0"

    /// The handshake, then the announcement that the client is ready. Both are
    /// required by the spec; skipping `notifications/initialized` leaves some
    /// servers holding the session open without answering `tools/list`.
    public static let methodInitialize = "initialize"
    public static let methodInitialized = "notifications/initialized"
    public static let methodToolsList = "tools/list"
    public static let methodToolsCall = "tools/call"
    public static let methodPing = "ping"

    /// JSON-RPC 2.0 reserved codes (the ones a tool bridge can actually meet).
    public static let codeParseError = -32_700
    public static let codeInvalidRequest = -32_600
    public static let codeMethodNotFound = -32_601
    public static let codeInvalidParams = -32_602
    public static let codeInternalError = -32_603

    /// The node's own identity in `clientInfo`. A server operator reading their log
    /// should see which program knocked, and it must not be a generic name.
    public static let clientName = "popopx-mac-node"
}

// MARK: - Requests

/// A JSON-RPC request: `id` present, so an answer is expected.
public struct MCPRequest: Sendable, Equatable {
    public var id: Int
    public var method: String
    public var params: [String: JSONValue]

    public init(id: Int, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var payload: JSONValue {
        var document: [String: JSONValue] = [
            "jsonrpc": .string(MCPProtocol.jsonrpc),
            "id": .int(id),
            "method": .string(method)
        ]
        // `params` is optional in the grammar. Sending an empty object is legal too,
        // but a server that logs `{}` for `ping` learns nothing, so omit it when empty.
        if !params.isEmpty { document["params"] = .object(params) }
        return .object(document)
    }

    public var line: String { payload.serialized() }

    public static func initialize(id: Int) -> MCPRequest {
        // The node offers no roots, no sampling and no elicitation: it is a client of
        // tools, not a host that lets a server call back into it.
        MCPRequest(id: id, method: MCPProtocol.methodInitialize, params: [
            "protocolVersion": .string(MCPProtocol.clientVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(MCPProtocol.clientName),
                "version": .string(NodeVersion.current.semanticString)
            ])
        ])
    }

    public static func toolsList(id: Int, cursor: String = "") -> MCPRequest {
        var params: [String: JSONValue] = [:]
        if !cursor.isEmpty { params["cursor"] = .string(cursor) }
        return MCPRequest(id: id, method: MCPProtocol.methodToolsList, params: params)
    }

    public static func toolsCall(id: Int, name: String, arguments: [String: JSONValue]) -> MCPRequest {
        var params: [String: JSONValue] = ["name": .string(name)]
        params["arguments"] = .object(arguments)
        return MCPRequest(id: id, method: MCPProtocol.methodToolsCall, params: params)
    }
}

/// A JSON-RPC notification: no `id`, therefore never answered. Absence of the field
/// is the whole difference from a request, which is exactly the kind of detail a
/// hand-built dictionary gets wrong.
public struct MCPNotification: Sendable, Equatable {
    public var method: String
    public var params: [String: JSONValue]

    public init(method: String, params: [String: JSONValue] = [:]) {
        self.method = method
        self.params = params
    }

    public var payload: JSONValue {
        var document: [String: JSONValue] = [
            "jsonrpc": .string(MCPProtocol.jsonrpc),
            "method": .string(method)
        ]
        if !params.isEmpty { document["params"] = .object(params) }
        return .object(document)
    }

    public var line: String { payload.serialized() }

    public static let initialized = MCPNotification(method: MCPProtocol.methodInitialized)
}

// MARK: - Errors

public enum MCPRpcError: Error, Equatable, CustomStringConvertible {
    /// The bytes were not a JSON-RPC object at all.
    case malformed(String)
    /// It was JSON, but not an answer: no `jsonrpc`, both results, or no `id`.
    case invalidResponse(String)
    /// The server answered a different `id` than the one it was given.
    case mismatchedIdentifier(expected: Int, found: String)
    /// A well-formed JSON-RPC error object.
    case server(code: Int, message: String, data: JSONValue?)

    public var description: String {
        switch self {
        case let .malformed(detail):
            return "响应不是合法 JSON / malformed JSON-RPC: \(detail)"
        case let .invalidResponse(detail):
            return "响应不符合 JSON-RPC 2.0 / invalid JSON-RPC response: \(detail)"
        case let .mismatchedIdentifier(expected, found):
            return "响应 id 与请求不符 / id mismatch (asked \(expected), answered \(found))"
        case let .server(code, message, _):
            return "服务端错误 \(code) / server error \(code): \(message)"
        }
    }

    /// The stable wire token that goes into an audit row, so a log line can be
    /// grepped without embedding somebody's error prose.
    public var auditCode: String {
        switch self {
        case .malformed: return "malformed"
        case .invalidResponse: return "invalid_response"
        case .mismatchedIdentifier: return "id_mismatch"
        case let .server(code, _, _): return "rpc_\(code)"
        }
    }
}

// MARK: - Responses

/// One JSON-RPC answer. `result` and `error` are mutually exclusive by
/// construction, which is why parsing refuses a document that carries both.
public struct MCPResponse: Sendable, Equatable {
    public var id: Int
    public var outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case result(JSONValue)
        case error(code: Int, message: String, data: JSONValue?)
    }

    public init(id: Int, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    public static func result(_ value: JSONValue, id: Int) -> MCPResponse {
        MCPResponse(id: id, outcome: .result(value))
    }

    public static func error(code: Int, message: String, data: JSONValue? = nil, id: Int) -> MCPResponse {
        MCPResponse(id: id, outcome: .error(code: code, message: message, data: data))
    }

    public var isError: Bool {
        if case .error = outcome { return true }
        return false
    }

    /// Parses one decoded JSON document into a response, expecting `id`.
    public static func parse(_ document: JSONValue, expecting id: Int) throws -> MCPResponse {
        guard case .object(let fields) = document else {
            throw MCPRpcError.malformed("expected a JSON object")
        }
        guard let version = fields["jsonrpc"]?.stringValue, version == MCPProtocol.jsonrpc else {
            throw MCPRpcError.invalidResponse("jsonrpc is \(fields["jsonrpc"]?.stringValue ?? "absent"), not \"2.0\"")
        }
        guard let answered = fields["id"] else {
            throw MCPRpcError.invalidResponse("a response without an id is a notification")
        }
        guard let answeredId = answered.intValue else {
            throw MCPRpcError.invalidResponse("id is not a number")
        }
        guard answeredId == id else {
            throw MCPRpcError.mismatchedIdentifier(expected: id, found: String(answeredId))
        }
        let hasResult = fields["result"] != nil
        let hasError = fields["error"] != nil
        guard hasResult != hasError else {
            throw MCPRpcError.invalidResponse(hasResult
                ? "carries both result and error"
                : "carries neither result nor error")
        }
        if hasResult { return MCPResponse(id: id, outcome: .result(fields["result"] ?? .null)) }
        guard case .object(let errorFields)? = fields["error"],
              let code = errorFields["code"]?.intValue,
              let message = errorFields["message"]?.stringValue else {
            throw MCPRpcError.invalidResponse("error is missing code or message")
        }
        return MCPResponse(id: id, outcome: .error(code: code, message: message, data: errorFields["data"]))
    }

    /// `Result` form, so a caller cannot forget that an error object is not a success
    /// with an extra field.
    public func unwrapped() -> Result<JSONValue, MCPRpcError> {
        switch outcome {
        case let .result(value): return .success(value)
        case let .error(code, message, data): return .failure(.server(code: code, message: message, data: data))
        }
    }
}

// MARK: - Tools

/// How much of the world a tool touches, as the *node* reads it.
public enum MCPToolSafety: String, Codable, Sendable, Equatable {
    case readOnly
    case mutating
}

/// One entry of `tools/list`.
///
/// `annotations` is an optional extension in the protocol, so every hint defaults to
/// the value that costs the owner one extra confirmation rather than the value that
/// lets a write through.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    /// JSON Schema for the arguments. Kept as a `JSONValue` because the node forwards
    /// it to the console verbatim; inventing a Swift model for a schema language it
    /// does not validate would only lose fields.
    public var inputSchema: JSONValue
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        name: String,
        title: String = "",
        description: String = "",
        inputSchema: JSONValue = .object([:]),
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public static func parse(_ value: JSONValue) -> MCPTool? {
        guard case .object(let fields) = value,
              let name = fields["name"]?.stringValue, !name.isEmpty else { return nil }
        let annotations = fields["annotations"]?.objectValue ?? [:]
        return MCPTool(
            name: name,
            title: fields["title"]?.stringValue ?? "",
            description: fields["description"]?.stringValue ?? "",
            inputSchema: fields["inputSchema"] ?? .object([:]),
            readOnlyHint: annotations["readOnlyHint"]?.boolValue,
            destructiveHint: annotations["destructiveHint"]?.boolValue,
            idempotentHint: annotations["idempotentHint"]?.boolValue,
            openWorldHint: annotations["openWorldHint"]?.boolValue
        )
    }

    /// The gate every MCP call is measured against.
    ///
    /// Default-deny in both directions of doubt:
    /// * no `annotations` at all → mutating;
    /// * `destructiveHint: true` → mutating even if the server also claimed
    ///   `readOnlyHint: true`, because that pair is a contradiction and the safe
    ///   reading of a contradiction is the one that asks a human.
    ///
    /// `mutatingNameHints` can only ever *widen* the deny set for the same reason —
    /// a tool called `delete_file` that claims to be read-only gets confirmed.
    public var safety: MCPToolSafety {
        if destructiveHint == true { return .mutating }
        if openWorldHint == true { return .mutating }
        if mutatingNameHint { return .mutating }
        return readOnlyHint == true ? .readOnly : .mutating
    }

    public var isReadOnly: Bool { safety == .readOnly }

    /// Verbs that mean "this changes something", matched on the identifier because
    /// it is the one field every server is required to send.
    static let mutatingNameHints: [String] = [
        "create", "write", "insert", "add", "append", "update", "patch", "edit", "set",
        "put", "post", "delete", "remove", "rename", "move", "copy", "mkdir", "touch",
        "apply", "commit", "push", "merge", "revert", "reset", "send", "exec", "execute",
        "run", "spawn", "kill", "start", "stop", "install", "uninstall", "deploy",
        "publish", "upload", "submit", "cancel", "approve", "close", "reopen", "assign"
    ]

    var mutatingNameHint: Bool {
        let haystack = name.lowercased()
        return Self.mutatingNameHints.contains { haystack.contains($0) }
    }
}

// MARK: - Call results

/// The content of a `tools/call` answer, after the node has capped it.
///
/// Truncation is not cosmetic: a tool that prints a whole log file would otherwise
/// be pasted into the owner's console panel and into an audit row.
public struct MCPToolResult: Sendable, Equatable {
    public static let maximumCharacters = 8_000

    public var text: String
    public var blocks: [JSONValue]
    public var isError: Bool
    public var truncated: Bool

    public init(text: String, blocks: [JSONValue] = [], isError: Bool = false, truncated: Bool = false) {
        self.text = text
        self.blocks = blocks
        self.isError = isError
        self.truncated = truncated
    }

    public static func parse(_ value: JSONValue) -> MCPToolResult {
        let fields = value.objectValue ?? [:]
        let content = fields["content"]?.arrayValue ?? []
        var pieces: [String] = []
        for block in content {
            guard case .object(let blockFields) = block else { continue }
            let type = blockFields["type"]?.stringValue ?? "text"
            guard type == "text" else {
                // A non-text block (image, resource) is named but never carried: the
                // console renders text, and base64 blobs have no business in a poll
                // payload or an audit row.
                pieces.append("[\(type)]")
                continue
            }
            if let text = blockFields["text"]?.stringValue { pieces.append(text) }
        }
        let joined = pieces.joined(separator: "\n")
        // The error flag lives beside `content`, not inside it, and a server that
        // says "isError" must not be reported as a success with sad text.
        let failed = fields["isError"]?.boolValue == true
        guard joined.count > maximumCharacters else {
            return MCPToolResult(text: joined, blocks: content, isError: failed)
        }
        return MCPToolResult(
            text: String(joined.prefix(maximumCharacters)) + "\n… (已截断 / truncated)",
            blocks: content,
            isError: failed,
            truncated: true
        )
    }
}

// MARK: - Handshake answer

public struct MCPServerInfo: Sendable, Equatable {
    public var protocolVersion: String
    public var name: String
    public var title: String
    /// Which server methods it claims. Read for the console's status line only; the
    /// node never calls a method this list does not advertise, and the call sites do
    /// not consult it, because a server that omits `tools` would answer `tools/list`
    /// anyway and refusing it would break a working bridge.
    public var capabilities: [String: JSONValue]

    public init(protocolVersion: String = "", name: String = "", title: String = "", capabilities: [String: JSONValue] = [:]) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.title = title
        self.capabilities = capabilities
    }

    public static func parse(_ value: JSONValue) -> MCPServerInfo {
        let fields = value.objectValue ?? [:]
        let info = fields["serverInfo"]?.objectValue ?? [:]
        return MCPServerInfo(
            protocolVersion: fields["protocolVersion"]?.stringValue ?? "",
            name: info["name"]?.stringValue ?? "",
            title: info["title"]?.stringValue ?? "",
            capabilities: fields["capabilities"]?.objectValue ?? [:]
        )
    }
}

//
//  HubCallPayload.swift
//  PopopxMacNode — what a hub proposal promises to do, as a value.
//
//  The calendar gate works because a proposal *is* the write: it carries an
//  `CalendarEventDraft`, and the executor applies that draft and nothing else. A hub
//  action needs the same property, or 「批准」 means "approve whatever the caller passes
//  next". So a smart-home or MCP proposal carries this struct, and the executor's only
//  input is the struct that the owner was shown.
//
//  `preview` is the human line on the card. It is derived here, once, rather than at
//  every call site, because the failure mode of a hand-written preview is a leak: a tool's
//  `content` argument or a device's `message` value is exactly the kind of text the node
//  exists to keep off the wire, and it must not reach a notification banner or a rendered
//  HTML page. Argument *keys* are always shown; argument *values* are shown only when they
//  are short scalars and their key is not on the redacted list.
//

import Foundation

public struct HubCallPayload: Sendable, Equatable, Codable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An MCP `tools/call`.
        case mcpTool
        /// A Home Assistant `/api/services/<domain>/<service>`.
        case haService
        /// A raw MQTT publish.
        case mqttPublish
    }

    public static let maximumPreviewCharacters = 180
    public static let maximumShownArguments = 6

    /// Keys whose values never appear in a preview, whatever their length. Chosen for the
    /// shape of what these bridges actually get handed: a document body, a chat message,
    /// a credential.
    public static let redactedArgumentKeys: Set<String> = [
        "content", "body", "text", "message", "html", "markdown", "data",
        "password", "secret", "token", "apikey", "api_key", "key", "code",
        "payload", "value_json", "query", "sql", "prompt", "attachment"
    ]

    public var kind: Kind
    /// The configured server's id (`mcp`), or the bridge name (`smartHome`).
    public var serverID: String
    /// Tool name, `entity_id`, or topic — whatever names the thing being acted on.
    public var target: String
    public var arguments: [String: JSONValue]
    /// Where this will be sent, already validated: `stdio`, or the endpoint origin.
    public var destination: String
    /// The owner's own wording for the target, when the config has one.
    public var label: String

    public init(
        kind: Kind,
        serverID: String,
        target: String,
        arguments: [String: JSONValue] = [:],
        destination: String = "",
        label: String = ""
    ) {
        self.kind = kind
        self.serverID = serverID
        self.target = target
        self.arguments = arguments
        self.destination = destination
        self.label = label
    }

    /// One line, safe to render. Bounded, and never containing an argument value that
    /// the redaction list covers.
    public var preview: String {
        var parts: [String] = []
        parts.append(target.isEmpty ? "—" : target)
        let shown = arguments.keys.sorted().prefix(Self.maximumShownArguments)
        var pairs: [String] = []
        for key in shown {
            guard let value = arguments[key] else { continue }
            pairs.append("\(key)=\(Self.previewValue(key: key, value: value))")
        }
        if !pairs.isEmpty { parts.append(pairs.joined(separator: " ")) }
        if arguments.count > Self.maximumShownArguments {
            parts.append("+\(arguments.count - Self.maximumShownArguments) 项 / more")
        }
        if !destination.isEmpty { parts.append("→ \(destination)") }
        return String(parts.joined(separator: " ").prefix(Self.maximumPreviewCharacters))
    }

    /// A short scalar stays visible (`entity_id=light.desk`, `brightness=40`); anything
    /// bulk, opaque, or named like a secret becomes a length notice. Saying "2048 字符"
    /// instead of showing the text still lets an owner recognise the call they asked for.
    static func previewValue(key: String, value: JSONValue) -> String {
        let normalised = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if redactedArgumentKeys.contains(normalised) {
            let text = value.scalarText
            return text.isEmpty ? "已隐藏 / hidden" : "已隐藏 \(text.count) 字符 / hidden"
        }
        let text = value.scalarText
        if text.count > 40 { return "已截断 \(text.count) 字符 / truncated" }
        return text.isEmpty ? "—" : text
    }
}

extension JSONValue {
    /// A single-line rendering of a scalar, empty for a container. Containers are not
    /// shown in a preview: an object argument is either bulk data or a nested document,
    /// and printing its keys would be a different leak with a nicer name.
    var scalarText: String {
        switch self {
        case let .string(text): return String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object: return ""
        }
    }
}

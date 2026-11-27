//
//  Inkling2MiniAdapter.swift
//  PopopxMacNode — the assistant's local multimodal and structured-JSON brain.
//
//  Inkling 2 Mini is a model the owner installs; the node ships none of it. This
//  adapter only knows how to *ask a local runtime* for an answer, and four rules
//  shape every line below:
//
//  * **Loopback only, enforced before the request exists.** Every base URL goes
//    through `EdgeBoundary.resolve(url:policy:.loopbackOnly)`, and the request
//    carries the resulting `EdgeEndpoint`, so the host cannot be swapped after the
//    check. A public IP, a domain, a userinfo URL: refused, with zero transport
//    calls.
//  * **Typed JSON, not hopeful text.** A caller hands over an `InklingJSONSchema`;
//    a response that parses but does not match is as wrong as a malformed one. One
//    repair attempt is allowed, then the caller gets a degraded result it can fall
//    back from.
//  * **Media stays on this Mac.** Files are read only inside the owner-authorized
//    workspace roots, through the same symlink/deny-list guard the workspace
//    bridge uses. The Base64 payload exists in memory for one loopback request and
//    is never written to the audit store, a snapshot or a phone card; the audit
//    row carries an anonymised name, a SHA-256 prefix and a byte count.
//  * **No probe behind a poll.** `card()` is a cached description. Only an explicit
//    probe, a briefing or a triage refreshes it, so the console's snapshot timer
//    cannot turn into a loopback poll.
//

import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

// MARK: - Configuration

/// The owner-facing switchboard for the local model. `enabled` defaults to `true`
/// because the feature is "use the model when this Mac has one": the assistant
/// master switch is still off by default, so nothing is probed until the owner
/// turns the assistant on.
public struct InklingConfig: Codable, Sendable, Equatable {
    public static let defaultOllamaEndpoint = "http://127.0.0.1:11434"
    public static let defaultMlxEndpoint = "http://127.0.0.1:8080"
    public static let defaultModel = ModelCatalog.inkling2Mini.ollamaModel
    public static let maximumTicketPaths = 4

    public var enabled: Bool
    /// Stored as written. Non-loopback values are kept rather than rewritten so the
    /// console can say *why* the address was refused instead of silently replacing it.
    public var ollamaEndpoint: String
    public var mlxEndpoint: String
    public var model: String
    public var allowMultimodal: Bool
    public var structuredJSON: Bool
    /// Owner-shaped paths; the media reader still checks each one against the
    /// authorized workspace roots at use time.
    public var ticketPaths: [String]

    public init(
        enabled: Bool = true,
        ollamaEndpoint: String = InklingConfig.defaultOllamaEndpoint,
        mlxEndpoint: String = InklingConfig.defaultMlxEndpoint,
        model: String = InklingConfig.defaultModel,
        allowMultimodal: Bool = true,
        structuredJSON: Bool = true,
        ticketPaths: [String] = []
    ) {
        self.enabled = enabled
        self.ollamaEndpoint = ollamaEndpoint
        self.mlxEndpoint = mlxEndpoint
        self.model = model
        self.allowMultimodal = allowMultimodal
        self.structuredJSON = structuredJSON
        self.ticketPaths = ticketPaths
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, ollamaEndpoint, mlxEndpoint, model
        case allowMultimodal, structuredJSON, ticketPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = InklingConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        ollamaEndpoint = try c.decodeIfPresent(String.self, forKey: .ollamaEndpoint) ?? fallback.ollamaEndpoint
        mlxEndpoint = try c.decodeIfPresent(String.self, forKey: .mlxEndpoint) ?? fallback.mlxEndpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        allowMultimodal = try c.decodeIfPresent(Bool.self, forKey: .allowMultimodal) ?? fallback.allowMultimodal
        structuredJSON = try c.decodeIfPresent(Bool.self, forKey: .structuredJSON) ?? fallback.structuredJSON
        ticketPaths = try c.decodeIfPresent([String].self, forKey: .ticketPaths) ?? fallback.ticketPaths
    }

    public var normalised: InklingConfig {
        var copy = self
        copy.ollamaEndpoint = Self.endpoint(ollamaEndpoint, fallback: Self.defaultOllamaEndpoint)
        copy.mlxEndpoint = Self.endpoint(mlxEndpoint, fallback: Self.defaultMlxEndpoint)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = ModelRefOverrides.isValid(cleanModel) ? cleanModel : Self.defaultModel
        copy.ticketPaths = Array(
            ticketPaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(Self.maximumTicketPaths)
        )
        return copy
    }

    private static func endpoint(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

// MARK: - Card

public enum InklingState: String, Codable, Sendable, Equatable {
    case off
    case unknown
    case ready
    case modelMissing = "model_missing"
    case runtimeMissing = "runtime_missing"
    case refused
}

/// What the console and the phone read. It carries no prompt, no file content and
/// no Base64 — only the decision and the guidance to act on it.
public struct AssistantInklingCard: Codable, Sendable, Equatable {
    public static let displayName = "Inkling 2 Mini (Apache 2.0 · Multimodal MoE)"
    public static let license = "Apache 2.0 · Multimodal MoE"

    public var enabled: Bool
    public var state: InklingState
    public var runtime: String
    public var model: String
    public var displayName: String
    public var license: String
    public var ollamaEndpoint: String
    public var mlxEndpoint: String
    public var allowMultimodal: Bool
    public var structuredJSON: Bool
    public var ticketPaths: [String]
    public var pullCommand: String
    public var lastProbeAt: Date?
    public var lastDetail: String
    public var jsonRuns: Int
    public var mediaRuns: Int
    public var degradedRuns: Int
    public var lastUsedAt: Date?

    public init(
        enabled: Bool = false,
        state: InklingState = .off,
        runtime: String = "",
        model: String = InklingConfig.defaultModel,
        displayName: String = AssistantInklingCard.displayName,
        license: String = AssistantInklingCard.license,
        ollamaEndpoint: String = InklingConfig.defaultOllamaEndpoint,
        mlxEndpoint: String = InklingConfig.defaultMlxEndpoint,
        allowMultimodal: Bool = true,
        structuredJSON: Bool = true,
        ticketPaths: [String] = [],
        pullCommand: String = "",
        lastProbeAt: Date? = nil,
        lastDetail: String = "",
        jsonRuns: Int = 0,
        mediaRuns: Int = 0,
        degradedRuns: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.state = state
        self.runtime = runtime
        self.model = model
        self.displayName = displayName
        self.license = license
        self.ollamaEndpoint = ollamaEndpoint
        self.mlxEndpoint = mlxEndpoint
        self.allowMultimodal = allowMultimodal
        self.structuredJSON = structuredJSON
        self.ticketPaths = ticketPaths
        self.pullCommand = pullCommand
        self.lastProbeAt = lastProbeAt
        self.lastDetail = lastDetail
        self.jsonRuns = jsonRuns
        self.mediaRuns = mediaRuns
        self.degradedRuns = degradedRuns
        self.lastUsedAt = lastUsedAt
    }

    /// The honest document before anything has been probed — and after the
    /// assistant is switched off, when no adapter is even assembled.
    public static func saved(_ config: InklingConfig) -> AssistantInklingCard {
        let value = config.normalised
        return AssistantInklingCard(
            enabled: value.enabled,
            state: value.enabled ? .unknown : .off,
            model: value.model,
            ollamaEndpoint: value.ollamaEndpoint,
            mlxEndpoint: value.mlxEndpoint,
            allowMultimodal: value.allowMultimodal,
            structuredJSON: value.structuredJSON,
            ticketPaths: value.ticketPaths,
            pullCommand: ModelCatalog.inkling2Mini.pullCommand(for: ModelCatalog.inkling2Mini.ollamaRef),
            lastDetail: value.enabled
                ? "尚未探测本机运行时 / not probed yet"
                : "本地模型已关闭 / the local model is off"
        )
    }
}

// MARK: - JSON schema

/// A deliberately small schema language: enough to describe every answer this
/// adapter asks for, and strict about the field that matters — an unknown field is
/// refused unless the caller opted into it, and an enum is a closed set.
public struct InklingJSONSchema: Sendable, Equatable {
    public indirect enum Node: Sendable, Equatable {
        case object(properties: [String: Node], required: [String], additionalProperties: Bool)
        case array(items: Node)
        case string(enumValues: [String])
        case number
        case integer
        case boolean

        var jsonValue: JSONValue {
            switch self {
            case let .object(properties, required, additional):
                var value: [String: JSONValue] = [
                    "type": .string("object"),
                    "properties": .object(properties.mapValues(\.jsonValue)),
                    "additionalProperties": .bool(additional)
                ]
                if !required.isEmpty {
                    value["required"] = .array(required.map { .string($0) })
                }
                return .object(value)
            case .array(let items):
                return .object(["type": .string("array"), "items": items.jsonValue])
            case .string(let allowed):
                var value: [String: JSONValue] = ["type": .string("string")]
                if !allowed.isEmpty { value["enum"] = .array(allowed.map { .string($0) }) }
                return .object(value)
            case .number:
                return .object(["type": .string("number")])
            case .integer:
                return .object(["type": .string("integer")])
            case .boolean:
                return .object(["type": .string("boolean")])
            }
        }
    }

    public var root: Node

    public init(root: Node) {
        self.root = root
    }

    public var jsonValue: JSONValue { root.jsonValue }

    /// `nil` when the value matches; otherwise a path-shaped reason that is safe to
    /// send back to the model and to the audit log (it names types, never values).
    public func validate(_ value: JSONValue) -> String? {
        Self.check(value, against: root, path: "$")
    }

    public var summary: String {
        switch root {
        case let .object(properties, required, _):
            return "object(\(properties.count) fields, \(required.count) required)"
        case .array:
            return "array"
        case .string:
            return "string"
        case .number:
            return "number"
        case .integer:
            return "integer"
        case .boolean:
            return "boolean"
        }
    }

    private static func check(_ value: JSONValue, against node: Node, path: String) -> String? {
        switch node {
        case let .object(properties, required, additional):
            guard let object = value.objectValue else { return "\(path): expected object" }
            for key in required where object[key] == nil {
                return "\(path).\(key): missing"
            }
            for (key, child) in object {
                if let schema = properties[key] {
                    if let problem = check(child, against: schema, path: "\(path).\(key)") { return problem }
                } else if !additional {
                    return "\(path).\(key): unexpected field"
                }
            }
            return nil
        case .array(let items):
            guard let list = value.arrayValue else { return "\(path): expected array" }
            for (index, child) in list.enumerated() {
                if let problem = check(child, against: items, path: "\(path)[\(index)]") { return problem }
            }
            return nil
        case .string(let allowed):
            // `stringValue` coerces numbers and booleans; a typed schema must not.
            guard case .string(let text) = value else { return "\(path): expected string" }
            if !allowed.isEmpty, !allowed.contains(text) { return "\(path): value not allowed" }
            return nil
        case .number:
            switch value {
            case .int, .double: return nil
            default: return "\(path): expected number"
            }
        case .integer:
            switch value {
            case .int: return nil
            case .double(let number) where number.rounded() == number: return nil
            default: return "\(path): expected integer"
            }
        case .boolean:
            if case .bool = value { return nil }
            return "\(path): expected boolean"
        }
    }
}

// MARK: - Transport

public struct InklingHTTPRequest: Sendable, Equatable {
    public var method: String
    public var endpoint: EdgeEndpoint
    public var path: String
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, endpoint: EdgeEndpoint, path: String, body: Data?, timeout: TimeInterval) {
        self.method = method
        self.endpoint = endpoint
        self.path = path
        self.body = body
        self.timeout = timeout
    }
}

public struct InklingHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The injection seam the tests replace. A request can only name a validated
/// `EdgeEndpoint`, so a fake transport is also proof that the guard ran.
public protocol InklingTransporting: Sendable {
    func send(_ request: InklingHTTPRequest) async throws -> InklingHTTPResponse
}

public enum InklingTransportError: Error, Equatable, CustomStringConvertible {
    case badURL
    case notHTTP

    public var description: String {
        switch self {
        case .badURL: return "无法构造已校验端点的 URL / could not build the validated endpoint URL"
        case .notHTTP: return "响应不是 HTTP / the response was not HTTP"
        }
    }
}

/// Ephemeral session, no cache, no cookies, no redirects — the same posture as the
/// hub bridges. The host came from an `EdgeEndpoint`, never from a raw string.
public struct InklingURLSessionTransport: InklingTransporting {
    public init() {}

    public func send(_ request: InklingHTTPRequest) async throws -> InklingHTTPResponse {
        guard let url = request.endpoint.url(path: request.path) else {
            throw InklingTransportError.badURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = HubHTTP.session(timeout: request.timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw InklingTransportError.notHTTP
        }
        return InklingHTTPResponse(status: http.statusCode, body: data)
    }
}

// MARK: - Media scope

public enum InklingMediaRefusal: String, Sendable, Equatable, Error {
    case disabled
    case noDirectories
    case emptyPath
    case pathTraversal
    case sensitivePath
    case outsideSandbox
    case notFound
    case isDirectory
    case tooLarge
    case notMedia
    case unreadable
    case pdfRasterFailed

    public var message: String {
        switch self {
        case .disabled: return "多模态已关闭 / multimodal is off"
        case .noDirectories: return "未授权任何工作区目录 / no workspace directory is authorized"
        case .emptyPath: return "缺少路径 / missing path"
        case .pathTraversal: return "拒绝路径穿越（..）/ path traversal refused"
        case .sensitivePath: return "拒绝系统敏感目录 / sensitive location refused"
        case .outsideSandbox: return "路径不在已授权目录内 / path is outside the authorized directories"
        case .notFound: return "文件不存在 / file not found"
        case .isDirectory: return "目标是目录 / the path is a directory"
        case .tooLarge: return "文件超过大小上限 / the file exceeds the media limit"
        case .notMedia: return "不是 PNG/JPEG/WebP/PDF / not a supported image or PDF"
        case .unreadable: return "文件不可读 / the file could not be read"
        case .pdfRasterFailed: return "PDF 首页无法渲染 / the first PDF page could not be rendered"
        }
    }

    init(workspace: WorkspaceRefusal) {
        switch workspace {
        case .bridgeDisabled, .readDisabled, .writeDisabled:
            self = .disabled
        case .noDirectories:
            self = .noDirectories
        case .emptyPath:
            self = .emptyPath
        case .pathTraversal:
            self = .pathTraversal
        case .sensitivePath:
            self = .sensitivePath
        case .outsideSandbox:
            self = .outsideSandbox
        case .notFound, .sourceMissing, .targetExists:
            self = .notFound
        case .isDirectory:
            self = .isDirectory
        case .tooLarge:
            self = .tooLarge
        case .notText:
            self = .notMedia
        }
    }
}

/// A loaded file, ready for one loopback request. Internal to the adapter's work;
/// only the analysis summary leaves this type.
public struct InklingMediaFile: Sendable, Equatable {
    public var url: URL
    public var displayPath: String
    public var name: String
    public var bytes: Int
    public var digest: String
    /// `image/png`, `image/jpeg`, `image/webp`, or `image/png` after a PDF is
    /// rasterised. The model receives this payload, never the PDF bytes.
    public var mimeType: String
    public var payload: Data
}

/// The guard plus reader. It reuses `WorkspaceSandbox` for the four checks that
/// must agree with the workspace bridge (traversal, roots, symlinks, deny-list),
/// then applies media rules: a magic-byte check, a 12 MB cap, and page-1
/// rasterisation for a PDF.
public struct InklingMediaScope: Sendable {
    public static let maximumSourceBytes = 12_000_000
    public static let maximumImageDimension = 1_600

    public var directoryPaths: [String]

    public init(directoryPaths: [String]) {
        self.directoryPaths = Array(directoryPaths.prefix(PrivacyBridgeConfig.maximumDirectories))
    }

    public func load(_ raw: String) -> Result<InklingMediaFile, InklingMediaRefusal> {
        guard !directoryPaths.isEmpty else { return .failure(.noDirectories) }
        let sandbox = WorkspaceSandbox(readAllowed: true, directoryPaths: directoryPaths)
        if let refusal = sandbox.guardPath(raw, writing: false) {
            return .failure(InklingMediaRefusal(workspace: refusal))
        }
        guard let url = sandbox.resolvedURL(raw) else { return .failure(.outsideSandbox) }

        var isDirectory: ObjCBool = false
        guard AppPaths.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.notFound)
        }
        guard !isDirectory.boolValue else { return .failure(.isDirectory) }
        let attributes = try? AppPaths.fileManager.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue else { return .failure(.unreadable) }
        guard size > 0, size <= Self.maximumSourceBytes else {
            return size > Self.maximumSourceBytes ? .failure(.tooLarge) : .failure(.notMedia)
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return .failure(.unreadable) }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), data.count == size else { return .failure(.unreadable) }

        guard let mime = Self.mimeType(of: data) else { return .failure(.notMedia) }
        let payload: Data
        let payloadMime: String
        if mime == "application/pdf" {
            guard let png = Self.rasterizePDF(data) else { return .failure(.pdfRasterFailed) }
            payload = png
            payloadMime = "image/png"
        } else {
            payload = data
            payloadMime = mime
        }
        return .success(InklingMediaFile(
            url: url,
            displayPath: AppPaths.anonymise(url.path),
            name: String(url.lastPathComponent.prefix(120)),
            bytes: data.count,
            digest: Self.sha256(data),
            mimeType: payloadMime,
            payload: payload
        ))
    }

    static func mimeType(of data: Data) -> String? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= png.count, data.prefix(png.count).elementsEqual(png) { return "image/png" }
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        if data.count >= jpeg.count, data.prefix(jpeg.count).elementsEqual(jpeg) { return "image/jpeg" }
        if data.count >= 12,
           data.prefix(4).elementsEqual(Data("RIFF".utf8)),
           data[data.startIndex + 8..<data.startIndex + 12].elementsEqual(Data("WEBP".utf8)) {
            return "image/webp"
        }
        if data.count >= 5, String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-" {
            return "application/pdf"
        }
        return nil
    }

    /// Only page one is rendered: a bill is a bill, and a 60-page statement is more
    /// a memory hazard than an answer. The page is scaled to fit 1600 px on the
    /// long edge; no PDF data is ever sent to the model.
    static func rasterizePDF(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages >= 1,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, CGFloat(maximumImageDimension) / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let target = CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Results

public struct InklingGeneration: Sendable, Equatable {
    public var value: JSONValue?
    public var runtime: String
    public var model: String
    public var attempts: Int
    public var degradedReason: String

    public var ok: Bool { value != nil }

    public init(
        value: JSONValue?,
        runtime: String,
        model: String,
        attempts: Int,
        degradedReason: String
    ) {
        self.value = value
        self.runtime = runtime
        self.model = model
        self.attempts = attempts
        self.degradedReason = degradedReason
    }
}

public struct InklingMediaExtraction: Codable, Sendable, Equatable {
    public var documentKind: String
    public var merchant: String
    public var amount: String
    public var dueDate: String
    public var summary: String

    public init(
        documentKind: String,
        merchant: String,
        amount: String,
        dueDate: String,
        summary: String
    ) {
        self.documentKind = documentKind
        self.merchant = merchant
        self.amount = amount
        self.dueDate = dueDate
        self.summary = summary
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        documentKind = object["document_kind"]?.stringValue ?? ""
        merchant = object["merchant"]?.stringValue ?? ""
        amount = object["amount"]?.stringValue ?? ""
        dueDate = object["due_date"]?.stringValue ?? ""
        summary = object["summary"]?.stringValue ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case documentKind = "document_kind"
        case merchant, amount
        case dueDate = "due_date"
        case summary
    }
}

public struct InklingMediaAnalysis: Sendable, Equatable {
    public var ok: Bool
    /// Anonymised (`~/…`), never the raw path.
    public var file: String
    public var digest: String
    public var bytes: Int
    public var mimeType: String
    public var extraction: InklingMediaExtraction?
    public var degradedReason: String
    public var attempts: Int

    public static func refused(_ file: String, _ reason: String) -> InklingMediaAnalysis {
        InklingMediaAnalysis(
            ok: false,
            file: file,
            digest: "",
            bytes: 0,
            mimeType: "",
            extraction: nil,
            degradedReason: reason,
            attempts: 0
        )
    }
}

// MARK: - Runtime

public enum InklingRuntime: String, Sendable, CaseIterable {
    case ollama
    case mlx
}

public enum InklingAdapterError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int)
    case badResponse(String)
    case noRuntime
    case noModel

    public var description: String {
        switch self {
        case let .httpStatus(code): return "本机运行时返回 HTTP \(code)"
        case let .badResponse(detail): return detail
        case .noRuntime: return "未检测到本机运行时 / no local runtime answered"
        case .noModel: return "模型未安装 / the model is not installed"
        }
    }
}

// MARK: - Adapter

public actor Inkling2MiniAdapter {
    public static let probeTTL: TimeInterval = 60
    private static let probeTimeout: TimeInterval = 2.5
    private static let generateTimeout: TimeInterval = 45

    public static let briefingSystem =
        "You are a local-only assistant on the owner's Mac. You restate only facts supplied in the input. " +
        "You never invent an event, amount, date or device state, and you answer with JSON only."
    public static let mediaSystem =
        "You are a local-only OCR and bookkeeping assistant. You answer with JSON only. " +
        "Copy only text that is actually visible in the image; use empty strings for absent fields."

    public static let briefingSchema = InklingJSONSchema(root: .object(properties: [
        "headline": .string(enumValues: []),
        "summary": .string(enumValues: []),
        "priorities": .array(items: .string(enumValues: [])),
        "anomaly_notes": .string(enumValues: [])
    ], required: ["headline", "summary", "priorities"], additionalProperties: true))

    public static let mediaSchema = InklingJSONSchema(root: .object(properties: [
        "document_kind": .string(enumValues: []),
        "merchant": .string(enumValues: []),
        "amount": .string(enumValues: []),
        "due_date": .string(enumValues: []),
        "summary": .string(enumValues: [])
    ], required: ["document_kind", "merchant", "amount", "due_date", "summary"], additionalProperties: true))

    private struct Candidate {
        var runtime: InklingRuntime
        var endpoint: EdgeEndpoint
    }

    private struct ReadyRuntime {
        var runtime: InklingRuntime
        var endpoint: EdgeEndpoint
        var modelRef: String
    }

    private struct Probe {
        var at: Date
        var state: InklingState
        var runtime: InklingRuntime?
        var endpoint: EdgeEndpoint?
        var detail: String
    }

    private var config: InklingConfig
    private var scopeRoots: [String]
    private let transport: any InklingTransporting
    private let store: AssistantAuditStore?
    private let clock: AssistantClock
    private var cachedProbe: Probe?
    private var jsonRuns = 0
    private var mediaRuns = 0
    private var degradedRuns = 0
    private var lastUsedAt: Date?

    public init(
        config: InklingConfig = InklingConfig(),
        scopeRoots: [String] = [],
        transport: any InklingTransporting = InklingURLSessionTransport(),
        store: AssistantAuditStore? = nil,
        clock: AssistantClock = SystemAssistantClock()
    ) {
        self.config = config.normalised
        self.scopeRoots = Array(scopeRoots.prefix(PrivacyBridgeConfig.maximumDirectories))
        self.transport = transport
        self.store = store
        self.clock = clock
    }

    public func update(config next: InklingConfig, scopeRoots nextRoots: [String]) {
        let normalised = next.normalised
        if normalised != config {
            cachedProbe = nil
        }
        config = normalised
        scopeRoots = Array(nextRoots.prefix(PrivacyBridgeConfig.maximumDirectories))
    }

    // MARK: State

    /// A cached description. This never contacts a runtime, which is what keeps it
    /// safe to call from every snapshot.
    public func card(now: Date? = nil) -> AssistantInklingCard {
        var value = AssistantInklingCard.saved(config)
        if !config.enabled {
            value.state = .off
        } else if let cachedProbe {
            value.state = cachedProbe.state
            value.runtime = cachedProbe.runtime?.rawValue ?? ""
            value.lastProbeAt = cachedProbe.at
            value.lastDetail = cachedProbe.detail
        }
        value.jsonRuns = jsonRuns
        value.mediaRuns = mediaRuns
        value.degradedRuns = degradedRuns
        value.lastUsedAt = lastUsedAt
        value.lastDetail = String(value.lastDetail.prefix(AssistantAuditStore.maximumDetail))
        return value
    }

    @discardableResult
    public func probe(now: Date? = nil) async -> AssistantInklingCard {
        let moment = now ?? clock.now
        guard config.enabled else {
            cachedProbe = nil
            await audit("probe", "disabled", "refused", at: moment)
            return card(now: moment)
        }
        let resolution = candidates()
        guard !resolution.values.isEmpty else {
            let detail = "端点必须是回环地址 / loopback endpoints only: " + resolution.refusals.joined(separator: "; ")
            cachedProbe = Probe(at: moment, state: .refused, runtime: nil, endpoint: nil, detail: String(detail.prefix(280)))
            await audit("probe", "refused · " + resolution.refusals.joined(separator: "; "), "refused", at: moment)
            return card(now: moment)
        }

        var sawRuntime = false
        var failure = ""
        for candidate in resolution.values {
            do {
                let listed = try await listModels(runtime: candidate.runtime, endpoint: candidate.endpoint)
                sawRuntime = true
                if listed.contains(where: { Self.referenceMatches($0, config.model) }) {
                    let detail = "\(candidate.runtime.rawValue) 已就绪 / ready · \(config.model) · \(candidate.endpoint.origin)"
                    cachedProbe = Probe(
                        at: moment,
                        state: .ready,
                        runtime: candidate.runtime,
                        endpoint: candidate.endpoint,
                        detail: detail
                    )
                    await audit("probe", "ready · \(candidate.runtime.rawValue) · \(config.model)", "ok", at: moment)
                    return card(now: moment)
                }
                failure = "\(candidate.runtime.rawValue): 模型未拉取 / model not listed"
            } catch {
                failure = "\(candidate.runtime.rawValue): \(describe(error))"
            }
        }

        let state: InklingState = sawRuntime ? .modelMissing : .runtimeMissing
        let detail: String
        if sawRuntime {
            detail = "未找到 \(config.model)；本地拉取 \(ModelCatalog.inkling2Mini.pullCommand(for: ModelCatalog.inkling2Mini.ollamaRef))"
        } else {
            detail = "未检测到本机 Ollama/MLX 运行时 / no local runtime answered · " + failure
        }
        cachedProbe = Probe(at: moment, state: state, runtime: nil, endpoint: nil, detail: String(detail.prefix(280)))
        await audit("probe", "\(state.rawValue) · \(failure)", "failed", at: moment)
        return card(now: moment)
    }

    public func isReady(now: Date? = nil) async -> Bool {
        guard config.enabled else { return false }
        let moment = now ?? clock.now
        if let cachedProbe,
           moment.timeIntervalSince(cachedProbe.at) >= 0,
           moment.timeIntervalSince(cachedProbe.at) < Self.probeTTL {
            return cachedProbe.state == .ready
        }
        return await probe(now: moment).state == .ready
    }

    // MARK: Structured JSON

    public func generateStructuredJSON(
        prompt: String,
        schema: InklingJSONSchema,
        system: String = "",
        now: Date? = nil
    ) async -> InklingGeneration {
        let moment = now ?? clock.now
        guard config.enabled else {
            return degraded("本机模型已关闭 / the local model is off", at: moment)
        }
        guard config.structuredJSON else {
            return degraded("结构化 JSON 推理已关闭 / structured JSON is off", at: moment)
        }
        guard let runtime = await readyRuntime(now: moment) else {
            return degraded(cachedProbe?.detail ?? "未检测到本机运行时 / no local runtime", at: moment)
        }
        let outcome = await requestJSON(
            runtime: runtime,
            prompt: prompt,
            system: system,
            schema: schema,
            images: [],
            at: moment
        )
        guard let value = outcome.value else {
            degradedRuns += 1
            await audit(
                "json_degraded",
                "\(runtime.runtime.rawValue) · \(outcome.failure)",
                "failed",
                at: moment
            )
            return InklingGeneration(
                value: nil,
                runtime: runtime.runtime.rawValue,
                model: runtime.modelRef,
                attempts: outcome.attempts,
                degradedReason: outcome.failure
            )
        }
        jsonRuns += 1
        lastUsedAt = moment
        await audit(
            "json_ok",
            "\(runtime.runtime.rawValue) · attempts \(outcome.attempts) · \(schema.summary)",
            "ok",
            at: moment
        )
        return InklingGeneration(
            value: value,
            runtime: runtime.runtime.rawValue,
            model: runtime.modelRef,
            attempts: outcome.attempts,
            degradedReason: ""
        )
    }

    // MARK: Media

    public func analyzeLocalMedia(path: String, now: Date? = nil) async -> InklingMediaAnalysis {
        let moment = now ?? clock.now
        let display = AppPaths.anonymise(path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard config.enabled else {
            return .refused(display, InklingMediaRefusal.disabled.message)
        }
        guard config.allowMultimodal else {
            await audit("media_refused", "multimodal off · \(display)", "refused", at: moment)
            return .refused(display, InklingMediaRefusal.disabled.message)
        }
        let loaded: InklingMediaFile
        switch InklingMediaScope(directoryPaths: scopeRoots).load(path) {
        case .failure(let refusal):
            await audit("media_refused", "\(refusal.rawValue) · \(display)", "refused", at: moment)
            return .refused(display, refusal.message)
        case .success(let value):
            loaded = value
        }
        guard let runtime = await readyRuntime(now: moment) else {
            await audit(
                "media_degraded",
                "runtime unavailable · \(loaded.name) · sha256 \(loaded.digest.prefix(12)) · \(loaded.bytes)B",
                "failed",
                at: moment
            )
            return InklingMediaAnalysis(
                ok: false,
                file: loaded.displayPath,
                digest: loaded.digest,
                bytes: loaded.bytes,
                mimeType: loaded.mimeType,
                extraction: nil,
                degradedReason: cachedProbe?.detail ?? "未检测到本机运行时 / no local runtime",
                attempts: 0
            )
        }
        let prompt = """
        The attached image is a bill, receipt, invoice, or notice. Return JSON with exactly these string keys: \
        document_kind (bill, receipt, invoice, notice, or other), merchant, amount, due_date (YYYY-MM-DD when \
        visible), summary (one short line). Copy only text that is visible; use an empty string when a field is \
        absent. Never guess a number.
        """
        let outcome = await requestJSON(
            runtime: runtime,
            prompt: prompt,
            system: Self.mediaSystem,
            schema: Self.mediaSchema,
            images: [InklingInlineImage(mimeType: loaded.mimeType, base64: loaded.payload.base64EncodedString())],
            at: moment
        )
        guard let value = outcome.value, let extraction = InklingMediaExtraction(json: value) else {
            degradedRuns += 1
            let reason = outcome.failure.isEmpty ? "模型返回缺字段的 JSON / the JSON missed required fields" : outcome.failure
            await audit(
                "media_degraded",
                "\(loaded.name) · sha256 \(loaded.digest.prefix(12)) · \(loaded.bytes)B · \(reason)",
                "failed",
                at: moment
            )
            return InklingMediaAnalysis(
                ok: false,
                file: loaded.displayPath,
                digest: loaded.digest,
                bytes: loaded.bytes,
                mimeType: loaded.mimeType,
                extraction: nil,
                degradedReason: reason,
                attempts: outcome.attempts
            )
        }
        mediaRuns += 1
        lastUsedAt = moment
        await audit(
            "media_ok",
            "\(loaded.name) · sha256 \(loaded.digest.prefix(12)) · \(loaded.bytes)B · \(loaded.mimeType) · \(runtime.runtime.rawValue)",
            "ok",
            at: moment
        )
        return InklingMediaAnalysis(
            ok: true,
            file: loaded.displayPath,
            digest: loaded.digest,
            bytes: loaded.bytes,
            mimeType: loaded.mimeType,
            extraction: extraction,
            degradedReason: "",
            attempts: outcome.attempts
        )
    }

    // MARK: Request pipeline

    private struct InklingInlineImage: Sendable, Equatable {
        var mimeType: String
        var base64: String
    }

    private struct JSONOutcome {
        var value: JSONValue?
        var attempts: Int
        var failure: String
    }

    private func readyRuntime(now: Date) async -> ReadyRuntime? {
        if let cachedProbe,
           now.timeIntervalSince(cachedProbe.at) >= 0,
           now.timeIntervalSince(cachedProbe.at) < Self.probeTTL,
           cachedProbe.state == .ready,
           let runtime = cachedProbe.runtime,
           let endpoint = cachedProbe.endpoint {
            return ReadyRuntime(runtime: runtime, endpoint: endpoint, modelRef: config.model)
        }
        let card = await probe(now: now)
        guard card.state == .ready,
              let runtime = cachedProbe?.runtime,
              let endpoint = cachedProbe?.endpoint else { return nil }
        return ReadyRuntime(runtime: runtime, endpoint: endpoint, modelRef: config.model)
    }

    /// One call, one repair attempt on malformed/shape-wrong JSON, no retry for a
    /// transport failure — an unreachable runtime will not become reachable within
    /// the same tick.
    private func requestJSON(
        runtime: ReadyRuntime,
        prompt: String,
        system: String,
        schema: InklingJSONSchema,
        images: [InklingInlineImage],
        at moment: Date
    ) async -> JSONOutcome {
        var attempts = 0
        var failure = ""
        var outbound = prompt
        while attempts < 2 {
            attempts += 1
            do {
                let text = try await send(
                    runtime: runtime,
                    prompt: outbound,
                    system: system,
                    schema: schema,
                    images: images
                )
                if let raw = Self.decodeJSONText(text) {
                    if let problem = schema.validate(raw) {
                        failure = problem
                    } else {
                        return JSONOutcome(value: raw, attempts: attempts, failure: "")
                    }
                } else {
                    failure = "模型返回非法 JSON / the model did not return valid JSON"
                }
            } catch {
                failure = describe(error)
                return JSONOutcome(value: nil, attempts: attempts, failure: failure)
            }
            if attempts == 1 {
                await audit("json_retry", "attempt 1 rejected · \(failure)", "failed", at: moment)
                outbound = prompt + "\n\nYOUR PREVIOUS ANSWER WAS REJECTED (\(failure)). Return only JSON that matches the schema."
            }
        }
        return JSONOutcome(value: nil, attempts: attempts, failure: failure)
    }

    private func send(
        runtime: ReadyRuntime,
        prompt: String,
        system: String,
        schema: InklingJSONSchema,
        images: [InklingInlineImage]
    ) async throws -> String {
        switch runtime.runtime {
        case .ollama:
            var fields: [String: JSONValue] = [
                "model": .string(runtime.modelRef),
                "prompt": .string(prompt),
                "stream": .bool(false),
                "format": schema.jsonValue,
                "options": .object([
                    "temperature": .double(0.1),
                    "num_ctx": .int(8_192)
                ])
            ]
            if !system.isEmpty { fields["system"] = .string(system) }
            if !images.isEmpty { fields["images"] = .array(images.map { .string($0.base64) }) }
            let body = JSONValue.object(fields).serialized()
            let response = try await transport.send(InklingHTTPRequest(
                method: "POST",
                endpoint: runtime.endpoint,
                path: "/api/generate",
                body: Data(body.utf8),
                timeout: Self.generateTimeout
            ))
            guard response.status == 200 else { throw InklingAdapterError.httpStatus(response.status) }
            guard let document = NodeJSON.decode(JSONValue.self, from: response.body),
                  let text = document.objectValue?["response"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InklingAdapterError.badResponse("本机模型返回空内容 / the local model answered nothing")
            }
            return text
        case .mlx:
            var content: [JSONValue] = [
                .object(["type": .string("text"), "text": .string(prompt)])
            ]
            for image in images {
                content.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(image.mimeType);base64,\(image.base64)")
                    ])
                ]))
            }
            let systemText = system.isEmpty
                ? "Answer with JSON matching this schema: \(schema.jsonValue.serialized())"
                : system + "\nAnswer with JSON matching this schema: \(schema.jsonValue.serialized())"
            let request = JSONValue.object([
                "model": .string(runtime.modelRef),
                "messages": .array([
                    .object(["role": .string("system"), "content": .string(systemText)]),
                    .object(["role": .string("user"), "content": .array(content)])
                ]),
                "temperature": .double(0.1),
                "stream": .bool(false),
                "response_format": .object(["type": .string("json_object")])
            ]).serialized()
            let response = try await transport.send(InklingHTTPRequest(
                method: "POST",
                endpoint: runtime.endpoint,
                path: "/v1/chat/completions",
                body: Data(request.utf8),
                timeout: Self.generateTimeout
            ))
            guard response.status == 200 else { throw InklingAdapterError.httpStatus(response.status) }
            guard let document = NodeJSON.decode(JSONValue.self, from: response.body),
                  let choices = document.objectValue?["choices"]?.arrayValue,
                  let message = choices.first?.objectValue?["message"]?.objectValue else {
                throw InklingAdapterError.badResponse("MLX 返回的内容不可解析 / the MLX answer is not parseable")
            }
            let text: String
            if let direct = message["content"]?.stringValue {
                text = direct
            } else if let parts = message["content"]?.arrayValue {
                text = parts.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
            } else {
                text = ""
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InklingAdapterError.badResponse("本机模型返回空内容 / the local model answered nothing")
            }
            return text
        }
    }

    private func listModels(runtime: InklingRuntime, endpoint: EdgeEndpoint) async throws -> [String] {
        let path = runtime == .ollama ? "/api/tags" : "/v1/models"
        let response = try await transport.send(InklingHTTPRequest(
            method: "GET",
            endpoint: endpoint,
            path: path,
            body: nil,
            timeout: Self.probeTimeout
        ))
        guard response.status == 200 else { throw InklingAdapterError.httpStatus(response.status) }
        guard let document = NodeJSON.decode(JSONValue.self, from: response.body) else {
            throw InklingAdapterError.badResponse("模型清单不可解析 / the model list is not JSON")
        }
        switch runtime {
        case .ollama:
            return (document.objectValue?["models"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["name"]?.stringValue ?? $0.objectValue?["model"]?.stringValue
            }
        case .mlx:
            if let rows = document.objectValue?["data"]?.arrayValue {
                return rows.compactMap { $0.objectValue?["id"]?.stringValue }
            }
            if let rows = document.objectValue?["models"]?.arrayValue {
                return rows.compactMap {
                    $0.stringValue ?? $0.objectValue?["id"]?.stringValue ?? $0.objectValue?["name"]?.stringValue
                }
            }
            return []
        }
    }

    private func candidates() -> (values: [Candidate], refusals: [String]) {
        var values: [Candidate] = []
        var refusals: [String] = []
        for (runtime, text) in [
            (InklingRuntime.ollama, config.ollamaEndpoint),
            (InklingRuntime.mlx, config.mlxEndpoint)
        ] {
            do {
                let endpoint = try EdgeBoundary.resolve(url: text, policy: .loopbackOnly)
                values.append(Candidate(runtime: runtime, endpoint: endpoint))
            } catch {
                refusals.append("\(runtime.rawValue): \(describe(error))")
            }
        }
        return (values, refusals)
    }

    // MARK: Helpers

    /// Compares by base name so `inkling-2-mini:q4_k_m` (a local import) satisfies a
    /// request for `inkling-2-mini`, and a listed `:latest` satisfies either.
    static func referenceMatches(_ listed: String, _ wanted: String) -> Bool {
        let left = listed.lowercased()
        let right = wanted.lowercased()
        if left == right { return true }
        let leftBase = left.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? left
        let rightBase = right.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? right
        return leftBase == rightBase
    }

    static func decodeJSONText(_ text: String) -> JSONValue? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let firstBreak = value.firstIndex(where: { $0 == "\n" }) {
                value = String(value[value.index(after: firstBreak)...])
            }
            if let closing = value.range(of: "```", options: .backwards) {
                value = String(value[..<closing.lowerBound])
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = value.data(using: .utf8),
           let document = NodeJSON.decode(JSONValue.self, from: data),
           document.objectValue != nil || document.arrayValue != nil {
            return document
        }
        if let start = value.firstIndex(of: "{"),
           let end = value.lastIndex(of: "}"),
           start < end,
           let data = String(value[start...end]).data(using: .utf8),
           let document = NodeJSON.decode(JSONValue.self, from: data) {
            return document
        }
        return nil
    }

    private func degraded(_ reason: String, at moment: Date) -> InklingGeneration {
        InklingGeneration(
            value: nil,
            runtime: cachedProbe?.runtime?.rawValue ?? "",
            model: config.model,
            attempts: 0,
            degradedReason: String(AssistantRedaction.scrub(reason).prefix(200))
        )
    }

    private func describe(_ error: Error) -> String {
        let text = String(describing: error)
        return String(AssistantRedaction.scrub(text).prefix(200))
    }

    private func audit(_ event: String, _ detail: String, _ outcome: String, at moment: Date) async {
        guard let store else { return }
        await store.record(channel: "inkling", event: event, detail: detail, outcome: outcome, at: moment)
    }
}

// MARK: - Mail classifier bridge

/// The one thing the assistant asks the local model during triage: a category and
/// two extractions per message. The rules stay as the fallback, so an absent or
/// broken model changes nothing about whether triage runs.
public struct InklingMailClassifier: MailBatchClassifying {
    public static let maximumMessages = 12

    public static let schema = InklingJSONSchema(root: .object(properties: [
        "messages": .array(items: .object(properties: [
            "id": .string(enumValues: []),
            "category": .string(enumValues: MailCategory.allCases.map(\.rawValue)),
            "amount": .string(enumValues: []),
            "deadline": .string(enumValues: [])
        ], required: ["id", "category"], additionalProperties: true))
    ], required: ["messages"], additionalProperties: true))

    public static let system =
        "You classify a private mailbox on the owner's Mac. You answer with JSON only and never add commentary."

    private let adapter: Inkling2MiniAdapter

    public init(adapter: Inkling2MiniAdapter) {
        self.adapter = adapter
    }

    public func classify(_ messages: [MailClassifierMessage]) async -> [String: MailClassificationHint] {
        let trimmed = Array(messages.prefix(Self.maximumMessages))
        guard !trimmed.isEmpty else { return [:] }
        let rows = trimmed.map { message in
            JSONValue.object([
                "id": .string(message.id),
                "subject": .string(String(message.subject.prefix(120))),
                "from": .string(String(message.from.prefix(120))),
                "snippet": .string(String(message.snippet.prefix(160)))
            ])
        }
        let prompt = """
        Classify each mailbox message. Return JSON {"messages":[{"id":"…","category":"needs_reply|bill|invitation|notification","amount":"…","deadline":"YYYY-MM-DD or empty"}]}. \
        Copy the id exactly. Use an empty string for a field the text does not contain.
        MESSAGES:
        \(JSONValue.array(rows).serialized())
        """
        let generation = await adapter.generateStructuredJSON(
            prompt: prompt,
            schema: Self.schema,
            system: Self.system
        )
        guard let document = generation.value?.objectValue,
              let answered = document["messages"]?.arrayValue else { return [:] }
        let known = Set(trimmed.map(\.id))
        var hints: [String: MailClassificationHint] = [:]
        for row in answered {
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue,
                  known.contains(id) else { continue }
            let category = object["category"]?.stringValue.flatMap(MailCategory.init(rawValue:))
            let amount = object["amount"]?.stringValue.map { String($0.prefix(32)) } ?? ""
            let deadline = object["deadline"]?.stringValue.map { String($0.prefix(40)) } ?? ""
            guard category != nil || !amount.isEmpty || !deadline.isEmpty else { continue }
            hints[id] = MailClassificationHint(
                category: category,
                amount: amount.isEmpty ? nil : amount,
                deadline: deadline.isEmpty ? nil : deadline
            )
        }
        return hints
    }
}
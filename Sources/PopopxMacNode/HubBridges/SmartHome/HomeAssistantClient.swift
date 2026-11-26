//
//  HomeAssistantClient.swift
//  PopopxMacNode — the Home Assistant REST surface the bridge uses.
//
//  Two endpoints, both of them Home Assistant's documented ones: `GET /api/states` to read,
//  `POST /api/services/<domain>/<service>` to act. Nothing else on that server is reachable
//  from this node — no websocket, no `/api/template` (which is a code-execution endpoint
//  wearing a hat), no `/api/config`.
//
//  The parsing and request-building are static functions taking `Data`/returning `URLRequest`
//  so the contract tests can exercise them without a server. The one behaviour that cannot be
//  tested that way — refusing a redirect — lives in `HubHTTP.session`, and is commented there.
//
//  Attributes are the interesting risk. An `entity_id` and a `state` are short tokens, but
//  `attributes` is a free-form dictionary the *server* chooses: a calendar integration puts
//  event summaries in it, a media player puts a track name, a custom component can put
//  anything. So `sanitize` bounds it hard — depth, key count, string length, total bytes — and
//  the bridge only ever shows entities the owner whitelisted anyway.
//

import Foundation

// MARK: - Model

public struct HAEntityState: Sendable, Codable, Equatable {
    public var entityID: String
    public var state: String
    public var friendlyName: String
    public var domain: String
    /// Bounded, server-supplied metadata. See the file header.
    public var attributes: [String: JSONValue]
    public var lastUpdated: String

    public init(
        entityID: String,
        state: String = "",
        friendlyName: String = "",
        domain: String = "",
        attributes: [String: JSONValue] = [:],
        lastUpdated: String = ""
    ) {
        self.entityID = entityID
        self.state = state
        self.friendlyName = friendlyName
        self.domain = domain
        self.attributes = attributes
        self.lastUpdated = lastUpdated
    }

    /// The value the state card shows: the owner's own name for the entity when the server
    /// supplied one, otherwise the id.
    public var display: String { friendlyName.isEmpty ? entityID : friendlyName }

    // MARK: Bounding

    public static let maximumAttributeKeys = 12
    public static let maximumStringCharacters = 80
    public static let maximumDepth = 2

    /// Keeps the small scalars a status card needs and drops the rest, by rule rather than
    /// by key-name guessing — a whitelist of attribute names would break the day somebody
    /// installs a sensor whose useful field has a name nobody predicted.
    static func sanitize(_ attributes: [String: JSONValue], depth: Int = 0) -> [String: JSONValue] {
        guard depth < maximumDepth else { return [:] }
        var kept: [String: JSONValue] = [:]
        for (key, value) in attributes.prefix(maximumAttributeKeys) {
            switch value {
            case .string(let text):
                if text.count <= maximumStringCharacters { kept[key] = .string(text) }
            case .int, .double, .bool, .null:
                kept[key] = value
            case .object(let nested):
                let inner = sanitize(nested, depth: depth + 1)
                if !inner.isEmpty { kept[key] = .object(inner) }
            case .array(let items):
                // Only a flat array of scalars survives; a list of objects is where the
                // interesting free text of an integration lives.
                let scalars = items.prefix(8).filter {
                    if case .string = $0 { return true }
                    if case .int = $0 { return true }
                    if case .double = $0 { return true }
                    if case .bool = $0 { return true }
                    return false
                }
                if !scalars.isEmpty { kept[key] = .array(Array(scalars)) }
            }
        }
        return kept
    }
}

// MARK: - Errors

public enum HomeAssistantError: Error, Equatable, CustomStringConvertible {
    case missingToken
    case unreachable(String)
    case status(Int)
    case rejectedCredential
    case unexpectedBody
    case responseTooLarge
    case invalidEntity(String)

    public var description: String {
        switch self {
        case .missingToken:
            return "未找到长期访问令牌 / no Long-Lived Access Token in the Keychain"
        case let .unreachable(reason):
            return "无法连接 Home Assistant / unreachable: \(reason)"
        case let .status(code):
            return "Home Assistant 返回 \(code) / HTTP \(code)"
        case .rejectedCredential:
            return "令牌被拒绝 / the token was refused (401/403)"
        case .unexpectedBody:
            return "响应格式不符 / unexpected response body"
        case .responseTooLarge:
            return "响应过大 / response exceeded the ceiling"
        case let .invalidEntity(entity):
            return "实体标识不合法 / invalid entity id: \(entity)"
        }
    }
}

// MARK: - Client

public struct HomeAssistantClient: Sendable {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumEntities = 512

    public let endpoint: EdgeEndpoint
    public let timeout: TimeInterval
    private let token: String
    private let session: URLSession

    /// `token` must come from `HubSecretStoring` — this type never reads the Keychain, so a
    /// caller cannot accidentally hand it a value that came from a settings document.
    public init(
        endpoint: EdgeEndpoint,
        token: String,
        timeout: TimeInterval = 8,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.timeout = timeout
        self.session = session ?? HubHTTP.session(timeout: timeout)
    }

    // MARK: Requests (pure)

    static func statesRequest(endpoint: EdgeEndpoint, token: String) throws -> URLRequest {
        let url = endpoint.origin + "/api/states"
        guard EdgeBoundary.isAllowed(url, policy: .privateNetworkOnly), let target = URL(string: url) else {
            throw HomeAssistantError.invalidEntity(endpoint.host)
        }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func serviceRequest(
        endpoint: EdgeEndpoint,
        token: String,
        domain: String,
        service: String,
        data: [String: JSONValue]
    ) throws -> URLRequest {
        guard let safeDomain = HubHTTP.segment(domain, maximumLength: 40),
              let safeService = HubHTTP.segment(service, maximumLength: 40)
        else { throw HomeAssistantError.invalidEntity("\(domain)/\(service)") }
        let url = endpoint.origin + "/api/services/\(safeDomain)/\(safeService)"
        guard EdgeBoundary.isAllowed(url, policy: .privateNetworkOnly), let target = URL(string: url) else {
            throw HomeAssistantError.invalidEntity(safeDomain)
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = NodeJSON.encodePretty(["data": JSONValue.object(data)])
        return request
    }

    // MARK: Reading

    /// All entities the server reports. Callers filter; this type does not know the
    /// whitelist, and keeping the two apart is what lets a test prove that an entity the
    /// owner never exposed cannot reach a card.
    public func states() async throws -> [HAEntityState] {
        guard !token.isEmpty else { throw HomeAssistantError.missingToken }
        let request = try Self.statesRequest(endpoint: endpoint, token: token)
        let data = try await perform(request)
        return Self.parseStates(data)
    }

    static func parseStates(_ data: Data) -> [HAEntityState] {
        guard let value = NodeJSON.decode(JSONValue.self, from: data) else { return [] }
        return (value.arrayValue ?? []).compactMap { item in
            guard case let .object(fields) = item,
                  let entityID = fields["entity_id"]?.stringValue, !entityID.isEmpty else { return nil }
            let attributes = (fields["attributes"]?.objectValue ?? [:])
            let friendly = String((attributes["friendly_name"]?.stringValue ?? "").prefix(80))
            return HAEntityState(
                entityID: entityID,
                state: Self.stateText(fields["state"]),
                friendlyName: friendly,
                domain: entityID.split(separator: ".").first.map(String.init) ?? "",
                attributes: HAEntityState.sanitize(attributes),
                lastUpdated: String((fields["last_updated"]?.stringValue ?? "").prefix(40))
            )
        }
        .prefix(Self.maximumEntities)
        .map { $0 }
    }

    static func stateText(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): return String(text.prefix(80))
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "on" : "off"
        default: return ""
        }
    }

    // MARK: Acting

    /// Calls a service. **The caller is the proposal executor**: reaching this method from a
    /// request path is the bug this whole file is arranged to prevent.
    @discardableResult
    public func callService(domain: String, service: String, data: [String: JSONValue]) async throws -> String {
        guard !token.isEmpty else { throw HomeAssistantError.missingToken }
        let request = try Self.serviceRequest(
            endpoint: endpoint, token: token, domain: domain, service: service, data: data
        )
        let body = try await perform(request)
        // Home Assistant answers a service call with the list of entities it changed. The
        // bridge reports how many, not what: an entity list is not sensitive, but the
        // attributes inside it are, and the count is all an owner needs to see.
        if let value = NodeJSON.decode(JSONValue.self, from: body), case .array(let changed) = value {
            return "已更新 \(changed.count) 个实体 / \(changed.count) entities updated"
        }
        return "已执行 / service called"
    }

    // MARK: Transport

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HomeAssistantError.unreachable(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw HomeAssistantError.unexpectedBody
        }
        switch http.statusCode {
        case 401, 403: throw HomeAssistantError.rejectedCredential
        case 404: throw HomeAssistantError.status(404)
        case 200..<300: break
        default: throw HomeAssistantError.status(http.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else { throw HomeAssistantError.responseTooLarge }
        return data
    }
}

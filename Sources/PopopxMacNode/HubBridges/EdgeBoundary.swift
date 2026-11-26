//
//  EdgeBoundary.swift
//  PopopxMacNode — the address allow-list every outbound hub bridge must pass.
//
//  This file is the reason the v1.1 bridges are still "zero cloud dependency"
//  after an MQTT client, a Home Assistant caller and a CalDAV agent are added to
//  the node: none of them opens a socket on its own. Each one asks this guard for
//  a permission decision first and refuses to connect without it.
//
//  Two rules decide the whole design:
//
//  * **The allow-list is positive, not negative.** A host is admitted because it
//    *is* loopback or *is* inside a private range, never because it failed to
//    look public. Anything the classifier cannot place is denied.
//  * **The decision is made on the literal the operator typed, and no name is
//    resolved in order to reach it.** Resolving `homeassistant.example.com` to
//    find out whether it is public would first connect to a resolver that can lie
//    — and a record that answers 127.0.0.1 on the second look is the classic SSRF
//    rebinding trick. So a bare hostname is only ever admitted under `.local`,
//    which mDNS answers on the link, and every other name is refused outright.
//

import Foundation

// MARK: - Policy

/// How far from this Mac a bridge may reach.
public enum EdgeHostPolicy: String, Codable, Sendable, CaseIterable {
    /// Loopback only. The MCP bridge uses it: a `stdio` child process *is* this
    /// machine, and an SSE/HTTP server has to answer on `127.0.0.1`.
    case loopbackOnly
    /// Loopback plus the private ranges a home network actually lives in.
    /// Used by Home Assistant, MQTT and CalDAV.
    case privateNetworkOnly
}

/// What the guard found a host to be.
public enum EdgeHostClass: String, Sendable, Equatable {
    case loopback
    case privateNetwork
    case linkLocal
    case publicAddress
    case unresolvedName
    case ambiguous
}

// MARK: - Errors

/// Why a target was refused. Every case names the value that was rejected,
/// because the audit log has to be able to say what the node did *not* do.
public enum EdgeBoundaryError: Error, Equatable, CustomStringConvertible {
    case missingHost
    case unsupportedScheme(String)
    case credentialsInURL
    case nonCanonicalHost(String)
    case hostOutsideMdns(String)
    case publicAddress(host: String)
    case loopbackOnly(host: String, classification: EdgeHostClass)
    case portOutOfRange(Int)
    case defaultPortUnknown(String)

    public var description: String {
        switch self {
        case .missingHost:
            return "缺少主机名 / no host in target"
        case let .unsupportedScheme(scheme):
            return "协议不受支持（仅 http/https）/ unsupported scheme: \(scheme)"
        case .credentialsInURL:
            return "URL 内不得携带凭据 / credentials do not belong in a URL"
        case let .nonCanonicalHost(host):
            return "地址写法无法判定，按公网拦截 / ambiguous address, denied as public: \(host)"
        case let .hostOutsideMdns(host):
            return "仅允许 .local 名称，不解析外部域名 / only .local names are admitted without resolution: \(host)"
        case let .publicAddress(host):
            return "目标为公网地址，已拦截 / public address blocked: \(host)"
        case let .loopbackOnly(host, classification):
            return "该桥接仅允许本机回环 / this bridge is loopback-only: \(host) (\(classification.rawValue))"
        case let .portOutOfRange(port):
            return "端口越界 / port out of range: \(port)"
        case let .defaultPortUnknown(scheme):
            return "未给出端口 / no port given for \(scheme)"
        }
    }
}

// MARK: - Endpoint

/// A target that has already been admitted, with the decision recorded beside it.
/// Bridges carry this value instead of a `URL` so that nothing downstream can
/// quietly swap the host after the check.
public struct EdgeEndpoint: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let hostClass: EdgeHostClass
    /// The host exactly as the operator wrote it, kept for the audit row.
    public let literal: String

    public init(scheme: String, host: String, port: Int, hostClass: EdgeHostClass, literal: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.hostClass = hostClass
        self.literal = literal
    }

    /// Bracketed form, for use inside a URL or a `Host:` header.
    public var hostHeader: String { host.contains(":") ? "[\(host)]" : host }

    public var origin: String { "\(scheme)://\(hostHeader):\(port)" }

    /// Absolute URL for an already-validated path. Callers hand over a path
    /// component, never a whole URL, so the host cannot be re-introduced here.
    public func url(path: String = "/", query: String = "") -> URL? {
        var text = origin
        text += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { text += "?" + query }
        return URL(string: text)
    }
}

// MARK: - Guard

public enum EdgeBoundary {
    public static let mdnsSuffix = ".local"
    private static let httpPorts: [String: Int] = ["http": 80, "https": 443]

    /// Admits a URL string, or throws the reason it refused.
    public static func resolve(url text: String, policy: EdgeHostPolicy) throws -> EdgeEndpoint {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EdgeBoundaryError.missingHost }
        // Require the "://" by hand: `URLComponents("127.0.0.1:1883")` parses that
        // as scheme "127.0.0.1" on some Foundation builds, which would make every
        // check below run against the wrong field.
        guard trimmed.contains("://") else {
            throw EdgeBoundaryError.unsupportedScheme(String(trimmed.prefix(16)))
        }
        guard let components = URLComponents(string: trimmed), let rawScheme = components.scheme?.lowercased() else {
            throw EdgeBoundaryError.nonCanonicalHost(trimmed)
        }
        guard rawScheme == "http" || rawScheme == "https" else {
            throw EdgeBoundaryError.unsupportedScheme(rawScheme)
        }
        // `http://127.0.0.1@relay.example.com/` connects to relay.example.com.
        // Admitting userinfo at all would make the address check decorative, and
        // a token belongs in a header anyway.
        if components.user != nil || components.password != nil {
            throw EdgeBoundaryError.credentialsInURL
        }
        guard let rawHost = host(of: components), !rawHost.isEmpty else {
            throw EdgeBoundaryError.missingHost
        }
        let hostClass = try classify(rawHost, policy: policy)
        let port = try validatedPort(components.port, scheme: rawScheme)
        try admit(hostClass, literal: rawHost, policy: policy)
        return EdgeEndpoint(
            scheme: rawScheme,
            host: normaliseHost(rawHost),
            port: port,
            hostClass: hostClass,
            literal: rawHost
        )
    }

    /// Admits a bare host and port. An MQTT broker is configured that way, not as
    /// a URL, and it is the same decision with the same teeth.
    public static func resolve(host rawHost: String, port: Int) throws -> EdgeEndpoint {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EdgeBoundaryError.missingHost }
        let hostClass = try classify(trimmed, policy: .privateNetworkOnly)
        let validated = try validatedPort(port, scheme: "tcp")
        try admit(hostClass, literal: trimmed, policy: .privateNetworkOnly)
        return EdgeEndpoint(
            scheme: "tcp",
            host: normaliseHost(trimmed),
            port: validated,
            hostClass: hostClass,
            literal: trimmed
        )
    }

    /// Whether a value already sitting in a settings document is still admissible
    /// — used when a saved config is loaded, so an edit made outside the app
    /// cannot smuggle a public host in past the console.
    public static func isAllowed(_ text: String, policy: EdgeHostPolicy) -> Bool {
        (try? resolve(url: text, policy: policy)) != nil
    }

    // MARK: Classification

    /// Pure classification, with no policy and no port: this is the table the
    /// tests pin, and the one the rest of the guard is built on.
    public static func classification(of rawHost: String) -> EdgeHostClass {
        let host = normaliseHost(rawHost)
        guard !host.isEmpty else { return .ambiguous }
        if host == "localhost" { return .loopback }
        if host.hasSuffix(mdnsSuffix) { return .privateNetwork }
        if host.contains(":") { return classifyIPv6(host) }
        if let octets = ipv4Octets(host) { return classifyIPv4(octets) }
        // A single label with no dot (`nas`, `printer`) would need DNS or NetBIOS
        // to place, so it is exactly the case the guard refuses to guess about.
        return .unresolvedName
    }

    static func classify(_ rawHost: String, policy: EdgeHostPolicy) throws -> EdgeHostClass {
        let host = normaliseHost(rawHost)
        guard !host.isEmpty else { throw EdgeBoundaryError.missingHost }
        let found = classification(of: host)
        if found == .ambiguous { throw EdgeBoundaryError.nonCanonicalHost(rawHost) }
        return found
    }

    static func admit(_ hostClass: EdgeHostClass, literal: String, policy: EdgeHostPolicy) throws {
        switch policy {
        case .loopbackOnly:
            guard hostClass == .loopback else {
                throw EdgeBoundaryError.loopbackOnly(host: literal, classification: hostClass)
            }
        case .privateNetworkOnly:
            switch hostClass {
            case .loopback, .privateNetwork: break
            case .publicAddress: throw EdgeBoundaryError.publicAddress(host: literal)
            case .unresolvedName: throw EdgeBoundaryError.hostOutsideMdns(literal)
            case .linkLocal, .ambiguous: throw EdgeBoundaryError.nonCanonicalHost(literal)
            }
        }
    }

    static func classifyIPv4(_ octets: [Int]) -> EdgeHostClass {
        guard octets.count == 4 else { return .ambiguous }
        let (a, b) = (octets[0], octets[1])
        switch a {
        case 127: return .loopback                                  // 127.0.0.0/8
        case 10: return .privateNetwork                              // 10.0.0.0/8
        case 172 where (16...31).contains(b): return .privateNetwork // 172.16.0.0/12
        case 192 where b == 168: return .privateNetwork              // 192.168.0.0/16
        case 169 where b == 254: return .linkLocal                   // 169.254.0.0/16
        case 0: return .ambiguous             // "0.x" is not a destination; it is
                                              // a way of writing *something else*
        default: return .publicAddress
        }
    }

    static func classifyIPv6(_ host: String) -> EdgeHostClass {
        // Down to the 16 bytes is the only way to read a compressed form: `::1`,
        // `::ffff:8.8.8.8` and `fd12::` all hide their class behind the `::`, and
        // a prefix test on the text gets all three wrong.
        guard let bytes = ipv6Bytes(host) else { return .ambiguous }
        if bytes == loopbackV6 { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .ambiguous }
        if bytes[0] & 0xfe == 0xfc { return .privateNetwork }                    // fc00::/7 ULA
        if bytes[0] == 0xff { return .linkLocal }                                // ff00::/8 multicast
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .linkLocal }       // fe80::/10
        if isIPv4Mapped(bytes) {
            // The v4 class is the answer, not "it is v6, therefore it is fine".
            return classifyIPv4(bytes[12...].map(Int.init))
        }
        if bytes[0...11].allSatisfy({ $0 == 0 }) { return .ambiguous }
        return .publicAddress
    }

    private static let loopbackV6: [UInt8] = [UInt8](repeating: 0, count: 15) + [1]

    private static func isIPv4Mapped(_ bytes: [UInt8]) -> Bool {
        bytes[0...9].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    }

    /// A full IPv6 literal, including `::` compression and a trailing dotted quad, as
    /// 16 bytes. `nil` for anything that is not exactly that.
    ///
    /// ULA (`fc00::/7`) is the v6 sibling of RFC 1918 and is admitted by the caller;
    /// link-local is not, because it is also what a captive portal or a rogue device on
    /// the wire answers from.
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var body = text.lowercased()
        if body.hasPrefix("["), body.hasSuffix("]") { body = String(body.dropFirst().dropLast()) }
        // A zone id (`fe80::1%en0`) names an interface, and the same address on another
        // interface is another network — not a decision to make from a string.
        guard !body.contains("%") else { return nil }
        let halves = body.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        guard let head = groupList(halves[0]),
              let tail = groupList(halves.count > 1 ? halves[1] : "") else { return nil }
        if halves.count == 2 {
            // `::` stands for at least one zero group, so the halves must leave room.
            guard head.count + tail.count <= 7 else { return nil }
            return expand(head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail)
        }
        guard head.count + tail.count == 8 else { return nil }
        return expand(head + tail)
    }

    /// 16-bit groups, with a trailing `1.2.3.4` translated into its two groups.
    static func groupList(_ text: String) -> [UInt16]? {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        if let last = parts.last, last.contains(".") {
            guard let octets = ipv4Octets(last) else { return nil }
            parts.removeLast()
            parts.append(String(format: "%x", (octets[0] << 8) | octets[1]))
            parts.append(String(format: "%x", (octets[2] << 8) | octets[3]))
        }
        var out: [UInt16] = []
        out.reserveCapacity(8)
        for part in parts {
            guard !part.isEmpty, part.count <= 4, part.allSatisfy(\.isHexDigit),
                  let value = UInt16(part, radix: 16) else { return nil }
            out.append(value)
        }
        return out
    }

    private static func expand(_ groups: [UInt16]) -> [UInt8]? {
        guard groups.count == 8 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for group in groups {
            out.append(UInt8(group >> 8))
            out.append(UInt8(group & 0xff))
        }
        return out
    }

    // MARK: Parsing helpers

    static func host(of components: URLComponents) -> String? {
        components.host.flatMap { $0.isEmpty ? nil : $0 }
            ?? components.percentEncodedHost
    }

    static func normaliseHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // A trailing dot is the FQDN spelling of the same name. Strip it, or
        // `"evil.com."` becomes a way past the `.local` suffix test.
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        return host
    }

    /// Exactly four decimal octets, none with a leading zero.
    ///
    /// The leading-zero ban is load-bearing: `inet_aton` reads `010.0.0.1` as
    /// octal 8 — a public address that *looks* private — and accepts `0x7f.1` or
    /// the two-part `127.1` as loopback. Anything this function cannot read
    /// unambiguously is something the node will not connect to.
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3 else { return nil }
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1, part.first == "0" { return nil }
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func validatedPort(_ candidate: Int?, scheme: String) throws -> Int {
        guard let candidate else {
            if let known = httpPorts[scheme] { return known }
            throw EdgeBoundaryError.defaultPortUnknown(scheme)
        }
        guard (1...65_535).contains(candidate) else { throw EdgeBoundaryError.portOutOfRange(candidate) }
        return candidate
    }
}

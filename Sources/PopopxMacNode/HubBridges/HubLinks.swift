//
//  HubLinks.swift
//  PopopxMacNode — the two seams every hub bridge is built on.
//
//  The protocol logic in this directory (JSON-RPC framing, the MQTT codec, the CalDAV
//  query) is pure, and the I/O is confined to these two protocols. That split exists for
//  one reason: the unit tests for the gate — 公网 IP 必拒, the write-tool confirmation
//  queue, the `exposedEntities` allow-list, the iCalendar redaction — must be able to
//  drive a whole conversation without opening a socket, spawning a process, unlocking a
//  Keychain, or touching `~/Library/Application Support/PopopxMacNode`. A fake conforming
//  to one of these protocols does all of it in memory.
//
//  Both are deliberately *byte*- or *line*-oriented rather than "call the API": the
//  bridges own their framing, so a truncated frame is a codec decision the tested code
//  makes, not something hidden inside a transport.
//

import Foundation

// MARK: - Errors

public enum HubLinkError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case alreadyConnected
    case connectFailed(String)
    case writeFailed(String)
    case readFailed(String)
    /// The peer went silent while a reply was owed. Carries the deadline so the audit row
    /// can distinguish "the broker is down" from "the broker is slow".
    case timedOut(TimeInterval)
    case peerClosed
    case invalidTarget(String)

    public var description: String {
        switch self {
        case .notConnected: return "未连接 / link not connected"
        case .alreadyConnected: return "已在连接中 / link already started"
        case let .connectFailed(reason): return "连接失败 / connect failed: \(reason)"
        case let .writeFailed(reason): return "写入失败 / write failed: \(reason)"
        case let .readFailed(reason): return "读取失败 / read failed: \(reason)"
        case let .timedOut(after): return "等待超时 / timed out after \(Int(after))s"
        case .peerClosed: return "对端已关闭 / peer closed the connection"
        case let .invalidTarget(target): return "目标不合法 / invalid target: \(target)"
        }
    }
}

// MARK: - Byte stream

/// A duplex, ordered, unframed byte channel. `MQTTHubLink` is the real one; a
/// `NWConnection` sits behind it.
public protocol HubByteStream: Sendable {
    var endpoint: EdgeEndpoint { get }
    /// Establishes the channel. Must not be called twice.
    func start(timeout: TimeInterval) async throws
    /// The next chunk the peer sent, or `nil` once it has closed. Chunks are not
    /// necessarily whole packets — the caller buffers and decodes.
    func receiveChunk(timeout: TimeInterval) async throws -> Data?
    func send(_ data: Data) async throws
    func finish() async
}

// MARK: - Line channel

/// A duplex, newline-delimited message channel. `stdio` (a child process's stdin/stdout)
/// and streamable HTTP both present as this once their framing is peeled off.
public protocol MCPLink: Sendable {
    var serverID: String { get }
    func start(timeout: TimeInterval) async throws
    /// Writes one JSON-RPC document, adding the newline the framing requires.
    func writeLine(_ line: String) async throws
    /// Reads the next complete line, or `nil` when the peer closed the stream.
    func readLine(timeout: TimeInterval) async throws -> String?
    func finish() async
}

// MARK: - Shared HTTP shape

/// The URLSession every hub bridge is built from, plus the one path rule they share.
///
/// The three HTTP bridges (MCP, Home Assistant, CalDAV) must not each re-decide what a safe
/// session looks like, so the decision lives here: ephemeral, uncached, cookieless, and
/// **incapable of following a redirect**. Redirect refusal is load-bearing rather than
/// tidy — an allow-listed host on the LAN that answers `302` at a public address is the
/// cheapest way to make this node a proxy for somebody else's server, and the address check
/// has already run by then.
public enum HubHTTP {
    public static func session(timeout: TimeInterval, delegate: URLSessionTaskDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = nil
        return URLSession(
            configuration: configuration,
            delegate: delegate ?? HubNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// A path segment taken from a device id, a service name, or a calendar path.
    ///
    /// Nothing from a settings document may be interpolated into a URL unexamined: `..` and
    /// a `%2F` both turn `/api/states/<entity>` into a request for something else on a
    /// server the owner did not name. The accepted alphabet is the one Home Assistant's
    /// `entity_id` grammar and a DAV href actually use, and a dot-pair is rejected inside it.
    public static func segment(_ text: String, maximumLength: Int = 128) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.contains("..") else { return nil }
        guard let first = trimmed.first, first.isLetter || first.isNumber else { return nil }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "/" }
            ? trimmed
            : nil
    }
}

/// Handing URLSession `nil` from this method is how a redirect is refused instead of
/// followed: the task fails rather than quietly contacting another host.
///
/// The parameter labels are the entire mechanism. The older spelling
/// (`willPerformHTTPRedemption:`) matches no requirement, so the delegate silently does
/// nothing and the default — follow the redirect — stays in force. That is a warning, not an
/// error, and this node builds warning-free on purpose.
public final class HubNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

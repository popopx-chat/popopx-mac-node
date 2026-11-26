//
//  CalDavClient.swift
//  PopopxMacNode — task 4: reading a calendar on the owner's own LAN for busy time.
//
//  The owner's calendar may live on Nextcloud, Radicale or Baïkal instead of on this Mac.
//  This file is the only place in the node that puts a credential on a LAN socket, and the
//  only place that ingests a document it did not write. The reduction to intervals lives in
//  `ICalendarFreeBusy.swift` and is not repeated here — this client's job is to not undo it,
//  which gives five invariants, each of which is a refusal rather than a preference:
//
//  * **A URL is never received, only built.** Every request goes through
//    `EdgeEndpoint.url(path:)`, whose scheme, host and port come from the value that already
//    passed `privateNetworkOnly`. A `href` in a server's answer is reduced to a path and
//    re-anchored (`CalDavPath`), so a returned host never chooses where the node connects
//    next — that is the SSRF rebinding this feature would otherwise ship.
//  * **No redirect is ever followed**, and a 3xx therefore arrives as an `httpStatus` error.
//    An allow-listed `192.168.1.20` answering `302 → 203.0.113.9` is the one response shape
//    that turns "internal host" into a public connection carrying this node's credentials.
//    Same refusal `MCPLinks.swift` makes for loopback MCP.
//  * **Credentials do not travel in clear text.** Plain `http` is refused unless the host is
//    loopback. A self-hosted server with a self-signed certificate must have that
//    certificate trusted by the system: TLS validation is never relaxed here, because a
//    Basic password over an unverified LAN link is the same password sent in the clear.
//  * **Nothing a response says about itself is quoted back.** No case of `CalDavError` and
//    no `HubLinkError` produced here carries a URL, a username, a password, an `href` or
//    document content — these strings reach the console and an audit row.
//  * **Every allocation is bounded while it happens**: the transport stops reading at
//    `CalDav.maximumResponseBytes` instead of checking afterwards, and the parser caps
//    responses, calendars, `calendar-data` blocks, per-block bytes and name lengths.
//    An attacker-controlled server on the owner's network must not be able to make the node
//    allocate freely.
//
//  Like the MQTT codec and the MCP protocol, the wire logic is pure and the I/O sits behind
//  one seam (`CalDavTransport`), so the gate tests can drive a whole PROPFIND/calendar-query
//  conversation without opening a socket.
//

import Foundation

// MARK: - Wire constants and bounds

/// Namespace URIs, method names, and the numbers a response is not allowed to exceed.
public enum CalDav {
    public static let methodPropfind = "PROPFIND"
    public static let methodReport = "REPORT"

    public static let namespaceDAV = "DAV:"
    public static let namespaceCalendar = "urn:ietf:params:xml:ns:caldav"
    /// Apple's calendar namespace. Nextcloud and Baïkal (both Sabre) and Radicale answer
    /// `getctag` and `calendar-description` from it, which is why it is asked for.
    public static let namespaceCalendarServer = "http://apple.com/ns/ical/"

    /// Two megabytes is more than a season of a household's events, and it is the ceiling
    /// the transport enforces *during* the read.
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let minimumResponseBytes = 64 * 1024
    public static let maximumResponses = 128
    public static let maximumCalendars = 32
    public static let maximumCalendarDataBlocks = 64
    public static let maximumCalendarDataBytes = 256 * 1024
    /// A collection's name is display text. Truncating it costs nothing and keeps an
    /// `href`-shaped or megabyte-long `displayname` out of a console cell.
    public static let maximumDisplayNameCharacters = 64
    public static let maximumDescriptionCharacters = 160
    public static let maximumPathCharacters = 512
    public static let maximumPathSegments = 32
    public static let maximumTextCharacters = 4_096
    /// How many collections get a probe `REPORT` when they did not advertise
    /// `supported-report-set`. Bounded, because a discovery walk is the one place a slow
    /// server is paid per answer.
    public static let maximumReportProbes = 8
    /// The same ceiling the EventKit probe enforces, so a typo'd window costs a refusal here
    /// too rather than a 92-day `calendar-query` against somebody's Raspberry Pi.
    public static let maximumWindowDays = CalendarProbe.maximumWindowDays

    /// `PROPFIND` Depth 1: this collection and its children, which is where the calendars
    /// live on all three targets. Depth infinity would let a server return its whole tree.
    public static let depthCollection = "1"

    /// The request body is assembled from constants plus stamps this enum formats itself.
    /// No path, name or other outside text is ever interpolated into it.
    public static func propfindBody() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>\
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" \
        xmlns:i="http://apple.com/ns/ical/">\
        <d:prop><d:resourcetype/><d:displayname/><d:current-user-principal/>\
        <c:calendar-home-set/><d:supported-report-set/><i:calendar-description/></d:prop>\
        </d:propfind>
        """
    }

    /// A `calendar-query` for `window`, with the time range in UTC basic format.
    ///
    /// The filter is a bandwidth optimisation only: `ICalendarParse.busy(in:window:)` clips
    /// to the same window again, so a server that ignores `time-range` cannot widen the
    /// answer. Recurrence is expanded on this side rather than with a server-side `<expand>`
    /// because that element is an ownCloud/Nextcloud extension and the answer must not depend
    /// on whether the host implements it. `VEVENT` is the only component filtered because it
    /// is the only one every target server's grammar accepts; a `VFREEBUSY` block that arrives
    /// anyway is still read by the parser.
    public static func calendarQueryBody(window: DateInterval, requestingCTag: Bool) -> String {
        let start = ICalendar.utcStamp(window.start)
        let end = ICalendar.utcStamp(window.end)
        let properties = requestingCTag
            ? "<i:getctag/><d:getetag/><c:calendar-data/>"
            : "<d:getetag/><c:calendar-data/>"
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" \
        xmlns:i="http://apple.com/ns/ical/">\
        <d:prop>\(properties)</d:prop>\
        <d:filter><c:comp-filter name="VCALENDAR">\
        <c:comp-filter name="VEVENT">\
        <c:time-range start="\(start)" end="\(end)"/>\
        </c:comp-filter></c:comp-filter></d:filter>\
        </c:calendar-query>
        """
    }
}

// MARK: - Errors

/// The server answered, and the answer was wrong.
///
/// Argument problems are `HubLinkError.invalidTarget` and a socket that never opened is
/// `HubLinkError.connectFailed`/`timedOut`, so this enum stays small and means one thing:
/// an exchange completed. No case carries a URL, a credential or document text, and the
/// payload of each one is either a number or a string this node produced or capped.
public enum CalDavError: Error, Equatable, CustomStringConvertible {
    /// Plain `http` to a host that is not loopback: refused before a byte is sent.
    case insecureTransport(String)
    /// Carries a *field name* ("username", "password"), never a value.
    case unusableCredential(String)
    case httpStatus(Int)
    case unexpectedContentType(String)
    case malformedDocument(String)
    case responseTooLarge(Int)
    case tooManyResults(Int)
    /// The collection answered successfully and returned no `calendar-data` at all. Kept
    /// distinct from "no busy intervals", which is a real answer: this one means the path
    /// or the server is not what the owner thinks it is.
    case emptyCalendar

    public var description: String {
        switch self {
        case let .insecureTransport(hostClass):
            return "凭据不走明文 / credentials will not cross \(hostClass) over plain http"
        case let .unusableCredential(field):
            return "凭据格式不受支持 / credential cannot be sent with Basic: \(field)"
        case let .httpStatus(code):
            return "服务器返回 HTTP \(code) / server answered HTTP \(code)"
        case let .unexpectedContentType(type):
            return "响应不是 XML / expected an XML multistatus, got: \(type)"
        case let .malformedDocument(reason):
            return "multistatus 无法解析 / malformed multistatus: \(reason)"
        case let .responseTooLarge(ceiling):
            return "响应超过上限 / response exceeds \(ceiling) bytes"
        case let .tooManyResults(count):
            return "返回条目过多 / too many results: \(count)"
        case .emptyCalendar:
            return "集合未返回日历数据 / the collection returned no calendar data"
        }
    }
}

// MARK: - Transport seam

/// One request, as the client decided to send it.
///
/// `url` is a `URL` and not a string because the only producer that matters builds it
/// through `EdgeEndpoint.url(path:)`. A fake that sets a different URL is testing its own
/// fixture, not this node.
public struct CalDavRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One answer: status, headers, and the body the transport agreed to hold.
public struct CalDavResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    /// Field names are lowercased on the way in, so `header(_:)` is a dictionary lookup and
    /// a test fixture does not have to know that HTTP names are case-insensitive by spec.
    /// Two names differing only in case collapse into one entry rather than trapping.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        var lowered: [String: String] = [:]
        lowered.reserveCapacity(headers.count)
        for (name, value) in headers { lowered[name.lowercased()] = value }
        self.statusCode = statusCode
        self.headers = lowered
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The whole I/O surface of this bridge. A fake conforming to it can drive a complete
/// CalDAV conversation — including a 2 MB body, a 302, or a multistatus full of `href`
/// traps — without a socket.
public protocol CalDavTransport: Sendable {
    func perform(_ request: CalDavRequest) async throws -> CalDavResponse
}

// MARK: - URLSession transport

/// The real transport: an ephemeral session with no cache, no cookies, no credential
/// storage, no redirect, and a byte ceiling enforced while the body is being read.
///
/// `urlCredentialStorage` is switched off so that a `401` cannot be answered from a
/// password some other bridge saved to the same process. `waitsForConnectivity` is off
/// because a calendar probe runs on the console's poll, where "the LAN is asleep" must be a
/// fast no rather than a stall.
public struct URLSessionCalDavTransport: CalDavTransport, @unchecked Sendable {
    private let session: URLSession
    private let reader: CalDavReadDelegate
    private let timeout: TimeInterval
    public let maximumResponseBytes: Int

    public init(timeout: TimeInterval = 10, maximumResponseBytes: Int = CalDav.maximumResponseBytes) {
        let ceiling = max(CalDav.minimumResponseBytes, maximumResponseBytes)
        let seconds = max(1, timeout)
        let reader = CalDavReadDelegate(ceiling: ceiling)
        self.maximumResponseBytes = ceiling
        self.timeout = seconds
        self.reader = reader
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
    }

    public func perform(_ request: CalDavRequest) async throws -> CalDavResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = timeout
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            return try await reader.load(urlRequest, using: session)
        } catch let failure as CalDavError {
            throw failure
        } catch let failure as HubLinkError {
            throw failure
        } catch {
            throw Self.classify(error, timeout: timeout)
        }
    }

    /// An OS network failure mapped to a house error by *code*. The error's own text is
    /// never quoted: a `URLError` description can carry the URL it failed on, and this
    /// node's rule is that no request line reaches an error message.
    static func classify(_ error: Error, timeout: TimeInterval) -> Error {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return HubLinkError.readFailed("transport error \(failure.code)") }
        switch failure.code {
        case NSURLErrorCancelled: return CancellationError()
        case NSURLErrorTimedOut: return HubLinkError.timedOut(timeout)
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return HubLinkError.connectFailed("host unreachable (\(failure.code))")
        case NSURLErrorNetworkConnectionLost: return HubLinkError.peerClosed
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
            return HubLinkError.connectFailed("no route to the network (\(failure.code))")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            // The deliberately unhelpful-to-attacker answer: the node never bypasses TLS.
            // An owner with a self-signed Nextcloud certificate has to trust it in the
            // Keychain, which is a decision they make, not one this code takes.
            return HubLinkError.connectFailed("TLS validation failed (\(failure.code)); trust the server certificate in the Keychain")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            // ATS says the same thing this file does about plain `http`.
            return HubLinkError.connectFailed("clear-text connection refused by App Transport Security")
        default:
            return HubLinkError.readFailed("network error (\(failure.code))")
        }
    }

    /// Releases the session. A delegate-backed `URLSession` retains its delegate until it is
    /// invalidated, so a client built without an injected transport would otherwise hold its
    /// read buffers for the life of the process. Injected transports are the caller's to
    /// invalidate.
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }
}

/// The read itself, in one delegate: no redirect, and a body that stops at the ceiling.
///
/// Checking `expectedContentLength` catches an honest server that says it is huge; counting
/// the bytes that actually arrive is what stops a lie, so both are done and neither is
/// sufficient alone.
private final class CalDavReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Load {
        let requestURL: URL?
        var body = Data()
        var overflowed = false
        var declaredTooLarge = false
    }

    private let ceiling: Int
    private let lock = NSLock()
    private var loads: [Int: Load] = [:]
    private var waiters: [Int: CheckedContinuation<CalDavResponse, Error>] = [:]

    init(ceiling: Int) {
        self.ceiling = ceiling
        super.init()
    }

    func load(_ request: URLRequest, using session: URLSession) async throws -> CalDavResponse {
        let task = session.dataTask(with: request)
        let identifier = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CalDavResponse, Error>) in
                lock.lock()
                loads[identifier] = Load(requestURL: request.url)
                waiters[identifier] = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        var load = loads[dataTask.taskIdentifier] ?? Load(requestURL: dataTask.originalRequest?.url)
        // `expectedContentLength` is -1 when the server declines to say, which is legal.
        if response.expectedContentLength > Int64(ceiling) {
            load.declaredTooLarge = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
        loads[dataTask.taskIdentifier] = load
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var load = loads[dataTask.taskIdentifier] ?? Load(requestURL: dataTask.originalRequest?.url)
        let room = ceiling - load.body.count
        guard data.count > max(0, room) else {
            load.body.append(data)
            loads[dataTask.taskIdentifier] = load
            lock.unlock()
            return
        }
        if room > 0 { load.body.append(contentsOf: data.prefix(room)) }
        load.overflowed = true
        loads[dataTask.taskIdentifier] = load
        lock.unlock()
        // Cancelled outside the lock: the cancellation re-enters this delegate.
        dataTask.cancel()
    }

    /// Handing back `nil` is how a redirect is refused: the task ends on the 3xx response
    /// instead of connecting to whatever host the allow-listed one named. The labels are
    /// `willPerformHTTPRedirection:newRequest:` because that is the spell the current
    /// `URLSessionTaskDelegate` requirement has — the older `willPerformHTTPRedemption`
    /// spelling compiles with nothing but a warning and then silently never runs, which
    /// would turn this refusal into an un-refused redirect.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let load = loads.removeValue(forKey: task.taskIdentifier)
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let waiter else { return }
        guard let load else {
            waiter.resume(throwing: HubLinkError.readFailed("no response"))
            return
        }
        if load.overflowed || load.declaredTooLarge {
            waiter.resume(throwing: CalDavError.responseTooLarge(ceiling))
            return
        }
        if let error {
            waiter.resume(throwing: error)
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            waiter.resume(throwing: HubLinkError.readFailed("response was not HTTP"))
            return
        }
        // Belt to the redirect refusal above: if the effective request left the origin this
        // node was handed, that body did not come from the allow-listed host.
        if let asked = load.requestURL, let reached = task.currentRequest?.url,
           !Self.isSameOrigin(asked, reached) {
            waiter.resume(throwing: HubLinkError.invalidTarget("answer came from another origin"))
            return
        }
        waiter.resume(returning: CalDavResponse(
            statusCode: http.statusCode,
            headers: Self.headerFields(http),
            body: load.body
        ))
    }

    static func headerFields(_ response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            fields[name.lowercased()] = (value as? String) ?? String(describing: value)
        }
        return fields
    }

    static func isSameOrigin(_ asked: URL, _ reached: URL) -> Bool {
        (asked.scheme?.lowercased() ?? "") == (reached.scheme?.lowercased() ?? "")
            && (asked.host?.lowercased() ?? "") == (reached.host?.lowercased() ?? "")
            && (asked.port ?? 0) == (reached.port ?? 0)
    }
}

// MARK: - Calendars

/// One calendar collection the server admitted this node to.
///
/// `displayName` and `description` are *collection* text — the name and note the owner typed
/// into their own calendar app, in a `PROPFIND` answer about the collection. They are not
/// event detail, so they are safe to show in the console; the properties this product must
/// never surface (`SUMMARY`, `DESCRIPTION`, `LOCATION`, `ATTENDEE` inside a `VEVENT`) live
/// only in `calendar-data`, which this client hands straight to `ICalendarParse.busy` and
/// holds for no longer than that call.
public struct CalDavCalendar: Sendable, Equatable, Codable {
    public var path: String
    public var displayName: String
    public var description: String?
    public var supportsReport: Bool

    public init(path: String, displayName: String, description: String? = nil, supportsReport: Bool) {
        self.path = path
        self.displayName = displayName
        self.description = description
        self.supportsReport = supportsReport
    }
}

// MARK: - Paths

/// Turns path text — from the config or from a server's `href` — into a path worth asking
/// for, or refuses it.
private enum CalDavPath {
    /// Unreserved characters plus the sub-delimiters a real calendar URI uses. `@`, `?`, `#`,
    /// `\` and every control byte are absent, so nothing here can re-open the authority
    /// section of the URL or truncate it, and `:` survives because Nextcloud's
    /// `/remote.php/dav/calendars/user/name` paths need it.
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        + "-._~%!$&'()*+,;=:@")

    /// The path component of `raw`, always leading-slashed and never escaping upward, or
    /// `nil` when the text is not something to request.
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= CalDav.maximumPathCharacters else { return nil }
        // Control bytes and a backslash are refused outright (a `\` is a path separator to
        // some proxies); a plain space survives and is percent-encoded below, because servers
        // really do answer `/calendars/alice/My Events/` unencoded.
        guard !text.contains("\\"), text.allSatisfy(\.isPrintableASCII) else { return nil }
        // An absolute href carries an origin this node must not inherit: keep its path,
        // throw its host away, and let `EdgeEndpoint.url(path:)` put the allowed one back.
        if let scheme = text.range(of: "://") {
            var tail = text[scheme.upperBound...]
            // No slash after the authority means the href named a root, which is the
            // endpoint's own "/" by the time the origin is put back.
            if let slash = tail.firstIndex(of: "/") { tail = tail[slash...] } else { tail = "" }
            text = String(tail)
        }
        for cut in ["?", "#"] {
            if let at = text.range(of: cut) { text = String(text[..<at.lowerBound]) }
        }
        guard wellFormedEscapes(text) else { return nil }
        let segments = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count <= CalDav.maximumPathSegments else { return nil }
        var kept: [String] = []
        kept.reserveCapacity(segments.count)
        for segment in segments {
            if segment == "." { continue }
            // `..` is refused rather than resolved. A calendar server has no business
            // handing back a parent path, and resolving it is how one walks out of the
            // collection the owner pointed the node at.
            if segment == ".." { return nil }
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encoded.isEmpty else { return nil }
            kept.append(encoded)
        }
        guard !kept.isEmpty else { return "/" }
        return "/" + kept.joined(separator: "/") + (text.hasSuffix("/") ? "/" : "")
    }

    /// `%` stays legal, because a server hands back already-encoded hrefs and re-encoding
    /// them would break every calendar with a space in its name — but a `%` that does not
    /// introduce two hex digits is not an encoding, it is a probe.
    static func wellFormedEscapes(_ text: String) -> Bool {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            guard index + 2 < characters.count,
                  characters[index + 1].isHexDigit, characters[index + 2].isHexDigit else { return false }
            index += 3
        }
        return true
    }
}

private extension Character {
    /// Bytes 0x20–0x7e, plus anything non-ASCII (which the percent-encode step below is
    /// allowed to escape). A control character in an `href` is a request-splitting attempt.
    var isPrintableASCII: Bool {
        guard let ascii = asciiValue else { return true }
        return ascii >= 0x20 && ascii != 0x7f
    }
}

// MARK: - multistatus reader

/// Delegate-based `XMLParser` for a `DAV:multistatus`, holding only the handful of elements
/// this bridge reads.
///
/// There is no document tree and no string matching on the body: an unknown element is
/// ignored rather than stored, so a server that sends a megabyte of properties this node
/// never asked for costs a comparison per element. `calendar-data` is collected as opaque
/// text and never walked — the iCalendar inside it is XML character data, and the *only*
/// consumer of it is `ICalendarParse.busy`, which is where the redaction happens.
private final class CalDavMultistatusReader: NSObject, XMLParserDelegate {
    struct Entry {
        var path = ""
        var displayName = ""
        var collectionDescription = ""
        var isCalendar = false
        var supportsReport = false
    }

    private enum Owner { case principal, calendarHome }
    /// Which element's text is being collected right now. `nothing` rather than `none`, so it
    /// can never be read as the absence of an `Optional`.
    private enum Field {
        case nothing, href, display, description, resourceName, reportName, ownerName, calendarData
    }

    private(set) var entries: [Entry] = []
    private(set) var calendarBlocks: [String] = []
    private(set) var principalHref = ""
    private(set) var calendarHomeHref = ""
    /// Blocks dropped for being too large, or for yielding no verdict at all. They are
    /// counted, not swallowed: under-reporting busy time is the dangerous direction.
    private(set) var droppedBlocks = 0
    private(set) var rootRejected = false
    private(set) var overflowed = false
    /// How many of whatever overflowed, so `tooManyResults` names a real number.
    private(set) var overflowCount = 0

    private var entry: Entry?
    private var owner: Owner?
    private var field: Field = .nothing
    private var text = ""
    private var block = ""
    private var blockBytes = 0
    private var blockUnusable = false
    private var sawRoot = false
    private var checkedRoot = false

    /// The calendar collections among the responses. Non-calendar resources (the principal,
    /// schedule inboxes, address books) are answered by the same `PROPFIND` and must not be
    /// offered to a `calendar-query`.
    var calendars: [Entry] { entries.filter { $0.isCalendar && !$0.path.isEmpty } }

    /// Where the next hop of discovery is, preferring the home set because one request from
    /// it lists every calendar.
    var nextHop: String? {
        if !calendarHomeHref.isEmpty { return calendarHomeHref }
        return principalHref.isEmpty ? nil : principalHref
    }

    static func read(_ body: Data) throws -> CalDavMultistatusReader {
        let parser = XMLParser(data: body)
        let reader = CalDavMultistatusReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        // `XMLParser` does not load external entities by default, and turning it on would
        // hand any LAN server a way to read this Mac's disk (`<!ENTITY x SYSTEM
        // "file:///etc/passwd">`) inside the node's own process. Stated, and asserted off.
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        // The reader's own flags first: an aborted parse is not necessarily an error one.
        if reader.rootRejected { throw CalDavError.malformedDocument("root is not a DAV:multistatus") }
        if reader.overflowed { throw CalDavError.tooManyResults(reader.overflowCount) }
        if let failure = parser.parserError as NSError? {
            // Code and line only: an XML error description can quote the offending text,
            // and the offending text here is somebody else's document.
            throw CalDavError.malformedDocument("xml code \(failure.code) line \(parser.lineNumber)")
        }
        return reader
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let uri = namespaceURI ?? ""
        if !checkedRoot {
            checkedRoot = true
            sawRoot = uri == CalDav.namespaceDAV && elementName == "multistatus"
            guard sawRoot else {
                rootRejected = true
                parser.abortParsing()
                return
            }
            return
        }
        switch (uri, elementName) {
        case (CalDav.namespaceDAV, "response"):
            if entries.count >= CalDav.maximumResponses {
                overflowed = true
                overflowCount = entries.count + 1
                parser.abortParsing()
                return
            }
            entry = Entry()
        case (CalDav.namespaceDAV, "href"):
            begin(owner == nil ? .href : .ownerName)
        case (CalDav.namespaceDAV, "displayname"):
            begin(.display)
        case (CalDav.namespaceCalendarServer, "calendar-description"):
            begin(.description)
        case (CalDav.namespaceDAV, "current-user-principal"):
            owner = .principal
        case (CalDav.namespaceCalendar, "calendar-home-set"):
            owner = .calendarHome
        case (CalDav.namespaceDAV, "resourcetype"):
            begin(.resourceName)
        case (CalDav.namespaceDAV, "report"):
            begin(.reportName)
        case (CalDav.namespaceCalendar, "calendar-data"):
            beginCalendarData(parser)
        default:
            break
        }
        // `<calendar xmlns="urn:ietf:params:xml:ns:caldav"/>` is what makes a collection a
        // calendar; it has no text, so it is read on the way in.
        if uri == CalDav.namespaceCalendar, elementName == "calendar", field == .resourceName {
            entry?.isCalendar = true
        }
        // A report name is an empty element, not text: RFC 4791 writes
        // `<report><calendar-query xmlns="urn:ietf:params:xml:ns:caldav"/></report>`, so a
        // reader that waited for characters inside `<report>` would conclude that no server
        // on the LAN supports `calendar-query` and probe all thirty-two collections to find
        // out. Namespaces disagree between Radicale and Baïkal in the wild, so the local name
        // inside `<report>` is what carries the meaning here.
        if field == .reportName, elementName == "calendar-query" {
            entry?.supportsReport = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard field != .nothing else { return }
        switch field {
        case .calendarData:
            let cost = string.utf8.count
            guard blockBytes + cost <= CalDav.maximumCalendarDataBytes else {
                blockUnusable = true
                droppedBlocks += 1
                block = ""
                field = .nothing
                return
            }
            blockBytes += cost
            block += string
        default:
            if text.utf8.count < CalDav.maximumTextCharacters { text += string }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard sawRoot else { return }
        let uri = namespaceURI ?? ""
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (uri, elementName) {
        case (CalDav.namespaceDAV, "response"):
            if let finished = entry, !finished.path.isEmpty { entries.append(finished) }
            entry = nil
        case (CalDav.namespaceDAV, "href"):
            if let which = owner {
                switch which {
                case .principal: if principalHref.isEmpty { principalHref = content }
                case .calendarHome: if calendarHomeHref.isEmpty { calendarHomeHref = content }
                }
            } else if entry?.path.isEmpty == true {
                // First `href` directly inside a `response` is the resource's own; later ones
                // belong to properties this reader does not care about.
                entry?.path = content
            }
            endField()
        case (CalDav.namespaceDAV, "displayname"):
            entry?.displayName = content
            endField()
        case (CalDav.namespaceCalendarServer, "calendar-description"):
            entry?.collectionDescription = content
            endField()
        case (CalDav.namespaceDAV, "report"):
            // The text form is a fallback for a server that writes the name as content.
            if content == "calendar-query" { entry?.supportsReport = true }
            endField()
        case (CalDav.namespaceDAV, "resourcetype"):
            endField()
        case (CalDav.namespaceDAV, "current-user-principal"), (CalDav.namespaceCalendar, "calendar-home-set"):
            owner = nil
        case (CalDav.namespaceCalendar, "calendar-data"):
            if !blockUnusable {
                let document = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if document.isEmpty {
                    droppedBlocks += 1
                } else {
                    calendarBlocks.append(document)
                }
            }
            block = ""
            blockBytes = 0
            blockUnusable = false
            field = .nothing
        default:
            break
        }
    }

    private func begin(_ next: Field) {
        field = next
        text = ""
    }

    private func beginCalendarData(_ parser: XMLParser) {
        // A `calendar-data` block is the iCalendar text itself; nothing nested inside it is
        // XML, so this element is a leaf as far as this reader is concerned.
        if calendarBlocks.count >= CalDav.maximumCalendarDataBlocks {
            overflowed = true
            overflowCount = calendarBlocks.count + 1
            parser.abortParsing()
            return
        }
        field = .calendarData
        block = ""
        blockBytes = 0
        blockUnusable = false
    }

    private func endField() {
        field = .nothing
        text = ""
    }
}

// MARK: - Client

/// Speaks CalDAV to one configured server.
///
/// Unlike `MCPClient`, which is an actor because it owns a session and a request counter,
/// this is a value: a CalDAV exchange is stateless, so there is nothing to serialise. The
/// one secret it holds is a resolved password, and only because the caller put it there.
public struct CalDavClient: Sendable {
    public let serverID: String
    /// What the config asked for, clamped to 1…60 seconds like `CalDavServerConfig.timeoutSeconds`.
    public let timeout: TimeInterval

    private let endpoint: EdgeEndpoint
    private let username: String
    /// Resolved by the caller from `HubSecretStoring.secret(for: config.passwordRef)`. This
    /// client never reads the Keychain and never owns a reference: taking the secret as a
    /// parameter is what keeps `HubSecrets.swift` the only file that touches `SecItem`, and
    /// it means a unit test can construct a client without a Keychain at all.
    private let password: String
    private let transport: any CalDavTransport
    /// The configured collection, held separately from `endpoint` because `EdgeEndpoint`
    /// deliberately carries no path: the allow-list decision is about the host.
    private let configuredPath: String
    /// The path half of the configured base URL. Nextcloud lives under `/remote.php/dav` and
    /// Radicale under `/`, and `EdgeEndpoint` keeps neither, so the request path is rebuilt
    /// from this instead of being silently rooted at `/`.
    private let basePath: String

    /// - Parameter password: the credential for `config.username`, already fetched by the
    ///   caller from `HubSecretStoring`. Nothing here stores or returns it.
    /// - Parameter transport: inject a fake to test the gate without a socket. `nil` builds
    ///   the real `URLSessionCalDavTransport`, which `close()` then owns.
    public init(config: CalDavServerConfig, password: String, transport: (any CalDavTransport)? = nil) throws {
        // `config.endpoint` is the allow-list decision, already made: a URL that does not
        // survive `privateNetworkOnly` never becomes a client.
        guard let endpoint = config.endpoint else { throw HubLinkError.invalidTarget(config.id) }
        // Credentials must not cross the owner's LAN in clear text. `http` is admissible on
        // loopback only, where the bytes never leave this Mac; a Radicale on plain `http` at
        // 192.168.1.20 has to be put behind TLS, or the owner has to accept that this node
        // will not read it. The node does not make that decision for them quietly.
        guard endpoint.scheme == "https" || endpoint.hostClass == .loopback else {
            throw CalDavError.insecureTransport("\(endpoint.hostClass.rawValue):\(endpoint.literal):\(endpoint.port)")
        }
        guard !config.username.isEmpty else { throw CalDavError.unusableCredential("username") }
        guard !password.isEmpty else { throw CalDavError.unusableCredential("password") }
        guard config.username.utf8.count <= 256 else { throw CalDavError.unusableCredential("username") }
        guard password.utf8.count <= HubSecrets.maximumSecretLength else {
            throw CalDavError.unusableCredential("password")
        }
        // RFC 7617 joins the pair on a single `:`, so a colon in either half is not a
        // credential this node can send unambiguously. Refused by field name, never printed.
        guard !config.username.contains(":"), !password.contains(":") else {
            throw CalDavError.unusableCredential("username or password contains a colon")
        }
        let seconds = TimeInterval(min(max(config.timeoutSeconds, 1), 60))
        self.serverID = config.id
        self.endpoint = endpoint
        self.username = config.username
        self.password = password
        self.configuredPath = config.calendarPath
        self.basePath = CalDavPath.sanitize(URLComponents(string: config.url)?.path ?? "") ?? "/"
        self.timeout = seconds
        self.transport = transport ?? URLSessionCalDavTransport(timeout: seconds)
    }

    /// Tears down a transport this client created. An injected one stays the caller's.
    public func close() {
        (transport as? URLSessionCalDavTransport)?.invalidate()
    }

    // MARK: Discovery

    /// The calendars this server will serve a `calendar-query` for.
    ///
    /// When `calendarPath` is set, it is the collection to list. When it is empty the walk
    /// starts at the configured base and follows `current-user-principal` then
    /// `calendar-home-set` — two hops, because that is what RFC 3744/4791 discovery actually
    /// is — and each hop is re-anchored to the endpoint, so a returned `href` can name a host
    /// and lose.
    ///
    /// `window` bounds the probe sent to a collection that did not advertise
    /// `supported-report-set`: a one-day slice at the front of the window is enough to prove
    /// the server understands the report without fetching a season of data to find out.
    public func discoverCalendars(window: DateInterval) async throws -> [CalDavCalendar] {
        try validated(window)
        let configured = CalDavPath.sanitize(configuredPath) ?? basePath
        var reading = try await properties(at: configured)
        var hops = 0
        while configured == "/", hops < 2, reading.calendars.isEmpty, let hop = reading.nextHop {
            guard let path = CalDavPath.sanitize(hop) else { break }
            reading = try await properties(at: path)
            hops += 1
        }
        let found = reading.calendars
        // Losing a calendar here would lose its busy time, which is the one failure mode a
        // scheduler cannot survive, so this is an error rather than a truncation.
        guard found.count <= CalDav.maximumCalendars else { throw CalDavError.tooManyResults(found.count) }

        var calendars: [CalDavCalendar] = []
        calendars.reserveCapacity(found.count)
        var probes = 0
        for entry in found {
            var answersReport = entry.supportsReport
            if !answersReport, probes < CalDav.maximumReportProbes {
                probes += 1
                // `supported-report-set` is optional in practice — a bare Radicale install
                // frequently omits it — so a collection that does not advertise is asked
                // instead of written off. A probe that throws means "no", and must not fail
                // the whole discovery.
                answersReport = (try? await probeReport(at: entry.path, window: window)) != nil
            }
            calendars.append(CalDavCalendar(
                path: entry.path,
                displayName: String(entry.displayName.prefix(CalDav.maximumDisplayNameCharacters)),
                description: entry.collectionDescription.isEmpty
                    ? nil
                    : String(entry.collectionDescription.prefix(CalDav.maximumDescriptionCharacters)),
                supportsReport: answersReport
            ))
        }
        return calendars
    }

    // MARK: Free/busy

    /// Busy intervals for one calendar collection inside `window`.
    ///
    /// `zone` is the *probe's* zone, handed to the parser as the reading for floating stamps:
    /// an unknown `TZID` is wall time in the owner's zone, and shifting it into UTC would move
    /// every block by hours and the scheduler would happily book on top of it.
    ///
    /// Nothing is cached. The `calendar-data` of every event the window covers arrives, is
    /// reduced by `ICalendarParse.busy(in:window:defaultZone:)`, and the text goes out of
    /// scope with this function — which is why there is no `getctag` field on any type here:
    /// a ctag is a cache key, and this node keeps no calendar cache.
    public func freeBusy(calendarPath: String, window: DateInterval, zone: TimeZone) async throws -> ICalendarFreeBusy {
        try validated(window)
        guard let path = CalDavPath.sanitize(calendarPath), path != "/" else {
            // The rejected value is deliberately not quoted: a hostile `href` may contain
            // anything, and the reason is the useful half.
            throw HubLinkError.invalidTarget("calendar path")
        }

        let response: CalDavResponse
        do {
            response = try await exchange(
                method: CalDav.methodReport,
                path: path,
                body: CalDav.calendarQueryBody(window: window, requestingCTag: true)
            )
        } catch {
            // Matched through an explicit cast rather than an `enum-case(x)` pattern on the
            // existential, which is not what Swift promises to compile.
            guard let refusal = error as? CalDavError, case .httpStatus(400) = refusal else { throw error }
            // A `400` on a `calendar-query` is usually one property the host has never heard
            // of — `{http://apple.com/ns/ical/}getctag` is Apple's, not RFC 4791's. Nothing
            // downstream reads the ctag, so it is dropped and asked once more before the
            // owner's configuration is blamed. One retry, never a loop.
            response = try await exchange(
                method: CalDav.methodReport,
                path: path,
                body: CalDav.calendarQueryBody(window: window, requestingCTag: false)
            )
        }

        let reading = try CalDavMultistatusReader.read(response.body)
        guard !reading.calendarBlocks.isEmpty else { throw CalDavError.emptyCalendar }

        var merged = ICalendarFreeBusy()
        var intervals: [RedactedBusyInterval] = []
        for block in reading.calendarBlocks {
            let part = ICalendarParse.busy(in: block, window: window, defaultZone: zone)
            intervals.append(contentsOf: part.busy)
            merged.eventCount += part.eventCount
            merged.discardedCount += part.discardedCount
            merged.approximated = merged.approximated || part.approximated
            merged.unknownTimeZone = merged.unknownTimeZone || part.unknownTimeZone
            // A block that reported neither a busy interval nor a discard was not understood.
            // Reporting it as an approximation keeps the answer a floor.
            if part.eventCount == 0, part.discardedCount == 0 {
                merged.discardedCount += 1
                merged.approximated = true
            }
        }
        // `ICalendarParse.merge` folds overlaps, and it is applied across collections as well
        // as within one: two calendars that both claim 09:00–10:00 are one busy hour for a
        // scheduler that subtracts this set from the working day.
        merged.busy = ICalendarParse.merge(intervals)
        merged.discardedCount += reading.droppedBlocks
        if reading.droppedBlocks > 0 { merged.approximated = true }
        return merged
    }

    // MARK: Exchange

    private func properties(at path: String) async throws -> CalDavMultistatusReader {
        let response = try await exchange(
            method: CalDav.methodPropfind,
            path: path,
            body: CalDav.propfindBody()
        )
        return try CalDavMultistatusReader.read(response.body)
    }

    private func probeReport(at path: String, window: DateInterval) async throws {
        let probe = DateInterval(start: window.start, end: window.start.addingTimeInterval(86_400))
        _ = try await exchange(
            method: CalDav.methodReport,
            path: path,
            body: CalDav.calendarQueryBody(window: probe, requestingCTag: false)
        )
    }

    private func exchange(method: String, path: String, body: String) async throws -> CalDavResponse {
        let request = CalDavRequest(
            method: method,
            url: try url(for: path),
            headers: [
                "Depth": CalDav.depthCollection,
                "Content-Type": "application/xml; charset=utf-8",
                "Accept": "application/xml, text/xml, text/calendar;q=0.9",
                "User-Agent": "popopx-mac-node/\(NodeVersion.current.semanticString)",
                "Authorization": basicAuthorization
            ],
            body: Data(body.utf8)
        )
        let response = try await transport.perform(request)
        // 207 Multi-Status is the expected answer and sits inside 2xx, so one range test
        // covers both — and it is what makes a refused redirect an error instead of a body:
        // a `302` fails here rather than quietly returning somebody else's calendar.
        guard (200..<300).contains(response.statusCode) else {
            throw CalDavError.httpStatus(response.statusCode)
        }
        let type = response.header("content-type") ?? ""
        guard type.localizedCaseInsensitiveContains("xml") else {
            // A captive portal or a proxy error page answers `200` with HTML. Capped because
            // the string came off somebody else's wire.
            throw CalDavError.unexpectedContentType(String(type.prefix(64)))
        }
        // Re-checked here because `CalDavTransport` is an open seam: a fake — or a future
        // transport — must not be able to hand this node an unbounded body.
        guard response.body.count <= CalDav.maximumResponseBytes else {
            throw CalDavError.responseTooLarge(CalDav.maximumResponseBytes)
        }
        return response
    }

    /// RFC 7617: the userid and the password are joined with one `:` and the pair is
    /// base64-encoded. There is no percent-encoding — that belongs to userinfo in a URI, and
    /// `EdgeBoundary` rejects userinfo outright. The result is built per request, is never
    /// stored, and never appears in an error message or a description.
    private var basicAuthorization: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private func url(for path: String) throws -> URL {
        guard let url = endpoint.url(path: rooted(path)) else { throw HubLinkError.invalidTarget("request url") }
        return url
    }

    /// The request path under the configured base. A server's own href already contains it,
    /// so the join is a prefix test rather than a concatenation, and cannot produce
    /// `/remote.php/dav/remote.php/dav/…`.
    private func rooted(_ path: String) -> String {
        guard basePath != "/", !path.hasPrefix(basePath) else { return path }
        return basePath + path
    }

    private func validated(_ window: DateInterval) throws {
        guard window.end > window.start else { throw HubLinkError.invalidTarget("window ends before it starts") }
        guard window.duration / 86_400 <= Double(CalDav.maximumWindowDays) else {
            throw HubLinkError.invalidTarget("window wider than \(CalDav.maximumWindowDays) days")
        }
    }
}

//
//  MailTransport.swift
//  PopopxMacNode — the only assistant code that dials outside this Mac.
//
//  This is the named egress exception the brief allows: mail cannot be read from a
//  loopback socket. The exception is bounded on purpose:
//
//  * the host is the owner's literal from the settings document (no discovery, no
//    redirect, no MX lookup);
//  * only **implicit TLS** is dialled — 993 for IMAP, 465 for SMTP — so there is no
//    STARTTLS path that could fall back to cleartext;
//  * credentials arrive as arguments from `HubSecretStoring` at use time and are
//    never written to a log or an error;
//  * reading uses `EXAMINE` and `BODY.PEEK[...]`, which do not change server flags;
//  * every fetch is bounded by a timeout and by the message cap, and the raw body
//    is discarded as soon as the bridge has its classification and snippet.
//
//  The channel is a small async wrapper over one `NWConnection`. All mutable state
//  is confined to one serial queue; continuations are settled exactly once by the
//  queue; a failure settles every waiter before cancelling the socket.
//

import Foundation
import Network

public enum MailTransportError: Error, Equatable, CustomStringConvertible {
    case refused(String)
    case protocolError(String)
    case authFailed(String)
    case timedOut
    case closed

    public var description: String {
        switch self {
        case .refused(let reason): return "邮件传输拒绝 / mail transport refused: \(reason)"
        case .protocolError(let reason): return "邮件协议错误 / mail protocol error: \(reason)"
        case .authFailed(let reason): return "邮件认证失败 / mail authentication failed: \(reason)"
        case .timedOut: return "邮件传输超时 / mail transport timed out"
        case .closed: return "邮件连接已关闭 / the mail connection closed"
        }
    }
}

// MARK: - TLS channel

/// One implicit-TLS socket with a byte buffer. Sequential by construction: the
/// protocol above awaits each read and each write, so at most one of each is
/// outstanding.
final class MailTLSChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "chat.popopx.macnode.mail.tls", qos: .utility)
    private let connection: NWConnection
    private var buffer = Data()
    private var closedError: MailTransportError?
    private var pumping = false
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var readWaiters: [CheckedContinuation<Data, Error>] = []
    private let maximumBuffer = 4 * 1_024 * 1_024

    init?(host: String, port: Int) {
        guard port == 993 || port == 465,
              let service = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 12
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: service,
            using: NWParameters(tls: tls, tcp: tcp)
        )
    }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MailTransportError.closed)
                    return
                }
                self.connectWaiter = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async { self.handle(state) }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard self.connectWaiter != nil else { return }
                    self.fail(.timedOut)
                }
            }
        }
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                if let error = self.closedError {
                    continuation.resume(throwing: error)
                    return
                }
                if !self.buffer.isEmpty {
                    let chunk = self.buffer
                    self.buffer.removeAll(keepingCapacity: true)
                    continuation.resume(returning: chunk)
                    return
                }
                self.readWaiters.append(continuation)
                self.pump()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MailTransportError.closed)
                    return
                }
                if let error = self.closedError {
                    continuation.resume(throwing: error)
                    return
                }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        continuation.resume(throwing: MailTransportError.closed)
                        return
                    }
                    self.queue.async {
                        if let error {
                            continuation.resume(throwing: error)
                            self.fail(.closed)
                            return
                        }
                        continuation.resume()
                    }
                })
            }
        }
    }

    func close() {
        queue.async {
            self.fail(.closed)
        }
    }

    // MARK: Private — queue only

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if let waiter = connectWaiter {
                connectWaiter = nil
                waiter.resume()
            }
        case .failed, .waiting:
            fail(.refused("TLS 连接失败 / the TLS connection could not be established"))
        case .cancelled:
            fail(.closed)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func pump() {
        guard !pumping, closedError == nil, !readWaiters.isEmpty else { return }
        pumping = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.pumping = false
                if let data, !data.isEmpty {
                    if self.buffer.count + data.count > self.maximumBuffer {
                        self.fail(.protocolError("response exceeded the buffer ceiling"))
                        return
                    }
                    self.buffer.append(data)
                    self.deliver()
                }
                if let error {
                    self.fail(.refused(error.localizedDescription))
                    return
                }
                if isComplete {
                    self.fail(.closed)
                    return
                }
                if !self.readWaiters.isEmpty, self.buffer.isEmpty {
                    self.pump()
                }
            }
        }
    }

    private func deliver() {
        while !readWaiters.isEmpty, !buffer.isEmpty {
            let waiter = readWaiters.removeFirst()
            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            waiter.resume(returning: chunk)
        }
    }

    private func fail(_ error: MailTransportError) {
        guard closedError == nil else { return }
        closedError = error
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.resume(throwing: error)
        }
        let reads = readWaiters
        readWaiters.removeAll()
        for waiter in reads { waiter.resume(throwing: error) }
        connection.cancel()
    }
}

// MARK: - Line reader

final class MailLineReader: @unchecked Sendable {
    private let channel: MailTLSChannel
    private var buffer = Data()
    private let crlf = Data([13, 10])

    init(channel: MailTLSChannel) {
        self.channel = channel
    }

    func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: crlf) {
                let lineData = Data(buffer[buffer.startIndex..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            if buffer.count > 2 * 1_024 * 1_024 {
                throw MailTransportError.protocolError("line exceeded the ceiling")
            }
            buffer.append(try await channel.read())
        }
    }

    func readLiteral(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 2 * 1_024 * 1_024 else {
            throw MailTransportError.protocolError("literal size out of range")
        }
        while buffer.count < count {
            buffer.append(try await channel.read())
        }
        let data = Data(buffer.prefix(count))
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: count))
        return data
    }
}

// MARK: - IMAP

final class IMAPSession: @unchecked Sendable {
    private let reader: MailLineReader
    private let channel: MailTLSChannel
    private var counter = 0

    init(channel: MailTLSChannel) {
        self.channel = channel
        self.reader = MailLineReader(channel: channel)
    }

    func open(username: String, password: String) async throws {
        let greeting = try await reader.readLine()
        guard greeting.uppercased().hasPrefix("* OK") || greeting.uppercased().hasPrefix("* PREAUTH") else {
            throw MailTransportError.protocolError("unexpected IMAP greeting")
        }
        let login = try await command("LOGIN \(quoted(username)) \(quoted(password))")
        guard login.status.uppercased().contains("OK") else {
            throw MailTransportError.authFailed(String(login.status.prefix(120)))
        }
        let examine = try await command("EXAMINE \"INBOX\"")
        guard examine.status.uppercased().contains("OK") else {
            throw MailTransportError.protocolError("EXAMINE refused: \(String(examine.status.prefix(120)))")
        }
    }

    func close() async {
        _ = try? await command("LOGOUT")
        channel.close()
    }

    /// `UID SEARCH UNSEEN SINCE <date>`. EXAMINE keeps the mailbox read-only.
    func searchUnseen(since: Date, limit: Int) async throws -> [Int] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        let result = try await command("UID SEARCH UNSEEN SINCE \(formatter.string(from: since))")
        let search = result.lines.last(where: { $0.uppercased().hasPrefix("* SEARCH") }) ?? ""
        let uids = search.split(separator: " ")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Array(uids.suffix(limit).reversed())
    }

    func fetch(uid: Int) async throws -> MailFetchedMessage? {
        let tag = nextTag()
        let request = "\(tag) UID FETCH \(uid) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.2048>)\r\n"
        try await channel.send(Data(request.utf8))
        var header = ""
        var body = ""
        var receivedAt = ""
        while true {
            let line = try await reader.readLine()
            if line.hasPrefix(tag + " ") {
                guard line.uppercased().contains("OK") else {
                    throw MailTransportError.protocolError("FETCH refused: \(String(line.prefix(120)))")
                }
                break
            }
            if let literal = literalCount(line) {
                let bytes = try await reader.readLiteral(literal)
                let text = String(decoding: bytes, as: UTF8.self)
                let upper = line.uppercased()
                if upper.contains("HEADER.FIELDS") {
                    header += text
                } else if upper.contains("BODY[TEXT]") || upper.contains("BODY[]") {
                    body += text
                }
            }
            if let value = internalDate(from: line) {
                receivedAt = value
            }
        }
        guard !header.isEmpty else { return nil }
        return parse(uid: uid, header: header, body: body, internalDate: receivedAt)
    }

    // MARK: Private

    private func nextTag() -> String {
        counter += 1
        return "A\(counter)"
    }

    private func command(_ text: String) async throws -> (status: String, lines: [String]) {
        let tag = nextTag()
        try await channel.send(Data((tag + " " + text + "\r\n").utf8))
        var lines: [String] = []
        while true {
            let line = try await reader.readLine()
            if line.hasPrefix(tag + " ") {
                return (String(line.dropFirst(tag.count + 1)), lines)
            }
            if line.hasPrefix(tag) {
                return (String(line.dropFirst(tag.count)), lines)
            }
            lines.append(line)
        }
    }

    private func quoted(_ value: String) throws -> String {
        guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
            throw MailTransportError.refused("credential contains a control character")
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func literalCount(_ line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let open = line.lastIndex(of: "{"), open > line.startIndex else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(digits)
    }

    private func internalDate(from line: String) -> String? {
        guard let range = line.range(of: "INTERNALDATE \"") else { return nil }
        let rest = line[range.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    private func parse(uid: Int, header: String, body: String, internalDate: String) -> MailFetchedMessage {
        let fields = HeaderFields(header)
        let subject = MailText.decodeHeader(fields.value("subject"))
        let sender = MailText.decodeHeader(fields.value("from"))
        let received = MailText.parse(date: fields.value("date"))
            ?? MailText.parse(imapDate: internalDate)
            ?? Date()
        let encoding = fields.value("content-transfer-encoding").lowercased()
        let decodedBody: String
        if encoding.contains("base64") {
            decodedBody = MailText.decodeBase64(body)
        } else if encoding.contains("quoted-printable") {
            decodedBody = MailText.decodeQuotedPrintable(body)
        } else {
            decodedBody = body
        }
        let id = fields.value("message-id").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return MailFetchedMessage(
            id: id.isEmpty ? "uid-\(uid)" : id,
            subject: subject.isEmpty ? "(no subject)" : subject,
            from: sender.isEmpty ? "(unknown sender)" : sender,
            receivedAt: received,
            body: String(decodedBody.prefix(MailAssistantBridge.maximumBodyCharacters)),
            unread: true
        )
    }
}

// MARK: - SMTP

final class SMTPSession: @unchecked Sendable {
    private let reader: MailLineReader
    private let channel: MailTLSChannel
    private let username: String

    init(channel: MailTLSChannel, username: String) {
        self.channel = channel
        self.reader = MailLineReader(channel: channel)
        self.username = username
    }

    func open(password: String) async throws {
        try expect(try await reader.readLine(), code: 220)
        try await send("EHLO popopx-mac-node\r\n")
        try await expectMultiline(try await reader.readLine(), code: 250)
        let token = Data(("\0" + username + "\0" + password).utf8).base64EncodedString()
        try await send("AUTH PLAIN \(token)\r\n")
        let auth = try await reader.readLine()
        if auth.hasPrefix("334") {
            try await send(token + "\r\n")
            try expect(try await reader.readLine(), code: 235)
        } else {
            try expect(auth, code: 235)
        }
    }

    func send(draft: MailOutgoingDraft, from: String) async throws {
        try await send("MAIL FROM:<\(from)>\r\n")
        try expect(try await reader.readLine(), code: 250)
        try await send("RCPT TO:<\(draft.canonicalTarget)>\r\n")
        let rcpt = try await reader.readLine()
        guard rcpt.hasPrefix("250") || rcpt.hasPrefix("251") else {
            throw MailTransportError.protocolError("RCPT refused: \(String(rcpt.prefix(80)))")
        }
        try await send("DATA\r\n")
        try expect(try await reader.readLine(), code: 354)
        let message = try MailText.message(draft: draft, from: from)
        try await send(message)
        try await send(".\r\n")
        try await expectMultiline(try await reader.readLine(), code: 250)
    }

    func close() async {
        try? await send("QUIT\r\n")
        channel.close()
    }

    // MARK: Private

    private func send(_ text: String) async throws {
        try await channel.send(Data(text.utf8))
    }

    private func expect(_ line: String, code: Int) throws {
        guard line.hasPrefix(String(code)) else {
            throw MailTransportError.protocolError("SMTP expected \(code), got \(String(line.prefix(80)))")
        }
    }

    private func expectMultiline(_ first: String, code: Int) async throws {
        var line = first
        guard line.hasPrefix(String(code)) else {
            throw MailTransportError.protocolError("SMTP expected \(code), got \(String(line.prefix(80)))")
        }
        while line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
            line = try await reader.readLine()
            guard line.hasPrefix(String(code)) else {
                throw MailTransportError.protocolError("SMTP expected continuation \(code), got \(String(line.prefix(80)))")
            }
        }
    }
}

// MARK: - Text helpers

enum MailText {
    static func parse(imapDate: String) -> Date? {
        guard !imapDate.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: imapDate)
    }

    static func parse(date: String) -> Date? {
        guard !date.isEmpty else { return nil }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: date) { return parsed }
        }
        return nil
    }

    /// RFC 2047 `=?...?B?...?=` and `=?...?Q?...?=` words, the form every mail
    /// client uses for a non-ASCII subject. Decoding is best-effort; an unknown
    /// charset leaves the original word in place rather than mojibake.
    static func decodeHeader(_ raw: String) -> String {
        guard raw.contains("=?") else { return clean(raw) }
        let pattern = "=\\?[^?]+\\?[BbQq]\\?[^?]*\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return clean(raw) }
        var result = raw
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = String(result[range])
            let parts = word.components(separatedBy: "?")
            guard parts.count >= 5 else { continue }
            let encoding = parts[1].lowercased()
            let payload = parts[3]
            if encoding == "b", let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
               let decoded = String(data: data, encoding: .utf8) {
                result.replaceSubrange(range, with: decoded)
            } else if encoding == "q" {
                result.replaceSubrange(range, with: decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " ")))
            }
        }
        return clean(result)
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeBase64(_ text: String) -> String {
        let compact = text.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) else { return text }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 { // "="
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high * 16 + low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    /// The DATA payload. Headers are ASCII-only; the body is base64 so no line can
    /// begin with the SMTP terminator and no 8-bit byte reaches a server that did
    /// not negotiate SMTPUTF8.
    static func message(draft: MailOutgoingDraft, from: String) throws -> String {
        let to = draft.canonicalTarget
        guard isASCII(to), isASCII(from), !to.isEmpty, !from.isEmpty else {
            throw MailTransportError.refused("non-ASCII envelope address")
        }
        let subject = headerSafe(draft.subject)
        let encodedSubject = isASCII(subject)
            ? subject
            : "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let formatter = RFC2822DateFormatter.shared
        let body = Data(draft.body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        var headers = [
            "From: <\(from)>",
            "To: <\(to)>",
            "Subject: \(encodedSubject)",
            "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(UUID().uuidString)@popopx.local>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64"
        ]
        if !draft.inReplyTo.isEmpty {
            headers.append("In-Reply-To: <\(headerSafe(draft.inReplyTo))>")
            headers.append("References: <\(headerSafe(draft.inReplyTo))>")
        }
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n"
    }

    private static func headerSafe(_ text: String) -> String {
        clean(text).replacingOccurrences(of: "<", with: " ")
            .replacingOccurrences(of: ">", with: " ")
    }

    private static func isASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII }
    }
}

private final class RFC2822DateFormatter: @unchecked Sendable {
    static let shared = RFC2822DateFormatter()
    private let lock = NSLock()
    private let formatter = DateFormatter()

    private init() {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

final class HeaderFields: @unchecked Sendable {
    private(set) var values: [String: String] = [:]

    init(_ raw: String) {
        var currentKey = ""
        var currentValue = ""
        func flush() {
            guard !currentKey.isEmpty else { return }
            values[currentKey.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentKey = ""
            currentValue = ""
        }
        for line in raw.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            currentKey = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        flush()
    }

    func value(_ key: String) -> String {
        values[key.lowercased()] ?? ""
    }
}

// MARK: - Transport

public struct MailNetTransport: MailTransporting {
    public init() {}

    public func fetchRecent(
        account: MailAssistantConfig,
        password: String,
        since: Date,
        limit: Int
    ) async throws -> [MailFetchedMessage] {
        let config = account.normalised
        guard config.imapPort == 993, !config.imapHost.isEmpty, !password.isEmpty else {
            throw MailTransportError.refused("IMAP needs an owner-typed host and implicit TLS 993")
        }
        guard let channel = MailTLSChannel(host: config.imapHost, port: 993) else {
            throw MailTransportError.refused("invalid IMAP endpoint")
        }
        let session = IMAPSession(channel: channel)
        defer { channel.close() }
        return try await MailTimeout.run(60) {
            try await channel.start(timeout: 12)
            try await session.open(username: config.username, password: password)
            let uids = try await session.searchUnseen(since: since, limit: min(max(limit, 1), 30))
            var messages: [MailFetchedMessage] = []
            for uid in uids {
                if let message = try await session.fetch(uid: uid) {
                    messages.append(message)
                }
            }
            return messages
        }
    }

    public func send(
        draft: MailOutgoingDraft,
        account: MailAssistantConfig,
        password: String
    ) async throws {
        let config = account.normalised
        guard config.smtpPort == 465, !config.smtpHost.isEmpty, !password.isEmpty else {
            throw MailTransportError.refused("SMTP needs an owner-typed host and implicit TLS 465")
        }
        guard MailAssistantConfig.mailbox(draft.to) == draft.to else {
            throw MailTransportError.refused("recipient is not a mailbox")
        }
        guard let channel = MailTLSChannel(host: config.smtpHost, port: 465) else {
            throw MailTransportError.refused("invalid SMTP endpoint")
        }
        let session = SMTPSession(channel: channel, username: config.username)
        defer { channel.close() }
        try await MailTimeout.run(45) {
            try await channel.start(timeout: 12)
            try await session.open(password: password)
            try await session.send(draft: draft, from: config.fromAddress)
            await session.close()
        }
    }
}

enum MailTimeout {
    static func run<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MailTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MailTransportError.timedOut }
            return first
        }
    }
}
//
//  MQTTPacket.swift
//  PopopxMacNode — MQTT v3.1.1 framing, byte for byte.
//
//  Written against the spec rather than pulled in as a package because the node's
//  claim is that no third-party cloud code runs in it, and a LAN broker is the one
//  dependency worth a hand-rolled codec: eleven packet types, a variable-length
//  integer and two-byte-prefixed UTF-8 strings.
//
//  Three rules the tests pin:
//
//  * **Encoding is exact.** A broker drops a CONNECT whose reserved bit is set and a
//    SUBSCRIBE whose flag nibble is not `0b0010`, and it says nothing helpful when it
//    does. The reserved nibbles are hard-coded, not parameters.
//  * **Decoding is total.** Reserved packet types, QoS 3, a zero-length topic, a
//    `0x80` suback code, a server-sent CONNECT — all are `.rejected`, never a
//    surprising frame. A frame from the wire is untrusted input.
//  * **A short buffer is not an error.** The read loop hands over whatever arrived, so
//    `.incomplete` is a normal answer meaning "read more", and no half packet is ever
//    reported as a message.
//

import Foundation

// MARK: - Types

public enum MQTTMessageType: UInt8, Sendable, CaseIterable {
    case connect = 1
    case connAck = 2
    case publish = 3
    case pubAck = 4
    case pubRec = 5
    case pubRel = 6
    case pubComp = 7
    case subscribe = 8
    case subAck = 9
    case unsubscribe = 10
    case unsubAck = 11
    case pingReq = 12
    case pingResp = 13
    case disconnect = 14
}

public enum MQTTCodecError: Error, Equatable, CustomStringConvertible {
    case truncated(need: Int, have: Int)
    case malformedRemainingLength
    case remainingLengthTooLong
    case unsupportedProtocolLevel(Int)
    case reservedFlagSet
    case invalidQoS(Int)
    case emptyTopic
    case topicTooLong(Int)
    case packetIdMissing
    case reservedPacketType(Int)
    case serverInitiatedPacket(Int)
    case malformedBody(String)

    public var description: String {
        switch self {
        case let .truncated(need, have): return "报文不完整 / incomplete frame: need \(need), have \(have)"
        case .malformedRemainingLength: return "长度字段非法 / malformed remaining length"
        case .remainingLengthTooLong: return "报文超过 256MiB / remaining length over 256MiB"
        case let .unsupportedProtocolLevel(level): return "协议级别不受支持 / unsupported protocol level: \(level)"
        case .reservedFlagSet: return "保留位必须为 0 / the reserved CONNECT bit is set"
        case let .invalidQoS(qos): return "QoS \(qos) 非法 / invalid QoS"
        case .emptyTopic: return "主题不能为空 / an empty topic is not legal"
        case let .topicTooLong(length): return "主题过长 / topic too long: \(length) bytes"
        case .packetIdMissing: return "缺少报文标识符 / missing packet identifier"
        case let .reservedPacketType(value): return "保留报文类型 / reserved packet type: \(value)"
        case let .serverInitiatedPacket(value): return "服务端不应发送该报文 / a server must not send type \(value)"
        case let .malformedBody(detail): return "报文结构非法 / malformed packet: \(detail)"
        }
    }
}

// MARK: - Frames

/// One inbound PUBLISH, already validated.
public struct MQTTPublish: Sendable, Equatable {
    public var topic: String
    public var payload: Data
    public var qos: Int
    public var retain: Bool
    public var duplicate: Bool
    public var packetId: Int

    public init(topic: String, payload: Data, qos: Int = 0, retain: Bool = false, duplicate: Bool = false, packetId: Int = 0) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
        self.duplicate = duplicate
        self.packetId = packetId
    }

    public var text: String? { String(data: payload, encoding: .utf8) }
}

/// What the broker said about a subscription. A `0x80` is a refusal; reading it as
/// "granted at QoS 128" would leave the bridge subscribed to nothing, convinced it
/// was subscribed.
public struct MQTTSubAck: Sendable, Equatable {
    public var packetId: Int
    public var returnCodes: [Int]

    public init(packetId: Int, returnCodes: [Int]) {
        self.packetId = packetId
        self.returnCodes = returnCodes
    }

    public var grantedQoS: [Int] { returnCodes.filter { $0 != 0x80 } }
    public var refused: Bool { returnCodes.contains(0x80) }
}

public enum MQTTConnAckCode: Int, Sendable, CaseIterable {
    case accepted = 0
    case unsupportedProtocol = 1
    case identifierRejected = 2
    case serverUnavailable = 3
    case badCredentials = 4
    case notAuthorized = 5

    public var explanation: String {
        switch self {
        case .accepted: return "已接受 / accepted"
        case .unsupportedProtocol: return "协议级别不受支持 / unsupported protocol version"
        case .identifierRejected: return "客户端标识被拒绝 / client identifier rejected"
        case .serverUnavailable: return "服务不可用 / broker unavailable"
        case .badCredentials: return "用户名或口令错误 / bad user name or password"
        case .notAuthorized: return "未授权 / not authorized"
        }
    }
}

public enum MQTTInboundFrame: Sendable, Equatable {
    case connAck(sessionPresent: Bool, code: MQTTConnAckCode?, rawCode: Int)
    case publish(MQTTPublish)
    case pubAck(packetId: Int)
    case pubRec(packetId: Int)
    case pubRel(packetId: Int)
    case pubComp(packetId: Int)
    case subAck(MQTTSubAck)
    case unsubAck(packetId: Int)
    case pingReq
    case pingResp
    case disconnect
}

/// The answer to one decode attempt.
public enum MQTTDecode: Sendable, Equatable {
    /// A whole packet, and how many bytes of the buffer it used.
    case frame(MQTTInboundFrame, consumed: Int)
    /// A prefix of a longer packet: read at least `needed` more bytes and try again.
    case incomplete(needed: Int)
    /// Not a packet this node will act on. The caller drops the connection; a frame
    /// that cannot be read is a frame that cannot be trusted.
    case rejected(MQTTCodecError)
}

// MARK: - Options

public struct MQTTWill: Sendable, Equatable {
    public var topic: String
    public var payload: Data
    public var qos: Int
    public var retain: Bool

    public init(topic: String, payload: Data, qos: Int = 0, retain: Bool = false) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }
}

public struct MQTTConnectOptions: Sendable, Equatable {
    public var clientID: String
    public var keepAliveSeconds: Int
    public var cleanSession: Bool
    public var username: String?
    public var password: String?
    public var will: MQTTWill?

    public init(
        clientID: String,
        keepAliveSeconds: Int = 30,
        cleanSession: Bool = true,
        username: String? = nil,
        password: String? = nil,
        will: MQTTWill? = nil
    ) {
        self.clientID = clientID
        self.keepAliveSeconds = keepAliveSeconds
        self.cleanSession = cleanSession
        self.username = username
        self.password = password
        self.will = will
    }
}

// MARK: - Codec

public enum MQTTCodec {
    public static let protocolLevel: UInt8 = 4
    public static let maximumPacketBytes = 268_435_455   // the varint limit, 256 MiB
    /// The node's own ceiling, far below the protocol's: a broker can answer a
    /// subscription with megabytes of retained state, and that must not be the reason
    /// the node runs out of memory.
    public static let receiveCeilingBytes = 4 * 1024 * 1024

    // MARK: Encoding

    /// §2.2.3: 1 to 4 bytes, 7 value bits each, least significant group first.
    public static func remainingLength(_ length: Int) throws -> [UInt8] {
        guard length >= 0 else { throw MQTTCodecError.malformedRemainingLength }
        guard length <= maximumPacketBytes else { throw MQTTCodecError.remainingLengthTooLong }
        var value = length
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    /// A UTF-8 string with its two-byte length, the form every MQTT field uses.
    ///
    /// The NUL ban is real: §1.5.3 forbids U+0000 in a UTF-8 encoded string, and a
    /// broker truncates at it, which would turn `home/\(id)/state` into a topic that
    /// silently belongs to somebody else.
    public static func string(_ text: String) throws -> [UInt8] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw MQTTCodecError.emptyTopic }
        guard bytes.count <= 0xFFFF else { throw MQTTCodecError.topicTooLong(bytes.count) }
        guard !bytes.contains(0) else { throw MQTTCodecError.emptyTopic }
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
    }

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func packet(type: MQTTMessageType, flags: UInt8, body: [UInt8]) throws -> Data {
        var out: [UInt8] = [type.rawValue << 4 | flags]
        out += try remainingLength(body.count)
        out += body
        return Data(out)
    }

    public static func encodeConnect(_ options: MQTTConnectOptions) throws -> Data {
        guard (0...0xFFFF).contains(options.keepAliveSeconds) else {
            throw MQTTCodecError.topicTooLong(options.keepAliveSeconds)
        }
        var flags = UInt8(0)
        if let username = options.username, !username.isEmpty { flags |= 0x80 }
        if let password = options.password, !password.isEmpty { flags |= 0x40 }
        if let will = options.will {
            guard (0...2).contains(will.qos) else { throw MQTTCodecError.invalidQoS(will.qos) }
            flags |= 0x04
            flags |= UInt8(will.qos & 0x03) << 3
            if will.retain { flags |= 0x20 }
        }
        if options.cleanSession { flags |= 0x02 }
        // Bit 0 is reserved and must be zero (§3.1.2.3), so no code path sets it.

        var body = try string("MQTT")
        body.append(protocolLevel)
        body.append(flags)
        body += u16(options.keepAliveSeconds)
        // An empty client id is only legal with CleanSession (§3.1.3.1) and the broker
        // then mints one the audit log cannot name, so it is refused here.
        body += try string(options.clientID)
        if let will = options.will {
            body += try string(will.topic)
            body += u16(will.payload.count) + Array(will.payload)
        }
        if let username = options.username, !username.isEmpty { body += try string(username) }
        if let password = options.password, !password.isEmpty { body += try string(password) }
        return try packet(type: .connect, flags: 0, body: body)
    }

    public static func encodePublish(
        topic: String,
        payload: Data,
        qos: Int = 0,
        retain: Bool = false,
        duplicate: Bool = false,
        packetId: Int = 0
    ) throws -> Data {
        guard (0...2).contains(qos) else { throw MQTTCodecError.invalidQoS(qos) }
        guard !topic.isEmpty else { throw MQTTCodecError.emptyTopic }
        // §4.7: a topic *name* carried by a PUBLISH may not contain a wildcard.
        guard !topic.contains("+"), !topic.contains("#") else {
            throw MQTTCodecError.malformedBody("wildcards are illegal in a publish topic: \(topic)")
        }
        var flags = UInt8(qos & 0x03) << 1
        if retain { flags |= 0x01 }
        if duplicate, qos > 0 { flags |= 0x08 }
        var body = try string(topic)
        if qos > 0 {
            guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
            body += u16(packetId)
        }
        body += Array(payload)
        return try packet(type: .publish, flags: flags, body: body)
    }

    /// SUBSCRIBE's flag nibble is fixed at `0b0010` (§3.8.1) and a broker rejects any
    /// other value, so it is hard-coded rather than a parameter.
    public static func encodeSubscribe(packetId: Int, filters: [(String, Int)]) throws -> Data {
        guard !filters.isEmpty else { throw MQTTCodecError.emptyTopic }
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        var body = u16(packetId)
        for (filter, qos) in filters {
            guard (0...2).contains(qos) else { throw MQTTCodecError.invalidQoS(qos) }
            body += try string(filter)
            body.append(UInt8(qos & 0x03))
        }
        return try packet(type: .subscribe, flags: 0x02, body: body)
    }

    public static func encodeUnsubscribe(packetId: Int, filters: [String]) throws -> Data {
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        guard !filters.isEmpty else { throw MQTTCodecError.emptyTopic }
        var body = u16(packetId)
        for filter in filters { body += try string(filter) }
        return try packet(type: .unsubscribe, flags: 0x02, body: body)
    }

    public static func encodePubAck(packetId: Int) throws -> Data {
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        return try packet(type: .pubAck, flags: 0, body: u16(packetId))
    }

    /// PUBREL is the one acknowledgement with a non-zero flag nibble (§3.6.1).
    public static func encodePubRel(packetId: Int) throws -> Data {
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        return try packet(type: .pubRel, flags: 0x02, body: u16(packetId))
    }

    /// The receiver's half of the QoS 2 handshake: PUBREC answers a PUBLISH, PUBCOMP
    /// answers the PUBREL that follows it. Both carry the packet id and no flags.
    public static func encodePubRec(packetId: Int) throws -> Data {
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        return try packet(type: .pubRec, flags: 0, body: u16(packetId))
    }

    public static func encodePubComp(packetId: Int) throws -> Data {
        guard packetId > 0 else { throw MQTTCodecError.packetIdMissing }
        return try packet(type: .pubComp, flags: 0, body: u16(packetId))
    }

    public static func encodePingReq() -> Data { Data([0xC0, 0x00]) }
    public static func encodeDisconnect() -> Data { Data([0xE0, 0x00]) }

    // MARK: Decoding

    /// Reads the first complete packet at the head of `data`.
    public static func decode(_ data: Data) -> MQTTDecode {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .incomplete(needed: 2) }
        guard bytes.count >= 2 else { return .incomplete(needed: 1) }
        switch readRemainingLength(bytes, from: 1) {
        case let .value(length, width):
            guard length <= maximumPacketBytes else { return .rejected(.remainingLengthTooLong) }
            let total = 1 + width + length
            guard bytes.count >= total else { return .incomplete(needed: total - bytes.count) }
            guard length <= receiveCeilingBytes else { return .rejected(.remainingLengthTooLong) }
            let typeValue = Int(bytes[0] >> 4)
            guard let type = MQTTMessageType(rawValue: UInt8(typeValue)) else {
                return .rejected(.reservedPacketType(typeValue))
            }
            let frame = decodeBody(
                type: type,
                flags: bytes[0] & 0x0f,
                body: Array(bytes[(1 + width)..<total])
            )
            switch frame {
            case let .ok(parsed): return .frame(parsed, consumed: total)
            case let .refused(error): return .rejected(error)
            }
        case .incomplete:
            return .incomplete(needed: 1)
        case .malformed:
            return .rejected(.malformedRemainingLength)
        }
    }

    enum LengthRead: Equatable {
        case value(Int, bytes: Int)
        case incomplete
        case malformed
    }

    /// §2.2.3: at most four bytes, so a fifth continuation bit is a broken packet
    /// rather than an invitation to keep reading forever.
    static func readRemainingLength(_ bytes: [UInt8], from index: Int) -> LengthRead {
        var multiplier = 1
        var value = 0
        var cursor = index
        while cursor < bytes.count {
            guard cursor - index < 4 else { return .malformed }
            let encoded = bytes[cursor]
            value += Int(encoded & 0x7f) * multiplier
            multiplier *= 128
            cursor += 1
            if encoded & 0x80 == 0 {
                guard value <= maximumPacketBytes else { return .malformed }
                return .value(value, bytes: cursor - index)
            }
        }
        return .incomplete
    }

    enum ParsedBody {
        case ok(MQTTInboundFrame)
        case refused(MQTTCodecError)
    }

    static func decodeBody(type: MQTTMessageType, flags: UInt8, body: [UInt8]) -> ParsedBody {
        switch type {
        case .connAck:
            guard body.count == 2 else { return .refused(.malformedBody("CONNACK is 2 bytes")) }
            return .ok(.connAck(
                sessionPresent: (body[0] & 0x01) != 0,
                code: MQTTConnAckCode(rawValue: Int(body[1])),
                rawCode: Int(body[1])
            ))
        case .publish:
            return decodePublish(flags: flags, body: body)
        case .pubAck: return idOnly(body).map { .ok(.pubAck(packetId: $0)) } ?? .refused(.packetIdMissing)
        case .pubRec: return idOnly(body).map { .ok(.pubRec(packetId: $0)) } ?? .refused(.packetIdMissing)
        case .pubRel: return idOnly(body).map { .ok(.pubRel(packetId: $0)) } ?? .refused(.packetIdMissing)
        case .pubComp: return idOnly(body).map { .ok(.pubComp(packetId: $0)) } ?? .refused(.packetIdMissing)
        case .subAck:
            guard let id = twoBytes(body) else { return .refused(.packetIdMissing) }
            return .ok(.subAck(MQTTSubAck(packetId: id, returnCodes: body[2...].map(Int.init))))
        case .unsubAck:
            guard let id = twoBytes(body) else { return .refused(.packetIdMissing) }
            return .ok(.unsubAck(packetId: id))
        case .pingReq: return .ok(.pingReq)
        case .pingResp: return .ok(.pingResp)
        case .disconnect: return .ok(.disconnect)
        case .connect, .subscribe, .unsubscribe:
            // A server does not send these. Accepting them would let a broker hand our
            // parser a CONNECT and have the node read its own client id back at itself.
            return .refused(.serverInitiatedPacket(Int(type.rawValue)))
        }
    }

    static func twoBytes(_ body: [UInt8]) -> Int? {
        guard body.count >= 2 else { return nil }
        return Int(body[0]) << 8 | Int(body[1])
    }

    static func idOnly(_ body: [UInt8]) -> Int? {
        guard let id = twoBytes(body), id > 0 else { return nil }
        return id
    }

    static func decodePublish(flags: UInt8, body: [UInt8]) -> ParsedBody {
        let qos = Int((flags >> 1) & 0x03)
        guard qos <= 2 else { return .refused(.invalidQoS(qos)) }
        var reader = MQTTReader(body)
        guard let topic = reader.string() else {
            return .refused(.malformedBody("unreadable topic"))
        }
        var packetId = 0
        if qos > 0 {
            guard let id = reader.u16(), id > 0 else { return .refused(.packetIdMissing) }
            packetId = id
        } else if (flags & 0x08) != 0 {
            // §3.3.1.2: DUP means "redelivery of an unacknowledged packet", which a
            // QoS-0 publish never is.
            return .refused(.malformedBody("DUP is set on a QoS-0 publish"))
        }
        return .ok(.publish(MQTTPublish(
            topic: topic,
            payload: reader.remainingData(),
            qos: qos,
            retain: (flags & 0x01) != 0,
            duplicate: (flags & 0x08) != 0,
            packetId: packetId
        )))
    }
}

// MARK: - Reader

/// Cursor over one packet body. Every read is optional so that a short or hostile
/// frame produces `nil` instead of trapping on an out-of-range slice.
struct MQTTReader {
    let bytes: [UInt8]
    var cursor: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isExhausted: Bool { cursor >= bytes.count }

    mutating func u16() -> Int? {
        guard cursor + 2 <= bytes.count else { return nil }
        let value = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
        cursor += 2
        return value
    }

    /// A length-prefixed UTF-8 string. `nil` when the frame is short, the length is
    /// zero, or a NUL is embedded — a topic name is a dictionary key downstream, so
    /// replacement characters would merge two distinct devices into one row.
    mutating func string() -> String? {
        guard let length = u16(), length > 0, cursor + length <= bytes.count else { return nil }
        let slice = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        guard !slice.contains(0) else { return nil }
        guard String(data: Data(slice), encoding: .utf8) != nil else { return nil }
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func remainingData() -> Data {
        defer { cursor = bytes.count }
        guard cursor < bytes.count else { return Data() }
        return Data(bytes[cursor...])
    }
}

// MARK: - Topic filters

/// MQTT topic filters (§4.7). This is the matcher the smart-home allow-list is
/// enforced with, so it is separate from the codec and separately tested.
public enum MQTTTopics {
    public static let maximumLevels = 32

    /// Whether a published topic is covered by a subscription filter.
    public static func matches(_ filter: String, topic: String) -> Bool {
        match(filter: levels(filter), topic: levels(topic))
    }

    static func levels(_ text: String) -> [String] {
        text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func match(filter: [String], topic: [String]) -> Bool {
        guard let head = filter.first else { return topic.isEmpty }
        if head == "#" {
            // `sport/#` also covers `sport` itself (§4.7.1.2), which is why this
            // returns before the topic is consumed.
            return true
        }
        guard let topicHead = topic.first else { return false }
        if head == "+" {
            return match(filter: Array(filter.dropFirst()), topic: Array(topic.dropFirst()))
        }
        guard head == topicHead else { return false }
        return match(filter: Array(filter.dropFirst()), topic: Array(topic.dropFirst()))
    }

    /// A well-formed filter: no wildcard glued inside a level (`a+b`), and `#` only as
    /// the final level on its own.
    public static func isValidFilter(_ filter: String) -> Bool {
        guard !filter.isEmpty else { return false }
        let parts = levels(filter)
        guard parts.count <= maximumLevels else { return false }
        for (index, level) in parts.enumerated() {
            if level == "#" { return index == parts.count - 1 }
            if level.contains("#") { return false }
            if level.contains("+"), level != "+" { return false }
        }
        return true
    }

    /// A topic that may be published to: no wildcards, and not the `$`-prefixed
    /// broker-internal namespace (`$SYS`, `$bridge`) which a client must not write.
    public static func isValidTopicName(_ topic: String) -> Bool {
        guard !topic.isEmpty else { return false }
        guard !topic.contains("+"), !topic.contains("#"), !topic.hasPrefix("$") else { return false }
        return levels(topic).count <= maximumLevels
    }
}

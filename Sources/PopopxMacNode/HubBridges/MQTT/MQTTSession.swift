//
//  MQTTSession.swift
//  PopopxMacNode — one MQTT 3.1.1 session, driven over a `HubByteStream`.
//
//  The codec (`MQTTPacket.swift`) turns bytes into packets and back; this type is the small
//  state machine that runs a session: `CONNECT` → `CONNACK`, `SUBSCRIBE` → `SUBACK`,
//  `PUBLISH` out with its acknowledgement, `PUBLISH` in with the reply the QoS requires,
//  `PINGREQ` to hold the line, `DISCONNECT` on the way out.
//
//  Everything here is deliberately **serial**. MQTT is an ordered stream, and a client this
//  size has one outstanding operation at a time, so `pump` reads until a named answer arrives
//  instead of multiplexing. That choice is what makes the failure modes legible: a broker that
//  answers the wrong thing ends the operation with a reason, rather than leaving a coroutine
//  waiting for a SUBACK that belongs to somebody else.
//
//  The byte source is injected as `HubByteStream`, so every branch of this machine — a CONNACK
//  of 5, a packet split across three reads, a broker that closes mid-handshake — is reachable
//  from a test without a socket, a broker, or a network entitlement.
//

import Foundation

public actor MQTTSession {
    public static let maximumInbox = 256
    public static let maximumPacketId = 65_535

    /// What the pump is waiting to see. A value rather than a closure: reading actor state
    /// from a escaping `@Sendable` predicate is exactly the kind of race this file is
    /// arranged not to have.
    enum Wait {
        case connAck
        case subAck(Int)
        /// The packet id whose acknowledgement has *not* yet been seen.
        case publishDone(Int)
        /// Read whatever is already buffered, then stop at the deadline.
        case nothing
    }

    public struct Failure: Sendable, Equatable {
        public var reason: String
        public var connAckCode: Int?

        public init(reason: String, connAckCode: Int? = nil) {
            self.reason = reason
            self.connAckCode = connAckCode
        }
    }

    private let stream: HubByteStream
    private let options: MQTTConnectOptions
    private let readTimeout: TimeInterval
    private let keepAliveSeconds: Int

    private var buffer = Data()
    private var nextPacketId = 1
    private var inbox: [MQTTPublish] = []
    private var connected = false
    private var connAck: MQTTConnAckCode?
    private var lastSubAck: MQTTSubAck?
    private var awaitingAckFor: Int?
    private var failure: Failure?
    private var closed = false
    private var lastActivity = Date()
    private var inflightQoS2 = Set<Int>()

    public init(stream: HubByteStream, options: MQTTConnectOptions, readTimeout: TimeInterval = 8) {
        self.stream = stream
        self.options = options
        self.readTimeout = readTimeout
        self.keepAliveSeconds = max(30, options.keepAliveSeconds)
    }

    public var isConnected: Bool { connected }
    public var failureReason: String { failure?.reason ?? "" }
    public var endpoint: EdgeEndpoint { stream.endpoint }

    // MARK: - Lifecycle

    /// Opens the socket, sends `CONNECT`, and waits for a `CONNACK` of 0.
    public func connect() async -> Bool {
        guard !closed else { return false }
        if connected { return true }
        connAck = nil
        do {
            try await stream.start(timeout: readTimeout)
            try await stream.send(MQTTCodec.encodeConnect(options))
            lastActivity = Date()
        } catch {
            fail(String(describing: error))
            return false
        }
        await pump(until: .connAck, timeout: readTimeout)
        guard let code = connAck else {
            fail("broker did not answer CONNECT / no CONNACK arrived")
            return false
        }
        guard code == .accepted else {
            fail(code.explanation, connAckCode: code.rawValue)
            await abandon()
            return false
        }
        connected = true
        failure = nil
        return true
    }

    /// Subscribes to filters and waits for the matching `SUBACK`.
    ///
    /// Filters are checked before they leave the process: a filter beginning `$` reads the
    /// broker's own namespace, which §4.7 tells a client not to subscribe to, and anything
    /// the codec considers malformed must not reach the wire.
    public func subscribe(_ filters: [String], qos: Int = 0) async -> Bool {
        guard connected else { return false }
        let accepted = filters.filter { MQTTTopics.isValidFilter($0) && !$0.hasPrefix("$") }
        guard !accepted.isEmpty, accepted.count == filters.count else {
            fail("主题过滤器不合法 / rejected topic filter")
            return false
        }
        let packetId = allocatePacketId()
        lastSubAck = nil
        do {
            try await stream.send(MQTTCodec.encodeSubscribe(packetId: packetId, filters: accepted.map { ($0, qos) }))
            lastActivity = Date()
        } catch {
            fail(String(describing: error)); return false
        }
        await pump(until: .subAck(packetId), timeout: readTimeout)
        guard let ack = lastSubAck, ack.packetId == packetId else {
            fail("broker did not answer SUBSCRIBE / no SUBACK")
            return false
        }
        guard !ack.refused else {
            fail("订阅被拒绝 / the broker refused the subscription (0x80)")
            return false
        }
        return true
    }

    /// Publishes one message. QoS 1 waits for `PUBACK`, QoS 2 for the `PUBCOMP` at the end of
    /// the four-way handshake.
    public func publish(topic: String, payload: String, qos: Int = 0, retain: Bool = false) async -> Bool {
        guard connected else { return false }
        guard MQTTTopics.isValidTopicName(topic), !topic.hasPrefix("$") else {
            fail("主题名不合法 / invalid topic name: \(topic)")
            return false
        }
        return await publishData(Data(payload.utf8), topic: topic, qos: qos, retain: retain)
    }

    private func publishData(_ payload: Data, topic: String, qos: Int, retain: Bool) async -> Bool {
        let packetId = qos > 0 ? allocatePacketId() : 0
        // Registered before the write: a local broker can answer a QoS 1 publish in the same
        // segment it arrives in, and a pump that starts after the send could miss it.
        if qos > 0 { awaitingAckFor = packetId }
        do {
            try await stream.send(MQTTCodec.encodePublish(
                topic: topic, payload: payload, qos: qos, retain: retain, packetId: packetId
            ))
            lastActivity = Date()
        } catch {
            awaitingAckFor = nil
            fail(String(describing: error)); return false
        }
        guard qos > 0 else { return true }
        await pump(until: .publishDone(packetId), timeout: readTimeout)
        let settled = awaitingAckFor != packetId
        awaitingAckFor = nil
        guard settled else {
            fail("broker did not acknowledge the publish / no PUBACK for QoS \(qos)")
            return false
        }
        return true
    }

    /// Reads whatever the broker is holding, for a bounded window, without failing the
    /// session when there is nothing to read. The console poll calls this.
    @discardableResult
    public func poll(timeout: TimeInterval = 0.5) async -> Int {
        guard connected else { return 0 }
        if Date().timeIntervalSince(lastActivity) > TimeInterval(keepAliveSeconds / 2) {
            try? await stream.send(MQTTCodec.encodePingReq())
            lastActivity = Date()
        }
        let before = inbox.count
        await pump(until: .nothing, timeout: timeout)
        return inbox.count - before
    }

    /// Everything the broker pushed since the last drain, oldest first.
    public func drainInbox() -> [MQTTPublish] {
        defer { inbox.removeAll() }
        return inbox
    }

    public func disconnect() async {
        guard !closed else { return }
        if connected { try? await stream.send(MQTTCodec.encodeDisconnect()) }
        connected = false
        await stream.finish()
        closed = true
    }

    // MARK: - The pump

    /// Reads chunks and decodes whole packets until `target` is satisfied, the stream ends,
    /// or the deadline passes. A frame that cannot be decoded ends the session: a
    /// half-understood protocol is a protocol somebody else is describing.
    private func pump(until target: Wait, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !satisfied(target) {
            // Buffered first, so a broker that packs CONNACK and a retained PUBLISH into one
            // segment costs one read instead of two.
            decoding: while !satisfied(target) {
                switch MQTTCodec.decode(buffer) {
                case let .frame(frame, consumed):
                    buffer.removeFirst(min(consumed, buffer.count))
                    handle(frame)
                case .incomplete:
                    break decoding
                case let .rejected(error):
                    fail(String(describing: error))
                    await abandon()
                    return
                }
            }
            if satisfied(target) { return }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            do {
                guard let chunk = try await stream.receiveChunk(timeout: Swift.min(remaining, readTimeout)) else {
                    fail("broker closed the connection / the stream ended")
                    await abandon()
                    return
                }
                if chunk.isEmpty { continue }
                buffer.append(chunk)
                // A broker that streams faster than this node consumes must not be able to
                // grow its memory: the ceiling is the codec's own maximum packet size.
                if buffer.count > MQTTCodec.receiveCeilingBytes {
                    fail("inbound data exceeded the ceiling / unreadable stream")
                    await abandon()
                    return
                }
            } catch {
                fail(String(describing: error))
                await abandon()
                return
            }
        }
    }

    private func satisfied(_ target: Wait) -> Bool {
        switch target {
        case .connAck: return connAck != nil
        case let .subAck(packetId): return lastSubAck?.packetId == packetId
        case let .publishDone(packetId): return awaitingAckFor != packetId
        case .nothing: return false
        }
    }

    private func handle(_ frame: MQTTInboundFrame) {
        switch frame {
        case let .connAck(_, code, _):
            // A code outside the 0…5 table is still a refusal, and naming it by number beats
            // mapping it onto the nearest thing this client knows.
            connAck = code ?? .notAuthorized
        case let .publish(message):
            acknowledgeInbound(message)
        case let .pubAck(packetId):
            if awaitingAckFor == packetId { awaitingAckFor = nil }
        case let .pubRec(packetId):
            if awaitingAckFor == packetId {
                inflightQoS2.insert(packetId)
                sendQuietly(try? MQTTCodec.encodePubRel(packetId: packetId))
            }
        case let .pubRel(packetId):
            inflightQoS2.remove(packetId)
            sendQuietly(try? MQTTCodec.encodePubComp(packetId: packetId))
        case let .pubComp(packetId):
            inflightQoS2.remove(packetId)
            if awaitingAckFor == packetId { awaitingAckFor = nil }
        case let .subAck(ack):
            lastSubAck = ack
        case .unsubAck:
            lastSubAck = nil
        case .pingReq, .pingResp:
            break
        case .disconnect:
            // §3.14: the broker is ending the session. Nothing here may pretend otherwise.
            connected = false
        }
    }

    /// Acknowledges an inbound publish at its QoS, then keeps the message. The order is the
    /// point: acking before storing tells the broker it may forget a message this node has not
    /// yet recorded.
    private func acknowledgeInbound(_ message: MQTTPublish) {
        switch message.qos {
        case 1: sendQuietly(try? MQTTCodec.encodePubAck(packetId: message.packetId))
        case 2: sendQuietly(try? MQTTCodec.encodePubRec(packetId: message.packetId))
        default: break
        }
        while inbox.count >= Self.maximumInbox { inbox.removeFirst() }
        inbox.append(message)
    }

    /// Fire-and-forget for the acknowledgement path only — a failed PUBACK is a retried
    /// PUBLISH from the broker, not a lost message.
    private func sendQuietly(_ data: Data?) {
        guard let data, !closed else { return }
        Task { [stream] in
            try? await stream.send(data)
        }
    }

    private func allocatePacketId() -> Int {
        defer { nextPacketId = nextPacketId >= Self.maximumPacketId ? 1 : nextPacketId + 1 }
        return nextPacketId
    }

    private func fail(_ reason: String, connAckCode: Int? = nil) {
        if failure == nil { failure = Failure(reason: reason, connAckCode: connAckCode) }
        connected = false
    }

    private func abandon() async {
        connected = false
        await stream.finish()
        closed = true
    }
}

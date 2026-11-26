//
//  MQTTByteStream.swift
//  PopopxMacNode — the one raw socket the node opens on its own.
//
//  An MQTT broker is configured as a host and a port rather than a URL, so this
//  is the only bridge in the hub directory that speaks TCP directly. Everything
//  above it belongs to somebody else: the policy that admitted the address lives
//  in `EdgeBoundary`, the framing lives in `MQTTPacket`, and what is left here is
//  mechanics — dial, read, write, hang up.
//
//  **The invariant this file protects: nothing here re-decides where the socket
//  may go.** The allow-list ran on the literal the operator typed, before this
//  type was ever handed an `EdgeEndpoint`, and it is re-asserted at the socket
//  boundary below — not because a second look can catch a case the first missed,
//  but because a socket is the last place a bug elsewhere still costs a packet.
//  What this file will not do is *resolve* anything. Asking `getaddrinfo` whether
//  a name is public is precisely the hole `EdgeBoundary` documents: a resolver
//  that can lie, and a record that answers `127.0.0.1` on the second look. So the
//  host string goes to `NWConnection` untouched, exactly as the guard left it
//  (loopback, RFC 1918, ULA, or a `.local` name that mDNS answers on the link),
//  and the re-check reads the recorded `hostClass` and nothing else.
//
//  **The other thing worth reading closely is the continuation discipline.**
//  `NWConnection` completes on a queue while this API is `async`, so every
//  pending operation owns a `Waiter` holding one `CheckedContinuation`, and only
//  `workQueue` may touch it. `take()` removes the continuation from the waiter —
//  and cancels its deadline — before anybody may resume it, so "exactly once" is
//  structural rather than something to verify: the state handler, the completion
//  handler, the deadline and a task cancellation can race freely and the first one
//  to `take()` wins. Two cases are not covered by `take()`, and both are settled
//  here rather than left to chance:
//
//  * A *second* `receiveChunk` while the first is still owed. Network.framework
//    would answer whichever read it likes and the other continuation could never
//    be resumed, so `armRead` refuses it loudly instead of orphaning a waiter.
//  * Every path that ends the stream — the peer's FIN, an `NWError`, a failed
//    connect, a task cancellation, `finish()` — goes through `endStream(_:)`,
//    which is the only writer of `ending` and calls `serveRead()`. A pending read
//  therefore always gets an answer: the bytes it waited for, exactly one `nil`, or
//  a thrown reason. Nothing can be left holding a continuation over a dead socket.
//
//  Chunks are deliberately unframed. An MQTT packet carries a variable-length
//  remaining-length field, so it can straddle two TCP segments or arrive as five
//  packets in one read; framing is `MQTTPacket`'s decision and the cap here is
//  only the buffer the kernel may fill.
//

import Foundation
import Network

// MARK: - Stream

/// A live TCP channel to an already-admitted broker endpoint, as bytes.
///
/// The single `NWConnection` is built at initialisation and dialled by
/// `start(timeout:)`. `finish()` ends the stream for good: there is no reconnect
/// here, because reconnecting is a new permission decision and belongs to the
/// caller.
public final class MQTTByteStream: HubByteStream, @unchecked Sendable {

    // MARK: Wire limits

    /// The `maximumLength` handed to `NWConnection.receive`.
    ///
    /// 64 KB: an MQTT `PUBLISH` tops out just under that at the spec's own
    /// remaining-length ceiling, and a broker that backlogs — a burst of retained
    /// messages right after CONNACK — is drained by the caller looping, not by a
    /// bigger buffer here. It is also the cap the console's read pump uses, so a
    /// parked socket costs the node the same 64 KB whichever direction it arrived from.
    static let maxChunkBytes = 64 * 1_024

    /// One serial queue for this socket.
    ///
    /// `NWConnection` requires *a* callback queue and guarantees the callbacks on it
    /// are serial, so every piece of mutable state below — the phase, the three
    /// waiters, the EOF bookkeeping — is confined to it. That is what makes the
    /// `@unchecked Sendable` honest, and it is the shape `EventKitCalendarGateway`
    /// already uses in this package. Nothing here blocks the queue: every hand-off
    /// is a continuation, never a `wait()`, so an `async` caller on a cooperative
    /// thread and an `actor` bridge are both safe.
    static let workQueue = DispatchQueue(label: "chat.popopx.macnode.mqtt.stream", qos: .utility)

    /// The admitted target, decision included. Nothing downstream can swap the host,
    /// because this is the only place the address is read from.
    public let endpoint: EdgeEndpoint

    private let socket: NWConnection

    private var phase = Phase.setup

    /// `nil` once the continuation it held was taken, so a second settlement of the
    /// same waiter is a no-op rather than a crash.
    private var connectWaiter: Waiter<Void>?
    private var pendingRead: Waiter<Data?>?
    private var pendingSend: Waiter<Void>?

    /// Why the stream is over, or `nil` while it is still live. The first reason
    /// recorded is the one kept: a `cancelled` state echoing a `failed` one is not
    /// a new event.
    private var ending: Ending?

    /// `true` once the `nil` that ends the caller's read loop has been handed out.
    private var nilDelivered = false

    /// `true` between `receive(...)` and its callback, so at most one read is ever
    /// outstanding on the socket.
    private var readInFlight = false

    /// Bytes that arrived for a read whose deadline had already answered it. They
    /// are the caller's next chunk, not a lost frame.
    private var stashed = Data()

    // MARK: - Lifecycle

    /// Wraps an endpoint from `EdgeBoundary.resolve(host:port:)`.
    ///
    /// Throws `HubLinkError.invalidTarget` for a target this stream will not dial —
    /// a wrong scheme, a port that is not a port, an address class outside loopback
    /// and the private ranges. `start(timeout:)` runs the same check at the socket.
    public init(endpoint: EdgeEndpoint) throws {
        if let refusal = Self.refusal(for: endpoint) { throw refusal }
        // `refusal` has already put the port inside `1...65_535`, so this narrowing
        // cannot trap — and `clamping` means it could not trap even if the bounds
        // above were ever edited, which is the only way a hand-built endpoint gets
        // as far as a socket here.
        guard let service = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else {
            throw HubLinkError.invalidTarget("端口越界 / port out of range: \(endpoint.port)")
        }
        self.endpoint = endpoint

        // `NWParameters.tcp`, with no other opinion added.
        //
        // Deliberately *not* set: `requiredInterfaceType`, because a LAN broker is on
        // `en0` and pinning an interface would be a policy this file has no mandate to
        // make; `allowLocalEndpointReuse`, because a dialled socket is not a listener
        // and quietly taking a port nobody released is not a trade the node wants; and
        // `requiredLocalEndpoint`, because binding through an address we would first
        // have to compute is a second, resolvable opinion about the same decision.
        // `includePeerInfo` has no place to go either — this SDK's `NWParameters` does
        // not expose it — and nothing here needs the peer address, since the one
        // answer that matters was produced on the literal before this file existed.
        self.socket = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                   port: service,
                                   using: .tcp)
    }

    /// Dials the broker and waits for the path.
    ///
    /// Throws `.invalidTarget` for a target outside the allow-list,
    /// `.alreadyConnected` if called twice (including a second call while the first
    /// is still dialling), `.connectFailed` for a `.failed` or `.waiting` state and
    /// `.timedOut` if the deadline passes first.
    public func start(timeout: TimeInterval) async throws {
        let socket = self.socket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = Waiter<Void>(timeout: timeout, continuation: continuation)
                Self.workQueue.sync { self.armStart(waiter) }
            }
        } onCancel: {
            Self.workQueue.async { socket.cancel() }
        }
    }

    /// The next slice of the stream, or `nil` once — and only once — the peer is
    /// gone.
    ///
    /// Throws `.notConnected` before `start`, `.timedOut` when the deadline passes
    /// with nothing received, `.readFailed` for a broken socket, for a read after
    /// the `nil` has already been delivered, and for a second concurrent read.
    public func receiveChunk(timeout: TimeInterval) async throws -> Data? {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                let waiter = Waiter<Data?>(timeout: timeout, continuation: continuation)
                Self.workQueue.sync { self.armRead(waiter) }
            }
        } onCancel: {
            // Cancelling the socket is the only way to retract a read
            // Network.framework has already accepted, and a cancelled socket has
            // nothing left to give: the waiter settles as ended, exactly as a
            // deliberate `finish()` would.
            Self.workQueue.async { self.hangUp("this node hung up (the read was cancelled)") }
        }
    }

    /// Writes the whole buffer and returns once the kernel has taken it.
    ///
    /// Throws `.notConnected` before `start` and `.writeFailed` for anything the
    /// socket could not put on the wire.
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // A write carries no deadline of its own: it is bounded by TCP, and a
            // broker that stops taking bytes is a broker whose socket fails, which
            // reaches `noteSend` with a reason instead.
            let waiter = Waiter<Void>(timeout: 0, continuation: continuation)
            Self.workQueue.sync { self.armSend(waiter, data: data) }
        }
    }

    /// Hangs up for good. Idempotent, safe from any thread, and the reason a
    /// pending `receiveChunk` resolves to `nil` instead of outliving its socket.
    public func finish() async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            Self.workQueue.async {
                self.hangUp("this node hung up")
                resume.resume()
            }
        }
    }

    // MARK: - The socket-boundary check

    /// The allow-list, re-asserted at the place a packet actually leaves.
    ///
    /// `nil` means "admissible". A `.local` name arrives here as
    /// `hostClass == .privateNetwork` and stays a name: it is answered by mDNS on
    /// the link, which is the one resolution `EdgeBoundary` trusts. Everything the
    /// guard could not place — `.linkLocal`, `.ambiguous`, `.unresolvedName`,
    /// `.publicAddress` — is refused, including when a hand-built endpoint somehow
    /// carries one of them.
    static func refusal(for endpoint: EdgeEndpoint) -> HubLinkError? {
        guard endpoint.scheme == "tcp" else {
            return HubLinkError.invalidTarget(
                "MQTT 传输仅接受 tcp 端点 / this transport only dials tcp endpoints, got \(endpoint.origin)")
        }
        guard (1...65_535).contains(endpoint.port) else {
            // Names the endpoint as well as the port: this refusal reaches the audit
            // log on its own, and "port out of range: 0" says nothing about which
            // configured broker was refused.
            return HubLinkError.invalidTarget(
                "端口越界 / port out of range: \(endpoint.port) for \(endpoint.origin)")
        }
        switch endpoint.hostClass {
        case .loopback, .privateNetwork:
            return nil
        case .publicAddress, .unresolvedName, .linkLocal, .ambiguous:
            return HubLinkError.invalidTarget(
                "套接字边界仅拨回环与私有网段 / the socket boundary only dials loopback or private ranges, refusing \(endpoint.hostClass.rawValue) \(endpoint.literal):\(endpoint.port)")
        }
    }

    // MARK: - State

    enum Phase {
        case setup, connecting, ready, finished
    }

    /// Why the stream ended, and which answer that obliges a read to give.
    struct Ending {
        /// `true` when the peer — or this node — closed the stream cleanly, so the
        /// next read owes one `nil`. `false` for a broken socket, which owes a
        /// thrown reason: a quiet `nil` there would let the caller decode a half
        /// frame and report it as a message.
        let clean: Bool
        /// The `NWError` description, or our own words for a hang-up. Carried as a
        /// `String` because `NWError` is not `Sendable` and does not leave its queue.
        let message: String
    }

    /// What one `receive` callback reported, decided from its arguments alone so
    /// nothing but a value crosses onto `workQueue`.
    enum ReadSlice {
        case bytes(Data)
        case closed
        case broken(String)
    }

    /// A FIN is reported as `content == nil` with `isComplete` set; the codes below
    /// are the ways a reset or a local hang-up surface instead. Anything else is a
    /// real read failure, and the buffer that did arrive is handed back untouched.
    static func slice(of content: Data?, final isFinal: Bool, error: NWError?) -> ReadSlice {
        guard let error else {
            if let content, !content.isEmpty { return .bytes(content) }
            return isFinal ? .closed : .bytes(Data())
        }
        switch error {
        case .posix(let code) where code == .ECONNRESET || code == .ECANCELED || code == .EPIPE:
            return .closed
        default:
            return .broken(error.localizedDescription)
        }
    }

    // MARK: - Plumbing (`workQueue` only)

    private func armStart(_ waiter: Waiter<Void>) {
        if let refusal = Self.refusal(for: endpoint) {
            settle(waiter, with: .failure(refusal))
            return
        }
        if let ending {
            // The stream is over for good, and a reconnect is a new permission
            // decision: it belongs to a new `MQTTByteStream`, not to a second call
            // on this one.
            settle(waiter, with: .failure(ending.clean
                ? HubLinkError.peerClosed
                : HubLinkError.connectFailed(ending.message)))
            return
        }
        guard phase == .setup else {
            // `.connecting` included: a second `start` while the first is still
            // dialling is the same mistake as calling it after it came up.
            settle(waiter, with: .failure(HubLinkError.alreadyConnected))
            return
        }
        phase = .connecting
        connectWaiter = waiter
        socket.stateUpdateHandler = { [weak self] state in
            // `NWConnection.State` is an enum of `Sendable` cases, so the state
            // itself may cross; its `NWError` is unpacked into a `String` on this
            // queue, as the console's read pump does.
            guard let self else { return }
            Self.workQueue.async { self.noteState(state) }
        }
        socket.start(queue: Self.workQueue)
        waiter.deadline = Self.deadline(after: waiter.timeout) { [weak self] in
            self?.noteStartOverdue()
        }
    }

    private func armRead(_ waiter: Waiter<Data?>) {
        guard phase != .finished else {
            // Registered rather than answered here, so the one EOF rule below
            // decides: a clean end still owes exactly one `nil`, a broken one owes
            // a thrown reason, and stashed bytes come first either way.
            pendingRead = waiter
            serveRead()
            return
        }
        guard phase == .ready else {
            resumeRead(waiter, with: .failure(HubLinkError.notConnected))
            return
        }
        guard waiter.timeout >= 0 else {
            resumeRead(waiter, with: .failure(HubLinkError.timedOut(waiter.timeout)))
            return
        }
        guard pendingRead == nil else {
            resumeRead(waiter, with: .failure(HubLinkError.readFailed(
                "上一个 receiveChunk 仍欠其调用方 / a previous receiveChunk on this stream is still owed; read it from one task")))
            return
        }
        if !stashed.isEmpty {
            let content = stashed
            stashed = Data()
            resumeRead(waiter, with: .success(content))
            return
        }
        pendingRead = waiter
        waiter.deadline = Self.deadline(after: waiter.timeout) { [weak self] in
            self?.noteReadOverdue()
        }
        issueRead()
    }

    /// The only call site of `NWConnection.receive`.
    ///
    /// Exactly one read is outstanding on the socket at a time: a second concurrent
    /// `receive` would let Network.framework answer whichever callback it liked and
    /// leave the other waiter stranded, so this returns quietly when one is already
    /// in flight — that callback will serve the waiter `armRead` just registered.
    private func issueRead() {
        guard phase == .ready, pendingRead != nil, !readInFlight else { return }
        readInFlight = true
        socket.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunkBytes) { [weak self] content, _, isFinal, error in
            let slice = Self.slice(of: content, final: isFinal, error: error)
            guard let self else { return }
            Self.workQueue.async { self.noteRead(slice) }
        }
    }

    private func armSend(_ waiter: Waiter<Void>, data: Data) {
        if let ending {
            settle(waiter, with: .failure(HubLinkError.writeFailed(ending.message)))
            return
        }
        guard phase == .ready else {
            // `.setup` and `.connecting`: the caller has to hear that the link is
            // not there yet, not that its bytes vanished into a half-open socket.
            settle(waiter, with: .failure(HubLinkError.notConnected))
            return
        }
        pendingSend = waiter
        socket.send(content: data, completion: .contentProcessed { [weak self] error in
            // `.contentProcessed` is the only content-complete callback this SDK's
            // `SendCompletion` offers, and it means the kernel has the bytes.
            let reason = error.map { $0.localizedDescription }
            guard let self else { return }
            Self.workQueue.async { self.noteSend(reason) }
        })
    }

    /// The single EOF-and-bytes rule, and the only place a registered read is
    /// answered other than `noteRead`.
    private func serveRead() {
        guard let waiter = pendingRead else { return }
        if !stashed.isEmpty {
            pendingRead = nil
            let content = stashed
            stashed = Data()
            resumeRead(waiter, with: .success(content))
            return
        }
        guard let ending else { return }
        pendingRead = nil
        if ending.clean, !nilDelivered {
            resumeRead(waiter, with: .success(nil))
        } else {
            resumeRead(waiter, with: .failure(HubLinkError.readFailed(ending.message)))
        }
    }

    /// Records why the stream is over and answers anybody waiting on it. First
    /// reason wins; `serveRead()` runs even when the reason was already known, so a
    /// waiter registered while the news was landing is never left hanging.
    private func endStream(_ reason: Ending) {
        if ending == nil { ending = reason }
        phase = .finished
        serveRead()
    }

    /// Ends the stream and gives up on everything still owed an answer on it.
    private func closeOut(_ reason: Ending) {
        socket.cancel()
        settle(pendingSend, with: .failure(HubLinkError.writeFailed(reason.message)))
        pendingSend = nil
        endStream(reason)
    }

    /// The one place a read continuation is resumed. Consuming it through `take()`
    /// is what makes the exactly-once rule hold for reads as it does for the other
    /// two operations.
    private func resumeRead(_ waiter: Waiter<Data?>, with outcome: Result<Data?, any Error>) {
        guard let continuation = waiter.take() else { return }
        if case .success(nil) = outcome { nilDelivered = true }
        continuation.resume(with: outcome)
    }

    private func settle(_ waiter: Waiter<Void>?, with outcome: Result<Void, any Error>) {
        guard let waiter, let continuation = waiter.take() else { return }
        continuation.resume(with: outcome)
    }

    /// `hangUp` is what `finish()` and a cancelled read both mean: our decision,
    /// not the peer's, and the stream is over for good.
    private func hangUp(_ message: String) {
        settle(connectWaiter, with: .failure(HubLinkError.peerClosed))
        connectWaiter = nil
        settle(pendingSend, with: .failure(HubLinkError.writeFailed(message)))
        pendingSend = nil
        socket.cancel()
        endStream(Ending(clean: true, message: message))
    }

    private func noteState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard phase == .connecting else { return }
            phase = .ready
            settle(connectWaiter, with: .success(()))
            connectWaiter = nil
        case .waiting(let error):
            // A path that cannot be built yet is not a failure, but it is not a
            // broker either, and the node does not keep dialling behind a deadline.
            guard phase == .connecting else { return }
            let reason = error.localizedDescription
            settle(connectWaiter, with: .failure(HubLinkError.connectFailed(reason)))
            connectWaiter = nil
            closeOut(Ending(clean: false, message: reason))
        case .failed(let error):
            let reason = error.localizedDescription
            settle(connectWaiter, with: .failure(HubLinkError.connectFailed(reason)))
            connectWaiter = nil
            closeOut(Ending(clean: false, message: reason))
        case .cancelled:
            settle(connectWaiter, with: .failure(HubLinkError.connectFailed("the socket was cancelled before it opened")))
            connectWaiter = nil
            endStream(Ending(clean: true, message: "this node closed the socket"))
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func noteRead(_ slice: ReadSlice) {
        readInFlight = false
        switch slice {
        case .bytes(let content):
            guard !content.isEmpty else {
                // A zero-length, unfinished slice is not news: keep the waiter
                // armed on its original deadline and read again rather than handing
                // the caller an empty chunk it has to loop over.
                issueRead()
                return
            }
            guard let waiter = pendingRead else {
                // The deadline answered this read already. Nothing is lost: the
                // bytes wait here for the next `receiveChunk`, which is then served
                // without a second `receive` on the socket.
                stashed.append(content)
                return
            }
            pendingRead = nil
            resumeRead(waiter, with: .success(content))
        case .closed:
            closeOut(Ending(clean: true, message: "the broker closed the stream"))
        case .broken(let reason):
            closeOut(Ending(clean: false, message: reason))
        }
    }

    private func noteSend(_ reason: String?) {
        guard let waiter = pendingSend else { return }
        pendingSend = nil
        guard let reason else {
            settle(waiter, with: .success(()))
            return
        }
        // A failed write means the socket is not carrying anything, and `send` is
        // not allowed to report a half-written CONNECT as delivered.
        settle(waiter, with: .failure(HubLinkError.writeFailed(reason)))
        closeOut(Ending(clean: false, message: reason))
    }

    private func noteStartOverdue() {
        guard phase == .connecting, let waiter = connectWaiter else { return }
        connectWaiter = nil
        settle(waiter, with: .failure(HubLinkError.timedOut(waiter.timeout)))
        closeOut(Ending(clean: false, message: "the broker never answered the connect"))
    }

    private func noteReadOverdue() {
        guard let waiter = pendingRead else { return }
        pendingRead = nil
        // The socket stays as it was: a broker that is slow is not a broker that is
        // gone, and the next `receiveChunk` continues on the same connection.
        resumeRead(waiter, with: .failure(HubLinkError.timedOut(waiter.timeout)))
    }

    // MARK: - Deadlines

    /// A one-shot timer on *this* queue.
    ///
    /// The alternative — a `Task.sleep` — would put the overdue check on the
    /// cooperative pool and make it a second thread touching the same state. Here a
    /// deadline is just another serialised event, and cancelling it is only about
    /// not leaving work parked in GCD.
    static func deadline(after seconds: TimeInterval, _ overdue: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: overdue)
        workQueue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return item
    }
}

// MARK: - Waiters

/// One suspended operation, holding at most one continuation.
///
/// `withCheckedThrowingContinuation`'s body cannot hand a continuation to a queue
/// block and keep it alive on its own, so the continuation rides in one of these.
/// `take()` is the single operation that moves it out — and it cancels the
/// deadline in the same breath, since a settled waiter with a live timer is just a
/// second, later attempt to settle it. Whoever gets a non-nil answer from `take()`
/// is the only party allowed to resume.
private final class Waiter<Value> {
    let timeout: TimeInterval
    var deadline: DispatchWorkItem?
    private var continuation: CheckedContinuation<Value, any Error>?

    init(timeout: TimeInterval, continuation: CheckedContinuation<Value, any Error>) {
        self.timeout = timeout
        self.continuation = continuation
    }

    func take() -> CheckedContinuation<Value, any Error>? {
        deadline?.cancel()
        deadline = nil
        defer { continuation = nil }
        return continuation
    }
}

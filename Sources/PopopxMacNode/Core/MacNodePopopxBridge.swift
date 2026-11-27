//
//  MacNodePopopxBridge.swift
//  PopopxMacNode — module 2: the end-to-end encrypted signalling gateway.
//
//  This actor owns everything that talks to the local chat daemon:
//
//  * the daemon lifecycle (binary probe, resident `Process`, stderr ring buffer,
//    bounded crash-restart policy, clean SIGTERM→SIGKILL shutdown);
//  * the loopback WebSocket control channel (string command lines in, tagged
//    JSON out, correlation by our own `corrId`);
//  * the node identity (an Ed25519 keypair in `pairing/node.key`, mode 0600);
//  * pairing offers — the signed `PPXNODE1-…` credential behind wizard step 2;
//  * the paired-device whitelist, the only authorisation gate the node actually
//    controls;
//  * delivery of engine results back to iOS, with an on-disk outbox.
//
//  ── Wire facts this file is written against ────────────────────────────────
//
//  These come from the `popopx-chat` / `popopxmq` sources, not from upstream
//  folklore:
//
//  * The binary is `popopx-chat` started with
//    `--chat-server-port <N>`. There is **no default port** — without the flag
//    nothing binds, so we always pass `NodeWire.popopxControlPort`.
//  * We never pass `-e/--execute` (it runs one command and exits) and never pass
//    `--maintenance` (the chat core auto-starts before the server binds).
//  * `runLocalTCPServer` in `popopxmq/src/Popopx/Messaging/Transport/Server.hs`
//    is called with `Just "127.0.0.1"`: plain `ws://`, no TLS, **no authentication
//    of any kind**.
//  * One frame per JSON text object. Request: `{"corrId":"1","cmd":"/_connect 1"}`
//    — `cmd` is a *command line string*, not a JSON object.
//  * Response: `{"corrId":"1","resp":{"type":"<tag>", …flat record fields…}}`.
//    `type` is a sibling key of the payload and there is no `data` wrapper. Empty
//    records look like `{"type":"chatStarted"}`. Haskell `Maybe` fields are
//    *absent* when `Nothing`, so every read here is optional.
//  * Pushed events carry **no `corrId` key** (`Server.hs` uses `corrId = Nothing`
//    with `omitNothingFields = True`). The presence of `corrId` is therefore the
//    only discriminator between a reply and an event.
//  * There is no init/auth/version handshake: the server sends nothing on connect.
//    Correlation is entirely ours.
//  * The invitation scheme is `popopx:/` (share form `https://popopx.chat/`).
//    `simplex://ssmp/#/vi/…` has zero hits in these two repositories.
//
//  ── Threat model (read this before weakening anything) ─────────────────────
//
//  The control socket is loopback-only but unauthenticated, so *any* process the
//  user runs can attach to it and read or drive the chat core as that user. That
//  is a property of the daemon and cannot be fixed from here, so the real
//  admission control lives in this file:
//
//  1. A device is trusted only if it arrived through an invitation link we minted
//     ourselves (`/_connect 1`) while a signed, one-time, 15-minute offer was
//     live. Nothing else can manufacture that.
//  2. Commands reach the engines only when their sender resolves to a contact in
//     the persisted whitelist. Everything else is dropped, counted, and logged by
//     payload **hash** only — payload text may carry user data.
//  3. The pairing credential is signed with the node Ed25519 key, so a QR that did
//     not come from *this* node fails verification before anything is trusted.
//  4. Revocation removes the whitelist entry, which removes all authority. It does
//     not delete the SMP connection — see `revokeDevice(publicKey:)`.
//
//  Accepted limitation, surfaced in the event log on every start: a malicious
//  local process running as the same user can already read what the node reads.
//  The whitelist defends against other devices, not against this machine.
//
//  Privacy red line: nothing here hard-codes a developer path, no key material is
//  ever logged, and every path reaching `lastError` or an event goes through
//  `AppPaths.anonymise(_:)`.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - JSON lens

/// Total read helpers for decoded control frames.
///
/// The daemon emits Haskell record fields with `Maybe` keys omitted, so a typed
/// `Decodable` per record would be brittle across minor versions and wrong about
/// missing keys. Everything stays an `Any` tree behind these functions, all of
/// which answer `nil`/`false` instead of throwing.
enum SBJSON {
    static func object(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }

    static func object(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return object(from: data)
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func field(_ value: Any?, _ key: String) -> Any? {
        dictionary(value)?[key]
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            // `connId` and `contactId` arrive as numbers in some builds; a JSON
            // number must never read back as "42.0".
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    static func text(_ value: Any?, _ key: String) -> String? {
        string(field(value, key))
    }

    static func integer(_ value: Any?, _ key: String) -> Int? {
        if let number = field(value, key) as? NSNumber { return number.intValue }
        return Int(string(field(value, key)) ?? "")
    }

    /// The `type` sibling key carrying the Haskell constructor tag.
    static func tag(_ value: Any?) -> String? {
        string(field(value, "type"))
    }

    /// Compact re-encoding of a subtree — needed when a whole record is embedded
    /// into a command line, such as the `json` argument of `/_send`.
    static func serialized(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: writeOptions) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Depth-bounded search for the first value under `key`.
    ///
    /// The fork nests its records (`chatInfo.direct.contact.contactId`,
    /// `chatItem.chatDir.directRcv.fromChat.contactId`, …) and the nesting moved
    /// between releases, so a bounded DFS is more faithful than one hard-coded
    /// path. Each call site documents the path it actually expects.
    static func first(_ key: String, in value: Any?, depth: Int = 0, limit: Int = 8) -> Any? {
        guard depth <= limit else { return nil }
        if let dictionary = dictionary(value) {
            if let hit = dictionary[key] { return hit }
            for childKey in dictionary.keys.sorted() {
                if let hit = first(key, in: dictionary[childKey], depth: depth + 1, limit: limit) { return hit }
            }
            return nil
        }
        if let array = array(value) {
            for child in array {
                if let hit = first(key, in: child, depth: depth + 1, limit: limit) { return hit }
            }
        }
        return nil
    }

    static func firstString(_ key: String, in value: Any?, limit: Int = 8) -> String? {
        string(first(key, in: value, limit: limit))
    }

    /// Collects every string in the subtree that looks like a connection link.
    static func linkCandidates(_ value: Any?, depth: Int = 0, limit: Int = 8, into bucket: inout [String]) {
        guard depth <= limit else { return }
        if let text = value as? String {
            if SBChatWire.looksLikeConnectionLink(text) { bucket.append(text) }
            return
        }
        if let dictionary = dictionary(value) {
            for key in dictionary.keys.sorted() {
                linkCandidates(dictionary[key], depth: depth + 1, limit: limit, into: &bucket)
            }
            return
        }
        if let array = array(value) {
            for child in array { linkCandidates(child, depth: depth + 1, limit: limit, into: &bucket) }
        }
    }

    /// Every distinct value under `key` that reads as a non-empty string.
    static func allStrings(_ key: String, in value: Any?, depth: Int = 0, limit: Int = 8, into bucket: inout Set<String>) {
        guard depth <= limit else { return }
        if let dictionary = dictionary(value) {
            for childKey in dictionary.keys.sorted() {
                let child = dictionary[childKey]
                if childKey == key, let text = string(child), !text.isEmpty {
                    bucket.insert(text)
                }
                allStrings(key, in: child, depth: depth + 1, limit: limit, into: &bucket)
            }
            return
        }
        if let array = array(value) {
            for child in array { allStrings(key, in: child, depth: depth + 1, limit: limit, into: &bucket) }
        }
    }
}

// MARK: - Correlated request plumbing

/// Outcome of one command line on the control socket.
enum SBReply {
    /// Tagged payload object, matched by `corrId`.
    case payload(Any?)
    /// `chatCmdError` / `noActiveUser` / `chatNotStarted` … already sanitised.
    case chatError(String)
    /// Transport-level problem (socket down, send threw, bridge stopping).
    case transport(String)
    /// No reply inside the budget; the registration is gone either way.
    case timedOut
}

/// One-shot resume box for a pending request.
///
/// The reply and its watchdog race, so the box keeps a value that arrives before
/// the waiter registers and ignores a second resume afterwards. `NSLock` rather
/// than an actor because it is written from the receive loop and from a watchdog
/// task concurrently.
final class SBReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: SBReply?
    private var waiters: [CheckedContinuation<SBReply, Never>] = []

    func deliver(_ reply: SBReply) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = reply
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: reply) }
    }

    func settle() async -> SBReply {
        await withCheckedContinuation { (continuation: CheckedContinuation<SBReply, Never>) in
            lock.lock()
            if let value = settled {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// One decoded control frame.
struct SBWireFrame {
    /// Absent for pushed events — the only discriminator the daemon gives us.
    let corrId: String?
    let payload: [String: Any]
}

/// One in-flight command line.
struct SBRegistration {
    let box: SBReplyBox
    let watchdog: Task<Void, Never>
}

/// A pushed event handed from the receive loop to the serial event worker.
///
/// The hand-off is not an optimisation, it is a deadlock guard: command replies
/// can only arrive through the receive loop, so an event handler that issues a
/// command must never run *inside* that loop.
struct SBEvent {
    let tag: String
    let payload: [String: Any]
}

/// JSON writing options shared by every outbound control-plane payload.
///
/// `.sortedKeys` keeps a signed body byte-stable (a re-encoded copy must produce the
/// same bytes or the signature stops verifying); `.withoutEscapingSlashes` keeps
/// `popopx:/` links and file paths readable in the audit log instead of `popopx:\/`.
private let writeOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

// MARK: - Wire codec

/// Command-line construction and frame parsing for the local chat daemon.
///
/// A stateless namespace, so the exact strings we put on the wire can be reviewed
/// in one place while the actor keeps to policy.
enum SBChatWire {
    /// The daemon binds loopback only. `NodeWire.consoleHost` carries the same
    /// literal but means the web console, so it is deliberately not reused here.
    static let loopbackHost = "127.0.0.1"

    /// The fork's own executable and nothing else, so a resident daemon is always
    /// one this node can speak to.
    static let binaryNames = ["popopx-chat"]

    /// A link becomes a command-line argument, so it must stay short and free of
    /// anything a shell or a Haskell argument parser could mis-handle.
    static let maximumLinkLength = 2_048
    static let forbiddenLinkCharacters: Set<Character> = ["\"", "'", "`", "\\", "$"]

    /// Version-10-ish grid at correction level M. Past this the modules get too
    /// small for a phone camera at arm's length.
    static let qrPayloadBudget = 700
    /// AES hard cap for byte-mode QR; beyond it the generator silently truncates.
    static let qrMaximumBytes = 2_900

    static let commandTimeout: TimeInterval = 20
    static let invitationTimeout: TimeInterval = 25
    static let fileReceiveTimeout: TimeInterval = 180
    static let handshakeTimeout: TimeInterval = 15
    static let connectTimeout: TimeInterval = 6

    static func webSocketURL(port: UInt16) -> URL? {
        URL(string: "ws://\(loopbackHost):\(port)/")
    }

    static func requestFrame(corrId: String, cmd: String) -> String {
        let body: [String: Any] = ["corrId": corrId, "cmd": cmd]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: writeOptions),
              let text = String(data: data, encoding: .utf8)
        else {
            // Total fallback: never send a half-built frame.
            return "{\"corrId\":\"\",\"cmd\":\"\"}"
        }
        return text
    }

    static func frame(from text: String) -> SBWireFrame? {
        guard let root = SBJSON.object(from: text), let dictionary = SBJSON.dictionary(root) else { return nil }
        let corrId = SBJSON.string(dictionary["corrId"])
        guard let payload = SBJSON.dictionary(dictionary["resp"]) else { return nil }
        return SBWireFrame(corrId: corrId, payload: payload)
    }

    /// Maps a reply payload onto an `SBReply` by recognising the error tags.
    static func reply(from payload: [String: Any]) -> SBReply {
        let tag = SBJSON.tag(payload) ?? ""
        if tag == "chatCmdError" || tag == "error" || tag == "chatNotStarted" || tag.hasSuffix("Error") {
            return .chatError(errorSummary(in: payload) ?? "chat core rejected the command")
        }
        return .payload(payload)
    }

    /// Flattens a tagged error tree into one loggable line.
    ///
    /// `popopx-chat` nests errors — `chatCmdError ▸ chatError ▸ errorType ▸
    /// noActiveUser` — and the useful tag is usually the *deepest* one, so this walks
    /// the whole subtree for `type` values instead of guessing a fixed depth. Command
    /// arguments are never included: they may carry file paths or user text.
    static func errorSummary(in payload: Any?) -> String? {
        var tags: [String] = []
        collectTypes(payload, depth: 0, into: &tags)
        var details: [String] = []
        for key in ["reason", "item", "user", "err"] {
            if let detail = SBJSON.firstString(key, in: payload, limit: 6), !detail.isEmpty {
                details.append(detail)
            }
        }
        let unique = (tags + details).reduce(into: [String]()) { acc, piece in
            if !piece.isEmpty, !acc.contains(piece) { acc.append(piece) }
        }
        return unique.isEmpty ? nil : sanitized(unique.joined(separator: " / "))
    }

    private static func collectTypes(_ value: Any?, depth: Int, into tags: inout [String]) {
        guard depth <= 8, let dictionary = SBJSON.dictionary(value) else { return }
        if let tag = SBJSON.string(dictionary["type"]), !tag.isEmpty { tags.append(tag) }
        for key in dictionary.keys.sorted() where key != "type" {
            collectTypes(dictionary[key], depth: depth + 1, into: &tags)
        }
    }

    /// `/_send @<contactId> json [{"msgContent":…,"mentions":{}}]`
    static func sendLine(contactId: String, items: [[String: Any]]) -> String? {
        guard !contactId.isEmpty, !items.isEmpty else { return nil }
        guard let json = SBJSON.serialized(items) else { return nil }
        return "/_send @\(contactId) json \(json)"
    }

    static func textItem(_ text: String) -> [String: Any] {
        [
            "msgContent": ["type": "text", "text": text],
            "mentions": [String: Any]()
        ]
    }

    /// `filePath` is a top-level key (the wire form of `fileSource.filePath`).
    static func fileItem(path: String, name: String) -> [String: Any] {
        [
            "filePath": path,
            "msgContent": ["type": "file", "text": name],
            "mentions": [String: Any]()
        ]
    }

    /// `/_create user <NewUser JSON>`.
    ///
    /// `Commands.hs:6685` parses the argument straight into `NewUser`
    /// (`{profile, pastTimestamp, userChatRelay, clientService}`, derived with
    /// `deriveJSON defaultJSON`) — there is no `"config"` envelope, and the three
    /// non-`Maybe` fields must be present or Aeson rejects the whole object.
    static func createUserLine(displayName: String) -> String {
        let name = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let body: [String: Any] = [
            "profile": ["fullName": name.isEmpty ? "POPOPX Node" : name, "displayName": name.isEmpty ? "POPOPX" : name],
            "pastTimestamp": false,
            "userChatRelay": false,
            "clientService": false
        ]
        let json = SBJSON.serialized(body) ?? "{\"pastTimestamp\":false,\"userChatRelay\":false,\"clientService\":false}"
        return "/_create user \(json)"
    }

    /// Anything fed to the daemon as a command-line argument must survive its
    /// whitespace tokenizer and must not be re-interpreted by a shell.
    static func isSafeArgument(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return !text.contains(where: { forbiddenLinkCharacters.contains($0) })
    }

    /// The invitation link is fed back into a command line, so it is validated.
    static func isSafeLink(_ link: String) -> Bool {
        isSafeArgument(link) && link.count <= maximumLinkLength
    }

    static func looksLikeConnectionLink(_ text: String) -> Bool {
        guard text.count >= 12, text.count <= maximumLinkLength else { return false }
        if text.hasPrefix("popopx:/") { return true }
        return text.hasPrefix("https://popopx.chat/") || text.hasPrefix("http://popopx.chat/")
    }

    /// The short link (`popopx:/i#<linkId>/<linkKey>`) is what the iOS QR reader
    /// expects; the full link stays available for long-press / manual paste.
    static func invitationLinks(in payload: [String: Any]) -> (full: String?, short: String?) {
        var bucket: [String] = []
        if let invitation = SBJSON.field(payload, "connLinkInvitation") {
            if let full = SBJSON.string(SBJSON.field(invitation, "connFullLink")) { bucket.append(full) }
            if let short = SBJSON.string(SBJSON.field(invitation, "connShortLink")) { bucket.append(short) }
            SBJSON.linkCandidates(invitation, into: &bucket)
        }
        SBJSON.linkCandidates(payload, into: &bucket)
        let unique = Set(bucket.filter { isSafeLink($0) })
        let ordered = unique.sorted { $0.count < $1.count }
        // The short link (`popopx:/i#…`) is what the iOS reader expects, so it wins
        // for both slots; the long `/invitation/` form is only a fallback for builds
        // that stop emitting it.
        let short = ordered.first { $0.hasPrefix("popopx:/i#") }
        let full = short ?? ordered.first { $0.contains("/invitation") || $0.contains("/contact") } ?? ordered.first
        return (full, short ?? full)
    }

    /// Documented shape `chatInfo.direct.contact.contactId`, then the same key
    /// wherever it hides (`chatItem.chatDir.directRcv.fromChat.contactId`).
    static func contactIdentifier(in node: Any?) -> String? {
        if let fromChatInfo = SBJSON.firstString("contactId", in: SBJSON.field(node, "chatInfo"), limit: 5) {
            return fromChatInfo
        }
        guard let found = SBJSON.firstString("contactId", in: node, limit: 6) else { return nil }
        return found.isEmpty ? nil : found
    }

    static func contactIdentifiers(in node: Any?) -> [String] {
        var bucket = Set<String>()
        SBJSON.allStrings("contactId", in: node, into: &bucket)
        return bucket.sorted()
    }

    /// Every path that leaves this actor towards a log line or `lastError`.
    static func sanitized(_ text: String) -> String {
        let oneLine = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return TextKit.truncate(AppPaths.anonymise(oneLine), to: 320)
    }
}

// MARK: - Stderr ring buffer

/// Lock-protected ring of the last N daemon stderr lines.
///
/// Fed from a `Pipe` readability handler (i.e. from a GCD queue), so it cannot be
/// an actor without turning every append into a hop. 200 lines holds a Haskell
/// backtrace while staying clear of unbounded memory.
final class SBLineRing: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []
    private var fragment = ""

    init(capacity: Int = 200) {
        self.capacity = max(16, capacity)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        fragment += String(decoding: data, as: UTF8.self)
        while let newline = fragment.firstIndex(of: "\n") {
            let line = String(fragment[fragment.startIndex..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            fragment.removeSubrange(fragment.startIndex...newline)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var tail = lines
        let dangling = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dangling.isEmpty { tail.append(dangling) }
        return tail
    }

    var tailText: String {
        snapshot().joined(separator: " | ")
    }
}

// MARK: - Node identity key material

/// The node's Ed25519 signing key and the pairing-code codec.
///
/// `Curve25519.Signing.Keys` (Ed25519, not X25519) because the credential has to
/// be publicly verifiable by iOS from the QR alone. The public key is the raw
/// 32-byte value in base64url — this protocol has no SPKI wrapper.
enum SBSigning {
    struct Identity {
        #if canImport(CryptoKit)
        let key: Curve25519.Signing.PrivateKey
        let publicRaw: Data

        var seed: Data? { key.rawRepresentation }
        func signature(for body: Data) -> Data? { try? key.signature(for: body) }
        #else
        let publicRaw: Data
        var seed: Data? { nil }
        func signature(for body: Data) -> Data? { nil }
        #endif

        var publicKeyBase64URL: String { TextKit.base64URL(publicRaw) }

        /// Stable, human-typable node id: truncated SHA-256 of the public key.
        var nodeId: String { Digest.short(publicRaw, length: 12).uppercased() }
    }

    #if canImport(CryptoKit)
    static func generate() -> Identity? {
        let key = Curve25519.Signing.PrivateKey()
        return Identity(key: key, publicRaw: key.publicKey.rawRepresentation)
    }

    static func restore(seed: Data) -> Identity? {
        guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return Identity(key: key, publicRaw: key.publicKey.rawRepresentation)
    }

    static func verify(publicKeyBase64URL: String, signatureBase64URL: String, body: Data) -> Bool {
        guard let raw = TextKit.base64URLDecode(publicKeyBase64URL), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = TextKit.base64URLDecode(signatureBase64URL)
        else { return false }
        return key.isValidSignature(signature, for: body)
    }
    #else
    static func generate() -> Identity? { nil }
    static func restore(seed: Data) -> Identity? { nil }
    static func verify(publicKeyBase64URL: String, signatureBase64URL: String, body: Data) -> Bool { false }
    #endif

    /// `PPXNODE1-<base64url(body)>.<base64url(sig)>`
    static func pairingCode(body: Data, signature: String) -> String {
        "\(NodeWire.pairingCodePrefix)-\(TextKit.base64URL(body)).\(signature)"
    }

    static func splitPairingCode(_ code: String) -> (body: Data, signature: String)? {
        let marker = "\(NodeWire.pairingCodePrefix)-"
        guard code.hasPrefix(marker) else { return nil }
        let tail = String(code.dropFirst(marker.count))
        guard let dot = tail.firstIndex(of: ".") else { return nil }
        let bodyPart = String(tail[tail.startIndex..<dot])
        let signaturePart = String(tail[tail.index(after: dot)...])
        guard !signaturePart.isEmpty, let body = TextKit.base64URLDecode(bodyPart), !body.isEmpty else { return nil }
        return (body, signaturePart)
    }

    /// The signed body. Creation sorts keys, but verification always uses the
    /// *stored* bytes rather than a re-encoded copy — re-encoding would break the
    /// signature on any formatting drift.
    static func offerBody(
        nodeId: String,
        publicKey: String,
        link: String,
        issuedAt: Date,
        expiresAt: Date
    ) -> Data? {
        let body: [String: Any] = [
            "v": NodeVersion.schemaRevision,
            "node": nodeId,
            "key": publicKey,
            "link": link,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "once": true
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: writeOptions)
        else { return nil }
        return data
    }

    static func bodyFields(_ body: Data) -> [String: Any]? {
        SBJSON.dictionary(SBJSON.object(from: body))
    }
}

// MARK: - Command parsing

/// Decoder for the `::popopx_sys::NODE_CMD::…` marker the iOS service account uses.
///
/// ⚠️ Cross-repo fact that must stay visible: iOS only silently parses signals
/// whose `KIND` is one of the eleven `PopopxCommerceSignalKind` cases
/// (`PopopxBadgeCreditsModels.swift:1084-1157`, splitting on the **first** `::`).
/// `NODE_CMD` is not one of them, so today a node command shows up as a *visible*
/// chat bubble on the phone, and someone has to decide to add the kind on the iOS
/// side. We do **not** change the wire format to work around that.
enum SBCommandCodec {
    struct Parsed {
        let serviceId: String
        let action: String
        let payload: String
    }

    /// Splits `serviceId::action::payload` after the marker, tolerating `::`
    /// inside the payload (JSON payloads legitimately contain `::`).
    static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body: String
        if trimmed.hasPrefix(NodeWire.commandPrefix) {
            body = String(trimmed.dropFirst(NodeWire.commandPrefix.count))
        } else if let range = trimmed.range(of: NodeWire.commandPrefix) {
            // Tolerant: the bubble may wrap the marker in markdown or a quote.
            body = String(trimmed[range.upperBound...])
        } else {
            return nil
        }
        let parts = splitOnFirstSeparators(body)
        guard parts.count == NodeWire.commandSegmentCount else { return nil }
        let serviceId = parts[0].trimmingCharacters(in: .whitespaces)
        let action = parts[1].trimmingCharacters(in: .whitespaces)
        let payload = parts[2]
        guard !serviceId.isEmpty, !action.isEmpty else { return nil }
        return Parsed(serviceId: serviceId, action: action, payload: payload)
    }

    /// Consumes only the first two `::`; everything after them stays intact.
    static func splitOnFirstSeparators(_ text: String) -> [String] {
        let separatorBudget = NodeWire.commandSegmentCount - 1
        var parts: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if parts.count < separatorBudget,
               text[index] == ":",
               next < text.endIndex,
               text[next] == ":"
            {
                parts.append(current)
                current = ""
                index = text.index(next, offsetBy: 1)
                continue
            }
            current.append(text[index])
            index = next
        }
        parts.append(current)
        return parts
    }

    /// Deterministic lock triggers, matched on the *raw* text: `🔒` / `LOCK_ALL` /
    /// `lock_all` must reach the sentinel engine with no model in the path.
    static func lockTrigger(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NodeWire.lockTriggers.first { $0 == trimmed }
    }

    /// The `NodeCommand` equivalent of `isDeterministic: true`. The frozen model
    /// exposes `isDeterministicLock` as a computed property, so carrying the
    /// trigger in `action` (with an empty payload) is the only faithful form.
    static func deterministicLock(trigger: String, senderPublicKey: String, receivedAt: Date) -> NodeCommand {
        NodeCommand(
            serviceId: EngineKind.phantomSentinel.rawValue,
            action: trigger,
            payload: "",
            senderPublicKey: senderPublicKey,
            receivedAt: receivedAt,
            authenticated: true
        )
    }
}

// MARK: - QR rendering

/// CoreImage QR renderer for the pairing payload.
enum SBQRCode {
    /// Carries a reason so the bridge can fill `lastError` instead of silently
    /// handing back a blank square.
    struct Output {
        let png: Data?
        let reason: String?
        let pixelSize: Int
    }

    /// The filter is rasterised at native module resolution (one pixel per
    /// module), then upscaled by an **integer** factor into the requested canvas
    /// with `interpolationQuality = .none`. Letting `CIContext` do the scaling
    /// would smooth the module edges and cost scan reliability.
    static func render(_ payload: String, pixelSize: Int) -> Output {
        let target = min(max(pixelSize, 128), 4_096)
        guard !payload.isEmpty else {
            return Output(png: nil, reason: "配对载荷为空 / pairing payload is empty", pixelSize: target)
        }
        guard let data = payload.data(using: .utf8) else {
            return Output(png: nil, reason: "配对载荷不是 UTF-8 / pairing payload is not UTF-8", pixelSize: target)
        }
        guard data.count <= SBChatWire.qrMaximumBytes else {
            return Output(
                png: nil,
                reason: "配对载荷 \(data.count) 字节，超过二维码上限 \(SBChatWire.qrMaximumBytes) / payload exceeds the QR byte limit",
                pixelSize: target
            )
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return Output(png: nil, reason: "CIQRCodeGenerator 不可用 / CoreImage filter unavailable", pixelSize: target)
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let generated = filter.outputImage else {
            return Output(png: nil, reason: "二维码生成失败 / generator returned no image", pixelSize: target)
        }
        let extent = generated.extent
        let modules = Int(extent.width.rounded())
        guard modules > 0 else {
            return Output(png: nil, reason: "二维码网格为零 / degenerate QR grid", pixelSize: target)
        }
        let renderer = CIContext()
        guard let native = renderer.createCGImage(generated, from: extent) else {
            return Output(png: nil, reason: "无法光栅化二维码 / could not rasterise the QR", pixelSize: target)
        }
        let factor = max(1, target / modules)
        let scaledSide = modules * factor
        // A QR only needs black on white, and `CGImageAlphaInfo.none` is a *valid*
        // bitmap format for a gray space only — asking for an RGB context without an
        // alpha channel makes `CGContext(...)` return NULL, which is exactly the
        // silent-failure mode this module is supposed to report instead.
        guard let canvas = CGContext(
            data: nil,
            width: target,
            height: target,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        else {
            return Output(png: nil, reason: "无法创建位图上下文 / bitmap context unavailable", pixelSize: target)
        }
        canvas.interpolationQuality = .none
        canvas.setFillColor(gray: 1.0, alpha: 1.0)
        canvas.fill(CGRect(x: 0, y: 0, width: target, height: target))
        let offset = max(0, (target - scaledSide) / 2)
        canvas.draw(native, in: CGRect(x: offset, y: offset, width: scaledSide, height: scaledSide))
        guard let composed = canvas.makeImage() else {
            return Output(png: nil, reason: "无法合成二维码 / QR composition failed", pixelSize: target)
        }
        let representation = NSBitmapImageRep(cgImage: composed)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return Output(png: nil, reason: "PNG 编码失败 / PNG encoding failed", pixelSize: target)
        }
        return Output(png: png, reason: nil, pixelSize: target)
    }
}

// MARK: - Persistence records

/// One row of `pairing/devices.json`.
struct SBPairedDevice: Codable {
    var publicKey: String
    var contactId: String
    var label: String
    var deviceModel: String?
    var pairedAt: Date
    var lastSeenAt: Date?
    var revoked: Bool
    /// Fingerprint of the offer this device arrived through (audit trail only).
    var pairedWithOffer: String?

    var modelDevice: PairedDevice {
        PairedDevice(
            publicKey: publicKey,
            label: label,
            deviceModel: deviceModel,
            pairedAt: pairedAt,
            lastSeenAt: lastSeenAt,
            revoked: revoked
        )
    }
}

/// On-disk document; wrapped so a future format change stays a `revision` bump.
struct SBDeviceDocument: Codable {
    var revision: Int
    var updatedAt: Date
    var devices: [SBPairedDevice]
}

/// One undelivered result in `outbox/`.
struct SBOutboxEntry: Codable {
    var result: CommandResult
    var serviceId: String
    var contactId: String?
    var queuedAt: Date
    var attempts: Int
    /// Never encoded: set from the file name after loading.
    var url: URL?

    private enum CodingKeys: String, CodingKey {
        case result, serviceId, contactId, queuedAt, attempts
    }
}

/// Total outcome of one wire send.
enum SBOutcome {
    case sent
    case failed(String)
}

/// Filesystem helpers shared by the persisted documents.
enum SBStore {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NodeJSON.decode(T.self, from: data)
    }

    /// Atomic write, `0600`, optional full file protection: the device list and
    /// the node key must not be world-readable, and a crash must not leave a
    /// half-written whitelist.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL, fileProtection: Bool) -> Bool {
        guard let data = NodeJSON.encodePretty(value) else { return false }
        return writeRaw(data, to: url, fileProtection: fileProtection)
    }

    @discardableResult
    static func writeRaw(_ data: Data, to url: URL, fileProtection: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileProtection {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            } else {
                try data.write(to: url, options: [.atomic])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

/// Fallback identity for callers that construct the bridge without one. The real
/// `publicKey`/`nodeId` always come from the node keypair, never from this value.
/// Public because it is the default argument of a public initialiser.
public func SBPlaceholderIdentity() -> NodeIdentity {
    NodeIdentity(
        nodeId: Digest.short(Data("popopx-node-unbootstrapped".utf8), length: 12).uppercased(),
        publicKey: "",
        displayName: Host.current().localizedName ?? "POPOPX Node"
    )
}

// MARK: - The bridge

/// 模块二. The frozen `NodeSignaling` surface plus the daemon and socket behind it.
///
/// Concurrency shape:
/// * one resident `Process` and one `URLSessionWebSocketTask`, supervised by a
///   single heartbeat task;
/// * three cooperating tasks: receive loop (frames → replies / event queue),
///   event worker (events → commands, safely blocked on replies), supervisor
///   (restart and reconnect);
/// * no `DispatchQueue.main` and no `DispatchSemaphore.wait` anywhere — parking a
///   cooperative thread would stall the whole pool, and in particular the receive
///   loop that has to deliver the reply an event handler is waiting for.
public actor MacNodePopopxBridge: NodeSignaling {
    // MARK: Collaborators

    private let settings: SettingsStore
    private let hub: ConsoleEventHub
    private let injectedIdentity: NodeIdentity
    private let fileManager = FileManager.default
    /// Ephemeral so no cookie or cache survives a restart; the socket is loopback.
    private let session: URLSession

    // MARK: Daemon state

    private var daemonProcess: Process?
    private var daemonState: DaemonState = .stopped
    private var binaryPath: String?
    private let stderrRing = SBLineRing(capacity: 200)
    private var controlPort: UInt16 = NodeWire.popopxControlPort
    private var restarts = 0
    private var daemonGeneration = 0
    private var daemonStartedAt: Date?
    private var relaunchTask: Task<Void, Never>?
    /// `true` when a socket we did not launch answered — a second copy of the chat
    /// CLI owns the port. Reusing it beats crash-looping against a busy port.
    private var externallyOwnedSession = false

    // MARK: Socket state

    private var running = false
    private var socket: URLSessionWebSocketTask?
    private var websocketConnected = false
    private var receiveTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<SBEvent>.Continuation?
    private var correlationCounter = 0
    private var pending: [String: SBRegistration] = [:]
    private var nextConnectAttempt = Date.distantPast
    private var reconnectAttempt = 0

    // MARK: Identity, pairing, whitelist

    private var bootstrapped = false
    private var keyPair: SBSigning.Identity?
    private var nodeIdentity: NodeIdentity?
    private var devices: [SBPairedDevice] = []
    private var contactIndex: [String: String] = [:]
    private var cachedOffer: PairingOffer?
    private var invitationContactId: String?
    /// Called after `/freceive` has written one inbound file into quarantine. The
    /// console owns what a file is for (an audio memo, in this build), so the
    /// bridge reports the path and does not interpret it.
    private var inboundFileHandler: (@Sendable (URL) async -> Void)?
    private var nodeProfileName: String?

    // MARK: Accounting

    private var startedAt: Date?
    private var acceptedCommands = 0
    private var rejectedCommands = 0
    private var ignoredUnpairedCount = 0
    private var deliveredResults = 0
    private var lastError: String?
    private var commandBacklog: [NodeCommand] = []
    private var subscribers: [UUID: AsyncStream<NodeCommand>.Continuation] = [:]
    /// `NodeCommand.id` → contactId, so a slow engine result still goes back to
    /// the device that asked for it, even after the phone went quiet.
    private var commandTargets: [String: String] = [:]

    private static let maximumFastRestarts = 3
    private static let restartBackoffs: [TimeInterval] = [2, 5, 15]
    private static let stableRunSeconds: TimeInterval = 30
    private static let addressInUseSignatures = ["already in use", "eaddrinuse"]
    private static let maximumBacklog = 64
    private static let outboxMaximumAge: TimeInterval = 30 * 24 * 3_600
    private static let iosKindGapNotice =
        "iOS 端尚未把 NODE_CMD 加入 PopopxCommerceSignalKind，因此节点指令当前会作为可见的聊天气泡显示，"
            + "需要在 iOS 侧补一个 kind / NODE_CMD is not yet a PopopxCommerceSignalKind on iOS, so node commands "
            + "still render as visible chat bubbles until iOS adds the kind"

    // MARK: Init

    public init(
        settings: SettingsStore = .shared,
        hub: ConsoleEventHub = .shared,
        identity: NodeIdentity = SBPlaceholderIdentity()
    ) {
        self.settings = settings
        self.hub = hub
        self.injectedIdentity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SBChatWire.commandTimeout + 10
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [:]
        self.session = URLSession(configuration: configuration)
    }

    /// Actor initialisers cannot await, and reading the key file, the device list
    /// and the cached offer is blocking I/O — so it happens here, once, and every
    /// protocol entry point awaits it first.
    private func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            try AppPaths.ensureLayout()
        } catch {
            // Every later persistence step would fail too, so say it once, loudly.
            lastError = SBChatWire.sanitized("无法建立目录结构 / could not create the node layout: \(error.localizedDescription)")
            publish("\(lastError ?? "")", level: .error)
        }
        prepareIdentity()
        loadDevices()
        loadOffer()
        resolveBinary()
    }

    // MARK: - NodeSignaling

    /// Installs the post-transfer hook. The file has already passed `/freceive`;
    /// the handler receives a path inside quarantine and must re-check it.
    public func setInboundFileHandler(_ handler: (@Sendable (URL) async -> Void)?) {
        inboundFileHandler = handler
    }

    public func start() async {
        await bootstrap()
        guard !running else {
            publish("信令网关已在运行 / bridge already running", level: .warning)
            return
        }
        running = true
        startedAt = Date()
        restarts = 0
        reconnectAttempt = 0
        externallyOwnedSession = false
        startEventWorker()

        publish(
            "启动加密信令网关 / starting the signalling bridge on \(SBChatWire.loopbackHost):\(controlPort)",
            level: .notice,
            payload: ["port": .int(Int(controlPort)), "nodeId": .string(currentNodeId())]
        )
        publish(Self.iosKindGapNotice, level: .warning, channel: .pairing)

        if let launchPath = binaryPath {
            await launchDaemon(at: launchPath)
        } else {
            daemonState = .missingBinary
            lastError = "未找到 " + Self.binaryHint +
                " 可执行文件 — 拒绝假装在运行 / no daemon binary found; refusing to report a live session"
            publish(
                "\(lastError ?? "")；安装后网关会自动接管 / install it and the bridge will take over",
                level: .error
            )
        }

        supervisorTask = Task { [weak self] in
            guard let self else { return }
            await self.supervise()
        }
    }

    private static var binaryHint: String { SBChatWire.binaryNames.joined(separator: " / ") }

    public func stop() async {
        await bootstrap()
        guard running else {
            if daemonState != .stopped { daemonState = .stopped }
            return
        }
        running = false
        publish("停止信令网关 / stopping the signalling bridge", level: .notice)

        receiveTask?.cancel()
        receiveTask = nil
        supervisorTask?.cancel()
        supervisorTask = nil
        relaunchTask?.cancel()
        relaunchTask = nil

        // Release every awaiter before tearing the socket down, so no engine is
        // left suspended on a command that can never be answered.
        failAllPending("桥接已停止 / bridge stopped")

        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil

        closeSocket()
        await terminateDaemon()

        websocketConnected = false
        daemonState = .stopped
        startedAt = nil
        externallyOwnedSession = false
        invitationContactId = nil

        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll(keepingCapacity: true)
        publish("信令网关已停止 / bridge stopped", level: .warning)
    }

    public func status() async -> BridgeStatus {
        await bootstrap()
        let uptime = startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        return BridgeStatus(
            daemon: daemonState,
            binaryPath: binaryPath.map { AppPaths.anonymise($0) },
            controlPort: controlPort,
            websocketConnected: websocketConnected,
            pairedDevices: activeDevices().count,
            acceptedCommands: acceptedCommands,
            // The frozen `BridgeStatus` has no field of its own for drops caused by
            // unpaired senders, so they are folded into the rejection count; the
            // exact whitelist is available through `whitelist()`.
            rejectedCommands: rejectedCommands + ignoredUnpairedCount,
            deliveredResults: deliveredResults,
            outboxDepth: outboxCount(),
            uptimeSeconds: uptime,
            lastError: lastError,
            sampledAt: Date()
        )
    }

    /// `allowedPairedPublicKeys` cannot be expressed in the frozen `BridgeStatus`,
    /// so the whitelist is exposed directly instead of being smuggled into an
    /// unrelated field.
    public func whitelist() async -> [String] {
        await bootstrap()
        return activeDevices().map { $0.publicKey }.sorted()
    }

    public func identity() async -> NodeIdentity {
        await bootstrap()
        var resolved = buildIdentity()
        if resolved.displayName.isEmpty {
            resolved.displayName = await settings.current().nodeName
        }
        return resolved
    }

    public func currentOffer() async -> PairingOffer? {
        await bootstrap()
        // Deliberately never mints: the console polls this in every snapshot, and a
        // `/_connect 1` per poll would litter the chat core with half-used invites.
        guard let offer = cachedOffer, offer.isValid else { return nil }
        return offer
    }

    public func rotateOffer() async -> PairingOffer? {
        await bootstrap()
        if let previous = cachedOffer {
            var retired = previous
            retired.used = true
            cachedOffer = retired
            persistOffer(retired)
            publish(
                "旧配对二维码已作废 / previous pairing offer retired",
                level: .notice,
                channel: .pairing,
                payload: ["offer": .string(Self.codeFingerprint(retired.code))]
            )
        }
        guard websocketConnected else {
            lastError = "控制信道未连接，无法铸造邀请链接 / cannot mint an invitation while the control socket is down"
            publish("\(lastError ?? "")", level: .warning, channel: .pairing)
            return nil
        }
        guard let identity = keyPair else {
            lastError = "节点 Ed25519 密钥不可用，配对已禁用 / node Ed25519 key unavailable, pairing disabled"
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        }

        switch await perform("/_connect 1", timeout: SBChatWire.invitationTimeout) {
        case .payload(let value):
            guard let payload = SBJSON.dictionary(value) else {
                lastError = "邀请响应不是 JSON 对象 / invitation reply was not an object"
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
                return nil
            }
            guard SBJSON.tag(payload) == "invitation" else {
                lastError = SBChatWire.sanitized(
                    "邀请响应格式意外：\(SBJSON.tag(payload) ?? "nil") / unexpected invitation tag"
                )
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
                return nil
            }
            let links = SBChatWire.invitationLinks(in: payload)
            guard let link = links.short ?? links.full else {
                lastError = SBChatWire.sanitized(
                    "邀请响应里没有可用的 popopx:/ 链接 / invitation carried no usable popopx:/ link"
                )
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
                return nil
            }
            // A link that cannot survive a command line must never reach a QR.
            guard SBChatWire.isSafeLink(link) else {
                lastError = SBChatWire.sanitized(
                    "邀请链接过长或含非法字符（\(link.count) 字符）/ invitation link too long or unsafe"
                )
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
                return nil
            }
            // The connection created by `/_connect 1` is what the phone will land
            // on; remembering it lets us accept that contact and nothing else.
            invitationContactId = SBChatWire.contactIdentifier(in: SBJSON.field(payload, "connection"))
                ?? SBChatWire.contactIdentifier(in: payload)
            return mintOffer(link: link, identity: identity, issuedAt: Date())
        case .chatError(let detail):
            lastError = SBChatWire.sanitized("铸造邀请失败 / /_connect 1 failed: \(detail)")
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            if detail.lowercased().contains("noactiveuser") { _ = await verifyChatCore() }
            return nil
        case .timedOut:
            lastError = "铸造邀请超时 / invitation timed out after \(Int(SBChatWire.invitationTimeout))s"
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        case .transport(let detail):
            lastError = SBChatWire.sanitized("铸造邀请时信道中断 / invitation lost the socket: \(detail)")
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        }
    }

    public func qrAsset(pixelSize: Int) async -> QRAsset? {
        await bootstrap()
        guard let offer = cachedOffer, offer.isValid else {
            lastError = "没有有效的配对二维码，请先在向导第 2 步生成 / no live pairing offer; rotate one first"
            publish("\(lastError ?? "")", level: .warning, channel: .pairing)
            return nil
        }
        // The QR carries the *envelope* of the signed credential, never the
        // credential: a screenshot, a forwarded link or a chat-app preview must not
        // name a relay. The envelope still embeds nodeId + node key + link, so iOS
        // can prove the QR came from this node once it opens it.
        var sealed = (try? OpaquePairingCodec.pairingLink(offer.code))
            .flatMap { $0.utf8.count <= SBChatWire.qrPayloadBudget ? $0 : nil }
        if sealed == nil {
            // The credential is either too large to seal or its envelope scans past
            // what a phone camera resolves at arm's length. Degrade to the *sealed*
            // short link — opaque either way — and say so instead of emitting a QR
            // that silently fails to scan.
            if SBChatWire.isSafeLink(offer.invitationURI) {
                sealed = (try? OpaquePairingCodec.link(for: offer.invitationURI))
                    .flatMap { $0.utf8.count <= SBChatWire.qrPayloadBudget ? $0 : nil }
                publish(
                    "签名码 \(offer.code.utf8.count) 字节超出二维码预算，改封装短邀请链 / the signed code does not fit the QR budget, so the sealed short link is encoded instead",
                    level: .warning,
                    channel: .pairing
                )
            }
        }
        guard let payload = sealed else {
            lastError = SBChatWire.sanitized(
                "配对载荷 \(offer.code.utf8.count) 字节，封装后超过二维码预算 \(SBChatWire.qrPayloadBudget) / the sealed pairing payload is over the QR budget"
            )
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        }
        let render = SBQRCode.render(payload, pixelSize: pixelSize)
        guard let png = render.png else {
            lastError = SBChatWire.sanitized(render.reason ?? "二维码渲染失败 / QR render failed")
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        }
        publish(
            "已渲染 \(render.pixelSize) px 配对二维码 / pairing QR rendered",
            level: .info,
            channel: .pairing,
            payload: ["pixels": .int(render.pixelSize), "bytes": .int(png.count)]
        )
        return QRAsset(png: png, pixelSize: render.pixelSize, generatedAt: Date())
    }

    public func pairedDevices() async -> [PairedDevice] {
        await bootstrap()
        // Revoked rows stay on disk for the audit trail but are not surfaced here,
        // so the wizard and `BridgeStatus.pairedDevices` can never disagree.
        return activeDevices().map { $0.modelDevice }
    }

    public func revokeDevice(publicKey: String) async {
        await bootstrap()
        guard let index = devices.firstIndex(where: { Digest.matches($0.publicKey, publicKey) }) else {
            publish("未找到要撤销的设备 / no paired device with that key", level: .warning, channel: .pairing)
            return
        }
        guard !devices[index].revoked else {
            publish("设备已在撤销名单中 / device is already revoked", level: .notice, channel: .pairing)
            return
        }
        devices[index].revoked = true
        devices[index].lastSeenAt = Date()
        contactIndex.removeValue(forKey: devices[index].contactId)
        persistDevices()
        publish(
            "已撤销设备 \(TextKit.truncate(publicKey, to: 16))，其后续指令将被丢弃；"
                + "SMP 连接本身未拆除 — 如需彻底断开请在聊天端删除该联系人 / device revoked, its commands are now dropped. "
                + "The SMP connection itself still exists: delete the contact in the chat to tear it down",
            level: .warning,
            channel: .pairing,
            payload: ["keyHash": .string(Digest.short(Data(publicKey.utf8), length: 8))]
        )
    }

    /// The only `nonisolated` member: the stream has to be creatable from a
    /// non-isolated context (the composition root's `for await`), so it follows the
    /// `installEvents()` shape of the neighbouring module.
    public nonisolated func incomingCommands() -> AsyncStream<NodeCommand> {
        let id = UUID()
        return AsyncStream<NodeCommand>(bufferingPolicy: .bufferingNewest(Self.maximumBacklog)) { continuation in
            // Named rather than `self` on purpose: a nested `[weak self]` inside a
            // closure that also mentions `self` is a strong/weak capture mismatch, and
            // holding the bridge strongly here would keep it alive after `stop()`.
            Task { [weak bridge = self] in
                guard let bridge else { return }
                await bridge.attachSubscriber(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak bridge = self] _ in
                guard let bridge else { return }
                Task { await bridge.detachSubscriber(id: id) }
            }
        }
    }

    public func deliver(_ result: CommandResult, to serviceId: String) async -> Bool {
        await bootstrap()
        guard let contactId = resolveTargetContact(for: result, serviceId: serviceId) else {
            enqueueOutbox(result, serviceId: serviceId, contactId: nil, reason: "没有可回传的已配对设备 / no paired device to answer")
            return false
        }
        guard websocketConnected else {
            enqueueOutbox(result, serviceId: serviceId, contactId: contactId, reason: "控制信道未连接 / control socket is down")
            return false
        }
        switch await sendResult(result, to: contactId) {
        case .sent:
            deliveredResults += 1
            if let commandID = result.commandID { commandTargets.removeValue(forKey: commandID) }
            publish(
                "结果已回传 iOS / result delivered · \(TextKit.truncate(contactId, to: 16))",
                level: .success,
                channel: .result,
                payload: [
                    "engine": .string(result.engine.rawValue),
                    "resultId": .string(result.id),
                    "serviceId": .string(serviceId),
                    "artifacts": .int(result.artifacts.count)
                ]
            )
            return true
        case .failed(let reason):
            enqueueOutbox(result, serviceId: serviceId, contactId: contactId, reason: reason)
            return false
        }
    }

    /// Drains `outbox/` in queue order. Runs after every successful handshake, and
    /// is public so the console can retry after the operator fixes the daemon.
    @discardableResult
    public func flushOutbox() async -> Int {
        await bootstrap()
        guard websocketConnected else { return 0 }
        var delivered = 0
        outboxLoop: for entry in readOutbox() {
            guard running, websocketConnected else { break }
            let target = entry.contactId.flatMap { whitelistedContact($0) }
                ?? resolveTargetContact(for: entry.result, serviceId: entry.serviceId)
            guard let target else {
                lastError = "队列中的结果没有可投递设备 / queued result has no deliverable device"
                break
            }
            switch await sendResult(entry.result, to: target) {
            case .sent:
                if let url = entry.url { try? fileManager.removeItem(at: url) }
                delivered += 1
                deliveredResults += 1
            case .failed(let reason):
                lastError = SBChatWire.sanitized("队列回投中断 / outbox retry failed: \(reason)")
                if entry.queuedAt.timeIntervalSinceNow < -Self.outboxMaximumAge {
                    if let url = entry.url { try? fileManager.removeItem(at: url) }
                    publish(
                        "丢弃超过 \(Int(Self.outboxMaximumAge / 86_400)) 天的未投递结果 / dropped a stale undelivered result",
                        level: .warning,
                        channel: .result
                    )
                } else if let url = entry.url {
                    var retried = entry
                    retried.attempts += 1
                    _ = SBStore.write(retried, to: url, fileProtection: false)
                }
                // Stop on the first failure: the queue must stay ordered, and a
                // later result cannot overtake an unanswered one.
                break outboxLoop
            }
        }
        if delivered > 0 {
            publish("队列回投 \(delivered) 条 / outbox drained \(delivered) result(s)", level: .success, channel: .result)
        }
        return delivered
    }

    /// Menu-bar one-liner, mirroring the neighbouring module's convenience.
    public func statusLine() async -> String {
        let status = await status()
        let daemonText: String
        switch status.daemon {
        case .running: daemonText = externallyOwnedSession ? "会话在线（复用外部实例）" : "会话在线"
        case .starting: daemonText = "会话启动中"
        case .degraded: daemonText = "会话降级"
        case .missingBinary: daemonText = "缺少可执行文件"
        case .stopped: daemonText = "已停止"
        }
        return "SMP \(daemonText) · 信道 \(status.websocketConnected ? "已连接" : "断开") · \(status.pairedDevices) 台设备 · 队列 \(status.outboxDepth)"
    }

    // MARK: - Identity handling

    private func currentNodeId() -> String {
        nodeIdentity?.nodeId ?? buildIdentity().nodeId
    }

    /// Loads — or creates — the node Ed25519 keypair.
    ///
    /// `pairing/node.key` holds the base64url seed. A file we cannot parse is moved
    /// aside rather than overwritten: silently destroying somebody's key material is
    /// worse than one wasted directory entry. Two readers are tolerated because the
    /// bytes are only ever adopted, never rewritten: a base64url token (what a setup
    /// helper would write) decodes to 32 bytes and becomes the seed, and a raw 32-byte
    /// blob — the mesh engine uses this same file as an HKDF salt — is accepted
    /// directly. Whoever writes first owns the node id for the life of the install, so
    /// `identity()` reports the public half derived from whatever is already on disk.
    private func prepareIdentity() {
        guard keyPair == nil, nodeIdentity == nil else { return }
        let url = AppPaths.nodeKeyFile
        var identity: SBSigning.Identity?
        var createdNew = false

        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            let text = String(decoding: existing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = TextKit.base64URLDecode(text), let restored = SBSigning.restore(seed: decoded) {
                identity = restored
            } else if let raw = SBSigning.restore(seed: existing) {
                identity = raw
            } else {
                let discarded = AppPaths.pairing
                    .appendingPathComponent("node.key.unreadable-\(Digest.short(existing, length: 8))")
                try? fileManager.moveItem(at: url, to: discarded)
                publish(
                    "node.key 不是可识别的 Ed25519 种子，已原样保留在 "
                        + "\(AppPaths.anonymise(discarded.path)) 并重新生成 / unreadable key file preserved and a new one generated",
                    level: .warning,
                    channel: .pairing
                )
            }
        }
        if identity == nil {
            identity = SBSigning.generate()
            createdNew = identity != nil
        }
        guard let resolved = identity else {
            lastError = "CryptoKit Ed25519 不可用，配对功能已禁用 / Ed25519 unavailable, pairing disabled"
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return
        }
        keyPair = resolved
        nodeIdentity = NodeIdentity(
            nodeId: resolved.nodeId,
            publicKey: resolved.publicKeyBase64URL,
            displayName: injectedIdentity.displayName,
            version: NodeVersion.current.semanticString,
            schemaRevision: NodeVersion.schemaRevision,
            startedAt: injectedIdentity.startedAt
        )
        if createdNew {
            guard let seed = resolved.seed else {
                lastError = "无法导出密钥种子，本次配对码仅存于内存 / seed export failed, this offer is memory-only"
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
                return
            }
            let encoded = TextKit.base64URL(seed).data(using: .utf8) ?? Data()
            if !SBStore.writeRaw(encoded, to: url, fileProtection: true) {
                lastError = SBChatWire.sanitized("无法写入 node.key（权限或磁盘）/ could not persist the node key")
                publish("\(lastError ?? "")", level: .error, channel: .pairing)
            }
            // The public half only — the seed never reaches a log line.
            publish(
                "已生成本机节点密钥 / node Ed25519 keypair created · 节点 \(resolved.nodeId)",
                level: .success,
                channel: .pairing,
                payload: [
                    "nodeId": .string(resolved.nodeId),
                    "keyHash": .string(Digest.short(resolved.publicRaw, length: 8))
                ]
            )
        }
    }

    private func buildIdentity() -> NodeIdentity {
        if let cached = nodeIdentity { return cached }
        prepareIdentity()
        if let created = nodeIdentity { return created }
        return injectedIdentity
    }

    // MARK: - Daemon lifecycle

    private func resolveBinary() {
        for name in SBChatWire.binaryNames {
            if let path = Shell.which(name) {
                binaryPath = path
                publish(
                    "使用 \(name) → \(AppPaths.anonymise(path)) / resolved daemon binary",
                    level: .info,
                    payload: ["binary": .string(name)]
                )
                return
            }
        }
        binaryPath = nil
    }

    /// Starts the resident daemon. `--chat-server-port` is mandatory: with no port
    /// the CLI binds nothing and the control socket can never open.
    private func launchDaemon(at launchPath: String) async {
        guard running else { return }
        daemonState = .starting
        daemonStartedAt = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = ["--chat-server-port", String(controlPort)]
        process.environment = Shell.augmentedEnvironment
        // The daemon keeps its own profile directory; running from the node's tree
        // only makes a stray relative write easy to find.
        process.currentDirectoryURL = AppPaths.popopx
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let ring = stderrRing
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            ring.append(chunk)
        }

        daemonGeneration += 1
        let generation = daemonGeneration
        process.terminationHandler = { [weak bridge = self] finished in
            let code = finished.terminationStatus
            // `standardError` is `Any?`, so the pipe has to be downcast before the
            // readability handler can be released (otherwise GCD keeps a source alive).
            if let pipe = finished.standardError as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            Task {
                guard let bridge else { return }
                await bridge.handleDaemonExit(generation: generation, exitCode: code)
            }
        }

        do {
            try process.run()
        } catch {
            daemonState = .degraded
            lastError = SBChatWire.sanitized(
                "无法启动 \(AppPaths.anonymise(launchPath)): \(error.localizedDescription)"
            )
            publish("\(lastError ?? "")", level: .error)
            nextConnectAttempt = Date().addingTimeInterval(Self.restartBackoffs.last ?? 15)
            return
        }

        daemonProcess = process
        publish(
            "会话守护进程已启动 pid \(process.processIdentifier) · 端口 \(controlPort) / daemon launched",
            level: .info,
            payload: ["pid": .int(Int(process.processIdentifier)), "port": .int(Int(controlPort))]
        )
        // Never block `start()` on the bind: the supervisor retries the socket, and
        // a cold Haskell runtime takes a second or two to listen.
        nextConnectAttempt = Date().addingTimeInterval(0.4)
    }

    private func handleDaemonExit(generation: Int, exitCode: Int32) async {
        guard running, generation != 0, generation == daemonGeneration else { return }
        daemonGeneration = 0
        daemonProcess = nil
        websocketConnected = false
        closeSocket()

        let tail = SBChatWire.sanitized(stderrRing.tailText)
        // A daemon that survived the stability window gets a fresh restart budget;
        // the budget exists to stop a crash loop, not to punish a weeks-later OOM.
        if let started = daemonStartedAt, Date().timeIntervalSince(started) >= Self.stableRunSeconds {
            restarts = 0
        }

        let lower = tail.lowercased()
        if Self.addressInUseSignatures.contains(where: { lower.contains($0) }) {
            externallyOwnedSession = true
            daemonState = .degraded
            lastError = SBChatWire.sanitized(
                "端口 \(controlPort) 已被其它会话实例占用，将复用该实例 / port already served by another instance, reusing it"
            )
            publish("\(lastError ?? "")", level: .warning)
            nextConnectAttempt = Date()
            return
        }

        externallyOwnedSession = false
        restarts += 1
        if restarts <= Self.maximumFastRestarts {
            let backoff = Self.restartBackoffs[min(restarts - 1, Self.restartBackoffs.count - 1)]
            daemonState = .degraded
            lastError = SBChatWire.sanitized(
                "会话守护进程退出（code \(exitCode)），\(Int(backoff)) 秒后第 \(restarts)/\(Self.maximumFastRestarts) 次重启；"
                    + "stderr: \(tail)"
            )
            publish("\(lastError ?? "")", level: .error)
            relaunchTask?.cancel()
            relaunchTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.relaunchDaemon()
            }
            return
        }

        // Re-probe: the usual reason for a hard failure spurt is that the binary was
        // upgraded or uninstalled underneath us.
        resolveBinary()
        daemonState = binaryPath == nil ? .missingBinary : .degraded
        lastError = SBChatWire.sanitized(
            "会话守护进程在 \(Self.maximumFastRestarts) 次重启后仍失败（code \(exitCode)）；自动重启已停止，"
                + "stderr: \(tail) / daemon still failing after \(Self.maximumFastRestarts) restarts, automatic restart stopped"
        )
        publish(
            "\(lastError ?? "")\n修好后重启网关节即可恢复 / fix the cause and restart the bridge",
            level: .error
        )
    }

    private func relaunchDaemon() async {
        guard running, daemonGeneration == 0 else { return }
        guard let launchPath = binaryPath else {
            daemonState = .missingBinary
            lastError = "会话可执行文件已从 PATH 消失 / the daemon binary disappeared from PATH"
            publish("\(lastError ?? "")", level: .error)
            return
        }
        await launchDaemon(at: launchPath)
    }

    /// SIGTERM, then let the Haskell runtime flush its SQLite handles, then
    /// SIGKILL. `stop()` never leaves an orphan behind.
    private func terminateDaemon() async {
        guard let process = daemonProcess else { return }
        daemonProcess = nil
        daemonGeneration = 0
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                publish("守护进程 5 秒内未退出，已发送 SIGKILL / daemon ignored SIGTERM for 5s, sent SIGKILL", level: .warning)
            }
        }
    }

    // MARK: - Supervision

    /// One heartbeat for both the process and the socket. Polling every two seconds
    /// is deliberate: `Process` has no awaitable exit API and
    /// `URLSessionWebSocketTask` has no awaitable "opened" API, and parking a thread
    /// on either would take the cooperative pool with it.
    private func supervise() async {
        while !Task.isCancelled {
            if running {
                if let process = daemonProcess, daemonGeneration != 0, !process.isRunning {
                    await handleDaemonExit(generation: daemonGeneration, exitCode: process.terminationStatus)
                }
                if daemonState == .missingBinary {
                    resolveBinary()
                    if let launchPath = binaryPath, daemonGeneration == 0 {
                        restarts = 0
                        lastError = nil
                        publish("检测到会话可执行文件，重新接管 / daemon binary appeared, taking it over", level: .notice)
                        await launchDaemon(at: launchPath)
                    }
                } else if !websocketConnected,
                          daemonState != .stopped,
                          daemonState.isLive || daemonState == .starting,
                          Date() >= nextConnectAttempt {
                    await openSocket()
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Socket

    private func openSocket() async {
        guard running, socket == nil else { return }
        guard let url = SBChatWire.webSocketURL(port: controlPort) else {
            lastError = "无法构造回环控制地址 / could not build the loopback control URL"
            return
        }
        // Hold the supervisor off while we try, so attempts cannot overlap.
        nextConnectAttempt = Date.distantFuture
        var request = URLRequest(url: url)
        request.timeoutInterval = SBChatWire.connectTimeout
        let task = session.webSocketTask(with: request)
        task.resume()

        let deadline = Date().addingTimeInterval(SBChatWire.connectTimeout)
        while task.state != .running {
            if task.state == .canceling || task.state == .completed { break }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        guard task.state == .running else {
            task.cancel(with: .goingAway, reason: nil)
            // Launched but unreachable is impaired, not merely "still starting": the
            // Haskell runtime had its chance to bind inside the connect timeout.
            if daemonState == .starting { daemonState = .degraded }
            scheduleReconnect(
                SBChatWire.sanitized("无法连接 ws://\(SBChatWire.loopbackHost):\(controlPort) / control socket connect failed")
            )
            return
        }

        socket = task
        websocketConnected = true
        reconnectAttempt = 0
        nextConnectAttempt = Date.distantPast
        if daemonProcess == nil {
            // Somebody else's daemon answered. It is live, but it is not ours.
            externallyOwnedSession = true
        }
        // `.running` means "process up *and* control channel up"; until this point the
        // Haskell runtime may still be initialising, which is `.starting`, and a lost
        // socket drops back to `.degraded` rather than to `.stopped`.
        daemonState = externallyOwnedSession ? .degraded : .running
        publish(
            "控制信道已连接 ws://\(SBChatWire.loopbackHost):\(controlPort)"
                + (externallyOwnedSession ? "（复用外部实例 / external instance）" : "") + " / control socket established",
            level: .success,
            payload: ["port": .int(Int(controlPort))]
        )
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        if await verifyChatCore() {
            _ = await flushOutbox()
        }
    }

    private func scheduleReconnect(_ reason: String) {
        reconnectAttempt += 1
        let backoff = min(30, pow(2.0, Double(min(reconnectAttempt, 5))))
        nextConnectAttempt = Date().addingTimeInterval(backoff)
        lastError = SBChatWire.sanitized("\(reason)，\(Int(backoff)) 秒后重试 / retrying in \(Int(backoff))s")
    }

    private func closeSocket() {
        guard let current = socket else { return }
        socket = nil
        current.cancel(with: .goingAway, reason: nil)
    }

    /// The async `receive()` form rather than the completion-handler one: exactly one
    /// outstanding read at a time, and cancellation unwinds it.
    private func receiveLoop() async {
        guard let current = socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await current.receive()
                switch message {
                case .data(let data):
                    ingest(String(decoding: data, as: UTF8.self))
                case .string(let text):
                    ingest(text)
                @unknown default:
                    ingest("")
                }
            } catch {
                await handleSocketFailure(reason: SBChatWire.sanitized(error.localizedDescription))
                return
            }
        }
    }

    private func handleSocketFailure(reason: String) async {
        guard running else { return }
        let wasConnected = websocketConnected
        websocketConnected = false
        receiveTask = nil
        closeSocket()
        failAllPending("控制信道中断 / control socket dropped: \(reason)")
        // Process alive but the channel is gone is *degraded*, not stopped: the
        // supervisor keeps retrying on `.isLive`, and `status()` must not claim the
        // daemon is fine when nothing is listening, nor dead when it is running.
        if daemonState == .running { daemonState = .degraded }
        if wasConnected {
            publish("控制信道中断 / control socket dropped: \(reason)", level: .warning)
        }
        scheduleReconnect("控制信道中断 / control socket dropped")
        // The process may have died without our termination handler firing yet.
        if let process = daemonProcess, !process.isRunning, daemonGeneration != 0 {
            await handleDaemonExit(generation: daemonGeneration, exitCode: process.terminationStatus)
        }
    }

    /// Runs on the receive loop, so it must never await: replies are settled
    /// synchronously and events are handed to the serial worker.
    private func ingest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let frame = SBChatWire.frame(from: trimmed) else {
            publish("忽略无法解析的控制帧（\(trimmed.utf8.count) 字节）/ ignored unparseable control frame", level: .debug)
            return
        }
        if let corrId = frame.corrId {
            guard let registration = pending.removeValue(forKey: corrId) else {
                // A late reply after the watchdog fired; the caller already unwound.
                return
            }
            registration.watchdog.cancel()
            registration.box.deliver(SBChatWire.reply(from: frame.payload))
            return
        }
        eventContinuation?.yield(SBEvent(tag: SBJSON.tag(frame.payload) ?? "", payload: frame.payload))
    }

    /// Serial event worker. Blocking here on a command reply is safe because the
    /// receive loop that has to deliver that reply is a different task.
    private func startEventWorker() {
        guard eventTask == nil else { return }
        var installed: AsyncStream<SBEvent>.Continuation?
        let stream = AsyncStream<SBEvent>(bufferingPolicy: .bufferingNewest(512)) { continuation in
            installed = continuation
        }
        guard let continuation = installed else { return }
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.handleEvent(event)
            }
        }
    }

    // MARK: - Requests

    /// Sends one command line and waits for the frame carrying the same `corrId`.
    private func perform(_ line: String, timeout: TimeInterval = SBChatWire.commandTimeout) async -> SBReply {
        guard running, websocketConnected, let current = socket else {
            return .transport("控制信道未连接 / control socket is not connected")
        }
        correlationCounter += 1
        let corrId = "c\(correlationCounter)"
        let box = SBReplyBox()
        let watchdog = Task { [weak box] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
            guard !Task.isCancelled, let box else { return }
            // The waiter still holds the registration and removes it as soon as it
            // wakes, so the table cannot leak.
            box.deliver(.timedOut)
        }
        pending[corrId] = SBRegistration(box: box, watchdog: watchdog)
        do {
            try await current.send(.string(SBChatWire.requestFrame(corrId: corrId, cmd: line)))
        } catch {
            watchdog.cancel()
            pending.removeValue(forKey: corrId)
            return .transport(SBChatWire.sanitized(error.localizedDescription))
        }
        let reply = await box.settle()
        watchdog.cancel()
        pending.removeValue(forKey: corrId)
        return reply
    }

    private func failAllPending(_ reason: String) {
        let registrations = pending
        pending.removeAll(keepingCapacity: true)
        for (_, registration) in registrations {
            registration.watchdog.cancel()
            registration.box.deliver(.transport(SBChatWire.sanitized(reason)))
        }
    }

    // MARK: - Handshake with the chat core

    /// `/u` proves there is an active user, which is the precondition for every other
    /// command. A node without one gets exactly one conservative `/_create user`
    /// attempt; if the fork's record shape has moved on we say so plainly instead of
    /// guessing our way into a half-initialised profile.
    private func verifyChatCore() async -> Bool {
        for attempt in 1...3 {
            switch await perform("/u", timeout: SBChatWire.handshakeTimeout) {
            case .payload(let value):
                guard SBJSON.tag(value) == "activeUser" else {
                    lastError = SBChatWire.sanitized("预期 activeUser，收到 \(SBJSON.tag(value) ?? "nil") / unexpected /u reply")
                    publish("\(lastError ?? "")", level: .error)
                    return false
                }
                nodeProfileName = SBJSON.firstString("displayName", in: value, limit: 6)
                publish(
                    "聊天核心就绪，活动用户已确认 / chat core live, active user confirmed",
                    level: .success,
                    payload: nodeProfileName.map { ["profile": .string($0)] } ?? [:]
                )
                return true
            case .chatError(let detail):
                let lower = detail.lowercased()
                if lower.contains("noactiveuser") {
                    return await createActiveUser()
                }
                if lower.contains("chatnotstarted") {
                    publish(
                        "聊天核心仍在启动，第 \(attempt) 次重试 / chat core still starting, retry \(attempt)",
                        level: .notice
                    )
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                lastError = SBChatWire.sanitized("/u 被拒绝 / /u refused: \(detail)")
                publish("\(lastError ?? "")", level: .error)
                return false
            case .timedOut:
                lastError = "/u 超时 / /u timed out after \(Int(SBChatWire.handshakeTimeout))s"
                publish("\(lastError ?? "")", level: .warning)
                return false
            case .transport(let detail):
                lastError = SBChatWire.sanitized("/u 无法发送 / /u could not be sent: \(detail)")
                return false
            }
        }
        lastError = "/u 未确认活动用户 / active user could not be confirmed"
        publish("\(lastError ?? "")", level: .error)
        return false
    }

    private func createActiveUser() async -> Bool {
        let fallbackName = await settings.current().nodeName
        let displayName = nodeProfileName ?? fallbackName
        switch await perform(SBChatWire.createUserLine(displayName: displayName), timeout: SBChatWire.handshakeTimeout) {
        case .payload:
            publish(
                "已创建本机活动用户 / created the local active user",
                level: .success,
                payload: ["nodeId": .string(currentNodeId())]
            )
            return true
        case .chatError(let detail):
            lastError = SBChatWire.sanitized(
                "首次初始化失败：\(detail) — 请在 iOS 端或终端完成一次首次初始化 / first-run initialisation failed; "
                    + "complete it once on the iOS side or in the chat terminal"
            )
            publish("\(lastError ?? "")", level: .warning)
            return false
        case .timedOut:
            lastError = "/_create user 超时 / /_create user timed out"
            publish("\(lastError ?? "")", level: .warning)
            return false
        case .transport(let detail):
            lastError = SBChatWire.sanitized("/_create user 无法发送 / /_create user could not be sent: \(detail)")
            return false
        }
    }

    // MARK: - Pushed events

    /// Dispatch on the `type` tag. Unknown tags are ignored at debug level: the chat
    /// core pushes far more events than the node cares about, and logging every one
    /// would bury the pairing trail.
    private func handleEvent(_ event: SBEvent) async {
        switch event.tag {
        case "newChatItems":
            handleNewChatItems(event.payload)
        case "rcvFileDescrReady":
            await handleFileDescriptorReady(event.payload)
        case "chatStarted", "userContactUpdated", "connected", "contactConnecting":
            // Any of these may be the first evidence of a contact that just used our
            // invitation.
            discoverContacts(in: event.payload)
        default:
            publish("忽略事件 \(event.tag) / ignored event", level: .debug)
        }
    }

    /// Text lives at `chatItems[i].chatItem.content.msgContent.text`; the sender is
    /// `chatInfo.direct.contact.contactId`.
    private func handleNewChatItems(_ payload: [String: Any]) {
        // The event itself is the pairing evidence for many builds, so look before
        // we look at content.
        discoverContacts(in: payload)
        guard let items = SBJSON.array(SBJSON.field(payload, "chatItems")) else { return }
        for wrapper in items {
            guard let chatItem = SBJSON.field(wrapper, "chatItem") else { continue }
            let content = SBJSON.field(chatItem, "content")
            // `chatDir` sits on the item in the fork (`SndChatItemData.chatDir`) and
            // only in some builds inside `content`; outbound is `directSnd` /
            // `directSent`, inbound `directRcv` / `groupRcv`, so match the sender
            // markers rather than a prefix.
            let chatDir = SBJSON.field(chatItem, "chatDir") ?? SBJSON.field(content, "chatDir")
            let direction = (SBJSON.tag(chatDir) ?? "").lowercased()
            guard !direction.contains("snd"), !direction.contains("sent") else {
                continue // our own outbound echoes are not commands
            }
            let message = SBJSON.field(content, "msgContent")
            guard let text = SBJSON.text(message, "text") else { continue }
            // Only a text message can carry a command: an image or file description
            // puts a file name in the same `text` slot.
            let messageType = (SBJSON.tag(message) ?? "").lowercased()
            guard messageType.isEmpty || messageType == "text" else { continue }
            let contactId = SBChatWire.contactIdentifier(in: wrapper)
            // The sender is the *documented* `chatInfo.direct.contact`, then
            // `chatDir.directRcv.fromContact`/`fromGroup` (a group echo would otherwise
            // be attributed to whatever contactId hides deeper in the item), and only
            // then the depth-bounded search.
            var resolvedContactId = SBJSON.firstString("contactId", in: SBJSON.field(chatItem, "chatInfo"), limit: 4)
                ?? SBJSON.firstString("contactId", in: SBJSON.field(content, "chatInfo"), limit: 4)
            if resolvedContactId == nil, !direction.contains("group") {
                // A group sender is `fromGroup`/`memberContact`; attributing a group
                // message to one paired phone would hand the group its authority.
                resolvedContactId = SBJSON.firstString("contactId", in: chatDir, limit: 4)
            }
            resolvedContactId = resolvedContactId ?? contactId
            acceptIncoming(text: text, contactId: resolvedContactId)
        }
    }

    /// `/freceive <fileId> <path>` — inbound files land in `quarantine/`, never in a
    /// directory any engine reads directly.
    private func handleFileDescriptorReady(_ payload: [String: Any]) async {
        guard let rawId = SBJSON.first("fileId", in: payload, limit: 6) ?? SBJSON.first("fileNo", in: payload, limit: 6),
              let fileId = SBJSON.string(rawId), !fileId.isEmpty
        else {
            lastError = "rcvFileDescrReady 未带 fileId / file descriptor ready without an id"
            publish("\(lastError ?? "")", level: .warning)
            return
        }
        let suggestedName = SBJSON.firstString("fileName", in: payload, limit: 6) ?? "inbound"
        guard let destination = receiveDestination(fileId: fileId, suggestedName: suggestedName) else {
            publish("\(lastError ?? "")", level: .warning)
            return
        }
        switch await perform("/freceive \(fileId) \(destination.path)", timeout: SBChatWire.fileReceiveTimeout) {
        case .payload:
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            publish(
                "入站文件已隔离保存 / inbound file quarantined · \(AppPaths.anonymise(destination.path))",
                level: .info,
                payload: ["bytes": .int(size)]
            )
            await inboundFileHandler?(destination)
        case .chatError(let detail):
            lastError = SBChatWire.sanitized("/freceive 失败 / receive failed: \(detail)")
            publish("\(lastError ?? "")", level: .warning)
        case .timedOut:
            lastError = "/freceive 超时 / inbound file transfer timed out"
            publish("\(lastError ?? "")", level: .warning)
        case .transport(let detail):
            lastError = SBChatWire.sanitized("/freceive 无法发送 / receive command lost: \(detail)")
            publish("\(lastError ?? "")", level: .warning)
        }
    }

    /// Where an inbound file is allowed to land.
    ///
    /// The path is a command-line argument for the daemon, so it has to be free of
    /// whitespace and shell-ish characters. A home directory is not always (`a name
    /// with a space` is legal), in which case the per-user temporary directory — a
    /// whitespace-free `/var/folders/…` path on macOS — is the only place the daemon
    /// can be told to write. Still quarantine-named, so nothing treats it as trusted
    /// input, and `AppPaths.anonymise` still applies before it reaches a log line.
    private func receiveDestination(fileId: String, suggestedName: String) -> URL? {
        let stem = Digest.short(Data(fileId.utf8), length: 8)
        let name = isSuggestedFileName(suggestedName) ? suggestedName : TextKit.safeFileName(suggestedName, fallback: "inbound")
        for root in [AppPaths.quarantine, fileManager.temporaryDirectory] {
            let candidate = root.appendingPathComponent("\(stem)-\(name)")
            guard SBChatWire.isSafeArgument(candidate.path) else { continue }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                continue
            }
            return candidate
        }
        lastError = "没有可安全写入的隔离目录：路径含空白或 shell 特殊字符 / no daemon-safe quarantine directory exists"
        return nil
    }

    /// `safeFileName` is deliberately aggressive (CJK names collapse to `-`), and the
    /// inbound name is already namespaced by the file-id digest prefix. A name that is
    /// already a single safe path component is therefore kept verbatim.
    private func isSuggestedFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 96 else { return false }
        guard !name.contains("."), name != "..", !name.contains("/") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Whitelist enforcement

    /// The gate. Only a contact already on the whitelist — or one that just consumed
    /// a live one-time offer — may reach the engines.
    private func acceptIncoming(text: String, contactId: String?) {
        let receivedAt = Date()
        guard let contactId else {
            ignoredUnpairedCount += 1
            publish(
                "已忽略未配对来源 / ignored unpaired sender · hash \(Digest.short(Data(text.utf8), length: 8))",
                level: .warning,
                payload: ["reason": .string("no contact id on the wire")]
            )
            return
        }
        guard let device = activeDevice(for: contactId) else {
            if claimInvitation(for: contactId), let admitted = activeDevice(for: contactId) {
                continueIncoming(text: text, device: admitted, receivedAt: receivedAt)
            } else {
                ignoredUnpairedCount += 1
                // Payload text never reaches a log line — it may carry user data.
                publish(
                    "已忽略未配对来源 / ignored unpaired sender · hash \(Digest.short(Data(text.utf8), length: 8))",
                    level: .warning,
                    payload: ["contact": .string(TextKit.truncate(contactId, to: 16))]
                )
            }
            return
        }
        touch(deviceId: device.publicKey, at: receivedAt)
        continueIncoming(text: text, device: device, receivedAt: receivedAt)
    }

    private func continueIncoming(text: String, device: SBPairedDevice, receivedAt: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Deterministic lockdown first: it must not depend on the marker, on a model,
        // or on the payload being well-formed. The whitelist still applies.
        if let trigger = SBCommandCodec.lockTrigger(in: text) {
            submit(
                SBCommandCodec.deterministicLock(trigger: trigger, senderPublicKey: device.publicKey, receivedAt: receivedAt),
                note: "确定性闭锁指令直达哨兵引擎，未经任何模型 / deterministic lock bypassed every model",
                level: .notice,
                channel: .sentinel
            )
            return
        }
        guard text.contains(NodeWire.commandPrefix) else {
            return // ordinary chat from a paired phone is not a node command
        }
        guard let parsed = SBCommandCodec.parse(text) else {
            rejectedCommands += 1
            publish(
                "NODE_CMD 段数不足或 serviceId/action 为空 / malformed NODE_CMD · "
                    + "hash \(Digest.short(Data(text.utf8), length: 8))",
                level: .warning,
                payload: ["device": .string(TextKit.truncate(device.publicKey, to: 16))]
            )
            return
        }
        submit(
            NodeCommand(
                serviceId: parsed.serviceId,
                action: parsed.action,
                payload: parsed.payload,
                senderPublicKey: device.publicKey,
                receivedAt: receivedAt,
                authenticated: true
            ),
            note: "已接受 \(parsed.serviceId) · \(parsed.action) / command accepted",
            level: .info,
            channel: .bridge
        )
    }

    private func submit(_ command: NodeCommand, note: String, level: EventLevel, channel: ConsoleEvent.Channel) {
        acceptedCommands += 1
        if let contactId = contactId(for: command.senderPublicKey) {
            commandTargets[command.id] = contactId
        }
        commandBacklog.append(command)
        if commandBacklog.count > Self.maximumBacklog {
            commandBacklog.removeFirst(commandBacklog.count - Self.maximumBacklog)
        }
        for continuation in subscribers.values { continuation.yield(command) }
        var eventPayload: [String: JSONValue] = [
            "commandId": .string(command.id),
            "serviceId": .string(command.serviceId),
            "action": .string(command.action),
            "deterministic": .bool(command.isDeterministicLock),
            "payloadHash": .string(Digest.short(Data(command.payload.utf8), length: 8))
        ]
        if !command.isDeterministicLock {
            // Repeated on every marker command, because this is the moment the user
            // actually sees the bubble: iOS has no `NODE_CMD` case in
            // `PopopxCommerceSignalKind`, so the command is *not* silently parsed on
            // the phone and shows up as ordinary chat. Cross-repo decision — the wire
            // format is deliberately left alone here.
            eventPayload["iosSignalGap"] = .string(Self.iosKindGapNotice)
        }
        publish(
            note,
            level: level,
            channel: channel,
            payload: eventPayload
        )
    }

    /// A contact is admitted only while an offer we minted is still live and unused.
    /// That single rule is the whole security boundary, because the socket itself is
    /// open to every process on this machine.
    private func claimInvitation(for contactId: String) -> Bool {
        guard let offer = cachedOffer, offer.isValid else { return false }
        if let expected = invitationContactId, expected != contactId { return false }
        var retired = offer
        retired.used = true
        cachedOffer = retired
        persistOffer(retired)
        registerDevice(contactId: contactId, label: nil, deviceModel: nil, offerFingerprint: Self.codeFingerprint(offer.code))
        publish(
            "已通过一次性邀请配对设备 \(TextKit.truncate(contactId, to: 16)) / device paired through the one-time invitation",
            level: .success,
            channel: .pairing,
            payload: [
                "contact": .string(TextKit.truncate(contactId, to: 16)),
                "offer": .string(Self.codeFingerprint(offer.code))
            ]
        )
        return true
    }

    private func discoverContacts(in payload: [String: Any]) {
        for contactId in SBChatWire.contactIdentifiers(in: payload) where activeDevice(for: contactId) == nil {
            if claimInvitation(for: contactId) {
                publish(
                    "从事件中发现已用邀请连上的设备 / contact discovered from an event",
                    level: .success,
                    channel: .pairing
                )
            }
        }
    }

    // MARK: - Device registry

    private func activeDevices() -> [SBPairedDevice] {
        devices.filter { !$0.revoked }
    }

    private func activeDevice(for contactId: String) -> SBPairedDevice? {
        if let publicKey = contactIndex[contactId], let device = devices.first(where: { !$0.revoked && $0.publicKey == publicKey }) {
            return device
        }
        return activeDevices().first { $0.contactId == contactId }
    }

    private func whitelistedContact(_ contactId: String) -> String? {
        activeDevice(for: contactId)?.contactId
    }

    private func contactId(for publicKey: String) -> String? {
        devices.first { !$0.revoked && $0.publicKey == publicKey }?.contactId
    }

    /// Whitelist identity for a contact.
    ///
    /// Honest degradation, recorded here rather than hidden: this fork's app-API JSON
    /// does not surface the peer's Ed25519 key for an established contact (the
    /// handshake keys live below the chat layer). So the whitelist is keyed on the
    /// strongest identifier the wire really gives us — an explicit key field when a
    /// build has one, else the contact's connection address (which embeds the peer's
    /// link key), else a stable digest of the contact id. Unforgeability comes from
    /// the one-time invitation, not from this string.
    private func deviceKey(contactId: String, hint: Any?) -> String {
        for key in ["publicKey", "connPubKey", "devicePublicKey", "deviceKey"] {
            if let explicit = SBJSON.firstString(key, in: hint, limit: 5), !explicit.isEmpty {
                return explicit
            }
        }
        var bucket: [String] = []
        SBJSON.linkCandidates(hint, into: &bucket)
        if let address = bucket.sorted(by: { $0.count > $1.count }).first, SBChatWire.isSafeLink(address) {
            return "PPXADDR1-\(Digest.short(Data(address.utf8), length: 32))"
        }
        return "PPXDEV1-\(Digest.short(Data(contactId.utf8), length: 32))"
    }

    @discardableResult
    private func registerDevice(
        contactId: String,
        label: String?,
        deviceModel: String?,
        offerFingerprint: String?
    ) -> SBPairedDevice {
        if let existing = devices.first(where: { $0.contactId == contactId }) {
            contactIndex[existing.contactId] = existing.publicKey
            return existing
        }
        let device = SBPairedDevice(
            publicKey: deviceKey(contactId: contactId, hint: nil),
            contactId: contactId,
            label: label ?? "iPhone · \(TextKit.truncate(contactId, to: 12))",
            deviceModel: deviceModel,
            pairedAt: Date(),
            lastSeenAt: Date(),
            revoked: false,
            pairedWithOffer: offerFingerprint
        )
        devices.append(device)
        contactIndex[contactId] = device.publicKey
        persistDevices()
        return device
    }

    private func touch(deviceId: String, at date: Date) {
        guard let index = devices.firstIndex(where: { $0.publicKey == deviceId }) else { return }
        // Throttle the rewrite: a chatty phone must not turn every message into a
        // disk write.
        let shouldPersist = devices[index].lastSeenAt.map { date.timeIntervalSince($0) > 5 } ?? true
        devices[index].lastSeenAt = date
        if shouldPersist { persistDevices() }
    }

    private func loadDevices() {
        guard let document = SBStore.read(SBDeviceDocument.self, at: AppPaths.pairedDevicesFile) else { return }
        devices = document.devices
        contactIndex = Dictionary(document.devices.map { ($0.contactId, $0.publicKey) }) { first, _ in first }
        if !devices.isEmpty {
            publish(
                "已载入 \(activeDevices().count) 台已配对设备 / restored the paired-device whitelist",
                level: .info,
                channel: .pairing
            )
        }
    }

    private func persistDevices() {
        let document = SBDeviceDocument(revision: NodeVersion.schemaRevision, updatedAt: Date(), devices: devices)
        if !SBStore.write(document, to: AppPaths.pairedDevicesFile, fileProtection: true) {
            lastError = SBChatWire.sanitized("无法写入 devices.json / whitelist persistence failed")
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
        }
    }

    // MARK: - Offers

    private func mintOffer(link: String, identity: SBSigning.Identity, issuedAt: Date) -> PairingOffer? {
        let expiresAt = issuedAt.addingTimeInterval(NodeWire.pairingOfferLifetime)
        guard let body = SBSigning.offerBody(
            nodeId: identity.nodeId,
            publicKey: identity.publicKeyBase64URL,
            link: link,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        ) else {
            lastError = SBChatWire.sanitized("无法构造配对 body / could not build the pairing body")
            return nil
        }
        guard let rawSignature = identity.signature(for: body) else {
            lastError = "Ed25519 签名失败 / signing failed"
            return nil
        }
        let signature = TextKit.base64URL(rawSignature)
        guard SBSigning.verify(publicKeyBase64URL: identity.publicKeyBase64URL, signatureBase64URL: signature, body: body) else {
            lastError = SBChatWire.sanitized("签名自检失败，拒绝发布配对码 / signature self-check failed, refusing to publish")
            publish("\(lastError ?? "")", level: .error, channel: .pairing)
            return nil
        }
        let code = SBSigning.pairingCode(body: body, signature: signature)
        let offer = PairingOffer(
            code: code,
            invitationURI: link,
            nodePublicKey: identity.publicKeyBase64URL,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            oneTime: true,
            used: false
        )
        cachedOffer = offer
        persistOffer(offer)
        publish(
            "已铸造一次性配对二维码，\(offer.secondsRemaining(at: issuedAt)) 秒内有效 / minted a one-time pairing offer",
            level: .success,
            channel: .pairing,
            payload: [
                "offer": .string(Self.codeFingerprint(code)),
                "node": .string(identity.nodeId),
                "expiresAt": .string(expiresAt.ppxISO8601),
                "linkLength": .int(link.count)
            ]
        )
        return offer
    }

    /// A cached offer is only trusted when it is *ours*: verify the signature first,
    /// then the claims (`exp`, node id, key, embedded link).
    private func loadOffer() {
        guard let stored = SBStore.read(PairingOffer.self, at: AppPaths.offerFile) else { return }
        guard verify(stored) else {
            cachedOffer = nil
            lastError = SBChatWire.sanitized(
                "缓存的配对码验签失败（密钥已换或被篡改），已丢弃 / cached pairing offer failed verification and was dropped"
            )
            publish("\(lastError ?? "")", level: .warning, channel: .pairing)
            return
        }
        cachedOffer = stored
    }

    private func verify(_ offer: PairingOffer) -> Bool {
        guard let identity = keyPair else { return false }
        guard let (body, signature) = SBSigning.splitPairingCode(offer.code) else { return false }
        guard SBSigning.verify(publicKeyBase64URL: identity.publicKeyBase64URL, signatureBase64URL: signature, body: body) else {
            return false
        }
        guard let fields = SBSigning.bodyFields(body),
              SBJSON.string(fields["node"]) == identity.nodeId,
              SBJSON.string(fields["key"]) == identity.publicKeyBase64URL,
              let expiry = SBJSON.integer(fields, "exp"),
              expiry >= Int(Date().timeIntervalSince1970)
        else {
            return false
        }
        if let link = SBJSON.string(fields["link"]), link != offer.invitationURI { return false }
        if let once = SBJSON.field(fields, "once"), once as? Bool == false { return false }
        return true
    }

    private func persistOffer(_ offer: PairingOffer) {
        if !SBStore.write(offer, to: AppPaths.offerFile, fileProtection: true) {
            lastError = SBChatWire.sanitized("无法写入 offer.json / pairing offer persistence failed")
        }
    }

    /// Pairing codes are one-time credentials. They reach the audit log and the SSE
    /// stream, so only a fingerprint ever leaves this actor.
    private static func codeFingerprint(_ code: String) -> String {
        "\(NodeWire.pairingCodePrefix)·\(Digest.short(Data(code.utf8), length: 10))"
    }

    // MARK: - Delivery

    private func resolveTargetContact(for result: CommandResult, serviceId: String) -> String? {
        if let commandID = result.commandID,
           let contactId = commandTargets[commandID],
           whitelistedContact(contactId) != nil {
            return contactId
        }
        // Otherwise answer the most recently seen paired device: a node has a handful
        // of phones at most, and a result with no addressee is far better delivered to
        // the owner's phone than dropped on the floor.
        return activeDevices()
            .sorted { ($0.lastSeenAt ?? $0.pairedAt) > ($1.lastSeenAt ?? $1.pairedAt) }
            .first?.contactId
    }

    /// Card text plus one message per artifact.
    ///
    /// At-least-once semantics: if a file frame fails after the card went out, the
    /// whole result is re-queued, because a duplicated card is cheaper than a
    /// silently missing video.
    private func sendResult(_ result: CommandResult, to contactId: String) async -> SBOutcome {
        var card = result.cardText
        if !result.body.isEmpty {
            card += "\n\n" + TextKit.truncate(result.body, to: 1_800)
        }
        guard let textLine = SBChatWire.sendLine(contactId: contactId, items: [SBChatWire.textItem(card)]) else {
            return .failed("无法构造卡片帧 / could not build the card frame")
        }
        switch await perform(textLine, timeout: SBChatWire.commandTimeout) {
        case .payload:
            break
        case .chatError(let detail):
            return .failed("卡片被拒绝 / card refused: \(detail)")
        case .timedOut:
            return .failed("卡片发送超时 / card send timed out")
        case .transport(let detail):
            return .failed("卡片无法发送 / card could not be sent: \(detail)")
        }
        for artifact in result.artifacts where !artifact.isEmpty {
            guard fileManager.fileExists(atPath: artifact) else {
                return .failed("产物文件不存在 / artifact is missing: \(AppPaths.anonymise(artifact))")
            }
            let name = artifact.split(separator: "/").last.map(String.init) ?? "artifact"
            guard let line = SBChatWire.sendLine(contactId: contactId, items: [SBChatWire.fileItem(path: artifact, name: name)]) else {
                return .failed("无法构造文件帧 / could not build the file frame")
            }
            switch await perform(line, timeout: SBChatWire.commandTimeout) {
            case .payload:
                continue
            case .chatError(let detail):
                return .failed("产物被拒绝 / artifact refused: \(AppPaths.anonymise(detail))")
            case .timedOut:
                return .failed("产物发送超时 / artifact send timed out")
            case .transport(let detail):
                return .failed("产物无法发送 / artifact could not be sent: \(AppPaths.anonymise(detail))")
            }
        }
        return .sent
    }

    // MARK: - Outbox

    private func enqueueOutbox(_ result: CommandResult, serviceId: String, contactId: String?, reason: String) {
        let entry = SBOutboxEntry(
            result: result,
            serviceId: serviceId,
            contactId: contactId,
            queuedAt: Date(),
            attempts: 0,
            url: nil
        )
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let name = "\(stamp)-\(TextKit.safeFileName("\(serviceId)-\(result.id)")).json"
        let url = AppPaths.outbox.appendingPathComponent(name)
        lastError = SBChatWire.sanitized("结果已入队 / result queued: \(reason)")
        publish(
            SBStore.write(entry, to: url, fileProtection: false)
                ? "结果已写入 outbox，等待下次连接 / result queued in the outbox"
                : "结果入队失败 / outbox write failed: \(AppPaths.anonymise(url.lastPathComponent))",
            level: .warning,
            channel: .result,
            payload: [
                "engine": .string(result.engine.rawValue),
                "reason": .string(TextKit.truncate(reason, to: 120))
            ]
        )
    }

    /// Sorted by name: the file name starts with a fixed-width millisecond stamp, so
    /// lexicographic order is queue order.
    private func readOutbox() -> [SBOutboxEntry] {
        let directory = AppPaths.outbox
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name -> SBOutboxEntry? in
            guard name.hasSuffix(".json") else { return nil }
            let url = directory.appendingPathComponent(name)
            guard var entry = SBStore.read(SBOutboxEntry.self, at: url) else { return nil }
            entry.url = url
            return entry
        }
    }

    private func outboxCount() -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: AppPaths.outbox.path) else { return 0 }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    // MARK: - Subscribers

    private func attachSubscriber(id: UUID, continuation: AsyncStream<NodeCommand>.Continuation) {
        subscribers[id] = continuation
        for command in commandBacklog { continuation.yield(command) }
    }

    private func detachSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Logging

    private func publish(
        _ message: String,
        level: EventLevel,
        channel: ConsoleEvent.Channel = .bridge,
        payload: [String: JSONValue] = [:]
    ) {
        let safe = SBChatWire.sanitized(message)
        appendAudit(safe, level: level, channel: channel)
        let hub = self.hub
        Task {
            await hub.publish(channel, safe, level: level, payload: payload)
        }
    }

    /// Node-side audit trail, kept separate from the installer log so a support
    /// bundle can show the pairing history on its own.
    private func appendAudit(_ message: String, level: EventLevel, channel: ConsoleEvent.Channel) {
        let url = AppPaths.auditLogFile
        let line = "\(Date().ppxISO8601) [\(level.rawValue)] (\(channel.rawValue)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? fileManager.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

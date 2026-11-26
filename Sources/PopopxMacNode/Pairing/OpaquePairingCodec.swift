// Copyright (c) 2026 POPOPX (popopx.chat)
// SPDX-License-Identifier: AGPL-3.0-only
//
// Opaque pairing links: the public share form of a node pairing credential.
//
// Byte-level agreement with the implementations already shipped is the whole
// point of this file, so the constants below are not free parameters:
//
//   popopx-service-suite  gateway/app/opaque_invite_codec.py                     (a6c1632)
//   popopx-service-suite  official_tools/swift_opaque_invite_oracle.swift        (same commit)
//   popopx-bot-studio     studio/app/security/opaque_invite_codec.py
//
// A link is one path-shaped URL over an authenticated envelope:
//
//   https://popopx.chat/i/v1/<unpadded-base64url(nonce || ciphertext || tag)>
//
// The dotted form `https://popopx.chat.<code>` is unusable and never produced:
// a DNS label caps at 63 characters and the ciphertext is far longer, so the
// host never resolves — and `popopx.chat` alone is the host the shipped clients
// accept for an opaque link.

import CryptoKit
import Foundation
import Security

/// Refusals, spelled with the same stable codes the Python codecs use, so one
/// audit line can be read by all three implementations. The payloads a refusal
/// names are byte counts, never the payload text.
public enum OpaquePairingError: Error, Equatable, CustomStringConvertible {
    case payloadRequired
    case payloadShape
    case payloadScheme
    case payloadTooLong(bytes: Int, limit: Int)
    case nonceLength(bytes: Int)
    case entropyUnavailable
    case linkPrefix
    case codeShape
    case codeLength(chars: Int, limit: Int)
    case envelopeTooShort(bytes: Int)
    case tampered
    case payloadNotUTF8

    public var description: String {
        switch self {
        case .payloadRequired: return "invite_uri_required"
        case .payloadShape: return "invite_uri_invalid"
        case .payloadScheme: return "invite_uri_scheme_invalid"
        case .payloadTooLong(let bytes, let limit): return "invite_uri_too_long: \(bytes) > \(limit)"
        case .nonceLength(let bytes): return "invite_nonce_invalid: \(bytes)"
        case .entropyUnavailable: return "invite_entropy_unavailable"
        case .linkPrefix: return "invite_link_version_unsupported"
        case .codeShape: return "invite_code_invalid"
        case .codeLength(let chars, let limit): return "invite_link_invalid: \(chars) > \(limit)"
        case .envelopeTooShort(let bytes): return "invite_link_invalid: \(bytes) bytes"
        case .tampered: return "invite_link_tampered"
        case .payloadNotUTF8: return "invite_link_invalid: payload is not UTF-8"
        }
    }
}

public enum OpaquePairingCodec {
    /// Format v1 is fixed on purpose, not versioned away from: changing any input
    /// here is a new link format, and every link already handed out stops decoding.
    public static let version = "v1"
    public static let linkPrefix = "https://popopx.chat/i/\(version)/"

    /// Published format key material. It ships inside the app, so an envelope hides
    /// the relay from link previews, screenshots and forwards — it is not
    /// confidentiality against someone who opens this file or the binary.
    static let ikmHex = "d1abbcb09b5bf244d9d8b6b1dcc38835b5a419d8a1d62b014c1bb49e765dbdeb"
    static let saltText = "popopx.chat/invite-link/v1/salt"
    static let infoText = "popopx.chat/invite-link/v1/key"
    static let aadText = "popopx.chat/invite-link/v1/aad"
    /// The derived key the vectors file publishes for the inputs above. A drift in
    /// any of them changes this value, so a test can pin the derivation alone.
    static let publishedKeyHex = "18aae99401e21c87b52136c3e7e4cce3324db73fa4e076f9b93bdbcc941ed598"

    public static let nonceBytes = 12
    public static let tagBytes = 16
    public static let keyBytes = 32

    /// What this node puts *into* an envelope — the gateway's `MAX_URI_BYTES`.
    /// Emitting anything longer would produce a link the gateway itself refuses to
    /// open, so the send side keeps the tighter limit even though the receive side
    /// is looser.
    public static let maxSealableBytes = 2048

    /// What this node accepts *out of* an envelope — bot-studio's
    /// `MAX_ADDRESS_BYTES`, the cap the client decoders were given.
    public static let maxOpenableBytes = 4096

    /// The schemes the ecosystem's codecs will seal.
    public static let sealableSchemes = ["popopx:/", "popopx://", "https://"]

    /// A relay address may be shown to the node's owner in the diagnostics drawer and
    /// may arrive inside someone else's envelope, but this node never wraps one —
    /// bot-studio states the same rule (`smp://` is diagnostics-only, not sealable).
    public static let diagnosticsOnlySchemes = ["smp://"]

    /// Schemes a decoded envelope may carry. One wider than `sealableSchemes`: a
    /// relay URI another implementation sealed is still worth showing its owner
    /// rather than throwing away.
    public static let openableSchemes = sealableSchemes + diagnosticsOnlySchemes

    /// The Mac Node pairing credential, `PPXNODE1-<base64url(body)>.<base64url(sig)>`.
    /// It is a signed payload, not a URI, so it is named here instead of smuggled
    /// into the scheme list.
    public static var pairingPayloadPrefix: String { "\(NodeWire.pairingCodePrefix)-" }

    static let saltData = Data(saltText.utf8)
    static let infoData = Data(infoText.utf8)
    static let aadData = Data(aadText.utf8)
    static let ikmData: Data = hex(ikmHex) ?? Data()
    static let key: SymmetricKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikmData),
        salt: saltData,
        info: infoData,
        outputByteCount: keyBytes
    )

    /// Base64URL character ceilings for each plaintext cap, computed the way the
    /// Python codecs compute theirs.
    public static let maxSealableCodeChars = codeChars(forPlaintextBytes: nonceBytes + maxSealableBytes + tagBytes)
    public static let maxOpenableCodeChars = codeChars(forPlaintextBytes: nonceBytes + maxOpenableBytes + tagBytes)

    public struct Sealed {
        public let link: String
        public let code: String
        public let nonce: Data
        public let payloadBytes: Int
    }

    // MARK: - Encoding

    /// Wraps one payload and returns the public link.
    ///
    /// - Parameter nonce: only for reproducing a published test vector. A production
    ///   call must leave it nil: two envelopes under this fixed key sharing a nonce
    ///   expose the two plaintexts to each other, and the same URI is meant to
    ///   produce a different link every time.
    public static func seal(_ payload: String, nonce: Data? = nil) throws -> Sealed {
        let text = try validatedForSealing(payload)
        let nonceData: Data
        if let nonce {
            guard nonce.count == nonceBytes else { throw OpaquePairingError.nonceLength(bytes: nonce.count) }
            nonceData = nonce
        } else {
            nonceData = try randomNonce()
        }
        let box = try ChaChaPoly.seal(
            Data(text.utf8),
            using: key,
            nonce: ChaChaPoly.Nonce(data: nonceData),
            authenticating: aadData
        )
        let sealed = nonceData + box.ciphertext + box.tag
        let code = base64URL(sealed)
        return Sealed(link: linkPrefix + code, code: code, nonce: nonceData,
                      payloadBytes: Data(text.utf8).count)
    }

    public static func link(for payload: String, nonce: Data? = nil) throws -> String {
        try seal(payload, nonce: nonce).link
    }

    /// The pairing credential in its public form: what a QR and a copy button carry.
    public static func pairingLink(_ pairingCode: String, nonce: Data? = nil) throws -> String {
        try link(for: pairingCode, nonce: nonce)
    }

    // MARK: - Decoding

    /// Opens a link and returns the payload it carries. Any AEAD failure is
    /// `tampered`: a link is either intact or it is not a pairing link.
    public static func open(_ link: String) throws -> String {
        try payload(inCode: try code(fromLink: link))
    }

    /// Opens a pairing link and returns its credential, refusing a link that carries
    /// anything other than this node's pairing payload.
    public static func openPairing(_ link: String) throws -> String {
        let payload = try open(link)
        guard payload.hasPrefix(pairingPayloadPrefix) else { throw OpaquePairingError.payloadScheme }
        return payload
    }

    static func code(fromLink link: String) throws -> String {
        guard link.hasPrefix(linkPrefix) else { throw OpaquePairingError.linkPrefix }
        let code = String(link.dropFirst(linkPrefix.count))
        guard !code.isEmpty, code.count <= maxOpenableCodeChars else {
            throw OpaquePairingError.codeLength(chars: code.count, limit: maxOpenableCodeChars)
        }
        return code
    }

    static func payload(inCode code: String) throws -> String {
        guard isBase64URL(code), let sealed = base64URLDecode(code) else {
            throw OpaquePairingError.codeShape
        }
        guard sealed.count > nonceBytes + tagBytes else {
            throw OpaquePairingError.envelopeTooShort(bytes: sealed.count)
        }
        guard sealed.count <= nonceBytes + maxOpenableBytes + tagBytes else {
            throw OpaquePairingError.payloadTooLong(bytes: sealed.count - nonceBytes - tagBytes,
                                                    limit: maxOpenableBytes)
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Data(sealed.prefix(nonceBytes))),
                ciphertext: Data(sealed.dropFirst(nonceBytes).dropLast(tagBytes)),
                tag: Data(sealed.suffix(tagBytes))
            )
        } catch {
            throw OpaquePairingError.codeShape
        }
        let opened: Data
        do {
            opened = try ChaChaPoly.open(box, using: key, authenticating: aadData)
        } catch {
            throw OpaquePairingError.tampered
        }
        guard let text = String(data: opened, encoding: .utf8) else {
            throw OpaquePairingError.payloadNotUTF8
        }
        try validatedAsOpened(text)
        return text
    }

    // MARK: - Presentation

    /// Shape check only — it does not prove the envelope authenticates.
    public static func isOpaqueLink(_ value: String?) -> Bool {
        guard let value, let code = try? code(fromLink: value) else { return false }
        return isBase64URL(code)
    }

    /// The log-safe form: the prefix and the first ten code characters, never the
    /// whole code. This is what an audit row, an SSE event or a toast may carry.
    public static func mask(_ link: String) -> String {
        guard let code = try? code(fromLink: link), isBase64URL(code) else { return "…" }
        return "\(linkPrefix)\(code.prefix(10))…"
    }

    // MARK: - Validation

    static func validatedForSealing(_ payload: String) throws -> String {
        guard !payload.isEmpty else { throw OpaquePairingError.payloadRequired }
        guard payload.utf8.allSatisfy({ $0 > 0x20 && $0 != 0x7F }) else {
            // Covers surrounding whitespace, embedded spaces, tabs, newlines and
            // control characters — the same rule `opaque_invite_codec._validate_uri`
            // applies, and a byte above 0x7F is just a UTF-8 continuation byte.
            throw OpaquePairingError.payloadShape
        }
        guard acceptsAsPayload(payload) else { throw OpaquePairingError.payloadScheme }
        let bytes = Data(payload.utf8).count
        guard bytes <= maxSealableBytes else {
            throw OpaquePairingError.payloadTooLong(bytes: bytes, limit: maxSealableBytes)
        }
        return payload
    }

    static func validatedAsOpened(_ payload: String) throws {
        guard !payload.isEmpty else { throw OpaquePairingError.payloadRequired }
        guard payload.utf8.allSatisfy({ $0 != 0x00 && $0 != 0x0A && $0 != 0x0D }) else {
            throw OpaquePairingError.payloadShape
        }
        guard payload.hasPrefix(pairingPayloadPrefix)
            || openableSchemes.contains(where: { payload.hasPrefix($0) }) else {
            throw OpaquePairingError.payloadScheme
        }
    }

    static func acceptsAsPayload(_ payload: String) -> Bool {
        payload.hasPrefix(pairingPayloadPrefix) || sealableSchemes.contains { payload.hasPrefix($0) }
    }

    // MARK: - Bytes

    static func codeChars(forPlaintextBytes totalBytes: Int) -> Int {
        ((totalBytes + 2) / 3) * 4
    }

    static func isBase64URL(_ text: String) -> Bool {
        guard !text.isEmpty, text.count % 4 != 1 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2D, 0x5F, 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            default: return false
            }
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    static func randomNonce() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: nonceBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            // No weak fallback: a repeated nonce under this fixed key is worse than a
            // failed link.
            throw OpaquePairingError.entropyUnavailable
        }
        return Data(buffer)
    }

    static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func hexLower(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

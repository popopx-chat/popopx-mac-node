//
//  OpaquePairingTests.swift
//  The opaque pairing envelope: byte-level agreement with the published vectors,
//  AEAD refusal, and the privacy property the whole format exists for.
//
//  Five groups, in the order the format can fail:
//
//  * the derivation — one changed byte in IKM/salt/info and every link already
//    handed out stops decoding, so the key is pinned alone, before the envelopes;
//  * the published vectors — re-sealed and re-opened from the typed literals, then
//    again from the live `popopx-service-suite` file when this machine has it;
//  * tamper — a flipped *bit* in the tag, and the shapes that must never open;
//  * the leak property — no relay label, no plaintext, no legacy credential in any
//    emitted link, plus the mask an audit row is allowed to keep;
//  * the send-side limits — scheme list, byte caps and the QR budget a real
//    credential has to fit once it is wrapped.
//

import CryptoKit
import Foundation
import XCTest

@testable import PopopxMacNode

final class OpaquePairingTests: XCTestCase {
    // MARK: - The published vectors, typed so this suite is self-contained

    private struct Vector {
        let name: String
        let nonceHex: String
        let plaintext: String
        let code: String
        let link: String
    }

    /// Copied verbatim from `popopx-service-suite/gateway/app/opaque_invite_vectors.json`
    /// at commit `a6c1632` (sha256 `bcc0661205ecdba5de857ceb45f19cda6312feadc3ed7c6ec661af9edabfea26`).
    /// To regenerate after the suite changes: read that file, or run
    /// `swiftc -O -o /tmp/oracle official_tools/swift_opaque_invite_oracle.swift && /tmp/oracle gateway/app/opaque_invite_vectors.json`.
    /// `testPublishedVectorsFromFileWhenTheSuiteRepoIsPresent` re-checks these
    /// literals against the live file, so a stale copy here is a red test, not a lie.
    private let vectors: [Vector] = [
        Vector(
            name: "contact",
            nonceHex: "000102030405060708090a0b",
            plaintext: "https://smp1.popopx.im/a#contact-key-7f3c9d2e",
            code: "AAECAwQFBgcICQoLexDnGT5IpFl-wACcrRaMD-VAL_Neu_mxEVFBSiy_ntA1jeFWJQUOK2KN-Brkjm6cyTDMBLG6otbYN40_yA",
            link: "https://popopx.chat/i/v1/AAECAwQFBgcICQoLexDnGT5IpFl-wACcrRaMD-VAL_Neu_mxEVFBSiy_ntA1jeFWJQUOK2KN-Brkjm6cyTDMBLG6otbYN40_yA"
        ),
        Vector(
            name: "channel",
            nonceHex: "0c0d0e0f1011121314151617",
            plaintext: "popopx://channel/smp8.popopx.im/green-room#key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&pub=ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
            code: "DA0ODxAREhMUFRYXVJ7hF63rsa2m286inXXWr22y2IaJXqr8lpdlGFgdUpN9B3kYlSCkZ33ihVEe_8yT00K1YMzCcMTw61_JNVt1pWGhl84dXlszrmsVrL8TsxN5Dd-iy8hHBzDS_O4dUQvSXCh7vhUuMkq0A30GfAHUoaWG6_YR73N5YmVK4FpCm_GNxAZX1lwqaHI2hQATkoR5Ppb0x9VPwQLtnQ",
            link: "https://popopx.chat/i/v1/DA0ODxAREhMUFRYXVJ7hF63rsa2m286inXXWr22y2IaJXqr8lpdlGFgdUpN9B3kYlSCkZ33ihVEe_8yT00K1YMzCcMTw61_JNVt1pWGhl84dXlszrmsVrL8TsxN5Dd-iy8hHBzDS_O4dUQvSXCh7vhUuMkq0A30GfAHUoaWG6_YR73N5YmVK4FpCm_GNxAZX1lwqaHI2hQATkoR5Ppb0x9VPwQLtnQ"
        ),
    ]

    // MARK: - Derivation

    func testTheFormatKeyIsDerivedFromThePublishedInputs() throws {
        XCTAssertEqual(OpaquePairingCodec.ikmHex,
                       "d1abbcb09b5bf244d9d8b6b1dcc38835b5a419d8a1d62b014c1bb49e765dbdeb",
                       "the IKM is a cross-language constant, not a local choice")
        XCTAssertEqual(OpaquePairingCodec.saltText, "popopx.chat/invite-link/v1/salt")
        XCTAssertEqual(OpaquePairingCodec.infoText, "popopx.chat/invite-link/v1/key")
        XCTAssertEqual(OpaquePairingCodec.aadText, "popopx.chat/invite-link/v1/aad")
        XCTAssertEqual(OpaquePairingCodec.hexLower(OpaquePairingCodec.key.withUnsafeBytes { Data($0) }),
                       OpaquePairingCodec.publishedKeyHex,
                       "HKDF-SHA256 over the published inputs must give the published key")
        XCTAssertEqual(OpaquePairingCodec.keyBytes, 32)
        XCTAssertEqual(OpaquePairingCodec.nonceBytes, 12, "ChaCha20-Poly1305 takes a 12-byte nonce")
        XCTAssertEqual(OpaquePairingCodec.tagBytes, 16)
    }

    // MARK: - Vectors

    func testPublishedVectorsSealByteForByte() throws {
        for vector in vectors {
            let nonce = try XCTUnwrap(OpaquePairingCodec.hex(vector.nonceHex), "\(vector.name): nonce is not hex")
            XCTAssertEqual(nonce.count, 12)
            let sealed = try OpaquePairingCodec.seal(vector.plaintext, nonce: nonce)
            XCTAssertEqual(sealed.code, vector.code, "\(vector.name): sealed bytes differ")
            XCTAssertEqual(sealed.link, vector.link, "\(vector.name): link differs")
        }
    }

    func testPublishedVectorsOpenToTheirOriginalPayloads() throws {
        for vector in vectors {
            XCTAssertEqual(try OpaquePairingCodec.open(vector.link), vector.plaintext, vector.name)
        }
    }

    func testPublishedVectorsCarryBothUriKinds() throws {
        let names = Set(vectors.map { $0.name })
        XCTAssertTrue(names.contains("contact"), "a service-account URI must stay covered")
        XCTAssertTrue(names.contains("channel"), "a channel URI must stay covered")
        for vector in vectors {
            XCTAssertTrue(vector.plaintext.lowercased().contains(".popopx.im"),
                          "\(vector.name): the vector must actually name a relay, or it proves nothing")
            XCTAssertFalse(vector.link.lowercased().contains("popopx.im"),
                           "\(vector.name): the published link leaks the relay")
            XCTAssertFalse(vector.link.contains(vector.plaintext))
        }
    }

    func testPublishedVectorsFromFileWhenTheSuiteRepoIsPresent() throws {
        let suite = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpaquePairingTests.swift
            .deletingLastPathComponent()   // Tests/PopopxMacNodeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PopopxMacNode
            .appendingPathComponent("popopx-service-suite/gateway/app/opaque_invite_vectors.json")
        guard FileManager.default.fileExists(atPath: suite.path) else {
            throw XCTSkip("popopx-service-suite is not beside this repo: the typed vectors were still checked")
        }
        let data = try Data(contentsOf: suite)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func text(_ key: String) throws -> String {
            try XCTUnwrap(root[key] as? String, "vectors file has no \(key)")
        }
        XCTAssertEqual(try text("format"), "opaque-invite-v1")
        XCTAssertEqual(try text("link_prefix"), OpaquePairingCodec.linkPrefix,
                       "the published prefix moved: digest \(digest)")
        XCTAssertEqual(try text("ikm_hex"), OpaquePairingCodec.ikmHex, "the IKM moved: digest \(digest)")
        XCTAssertEqual(try text("salt_utf8"), OpaquePairingCodec.saltText)
        XCTAssertEqual(try text("info_utf8"), OpaquePairingCodec.infoText)
        XCTAssertEqual(try text("aad_utf8"), OpaquePairingCodec.aadText)
        XCTAssertEqual(try text("key_hex"), OpaquePairingCodec.publishedKeyHex)
        let published = vectors.map { $0.code }
        let live = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(live.count, vectors.count,
                       "the suite published \(live.count) vectors; this suite still types \(vectors.count) (digest \(digest))")
        for (entry, expectedCode) in zip(live, published) {
            let name = try XCTUnwrap(entry["name"] as? String)
            let plaintext = try XCTUnwrap(entry["plaintext_utf8"] as? String)
            let nonce = try XCTUnwrap(OpaquePairingCodec.hex(try XCTUnwrap(entry["nonce_hex"] as? String)))
            XCTAssertEqual(try OpaquePairingCodec.seal(plaintext, nonce: nonce).code, expectedCode, name)
            XCTAssertEqual(try OpaquePairingCodec.open(try XCTUnwrap(entry["link"] as? String)), plaintext, name)
        }
    }

    // MARK: - Tamper

    /// Flips one bit of the tag, not one base64 character: the last character of an
    /// unpadded code can carry discarded padding bits, so a character swap may decode
    /// to identical bytes and "pass" for the wrong reason.
    private func flipLastSealedByte(of code: String) throws -> String {
        var raw = [UInt8](try XCTUnwrap(OpaquePairingCodec.base64URLDecode(code)))
        raw[raw.count - 1] ^= 0x01
        return OpaquePairingCodec.base64URL(Data(raw))
    }

    func testFlippingATagBitIsAlwaysRefused() throws {
        for vector in vectors {
            let code = try XCTUnwrap(vector.link.split(separator: "/", omittingEmptySubsequences: false).last)
            let tampered = try flipLastSealedByte(of: String(code))
            XCTAssertNotEqual(tampered, String(code), "\(vector.name): the flip changed nothing")
            XCTAssertThrowsError(try OpaquePairingCodec.open(OpaquePairingCodec.linkPrefix + tampered), vector.name) { error in
                XCTAssertEqual(error as? OpaquePairingError, .tampered, "\(vector.name): refused for the wrong reason")
            }
        }
    }

    func testFlippingACiphertextByteIsRefusedToo() throws {
        let sealed = try OpaquePairingCodec.seal("popopx:/i#link-key")
        var raw = [UInt8](try XCTUnwrap(OpaquePairingCodec.base64URLDecode(sealed.code)))
        raw[20] ^= 0x80   // past the nonce, inside the ciphertext
        XCTAssertThrowsError(try OpaquePairingCodec.open(OpaquePairingCodec.linkPrefix + OpaquePairingCodec.base64URL(Data(raw)))) { error in
            XCTAssertEqual(error as? OpaquePairingError, .tampered)
        }
    }

    func testNonceAndAADAreBothCoveredByTheTag() throws {
        let sealed = try OpaquePairingCodec.seal("https://popopx.chat/a#x", nonce: OpaquePairingCodec.hex("000000000000000000000000"))
        var raw = [UInt8](try XCTUnwrap(OpaquePairingCodec.base64URLDecode(sealed.code)))
        raw[0] ^= 0x01    // the nonce, not the ciphertext
        XCTAssertThrowsError(try OpaquePairingCodec.open(OpaquePairingCodec.linkPrefix + OpaquePairingCodec.base64URL(Data(raw)))) { error in
            XCTAssertEqual(error as? OpaquePairingError, .tampered, "a rotated nonce must not decode to the same payload")
        }
    }

    func testTheWrongShapeFailsClosedWithoutTouchingTheCipher() throws {
        let sealed = try OpaquePairingCodec.seal("popopx:/i#link-key")
        let cases: [(String, OpaquePairingError)] = [
            ("https://popopx.chat/i/v2/" + sealed.code, .linkPrefix),
            ("https://popopx.chat." + sealed.code, .linkPrefix),
            (sealed.code, .linkPrefix),
            (OpaquePairingCodec.linkPrefix, .codeLength(chars: 0, limit: OpaquePairingCodec.maxOpenableCodeChars)),
            (OpaquePairingCodec.linkPrefix + "not base64!", .codeShape),
            (OpaquePairingCodec.linkPrefix + "AAECA+Q", .codeShape),
            (OpaquePairingCodec.linkPrefix + String(sealed.code.prefix(1)), .codeShape),
            (OpaquePairingCodec.linkPrefix + String(sealed.code.prefix(16)), .envelopeTooShort(bytes: 12)),
        ]
        for (link, expected) in cases {
            XCTAssertThrowsError(try OpaquePairingCodec.open(link), String(link.prefix(44))) { error in
                XCTAssertEqual(error as? OpaquePairingError, expected)
            }
        }
    }

    // MARK: - The leak property

    func testAnEncodedLinkCarriesNoRelayAndNoLegacyCredential() throws {
        // Fixed nonces: the ciphertext alphabet can spell "smp" by chance, and a
        // privacy assertion that depends on the draw is a flaky test, not a gate.
        let cases: [(String, String)] = [
            ("https://smp1.popopx.im/a#contact-key-7f3c9d2e", "000102030405060708090a0b"),
            ("popopx:/invitation#/?v=6-8&smp=smp://smp8.popopx.im:443/1234567890abcdef", "0c0d0e0f1011121314151617"),
            (pairingCredential(), "18191a1b1c1d1e1f20212223"),
        ]
        for (payload, nonceHex) in cases {
            XCTAssertTrue(payload.lowercased().contains("popopx.im") || payload.hasPrefix(NodeWire.pairingCodePrefix),
                          "\(payload.prefix(24)): the payload must name a relay, or the check proves nothing")
            let link = try OpaquePairingCodec.link(for: payload, nonce: try XCTUnwrap(OpaquePairingCodec.hex(nonceHex)))
            XCTAssertTrue(link.hasPrefix("https://popopx.chat/i/v1/"), "prefix must be exactly the published one")
            let lowered = link.lowercased()
            XCTAssertFalse(lowered.contains("smp"), "\(payload.prefix(24)): a relay label survived into the link")
            XCTAssertFalse(lowered.contains(".popopx.im"))
            XCTAssertFalse(lowered.contains("ppxnode1"))
            XCTAssertFalse(link.contains(payload))
            XCTAssertFalse(link.contains("popopx:/"), "the inner scheme must be inside the cipher")
            XCTAssertTrue(OpaquePairingCodec.isOpaqueLink(link))
            XCTAssertEqual(try OpaquePairingCodec.open(link), payload, "and it still opens")
        }
    }

    func testTheSamePayloadProducesADifferentLinkEveryTime() throws {
        let payload = pairingCredential()
        let links = try (0..<50).map { _ in try OpaquePairingCodec.link(for: payload) }
        XCTAssertEqual(Set(links).count, 50, "a repeated nonce makes two envelopes comparable")
        let nonces = try (0..<50).map { _ in try OpaquePairingCodec.seal(payload).nonce }
        XCTAssertEqual(Set(nonces.map { OpaquePairingCodec.hexLower($0) }).count, 50)
        for link in links.prefix(5) {
            XCTAssertEqual(try OpaquePairingCodec.open(link), payload)
        }
    }

    func testMaskingKeepsOnlyTenCodeCharacters() throws {
        let link = try OpaquePairingCodec.link(for: pairingCredential())
        let code = String(link.dropFirst(OpaquePairingCodec.linkPrefix.count))
        let masked = OpaquePairingCodec.mask(link)
        XCTAssertEqual(masked, "\(OpaquePairingCodec.linkPrefix)\(code.prefix(10))…")
        XCTAssertFalse(masked.contains(code), "a mask that carries the code is not a mask")
        XCTAssertEqual(OpaquePairingCodec.mask("https://smp1.popopx.im/a#x"), "…", "a non-link masks to a bare ellipsis")
        XCTAssertEqual(OpaquePairingCodec.mask("popopx:/i#abc"), "…")
        XCTAssertEqual(OpaquePairingCodec.mask(""), "…")
    }

    // MARK: - Send-side limits

    func testOnlyTheEcosystemSchemeListMayBeSealed() throws {
        for allowed in ["popopx:/i#abc/def", "popopx://channel/host/room#k=x", "https://smp1.popopx.im/a#k",
                        pairingCredential()] {
            _ = try OpaquePairingCodec.seal(allowed)
        }
        let refused: [(String, OpaquePairingError)] = [
            ("", .payloadRequired),
            ("  ", .payloadShape),
            ("smp1.popopx.im/a", .payloadScheme),
            ("javascript:alert(1)", .payloadScheme),
            ("smp://smp1.popopx.im/queue", .payloadScheme),
            ("file:///etc/passwd", .payloadScheme),
            ("data:text/plain,hi", .payloadScheme),
        ]
        for (payload, expected) in refused {
            XCTAssertThrowsError(try OpaquePairingCodec.link(for: payload), escaped(payload)) { error in
                XCTAssertEqual(error as? OpaquePairingError, expected)
            }
        }
    }

    func testARelayUriFromSomewhereElseStillOpens() throws {
        // The two lists differ on purpose: `smp://` is never sealed here, but a link
        // another implementation wrapped around a relay URI is still worth showing the
        // owner, and refusing it would hide the very state the diagnostics panel reads.
        let relay = "smp://smp1.popopx.im:443/0123456789abcdef#queue"
        let sealed = try ChaChaPoly.seal(
            Data(relay.utf8),
            using: OpaquePairingCodec.key,
            nonce: try ChaChaPoly.Nonce(data: Data((0..<12).map { UInt8($0) })),
            authenticating: OpaquePairingCodec.aadData
        )
        let code = OpaquePairingCodec.base64URL(Data((0..<12).map { UInt8($0) }) + sealed.ciphertext + sealed.tag)
        XCTAssertEqual(try OpaquePairingCodec.open(OpaquePairingCodec.linkPrefix + code), relay)
        XCTAssertThrowsError(try OpaquePairingCodec.link(for: relay)) { error in
            XCTAssertEqual(error as? OpaquePairingError, .payloadScheme)
        }
    }

    func testWhitespaceAndControlBytesNeverEnterAnEnvelope() throws {
        for refused in ["https://smp1.popopx.im/a b", "https://smp1.popopx.im/a\nb", "https://smp1.popopx.im/a\tb",
                        " https://smp1.popopx.im/a", "https://smp1.popopx.im/a ", "\u{0}https://popopx.chat/a"] {
            XCTAssertThrowsError(try OpaquePairingCodec.link(for: refused), escaped(refused)) { error in
                XCTAssertEqual(error as? OpaquePairingError, .payloadShape)
            }
        }
    }

    func testTheSendSideStaysInsideTheGatewayCap() throws {
        let base = "https://popopx.chat/i#"
        XCTAssertEqual(OpaquePairingCodec.maxSealableBytes, 2048, "the gateway's MAX_URI_BYTES")
        XCTAssertEqual(OpaquePairingCodec.maxOpenableBytes, 4096, "bot-studio's MAX_ADDRESS_BYTES")
        XCTAssertEqual(OpaquePairingCodec.maxSealableCodeChars, 2768)
        XCTAssertEqual(OpaquePairingCodec.maxOpenableCodeChars, 5500)
        _ = try OpaquePairingCodec.link(for: base + String(repeating: "a", count: OpaquePairingCodec.maxSealableBytes - base.count))
        XCTAssertThrowsError(try OpaquePairingCodec.link(for: base + String(repeating: "a", count: OpaquePairingCodec.maxSealableBytes - base.count + 1))) { error in
            XCTAssertEqual(error as? OpaquePairingError,
                           .payloadTooLong(bytes: OpaquePairingCodec.maxSealableBytes + 1,
                                           limit: OpaquePairingCodec.maxSealableBytes))
        }
        // Everything this node can emit must also be openable by the gateway.
        let longest = try OpaquePairingCodec.link(for: base + String(repeating: "a", count: OpaquePairingCodec.maxSealableBytes - base.count))
        XCTAssertLessThanOrEqual(longest.count - OpaquePairingCodec.linkPrefix.count, 2768)
    }

    func testANodeCredentialFitsTheQRBudgetOnceWrapped() throws {
        let credential = pairingCredential()
        let link = try OpaquePairingCodec.pairingLink(credential)
        XCTAssertLessThanOrEqual(link.utf8.count, SBChatWire.qrPayloadBudget,
                                 "a wrapped credential must still scan at arm's length")
        XCTAssertTrue(link.hasPrefix(OpaquePairingCodec.linkPrefix))
        XCTAssertEqual(try OpaquePairingCodec.openPairing(link), credential)
        XCTAssertThrowsError(try OpaquePairingCodec.openPairing(try OpaquePairingCodec.link(for: "popopx:/i#a/b"))) { error in
            XCTAssertEqual(error as? OpaquePairingError, .payloadScheme, "a pairing link must carry a pairing payload")
        }
    }

    func testAnInjectedNonceOfTheWrongLengthIsRefused() throws {
        for bytes in [0, 8, 11, 13, 24] {
            XCTAssertThrowsError(try OpaquePairingCodec.seal("popopx:/i#a/b", nonce: Data(count: bytes))) { error in
                XCTAssertEqual(error as? OpaquePairingError, .nonceLength(bytes: bytes))
            }
        }
    }

    // MARK: - The surfaces that show a pairing link

    private func offer(secondsToExpiry: Int = 900) -> PairingOffer {
        let now = Date(timeIntervalSince1970: 1_766_400_000)
        return PairingOffer(
            code: pairingCredential(),
            invitationURI: "popopx:/invitation#/?v=6-8&smp=smp://smp8.popopx.im:443/abcdef",
            nodePublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(secondsToExpiry))
        )
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testADisplayedEncodingCarriesTheEnvelopeAndTheStoreDoesNot() throws {
        let shown = try dictionary(NodeJSON.encoder(displayingOpaqueLinks: true).encode(offer()))
        let stored = try dictionary(NodeJSON.encodeLine(offer()) ?? Data())
        let link = try XCTUnwrap(shown["pairingLink"] as? String)
        XCTAssertTrue(link.hasPrefix(OpaquePairingCodec.linkPrefix))
        XCTAssertFalse(link.contains(NodeWire.pairingCodePrefix), "the credential itself leaked into the link field")
        XCTAssertEqual(try OpaquePairingCodec.openPairing(link), offer().code)
        XCTAssertEqual(try XCTUnwrap(shown["pairingMask"] as? String), OpaquePairingCodec.mask(link))
        // offer.json keeps its old shape: a fresh nonce on every write would rewrite
        // the file, and a second copy of the credential has no business in the store.
        XCTAssertNil(stored["pairingLink"])
        XCTAssertNil(stored["pairingMask"])
        XCTAssertEqual(Set(stored.keys), Set(["code", "invitationURI", "nodePublicKey", "issuedAt", "expiresAt", "oneTime", "used"]))
        let storedData = try XCTUnwrap(NodeJSON.encodeLine(offer()))
        XCTAssertEqual(try XCTUnwrap(NodeJSON.decode(PairingOffer.self, from: storedData)), offer(),
                       "the store round-trip must be unchanged by a display field")
    }

    func testTheConsoleCardShowsTheLinkAndNothingElse() throws {
        let page = WEBConsoleHTML.document
        let card = try XCTUnwrap(body(of: "function renderPairing()", in: page), "the pairing card is gone")
        XCTAssertTrue(card.contains("valueBlock(\"link\", offer.pairingLink)"), "the card must show the sealed link")
        XCTAssertTrue(card.contains("PPX.copyThis('link')"), "the copy button must copy the sealed link")
        XCTAssertTrue(card.contains("renderPairingDiag(offer)"), "the raw values must still reach the drawer")
        for raw in ["valueBlock(\"code\"", "valueBlock(\"uri\"", "copyThis('code')", "copyThis('uri')", "offer.invitationURI"] {
            XCTAssertFalse(card.contains(raw), "the card leaks a raw credential field: \(raw)")
        }
        let diag = try XCTUnwrap(body(of: "function renderPairingDiag(offer)", in: page), "the pairing diagnostics block is gone")
        for raw in ["valueBlock(\"code\", offer.code)", "valueBlock(\"uri\", offer.invitationURI)", "valueBlock(\"pubkey\""] {
            XCTAssertTrue(diag.contains(raw), "the drawer no longer shows \(raw)")
        }
        // The rotate toast used to print the first 20 characters of the credential.
        XCTAssertTrue(page.contains("offer.pairingMask"), "the toast must fall back to the mask")
        XCTAssertFalse(page.contains("code.slice(0, 20)"), "the toast still prints a raw credential")
        // And the drawer entry point exists in the markup, hidden by default.
        XCTAssertTrue(page.contains("id=\"pair-diag\""))
        XCTAssertTrue(page.contains("data-i18n=\"pairDiagTitle\""))
    }

    func testTheQRAndTheEventLogBothSealBeforeTheyEmit() throws {
        let bridge = try source(at: "Sources/PopopxMacNode/Core/MacNodePopopxBridge.swift")
        let qr = try XCTUnwrap(body(of: "public func qrAsset(pixelSize: Int)", in: bridge), "qrAsset is gone")
        XCTAssertTrue(qr.contains("OpaquePairingCodec.pairingLink(offer.code)"), "the QR no longer carries the envelope")
        XCTAssertTrue(qr.contains("OpaquePairingCodec.link(for: offer.invitationURI)"), "the degraded QR must be sealed too")
        XCTAssertFalse(qr.contains("var payload = offer.code"), "the QR still emits the raw credential")
        XCTAssertFalse(qr.contains("SBQRCode.render(offer."), "the renderer is handed a raw value")
        let app = try source(at: "Sources/PopopxMacNodeApp/PopopxMacNodeApp.swift")
        XCTAssertTrue(app.contains("OpaquePairingCodec.pairingLink(offer.code)"), "the pairing event lost its sealed form")
        XCTAssertFalse(app.contains("\"code\": .string(offer.code)"), "the pairing event logs the raw credential")
    }

    // MARK: - Source-reading helpers

    private func source(at relative: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PopopxMacNodeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PopopxMacNode
        return try String(contentsOf: repo.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The head line through the brace that closes its block: the first `}` whose
    /// indent is no deeper than the head's. The indent is measured from the start of
    /// the line, not the match, or a method inside an actor reads as column zero and
    /// the "scope" runs to the end of the file. Scoping a gate to one body keeps a
    /// similar literal elsewhere in the file from satisfying it.
    private func body(of head: String, in text: String) -> String? {
        guard let start = text.range(of: head) else { return nil }
        let before = text[..<start.lowerBound]
        let lineBegin = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let base = text[lineBegin..<start.lowerBound].prefix(while: { $0 == " " }).count
        var out: [String] = []
        for line in text[lineBegin...].components(separatedBy: "\n") {
            out.append(line)
            let indent = line.prefix(while: { $0 == " " }).count
            if line.trimmingCharacters(in: .whitespaces) == "}", indent <= base, out.count > 1 { break }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// A realistic signed credential: the same shape `SBSigning.pairingCode` emits,
    /// with a link that names a relay inside it.
    private func pairingCredential(link: String = "popopx:/i#abcDEF123-456xyz_789/ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3") -> String {
        let body = "{\"exp\":1766400900,\"iat\":1766400000,\"key\":\"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8\",\"link\":\"\(link)\",\"node\":\"ppxnode-7f3c9d2e\",\"once\":true,\"v\":6}"
        let signature = OpaquePairingCodec.base64URL(Data((0..<64).map { UInt8($0 & 0xFF) }))
        return "\(NodeWire.pairingCodePrefix)-\(TextKit.base64URL(Data(body.utf8))).\(signature)"
    }

    private func escaped(_ text: String) -> String {
        text.unicodeScalars.map { $0.value < 0x20 ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
    }
}

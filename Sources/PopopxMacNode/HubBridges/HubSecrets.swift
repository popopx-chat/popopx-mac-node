//
//  HubSecrets.swift
//  PopopxMacNode — where a bridge's credential actually lives.
//
//  Task 3 asks for the Home Assistant Long-Lived Token and the MQTT credentials to be
//  "加密存入 macOS Keychain". This file is the only place that touches `SecItem`, and the
//  only reason a hub credential can never be found in `settings.json`, in a console
//  response, in the audit log, or in a DMG.
//
//  Two implementations, chosen once at startup:
//
//  * `HubKeychainStore` — a generic password per reference, for the bundled app. The
//    item is created with `SecItem.add` under this app's own service name, so it is
//    readable by this app and by nothing else that asks politely.
//  * `VolatileSecretStore` — process memory only, for a bare executable (`swift run`,
//    a test harness) where the Keychain is unavailable or the caller has no bundle
//    identity to attach an ACL to. Secrets entered there die with the process.
//
//  There is deliberately **no third option**: no plaintext file fallback. A credential
//  that cannot be kept in the Keychain is kept for the session or not kept at all —
//  writing it to `~/Library/Application Support/PopopxMacNode` would put the token on the
//  same disk, in the same directory the node already shares with bug reports, which is
//  the guarantee the whole feature is built on.
//

import Foundation
import Security

// MARK: - Contract

public protocol HubSecretStoring: Sendable {
    /// Stores `value` under `reference`. Returns false when it could not.
    @discardableResult
    func store(_ value: String, for reference: String) -> Bool
    func secret(for reference: String) -> String?
    @discardableResult
    func delete(reference: String) -> Bool
    /// Whether a stored secret survives this process. The console says so: an owner who
    /// typed a token into a run that cannot save it must be told, not left to guess.
    var isPersistent: Bool { get }
    var backingName: String { get }
}

// MARK: - References

/// The answer to 「did that credential get stored」.
///
/// A bare `String?` would force the caller to guess whether the string it got back is a
/// Keychain reference or a refusal sentence, and a guessed reference written into
/// `settings.json` is a credential that can never be found again.
public enum HubSecretOutcome: Sendable, Equatable {
    case stored(reference: String)
    case refused(reason: String)

    public var reference: String? {
        if case .stored(let value) = self { return value }
        return nil
    }
    public var isStored: Bool { reference != nil }
}

public enum HubSecrets {
    /// The Keychain service name. Namespaced to the product so an item is attributable
    /// and so nothing here can collide with another app's entries.
    public static let service = "im.popopx.macnode.hub"
    public static let maximumReferenceLength = 96
    public static let maximumSecretLength = 4096

    /// The reference for a bridge credential, e.g. `smarthome/homeassistant/token`.
    ///
    /// A reference is *not* a secret — it is a key name that appears in `settings.json`
    /// so the node knows which item to fetch. It is therefore constrained to characters
    /// that are safe to display in the console and safe to pass to Security.framework.
    public static func reference(_ path: String...) -> String {
        path.map { component($0) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func component(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .compactMap { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : nil }
            .map(String.init)
            .joined()
    }

    /// Whether a value already in a settings document may be used as a reference at all.
    /// A hand-edited `tokenRef` of `../../etc/passwd` or of the token itself must not be
    /// followed into the Keychain or echoed anywhere.
    public static func isSafeReference(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumReferenceLength else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/" }
    }

    /// Selects the store. A bundled app gets the Keychain; anything else gets memory, so
    /// `swift test` never creates, reads, or deletes a real Keychain item.
    public static func makeStore(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> HubSecretStoring {
        guard bundleIdentifier != nil else { return VolatileSecretStore() }
        return HubKeychainStore(service: service)
    }

    // MARK: Redaction

    /// The short label the console renders in place of a secret.
    ///
    /// A credential is shown as `••••` plus its reference, never as a prefix of itself.
    /// Six characters of a Long-Lived Token is most of its entropy, and the page this
    /// would appear on is served over TCP to any process that can reach 127.0.0.1.
    public static func display(_ reference: String, stored: Bool) -> String {
        guard isSafeReference(reference) else { return "—" }
        return stored ? "\(reference) · 已存入钥匙串 / stored" : "\(reference) · 未存入 / not stored"
    }
}

// MARK: - Keychain

public final class HubKeychainStore: HubSecretStoring, @unchecked Sendable {
    public let service: String
    public let isPersistent = true
    public var backingName: String { "keychain" }

    /// Last Security.framework status, for the console's diagnostic line. Written from
    /// whatever thread happens to fail, read for display; a race here costs one stale code.
    private(set) var lastStatus: OSStatus = errSecSuccess

    public init(service: String = HubSecrets.service) {
        self.service = service
    }

    public func store(_ value: String, for reference: String) -> Bool {
        guard HubSecrets.isSafeReference(reference), !value.isEmpty,
              value.utf8.count <= HubSecrets.maximumSecretLength else {
            lastStatus = errSecParam
            return false
        }
        let data = Data(value.utf8)
        var query = baseQuery(reference: reference)
        // Update first: an item that already exists under this reference must be replaced,
        // and `SecItem.add` on a duplicate returns errSecDuplicateItem, which would make a
        // "rotate my token" click look like a failure.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            lastStatus = errSecSuccess
            return true
        }
        guard updated == errSecItemNotFound else {
            lastStatus = updated
            return false
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        lastStatus = added
        return added == errSecSuccess
    }

    public func secret(for reference: String) -> String? {
        guard HubSecrets.isSafeReference(reference) else { return nil }
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var outcome: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &outcome)
        lastStatus = status
        guard status == errSecSuccess, let raw = outcome as? Data else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    public func delete(reference: String) -> Bool {
        guard HubSecrets.isSafeReference(reference) else { return false }
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        lastStatus = status
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public func hasSecret(for reference: String) -> Bool {
        guard HubSecrets.isSafeReference(reference) else { return false }
        var query = baseQuery(reference: reference)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var outcome: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &outcome) == errSecSuccess
    }

    /// References this store holds, for the console's "which credentials are on disk"
    /// panel. Returns names only, and names are already visible in `settings.json`.
    public func references() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var outcome: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &outcome) == errSecSuccess,
              let items = outcome as? [[String: Any]] else { return [] }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted()
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
    }
}

// MARK: - Volatile

/// Memory-only store, for an unpackaged run and for every test.
public final class VolatileSecretStore: HubSecretStoring, @unchecked Sendable {
    public let isPersistent = false
    public var backingName: String { "memory" }

    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init(secrets: [String: String] = [:]) {
        self.values = secrets
    }

    @discardableResult
    public func store(_ value: String, for reference: String) -> Bool {
        guard HubSecrets.isSafeReference(reference), !value.isEmpty,
              value.utf8.count <= HubSecrets.maximumSecretLength else { return false }
        lock.lock(); defer { lock.unlock() }
        values[reference] = value
        return true
    }

    public func secret(for reference: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[reference]
    }

    @discardableResult
    public func delete(reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.removeValue(forKey: reference) != nil
    }

    public func hasSecret(for reference: String) -> Bool {
        secret(for: reference) != nil
    }

    public func references() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }

    /// Used by test teardown, so a fixture token cannot outlive the case that made it.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

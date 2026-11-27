//
//  AssistantAuditStore.swift
//  PopopxMacNode — the private assistant's durable ledger.
//
//  A schedule that fired, a proposal that expired, a mail that was sent: each is a
//  row here. The store is deliberately narrow:
//
//  * **SQLite, local, no network.** `ledger/assistant.sqlite3` under the node root,
//    opened with `SQLITE_OPEN_FULLMUTEX` and no extension loading.
//  * **No credentials, no mail bodies.** Callers pass short facts; `record` also
//    scrubs credential-shaped substrings and collapses newlines as a second line
//    of defence, because an error description is exactly where a secret leaks.
//  * **Bounded.** The table keeps the newest 500 rows; the console reads the newest
//    20. An audit log that grows forever is a disk leak with a nice name.
//

import Foundation
import SQLite3

// MARK: - Sink protocol

/// Anything the gate, scheduler, bridge or sentinel can write an audit row to.
/// `AssistantAuditStore` is the production sink; tests use a recording fake or
/// `NoopAssistantAudit`.
public protocol AssistantAuditWriting: Sendable {
    func record(_ row: AssistantAuditRow) async
}

public struct NoopAssistantAudit: AssistantAuditWriting {
    public init() {}
    public func record(_ row: AssistantAuditRow) async {}
}

// MARK: - Redaction

public enum AssistantRedaction {
    /// Removes the two shapes that actually appear in a credential-bearing error:
    /// `password: …` / `token=…` and an `Authorization: Bearer …` header. The
    /// replacement keeps the label so a reader can still see *that* a secret was
    /// involved without seeing the value.
    public static func scrub(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Bearer first: the label pass below would otherwise consume the word
        // "Bearer" as the value of `authorization:` and leave the token in place.
        value = replacing(
            in: value,
            pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+",
            template: "Bearer •"
        )
        // JSON-shaped pairs have a quote between the key and the colon, which the
        // label pass cannot see. Scrub the quoted value before the loose pass.
        value = replacing(
            in: value,
            pattern: "(?i)(\"(?:password|passwd|secret|token|api[_-]?key|authorization)\"\\s*:\\s*)\"[^\"]*\"",
            template: "$1\"•\""
        )
        value = replacing(
            in: value,
            pattern: "(?i)(password|passwd|secret|token|api[_-]?key|authorization)\\s*[:=]\\s*\\S+",
            template: "$1: •"
        )
        return String(value.prefix(AssistantAuditStore.maximumDetail))
    }

    private static func replacing(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

// MARK: - Store

public actor AssistantAuditStore: AssistantAuditWriting {
    public static let maximumDetail = 320
    public static let snapshotEntries = 20
    public static let maximumStoredEntries = 500
    public static let stateKeyBriefing = "scheduler.briefing.last"
    public static let stateKeyPatrol = "scheduler.patrol.last"

    private var database: OpaquePointer?
    private var lastError = ""
    private let path: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (and creates) the database. A failure leaves `healthy == false` and
    /// every write a no-op; the assistant keeps working in memory rather than
    /// refusing to start because its log file is read-only.
    public init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            lastError = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if handle != nil { sqlite3_close(handle) }
            return
        }
        database = handle
        sqlite3_busy_timeout(handle, 1_000)
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS assistant_audit (
                id TEXT PRIMARY KEY,
                at REAL NOT NULL,
                channel TEXT NOT NULL,
                event TEXT NOT NULL,
                detail TEXT NOT NULL,
                outcome TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_assistant_audit_at ON assistant_audit(at DESC);",
            """
            CREATE TABLE IF NOT EXISTS assistant_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated REAL NOT NULL
            );
            """
        ] {
            if lastError.isEmpty, let message = Self.execute(statement, on: handle) {
                lastError = message
            }
        }
    }

    public init(url: URL) {
        self.init(path: url.path)
    }

    public var healthy: Bool { database != nil }
    public var failureReason: String { database != nil ? "" : lastError }
    public var filePath: String { path }

    public func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    // MARK: - Audit

    public func record(_ row: AssistantAuditRow) async {
        let detail = AssistantRedaction.scrub(row.detail)
        guard let database else { return }
        let sql = "INSERT OR REPLACE INTO assistant_audit (id, at, channel, event, detail, outcome) VALUES (?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(database))
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, row.id, -1, transient)
        sqlite3_bind_double(statement, 2, row.at.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, row.channel, -1, transient)
        sqlite3_bind_text(statement, 4, row.event, -1, transient)
        sqlite3_bind_text(statement, 5, detail, -1, transient)
        sqlite3_bind_text(statement, 6, row.outcome, -1, transient)
        if sqlite3_step(statement) != SQLITE_DONE {
            lastError = String(cString: sqlite3_errmsg(database))
        }
        if let message = Self.execute("""
            DELETE FROM assistant_audit WHERE id NOT IN
            (SELECT id FROM assistant_audit ORDER BY at DESC LIMIT \(Self.maximumStoredEntries));
            """, on: database) {
            lastError = message
        }
    }

    public func record(
        channel: String,
        event: String,
        detail: String = "",
        outcome: String = "ok",
        at: Date = Date()
    ) async {
        await record(AssistantAuditRow(at: at, channel: channel, event: event, detail: detail, outcome: outcome))
    }

    public func recent(limit: Int = snapshotEntries) async -> [AssistantAuditRow] {
        guard let database else { return [] }
        let capped = min(max(limit, 1), Self.maximumStoredEntries)
        let sql = "SELECT id, at, channel, event, detail, outcome FROM assistant_audit ORDER BY at DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(database))
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(capped))
        var rows: [AssistantAuditRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            let at = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let channel = text(statement, 2)
            let event = text(statement, 3)
            let detail = text(statement, 4)
            let outcome = text(statement, 5)
            rows.append(AssistantAuditRow(id: id, at: at, channel: channel, event: event, detail: detail, outcome: outcome))
        }
        return rows
    }

    // MARK: - Scheduler state

    public func state(_ key: String) async -> String? {
        guard let database, !key.isEmpty else { return nil }
        let sql = "SELECT value FROM assistant_state WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    public func setState(_ key: String, value: String, at: Date = Date()) async {
        guard let database, !key.isEmpty else { return }
        let sql = "INSERT OR REPLACE INTO assistant_state (key, value, updated) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(database))
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
        if sqlite3_step(statement) != SQLITE_DONE {
            lastError = String(cString: sqlite3_errmsg(database))
        }
    }

    public func stateDate(_ key: String) async -> Date? {
        guard let raw = await state(key), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func setStateDate(_ key: String, date: Date) async {
        await setState(key, value: String(date.timeIntervalSince1970), at: date)
    }

    // MARK: - SQLite plumbing

    private static func execute(_ sql: String, on database: OpaquePointer) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        if let error { sqlite3_free(error) }
        return result == SQLITE_OK ? nil : String(cString: sqlite3_errmsg(database))
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}
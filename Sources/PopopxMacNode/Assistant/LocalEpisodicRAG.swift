//
//  LocalEpisodicRAG.swift
//  PopopxMacNode — a wholly local, encrypted memory over the owner's own history.
//
//  The index never leaves the Mac and never stores readable text:
//
//    * every title, body and source path is sealed with AES-GCM before SQLite
//      sees it;
//    * the FTS5 table indexes HMACs of normalized terms, not the terms, so a
//      copied database cannot be read with `strings`;
//    * ranking is FTS5 BM25 reranked by a small hashed-term cosine vector, which
//      gives a useful "keyword + vector" score without bundling an embedding
//      model or calling a cloud endpoint;
//    * indexing only walks paths that `WorkspaceSandbox` already admits, so the
//      assistant cannot remember a file the owner never authorized.
//
//  Search is read-only. Remembering a voice task *is* a write, and the manager
//  only reaches `record` after an approval receipt has been consumed.
//

import CryptoKit
import Foundation
import SQLite3

// MARK: - Public models

public enum EpisodicKind: String, Codable, Sendable, CaseIterable {
    case document
    case briefing
    case bill
    case alert
    case voice
    case mailSummary = "mail_summary"

    public var labelZh: String {
        switch self {
        case .document: return "文档"
        case .briefing: return "每日简报"
        case .bill: return "账单"
        case .alert: return "设备告警"
        case .voice: return "语音备忘"
        case .mailSummary: return "邮件摘要"
        }
    }

    public var labelEn: String {
        switch self {
        case .document: return "document"
        case .briefing: return "briefing"
        case .bill: return "bill"
        case .alert: return "alert"
        case .voice: return "voice memo"
        case .mailSummary: return "mail summary"
        }
    }
}

public struct EpisodicCitation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: EpisodicKind
    public var title: String
    public var snippet: String
    public var source: String
    public var occurredAt: Date
    public var score: Double

    public init(
        id: String,
        kind: EpisodicKind,
        title: String,
        snippet: String,
        source: String,
        occurredAt: Date,
        score: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.source = source
        self.occurredAt = occurredAt
        self.score = score
    }
}

public struct EpisodicAnswer: Codable, Sendable, Equatable {
    public var ok: Bool
    public var question: String
    public var answer: String
    public var citations: [EpisodicCitation]
    public var boundary: String

    public init(
        ok: Bool = false,
        question: String = "",
        answer: String = "",
        citations: [EpisodicCitation] = [],
        boundary: String = "纯本地 SQLite FTS5 + 加密正文；零字节离开本机 / local SQLite FTS5 + sealed text; zero bytes leave this Mac"
    ) {
        self.ok = ok
        self.question = question
        self.answer = answer
        self.citations = citations
        self.boundary = boundary
    }

    public static let empty = EpisodicAnswer()
}

public struct EpisodicRAGCard: Codable, Sendable, Equatable {
    public var healthy: Bool
    public var entries: Int
    public var documents: Int
    public var briefings: Int
    public var bills: Int
    public var alerts: Int
    public var voices: Int
    public var lastIndexedAt: Date?
    public var fts5: Bool
    public var encrypted: Bool
    public var failureReason: String
    public var boundary: String

    public init(
        healthy: Bool = false,
        entries: Int = 0,
        documents: Int = 0,
        briefings: Int = 0,
        bills: Int = 0,
        alerts: Int = 0,
        voices: Int = 0,
        lastIndexedAt: Date? = nil,
        fts5: Bool = false,
        encrypted: Bool = true,
        failureReason: String = "",
        boundary: String = "仅本机 SQLite · FTS5 全文 + 关键词向量重排 / local SQLite · FTS5 plus keyword-vector rerank"
    ) {
        self.healthy = healthy
        self.entries = entries
        self.documents = documents
        self.briefings = briefings
        self.bills = bills
        self.alerts = alerts
        self.voices = voices
        self.lastIndexedAt = lastIndexedAt
        self.fts5 = fts5
        self.encrypted = encrypted
        self.failureReason = failureReason
        self.boundary = boundary
    }

    public static let empty = EpisodicRAGCard()
}

public struct EpisodicIndexReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var indexed: Int
    public var skipped: Int
    public var detail: String
    public var card: EpisodicRAGCard

    public init(ok: Bool, indexed: Int, skipped: Int, detail: String, card: EpisodicRAGCard) {
        self.ok = ok
        self.indexed = indexed
        self.skipped = skipped
        self.detail = detail
        self.card = card
    }
}

// MARK: - LocalEpisodicRAG

public actor LocalEpisodicRAG {
    public static let maximumEntries = 2_000
    public static let maximumTitleCharacters = 180
    public static let maximumBodyCharacters = 8_000
    public static let maximumSnippetCharacters = 320
    public static let maximumIndexedFiles = 200
    public static let maximumIndexedBytes = 2_000_000
    public static let vectorDimensions = 64

    private var database: OpaquePointer?
    private var lastError = ""
    private let key: SymmetricKey
    private let keyPersistent: Bool
    private let databasePath: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Key selection is deliberately fail-soft: a read-only vault still yields an
    /// encrypted index for this process, but `card.encrypted` never claims the
    /// file was persisted when it was not.
    public init(databaseURL: URL, keyURL: URL? = nil) {
        self.databasePath = databaseURL.path
        let resolved = Self.loadKey(at: keyURL)
        self.key = resolved.key
        self.keyPersistent = resolved.persistent
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            lastError = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if handle != nil { sqlite3_close(handle) }
            return
        }
        database = handle
        sqlite3_busy_timeout(handle, 1_000)
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS rag_entries (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title BLOB NOT NULL,
                body BLOB NOT NULL,
                source BLOB NOT NULL,
                occurred REAL NOT NULL,
                tokens TEXT NOT NULL,
                vector BLOB NOT NULL,
                created REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_rag_occurred ON rag_entries(occurred DESC);",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS rag_fts USING fts5(
                entry_id UNINDEXED,
                tokens,
                tokenize = 'unicode61'
            );
            """
        ] {
            if lastError.isEmpty, let message = Self.execute(statement, on: handle) {
                lastError = message
            }
        }
    }

    public init(path: String, keyPath: String? = nil) {
        self.init(
            databaseURL: URL(fileURLWithPath: path),
            keyURL: keyPath.map { URL(fileURLWithPath: $0) }
        )
    }

    public var healthy: Bool { database != nil }
    public var failureReason: String { database != nil ? "" : lastError }

    public func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    // MARK: Recording

    /// Seals and indexes one entry. The returned id is the content digest, so
    /// re-running a briefing with identical text updates one row instead of
    /// growing the index on every tick.
    @discardableResult
    public func record(
        kind: EpisodicKind,
        title: String,
        body: String,
        source: String,
        occurredAt: Date = Date()
    ) -> String? {
        guard let database else { return nil }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTitleCharacters))
        let cleanBody = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumBodyCharacters))
        guard !cleanBody.isEmpty else { return nil }
        let cleanSource = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let id = AssistantDigest.sha256("rag.v1|\(kind.rawValue)|\(cleanSource)|\(cleanBody)")
        guard let sealedTitle = seal(cleanTitle),
              let sealedBody = seal(cleanBody),
              let sealedSource = seal(cleanSource)
        else {
            lastError = "AES-GCM seal failed"
            return nil
        }
        let tokens = Self.tokens(in: "\(cleanTitle) \(cleanBody)")
        let ftsTokens = tokens.map { Self.tokenDigest($0, key: key) }
        let vector = Self.vector(for: tokens)
        let now = Date().timeIntervalSince1970

        _ = Self.execute("DELETE FROM rag_fts WHERE entry_id = ?;", binding: { statement in
            Self.bind(id, at: 1, to: statement)
        }, on: database)
        let sql = """
        INSERT OR REPLACE INTO rag_entries
        (id, kind, title, body, source, occurred, tokens, vector, created)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(database))
            return nil
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(id, at: 1, to: statement)
        Self.bind(kind.rawValue, at: 2, to: statement)
        bind(sealedTitle, at: 3, to: statement)
        bind(sealedBody, at: 4, to: statement)
        bind(sealedSource, at: 5, to: statement)
        sqlite3_bind_double(statement, 6, occurredAt.timeIntervalSince1970)
        Self.bind(ftsTokens.joined(separator: " "), at: 7, to: statement)
        bind(vector, at: 8, to: statement)
        sqlite3_bind_double(statement, 9, now)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            lastError = String(cString: sqlite3_errmsg(database))
            return nil
        }
        insertFTS(id: id, tokens: ftsTokens.joined(separator: " "), database: database)
        trim(database: database)
        return id
    }

    public func recordBriefing(_ text: String, now: Date = Date()) {
        let stamp = Self.dayStamp(now)
        _ = record(
            kind: .briefing,
            title: "每日简报 · \(stamp)",
            body: text,
            source: "assistant/briefing/\(stamp)",
            occurredAt: now
        )
    }

    public func recordPatrol(_ text: String, anomalies: Int, now: Date = Date()) {
        guard anomalies > 0 || !text.isEmpty else { return }
        _ = record(
            kind: .alert,
            title: "设备巡检 · \(anomalies) 项异常",
            body: text,
            source: "assistant/patrol/\(Self.dayStamp(now))",
            occurredAt: now
        )
    }

    public func recordBill(merchant: String, amount: String, due: String, summary: String, source: String, now: Date = Date()) {
        let lines = [
            merchant.isEmpty ? "" : "商家：\(merchant)",
            amount.isEmpty ? "" : "金额：\(amount)",
            due.isEmpty ? "" : "到期：\(due)",
            summary.isEmpty ? "" : "摘要：\(summary)"
        ].filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        _ = record(
            kind: .bill,
            title: merchant.isEmpty ? "账单" : "账单 · \(merchant)",
            body: lines.joined(separator: "\n"),
            source: source.isEmpty ? "assistant/bill/\(Self.dayStamp(now))" : source,
            occurredAt: now
        )
    }

    // MARK: Indexing authorized roots

    /// Walks the owner-authorized roots and indexes small text documents. Every
    /// candidate is re-checked through `WorkspaceSandbox`, so a symlink planted in
    /// an authorized folder cannot pull `~/.ssh` into the index.
    public func indexScopeRoots(_ roots: [String], sandbox: WorkspaceSandbox? = nil) -> EpisodicIndexReport {
        let policy = sandbox ?? WorkspaceSandbox(
            readAllowed: true,
            writeAllowed: false,
            directoryPaths: roots
        )
        guard !roots.isEmpty else {
            return EpisodicIndexReport(
                ok: false,
                indexed: 0,
                skipped: 0,
                detail: "没有授权目录 / no authorized scope roots",
                card: status()
            )
        }
        var indexed = 0
        var skipped = 0
        let manager = FileManager.default
        for rawRoot in roots {
            guard let root = AppPaths.resolve(userPath: rawRoot) else {
                skipped += 1
                continue
            }
            let keys: [URLResourceKey] = [
                .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey,
                .contentModificationDateKey
            ]
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                skipped += 1
                continue
            }
            for case let url as URL in enumerator {
                if indexed >= Self.maximumIndexedFiles { break }
                guard Self.isIndexableExtension(url.pathExtension) else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true || values?.isHidden == true {
                    skipped += 1
                    continue
                }
                guard values?.isRegularFile == true,
                      (values?.fileSize ?? 0) <= Self.maximumIndexedBytes,
                      policy.guardPath(url.path, writing: false) == nil
                else {
                    skipped += 1
                    continue
                }
                switch policy.read(url.path) {
                case .failure:
                    skipped += 1
                case .success(let read):
                    let relative = Self.relativePath(url, root: root)
                    let stored = record(
                        kind: .document,
                        title: url.lastPathComponent,
                        body: read.text,
                        source: "\(AppPaths.anonymise(root.path))/\(relative)",
                        occurredAt: values?.contentModificationDate ?? Date()
                    )
                    if stored == nil { skipped += 1 } else { indexed += 1 }
                }
            }
        }
        return EpisodicIndexReport(
            ok: database != nil,
            indexed: indexed,
            skipped: skipped,
            detail: "已索引 \(indexed) 份文档，跳过 \(skipped) 项 / indexed \(indexed), skipped \(skipped)",
            card: status()
        )
    }

    // MARK: Search

    public func ask(_ question: String, limit: Int = 6) -> EpisodicAnswer {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, database != nil else { return .empty }
        let queryTokens = Self.tokens(in: clean)
        let hashed = queryTokens.map { Self.tokenDigest($0, key: key) }
        guard !hashed.isEmpty else { return .empty }
        let match = hashed.prefix(24).map { "\"\($0)\"" }.joined(separator: " OR ")
        let sql = """
        SELECT e.id, e.kind, e.title, e.body, e.source, e.occurred, e.tokens, e.vector
        FROM rag_fts f JOIN rag_entries e ON e.id = f.entry_id
        WHERE rag_fts MATCH ?
        ORDER BY bm25(rag_fts)
        LIMIT 32;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(database))
            return .empty
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(match, at: 1, to: statement)
        let queryVector = Self.vector(from: Self.vector(for: queryTokens))
        let querySet = Set(hashed)
        var rows: [(EpisodicCitation, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0),
                  let kind = EpisodicKind(rawValue: Self.text(statement, 1) ?? ""),
                  let titleData = blob(statement, 2), let title = open(titleData),
                  let bodyData = blob(statement, 3), let body = open(bodyData),
                  let sourceData = blob(statement, 4), let source = open(sourceData)
            else { continue }
            let occurred = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let storedTokens = Set((Self.text(statement, 6) ?? "").split(separator: " ").map(String.init))
            let coverage = querySet.isEmpty ? 0 : Double(querySet.intersection(storedTokens).count) / Double(querySet.count)
            let storedVector: [Float]
            if let vectorData = blob(statement, 7) {
                storedVector = Self.vector(from: vectorData)
            } else {
                storedVector = []
            }
            let cosine = Self.cosine(queryVector, storedVector)
            let score = min(1, max(0, coverage * 0.65 + cosine * 0.35))
            let citation = EpisodicCitation(
                id: id,
                kind: kind,
                title: String(title.prefix(Self.maximumTitleCharacters)),
                snippet: Self.snippet(body, matching: queryTokens),
                source: String(source.prefix(300)),
                occurredAt: occurred,
                score: score
            )
            rows.append((citation, score))
        }
        let citations = rows
            .sorted { $0.1 == $1.1 ? $0.0.occurredAt > $1.0.occurredAt : $0.1 > $1.1 }
            .prefix(max(1, min(limit, 12)))
            .map(\.0)
        guard !citations.isEmpty else {
            return EpisodicAnswer(
                ok: true,
                question: clean,
                answer: "本地索引中没有找到相关记录 / nothing relevant in the local index",
                citations: []
            )
        }
        var lines = ["根据本机加密索引 / from the local sealed index："]
        for (index, citation) in citations.prefix(4).enumerated() {
            lines.append("\(index + 1). [\(citation.kind.labelZh)] \(citation.title) · \(citation.snippet)")
        }
        lines.append("来源见下方引用 / sources are listed below")
        return EpisodicAnswer(ok: true, question: clean, answer: lines.joined(separator: "\n"), citations: citations)
    }

    public func status() -> EpisodicRAGCard {
        guard let database else {
            return EpisodicRAGCard(healthy: false, encrypted: keyPersistent, failureReason: lastError)
        }
        var card = EpisodicRAGCard(
            healthy: true,
            fts5: tableExists("rag_fts", database: database),
            encrypted: true,
            failureReason: ""
        )
        let sql = "SELECT kind, COUNT(*), MAX(created) FROM rag_entries GROUP BY kind;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            card.failureReason = String(cString: sqlite3_errmsg(database))
            return card
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = EpisodicKind(rawValue: Self.text(statement, 0) ?? "")
            let count = Int(sqlite3_column_int64(statement, 1))
            card.entries += count
            switch kind {
            case .document: card.documents = count
            case .briefing: card.briefings = count
            case .bill: card.bills = count
            case .alert: card.alerts = count
            case .voice: card.voices = count
            case .mailSummary: break
            case nil: break
            }
            let stamp = sqlite3_column_double(statement, 2)
            if stamp > 0 {
                let date = Date(timeIntervalSince1970: stamp)
                if card.lastIndexedAt == nil || date > card.lastIndexedAt! { card.lastIndexedAt = date }
            }
        }
        if !keyPersistent {
            card.failureReason = "密钥未能写入磁盘，本次进程内仍加密 / the key is volatile for this process"
        }
        return card
    }

    // MARK: SQLite helpers

    private func insertFTS(id: String, tokens: String, database: OpaquePointer) {
        let sql = "INSERT INTO rag_fts (entry_id, tokens) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        Self.bind(id, at: 1, to: statement)
        Self.bind(tokens, at: 2, to: statement)
        _ = sqlite3_step(statement)
    }

    private func trim(database: OpaquePointer) {
        let sql = """
        SELECT id FROM rag_entries ORDER BY created DESC LIMIT -1 OFFSET ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(Self.maximumEntries))
        var doomed: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = Self.text(statement, 0) { doomed.append(id) }
        }
        for id in doomed {
            _ = Self.execute("DELETE FROM rag_fts WHERE entry_id = ?;", binding: { $0.bind(id) }, on: database)
            _ = Self.execute("DELETE FROM rag_entries WHERE id = ?;", binding: { $0.bind(id) }, on: database)
        }
    }

    private func tableExists(_ name: String, database: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        Self.bind(name, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: Sealing

    private func seal(_ text: String) -> Data? {
        guard let sealed = try? AES.GCM.seal(Data(text.utf8), using: key) else { return nil }
        return sealed.combined
    }

    private func open(_ data: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func loadKey(at url: URL?) -> (key: SymmetricKey, persistent: Bool) {
        guard let url else {
            return (SymmetricKey(size: .bits256), false)
        }
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return (SymmetricKey(data: data), true)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let data = Data(bytes)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return (SymmetricKey(data: data), true)
        } catch {
            return (SymmetricKey(data: data), false)
        }
    }

    // MARK: Tokenizing and vectors

    /// Lowercased words plus CJK single characters, capped. The output is the
    /// input to HMAC, never to a persisted plaintext column.
    static func tokens(in text: String) -> [String] {
        var values: [String] = []
        var latin = ""
        func flushLatin() {
            if latin.count >= 2 { values.append(latin) }
            latin = ""
        }
        for scalar in text.unicodeScalars.prefix(12_000) {
            let value = scalar.value
            if (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) {
                latin.append(Character(scalar))
            } else if value >= 0x4E00 && value <= 0x9FFF {
                flushLatin()
                values.append(String(scalar))
            } else if value >= 0x3040 && value <= 0x30FF {
                flushLatin()
                values.append(String(scalar))
            } else {
                flushLatin()
            }
        }
        flushLatin()
        return Array(values.prefix(256))
    }

    static func tokenDigest(_ token: String, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: key)
        return mac.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func vector(for tokens: [String]) -> Data {
        var values = [Float](repeating: 0, count: vectorDimensions)
        for token in tokens {
            let digest = Array(SHA256.hash(data: Data(token.utf8)))
            var bucket = 0
            for byte in digest.prefix(4) { bucket = (bucket << 8) | Int(byte) }
            let index = abs(bucket) % vectorDimensions
            let sign: Float = (digest[0] & 1) == 0 ? 1 : -1
            values[index] += sign
        }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for index in values.indices { values[index] /= norm }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    static func vector(from data: Data) -> [Float] {
        guard data.count == vectorDimensions * 4 else { return [] }
        var values = [Float](repeating: 0, count: vectorDimensions)
        for index in 0..<vectorDimensions {
            let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
            values[index] = Float(bitPattern: bits)
        }
        return values
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        let denominator = sqrt(left) * sqrt(right)
        return denominator > 0 ? Double(dot / denominator) : 0
    }

    private static func snippet(_ body: String, matching query: [String]) -> String {
        let lowered = body.lowercased()
        let anchor = query.first(where: { !$0.isEmpty && lowered.contains($0) })
        let start: String.Index
        if let anchor, let range = lowered.range(of: anchor) {
            start = body.index(range.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        } else {
            start = body.startIndex
        }
        let snippet = String(body[start...].prefix(maximumSnippetCharacters))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return start == body.startIndex ? snippet : "…" + snippet
    }

    private static func isIndexableExtension(_ suffix: String) -> Bool {
        ["txt", "md", "markdown", "json", "csv", "log", "rtf", "org", "yaml", "yml"]
            .contains(suffix.lowercased())
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func execute(_ sql: String, on handle: OpaquePointer) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            return message
        }
        return nil
    }

    private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer?) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
        }
    }

    private func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        let count = sqlite3_column_bytes(statement, index)
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: Int(count))
    }

    private static func bind(_ text: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}

private extension OpaquePointer {
    func bind(_ text: String) {
        sqlite3_bind_text(self, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

private extension LocalEpisodicRAG {
    /// The closure-shaped overload keeps `DELETE … WHERE id = ?` from repeating a
    /// prepared-statement ladder in every trim call.
    static func execute(_ sql: String, binding: (OpaquePointer) -> Void, on database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        binding(statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }
}
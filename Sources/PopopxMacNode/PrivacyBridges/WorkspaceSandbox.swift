import Foundation

// MARK: - Workspace executor
//
// Reads and writes files inside directories the owner listed by hand. Every path
// that arrives here comes from a network peer — a paired phone, or Bot Studio over
// loopback — so the guard is written as if the input were hostile, because it is.

/// A file operation waiting on a click.
///
/// The content is held in memory as the exact bytes a write would produce. That is
/// what lets the console and the phone show the whole payload before anything is
/// committed, and it is why a proposal dies with a restart instead of being
/// reloaded from disk.
public struct WorkspaceFilePayload: Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case write
        case append
        case move
    }

    /// Display form: `~`-anonymised, safe to put in a card.
    public var path: String
    public var sourcePath: String
    public var content: String
    public var mode: Mode
    /// The target already exists, so the owner is about to replace something.
    public var overwrites: Bool
    public var currentBytes: Int
    /// Canonical filesystem path, used by the executor only. It is deliberately not
    /// serialized into a tool response, which answers with the anonymised form.
    public var canonicalPath: String

    public init(
        path: String = "",
        sourcePath: String = "",
        content: String = "",
        mode: Mode = .write,
        overwrites: Bool = false,
        currentBytes: Int = 0,
        canonicalPath: String = ""
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.content = content
        self.mode = mode
        self.overwrites = overwrites
        self.currentBytes = currentBytes
        self.canonicalPath = canonicalPath
    }
}

public enum WorkspaceRefusal: String, Sendable, Codable, CaseIterable {
    case bridgeDisabled
    case readDisabled
    case writeDisabled
    case noDirectories
    case emptyPath
    case pathTraversal
    case sensitivePath
    case outsideSandbox
    case notFound
    case isDirectory
    case tooLarge
    case notText
    case sourceMissing
    case targetExists

    public var message: String {
        switch self {
        case .bridgeDisabled: return "工作区桥接未开启 / workspace bridge is off"
        case .readDisabled: return "工作区读取授权未开启 / workspace read access is off"
        case .writeDisabled: return "工作区写入授权未开启 / workspace write access is off"
        case .noDirectories: return "尚未授权任何工作区目录 / no workspace directory is authorized"
        case .emptyPath: return "缺少 path 参数 / missing path argument"
        case .pathTraversal: return "拒绝路径穿越（..）/ path traversal refused"
        case .sensitivePath: return "拒绝访问系统敏感目录 / sensitive location refused"
        case .outsideSandbox: return "路径不在已授权目录内 / path is outside the authorized directories"
        case .notFound: return "文件不存在 / file not found"
        case .isDirectory: return "目标是目录 / the path is a directory"
        case .tooLarge: return "文件过大 / file exceeds the read limit"
        case .notText: return "不是文本文件 / not a text file"
        case .sourceMissing: return "移动源文件不存在 / move source is missing"
        case .targetExists: return "目标已存在 / the target already exists"
        }
    }
}

public enum WorkspaceError: Error, Equatable {
    case refusal(WorkspaceRefusal, detail: String)
}

/// One file's digest, as returned by `workspace/summarize`.
public struct WorkspaceRead: Sendable, Equatable {
    public var url: URL
    public var text: String
    public var truncated: Bool
    public var bytes: Int

    public init(url: URL, text: String, truncated: Bool, bytes: Int) {
        self.url = url
        self.text = text
        self.truncated = truncated
        self.bytes = bytes
    }
}

public struct WorkspaceDigest: Sendable, Equatable {
    public var path: String
    public var name: String
    public var kind: String
    public var bytes: Int
    public var lines: Int
    public var headings: [String]
    public var bullets: [String]
    public var summary: String
    /// `ollama:<model>` when the local model answered, `deterministic` when the
    /// offline extractor did. A caller must be able to tell an extracted outline
    /// from a generated summary.
    public var source: String
    public var truncated: Bool
    public var note: String

    public init(
        path: String,
        name: String,
        kind: String,
        bytes: Int = 0,
        lines: Int = 0,
        headings: [String] = [],
        bullets: [String] = [],
        summary: String = "",
        source: String = "deterministic",
        truncated: Bool = false,
        note: String = ""
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.lines = lines
        self.headings = headings
        self.bullets = bullets
        self.summary = summary
        self.source = source
        self.truncated = truncated
        self.note = note
    }
}

public struct WorkspaceEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var bytes: Int
    public var modified: String

    public init(name: String, isDirectory: Bool, bytes: Int, modified: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.modified = modified
    }
}

/// The request handed to a local model, assembled where the token budget lives.
public struct WorkspaceDigestRequest: Sendable {
    public var path: String
    public var text: String
    public var model: String

    public init(path: String, text: String, model: String) {
        self.path = path
        self.text = text
        self.model = model
    }
}

/// Asks the local Ollama for a summary. `nil` means "no model path is wired", which
/// is the state of a test host, of a Mac without Ollama, and of the offline default.
public typealias LocalSummarizer = @Sendable (WorkspaceDigestRequest) async throws -> String

// MARK: - Sandbox

/// Path guard plus file operations, scoped to the directories the owner listed.
public struct WorkspaceSandbox: Sendable {
    /// 2 MB of source is already more than a context window can use; reading more
    /// would be spent and thrown away.
    public static let maximumReadBytes = 2_000_000
    /// Characters of file text given to the model, so a large log cannot crowd the
    /// conversation out of the context.
    public static let modelContextCharacters = 12_000
    public static let maximumListingEntries = 200
    public static let maximumWriteCharacters = 400_000

    public var readAllowed: Bool
    public var writeAllowed: Bool
    /// Raw user-shaped paths, exactly as stored in settings.
    public var directoryPaths: [String]
    public var summarizer: LocalSummarizer?
    public var model: String

    /// Locations that must never be reachable through the workspace bridge, even if
    /// the owner authorizes their own home directory. Home-relative suffixes, so the
    /// list survives a different username or a moved home.
    public static let sensitiveSuffixes: [String] = [
        ".ssh", ".gnupg", ".aws", ".azure", ".config/gcloud", ".kube",
        ".npmrc", ".netrc", ".git-credentials", ".zsh_history", ".bash_history",
        ".sh_history", ".lldb", ".android", ".docker/config.json",
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/HomeKit", "Library/Health", "Library/Application Support/AddressBook",
        "Library/Application Support/CloudDocs", "Library/Group Containers",
        "Library/Containers/com.apple.Safari", "Library/Application Support/com.apple.TCC"
    ]

    /// This node's own secrets. Authorizing `~` must not turn the bridge into a
    /// reader of the sealed vault or the pairing keys.
    public static var nodeSecretPaths: [String] {
        [AppPaths.vault.path, AppPaths.pairing.path, AppPaths.ledger.path]
    }

    public init(
        readAllowed: Bool = false,
        writeAllowed: Bool = false,
        directoryPaths: [String] = [],
        summarizer: LocalSummarizer? = nil,
        model: String = ""
    ) {
        self.readAllowed = readAllowed
        self.writeAllowed = writeAllowed
        self.directoryPaths = directoryPaths
        self.summarizer = summarizer
        self.model = model
    }

    // MARK: Guard

    /// Turns a caller-supplied path into a canonical URL, or refuses with a reason.
    ///
    /// Four checks, each with its own refusal so a wrong guess stays diagnosable:
    ///
    /// 1. a literal `..` component in the input — refused outright, because the
    ///    contract says traversal is simply not a thing this bridge does;
    /// 2. `~`/absolute/relative resolution against the authorized roots;
    /// 3. symlink resolution of the existing part of the path, so a link inside a
    ///    workspace that points at `~/.ssh` cannot masquerade as a workspace file —
    ///    `standardizedFileURL` collapses `..` but never follows a link;
    /// 4. the deny-list, tested on both the raw and the resolved form.
    public func guardPath(_ raw: String, writing: Bool) -> WorkspaceRefusal? {
        if directoryPaths.isEmpty { return .noDirectories }
        if writing {
            guard readAllowed else { return .readDisabled }
            guard writeAllowed else { return .writeDisabled }
        } else if !readAllowed {
            return .readDisabled
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyPath }
        if trimmed.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            return .pathTraversal
        }
        if Self.matchesSensitive(trimmed) { return .sensitivePath }
        for directory in directoryPaths {
            guard let root = AppPaths.resolve(userPath: directory) else { continue }
            let canonicalRoot = Self.canonical(root)
            let candidate: URL
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                candidate = AppPaths.resolve(userPath: trimmed).map(Self.canonical)
                    ?? URL(fileURLWithPath: trimmed)
            } else {
                candidate = Self.canonical(canonicalRoot.appendingPathComponent(trimmed, isDirectory: false))
            }
            if Self.matchesSensitive(candidate.path) { return .sensitivePath }
            if candidate.path == canonicalRoot.path || candidate.path.hasPrefix(canonicalRoot.path + "/") {
                return nil
            }
        }
        return .outsideSandbox
    }

    /// The guard plus resolution, for callers that need the URL.
    public func resolve(_ raw: String, writing: Bool) -> Result<URL, WorkspaceError> {
        if let refusal = guardPath(raw, writing: writing) {
            return .failure(.refusal(refusal, detail: AppPaths.anonymise(raw)))
        }
        guard let url = resolvedURL(raw) else {
            return .failure(.refusal(.outsideSandbox, detail: AppPaths.anonymise(raw)))
        }
        return .success(url)
    }

    /// The first authorized root that contains `raw`, resolved canonically.
    public func resolvedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for directory in directoryPaths {
            guard let root = AppPaths.resolve(userPath: directory) else { continue }
            let canonicalRoot = Self.canonical(root)
            let candidate: URL
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                candidate = AppPaths.resolve(userPath: trimmed).map(Self.canonical) ?? URL(fileURLWithPath: trimmed)
            } else {
                candidate = Self.canonical(canonicalRoot.appendingPathComponent(trimmed, isDirectory: false))
            }
            if candidate.path == canonicalRoot.path || candidate.path.hasPrefix(canonicalRoot.path + "/") {
                return candidate
            }
        }
        return nil
    }

    static func matchesSensitive(_ path: String) -> Bool {
        let home = AppPaths.fileManager.homeDirectoryForCurrentUser.path
        for suffix in sensitiveSuffixes {
            let absolute = home.isEmpty ? "/" + suffix : home + "/" + suffix
            if path == absolute || path.hasPrefix(absolute + "/") { return true }
        }
        for secret in nodeSecretPaths where path == secret || path.hasPrefix(secret + "/") {
            return true
        }
        return false
    }

    /// Resolves symlinks for the deepest existing ancestor and re-attaches the rest,
    /// so a path whose file does not exist yet still gets a canonical answer.
    static func canonical(_ url: URL) -> URL {
        let manager = AppPaths.fileManager
        var tail: [String] = []
        var existing = url
        while !manager.fileExists(atPath: existing.path) {
            let last = existing.lastPathComponent
            if last.isEmpty { break }
            tail.insert(last, at: 0)
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            existing = parent
        }
        var result = existing.resolvingSymlinksInPath()
        for component in tail { result = result.appendingPathComponent(component) }
        return result.standardizedFileURL
    }

    // MARK: Reads

    public func list(_ raw: String) -> Result<WorkspaceListing, WorkspaceError> {
        guard guardPath(raw, writing: false) == nil else {
            return .failure(.refusal(guardPath(raw, writing: false) ?? .readDisabled, detail: AppPaths.anonymise(raw)))
        }
        guard let url = resolvedURL(raw) else {
            return .failure(.refusal(.outsideSandbox, detail: AppPaths.anonymise(raw)))
        }
        var isDirectory: ObjCBool = false
        guard AppPaths.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.refusal(.notFound, detail: AppPaths.anonymise(url.path)))
        }
        guard isDirectory.boolValue else { return .failure(.refusal(.isDirectory, detail: AppPaths.anonymise(url.path))) }
        let children = (try? AppPaths.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [WorkspaceEntry] = []
        for child in children.prefix(Self.maximumListingEntries) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            entries.append(WorkspaceEntry(
                name: child.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                bytes: values?.fileSize ?? 0,
                modified: values?.contentModificationDate.map { PrivacyStamp.iso($0) } ?? ""
            ))
        }
        return .success(WorkspaceListing(
            path: AppPaths.anonymise(url.path),
            entries: entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        ))
    }

    /// Reads a text file, capped. The binary check comes first so a `.db` or an image
    /// is refused instead of being turned into replacement characters.
    public func read(_ raw: String, byteLimit: Int = WorkspaceSandbox.maximumReadBytes) -> Result<WorkspaceRead, WorkspaceError> {
        if let refusal = guardPath(raw, writing: false) {
            return .failure(.refusal(refusal, detail: AppPaths.anonymise(raw)))
        }
        guard let url = resolvedURL(raw) else {
            return .failure(.refusal(.outsideSandbox, detail: AppPaths.anonymise(raw)))
        }
        var isDirectory: ObjCBool = false
        guard AppPaths.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.refusal(.notFound, detail: AppPaths.anonymise(url.path)))
        }
        guard !isDirectory.boolValue else {
            return .failure(.refusal(.isDirectory, detail: AppPaths.anonymise(url.path)))
        }
        let attributes = try? AppPaths.fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= byteLimit else { return .failure(.refusal(.tooLarge, detail: "\(size) bytes")) }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return .failure(.refusal(.notFound, detail: AppPaths.anonymise(url.path)))
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: byteLimit)
        guard data.firstIndex(of: 0) == nil else {
            return .failure(.refusal(.notText, detail: url.lastPathComponent))
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return .success(WorkspaceRead(
            url: url,
            text: text,
            truncated: data.count >= byteLimit,
            bytes: data.count
        ))
    }

    // MARK: Summarize

    /// Digests one file. The raw text never leaves this process: it is either
    /// outlined by the deterministic extractor or handed to Ollama on loopback, and
    /// only the digest goes into the response.
    public func digest(_ raw: String) async -> Result<WorkspaceDigest, WorkspaceError> {
        let read: WorkspaceRead
        switch self.read(raw) {
        case .failure(let error): return .failure(error)
        case .success(let value): read = value
        }
        let url = read.url
        var answer = WorkspaceDigest(
            path: AppPaths.anonymise(url.path),
            name: url.lastPathComponent,
            kind: url.pathExtension.lowercased(),
            bytes: read.bytes,
            lines: read.text.isEmpty ? 0 : read.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            headings: Extractor.headings(in: read.text),
            bullets: Extractor.bullets(in: read.text, kind: url.pathExtension.lowercased()),
            truncated: read.truncated
        )
        guard let summarizer else {
            answer.summary = Extractor.collapse(answer)
            return .success(answer)
        }
        do {
            let generated = try await summarizer(WorkspaceDigestRequest(
                path: answer.path,
                text: String(read.text.prefix(Self.modelContextCharacters)),
                model: model
            ))
            let cleaned = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                answer.summary = Extractor.collapse(answer)
                answer.note = "模型返回空内容，已改用离线摘要 / the model answered nothing, offline outline used"
                return .success(answer)
            }
            answer.summary = String(cleaned.prefix(1_600))
            answer.source = model.isEmpty ? "ollama" : "ollama:\(model)"
            return .success(answer)
        } catch {
            // A model that is not installed, or a daemon that is not running, still
            // has to answer with something useful.
            answer.summary = Extractor.collapse(answer)
            answer.note = Extractor.describe(error)
            return .success(answer)
        }
    }

    // MARK: Proposals and writes

    /// Freezes a requested write into the payload a proposal will carry. Nothing is
    /// written here; the result waits in the ledger for an approval.
    public func payload(for raw: String, content: String, mode: WorkspaceFilePayload.Mode) -> Result<WorkspaceFilePayload, WorkspaceError> {
        switch resolve(raw, writing: true) {
        case .failure(let error): return .failure(error)
        case .success(let url):
            if content.utf8.count > Self.maximumWriteCharacters {
                return .failure(.refusal(.tooLarge, detail: "\(content.utf8.count) bytes"))
            }
            let exists = AppPaths.fileManager.fileExists(atPath: url.path)
            let current = (try? AppPaths.fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int
            return .success(WorkspaceFilePayload(
                path: AppPaths.anonymise(url.path),
                content: content,
                mode: mode,
                overwrites: exists && mode != .append,
                currentBytes: current ?? 0,
                canonicalPath: url.path
            ))
        }
    }

    /// Freezes a move/organize request.
    public func movePayload(from source: String, to destination: String) -> Result<WorkspaceFilePayload, WorkspaceError> {
        switch resolve(source, writing: false) {
        case .failure(let error): return .failure(error)
        case .success(let sourceURL):
            guard AppPaths.fileManager.fileExists(atPath: sourceURL.path) else {
                return .failure(.refusal(.sourceMissing, detail: AppPaths.anonymise(sourceURL.path)))
            }
            switch resolve(destination, writing: true) {
            case .failure(let error): return .failure(error)
            case .success(let targetURL):
                guard !AppPaths.fileManager.fileExists(atPath: targetURL.path) else {
                    return .failure(.refusal(.targetExists, detail: AppPaths.anonymise(targetURL.path)))
                }
                return .success(WorkspaceFilePayload(
                    path: AppPaths.anonymise(targetURL.path),
                    sourcePath: sourceURL.path,
                    mode: .move,
                    canonicalPath: targetURL.path
                ))
            }
        }
    }

    /// Applies an approved payload. Reached only through the ledger's gate.
    public func apply(_ payload: WorkspaceFilePayload) -> PrivacyExecution {
        let target = payload.canonicalPath.isEmpty ? payload.path : payload.canonicalPath
        // Re-guard at execution time: the authorized directories may have changed
        // between the proposal and the click, and a stale proposal must not outrank
        // the current settings.
        switch resolve(target, writing: true) {
        case .failure: return .failed("授权目录已变更，写入被拒 / the authorized directories changed, write refused")
        case .success(let url):
            switch payload.mode {
            case .move:
                let source = URL(fileURLWithPath: payload.sourcePath)
                guard AppPaths.fileManager.fileExists(atPath: source.path) else {
                    return .failed(WorkspaceRefusal.sourceMissing.message)
                }
                guard !AppPaths.fileManager.fileExists(atPath: url.path) else {
                    return .failed(WorkspaceRefusal.targetExists.message)
                }
                do {
                    try AppPaths.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AppPaths.fileManager.moveItem(at: source, to: url)
                    return .succeeded(AppPaths.anonymise(url.path), "已移动 / moved to \(AppPaths.anonymise(url.path))")
                } catch {
                    return .failed("移动失败 / move failed: \(AppPaths.anonymise(error.localizedDescription))")
                }
            case .write, .append:
                var data = Data(payload.content.utf8)
                if payload.mode == .append, let existing = AppPaths.fileManager.contents(atPath: url.path) {
                    data = existing + data
                }
                do {
                    try AppPaths.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    return .succeeded(AppPaths.anonymise(url.path), "已写入 \(data.count) 字节 / wrote \(data.count) bytes")
                } catch {
                    return .failed("写入失败 / write failed: \(AppPaths.anonymise(error.localizedDescription))")
                }
            }
        }
    }
}

public struct WorkspaceListing: Sendable, Equatable {
    public var path: String
    public var entries: [WorkspaceEntry]

    public init(path: String, entries: [WorkspaceEntry]) {
        self.path = path
        self.entries = entries
    }
}

// MARK: - Offline extractor

/// Rule-based outlining, used whenever no local model is wired and as the fallback
/// when a model call fails. This is the half that keeps the workspace bridge useful
/// with no network at all.
public enum Extractor {
    public static func headings(in text: String) -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
            guard !title.isEmpty else { continue }
            found.append(String(title.prefix(120)))
            if found.count >= 8 { break }
        }
        return found
    }

    public static func bullets(in text: String, kind: String) -> [String] {
        switch kind {
        case "json": return jsonKeys(text)
        case "csv", "tsv": return csvOutline(text)
        case "md", "markdown", "txt", "text", "log", "": return proseBullets(text)
        default: return codeOutline(text)
        }
    }

    static func proseBullets(_ text: String) -> [String] {
        var bullets: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 12, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```") else { continue }
            bullets.append(String(trimmed.prefix(180)))
            if bullets.count >= 5 { break }
        }
        return bullets
    }

    static func jsonKeys(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else { return [] }
        return object.keys.sorted().prefix(12).map { "\"\($0)\"" }
    }

    static func csvOutline(_ text: String) -> [String] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = rows.first else { return [] }
        let columns = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return [
            "列 \(columns.count)：\(columns.prefix(8).joined(separator: ", "))",
            "数据行 \(max(0, rows.count - 1))"
        ]
    }

    static func codeOutline(_ text: String) -> [String] {
        let prefixes = ["public ", "internal ", "final ", "func ", "class ", "struct ", "enum ", "protocol ", "actor "]
        var bullets: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard prefixes.contains(where: { trimmed.hasPrefix($0) }) else { continue }
            bullets.append(String(trimmed.prefix(140)))
            if bullets.count >= 6 { break }
        }
        return bullets
    }

    /// The offline answer: an outline, so the response is a digest rather than an
    /// empty string.
    public static func collapse(_ digest: WorkspaceDigest) -> String {
        var lines: [String] = []
        if !digest.headings.isEmpty {
            lines.append("章节：" + digest.headings.joined(separator: " › "))
        }
        for bullet in digest.bullets.prefix(5) {
            lines.append("· " + bullet)
        }
        if lines.isEmpty {
            lines.append(digest.bytes == 0
                ? "空文件 / empty file"
                : "已读取 \(digest.bytes) 字节，未识别出结构 / read \(digest.bytes) bytes, no structure detected")
        }
        lines.append("共 \(digest.lines) 行 / \(digest.lines) lines")
        return lines.joined(separator: "\n")
    }

    public static func describe(_ error: Error) -> String {
        if let failure = error as? NodeFailure { return failure.errorDescription ?? "本地模型不可用 / local model unavailable" }
        return "本地模型不可用 / local model unavailable: \(AppPaths.anonymise(error.localizedDescription))"
    }
}

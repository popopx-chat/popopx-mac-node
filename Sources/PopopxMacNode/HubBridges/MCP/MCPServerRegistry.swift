//
//  MCPServerRegistry.swift
//  PopopxMacNode — reading and writing `config/mcp_servers.json`.
//
//  The registry exists so that the question "may this node spawn that program?" is
//  answered in exactly one place, from exactly one document. `settings.json` carries the
//  switch; *this* file carries the allow-list, and it is the file an owner is expected to
//  edit by hand. Splitting them means turning the MCP bridge on and giving a server a
//  binary to run are two separate acts, each visible in the place where it belongs.
//
//  Loading is fail-closed. A document that cannot be parsed leaves the registry empty
//  (with the reason kept for the console), rather than falling back to "trust whatever the
//  file seemed to say". Saving writes the file `0600` — the allow-list is a description of
//  what this Mac is willing to execute, and it has no business being world-readable.
//

import Foundation

public actor MCPServerRegistry {
    /// `nil` means "no file", which is how a test runs a registry from memory and how a
    /// fresh install behaves before the owner creates the document.
    public let fileURL: URL?

    public private(set) var document: MCPServersDocument
    public private(set) var loadFailure: String?

    public init(fileURL: URL? = AppPaths.mcpServersFile, boot: MCPServersDocument? = nil) {
        self.fileURL = fileURL
        self.document = (boot ?? .init()).normalised
    }

    // MARK: Reading

    public var servers: [MCPServerConfig] { document.servers }
    public var usableServers: [MCPServerConfig] { document.usableServers }
    public var allowedCommands: [String] { document.allowedCommands }
    public var rejections: [(id: String, reason: String)] { document.rejections }
    public var isEnabled: Bool { !usableServers.isEmpty }

    public func server(id: String) -> MCPServerConfig? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return document.servers.first { $0.id.lowercased() == wanted }
    }

    /// Re-reads the file. Returns the server count now in force.
    ///
    /// Called on demand rather than by a watcher: an owner edits this file with an editor,
    /// and the console has a 「重新载入」 button. A file watch would mean the node changes
    /// what it is willing to execute because something touched a path, with no click.
    @discardableResult
    public func reload() -> Int {
        guard let fileURL else {
            loadFailure = nil
            return document.usableServers.count
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Not an error: an install without the file simply has no servers. Keeping the
            // in-memory document (which is empty unless `boot` supplied one) is correct.
            loadFailure = nil
            document = document.normalised
            return document.usableServers.count
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let decoded = NodeJSON.decode(MCPServersDocument.self, from: data) else {
                loadFailure = "文件不是合法的 mcp_servers.json / document did not parse"
                document = MCPServersDocument()
                return 0
            }
            document = decoded.normalised
            loadFailure = nil
        } catch {
            loadFailure = String(describing: error)
            document = MCPServersDocument()
        }
        return document.usableServers.count
    }

    /// Whether a command may ever be executed, independent of which server named it.
    public func isAllowed(command: String) -> Bool {
        document.allowedCommands.contains(command)
    }

    // MARK: Writing

    /// Replaces the document and writes it out. Returns the reason it refused, or nil.
    ///
    /// A document whose entries are all rejected is still writable — the console has to be
    /// able to save a half-finished registration — but nothing may be *started* from it,
    /// which is what `usableServers` is for.
    @discardableResult
    public func save(_ candidate: MCPServersDocument) -> String? {
        let cleaned = candidate.normalised
        if cleaned.servers.count > MCPServersDocument.maximumServers {
            return "服务器数量超出上限 / too many servers"
        }
        document = cleaned
        guard let fileURL else { return nil }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = NodeJSON.encodePretty(cleaned) else {
                return "无法序列化 / could not encode the document"
            }
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

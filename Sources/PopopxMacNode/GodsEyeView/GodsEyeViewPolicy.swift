//
//  GodsEyeViewPolicy.swift
//  PopopxMacNode — every constant and every refusal the GodsEyeView bridge obeys.
//
//  The policy is deliberately boring and easy to audit, because it is the whole
//  security story of the feature:
//
//  * The bind host is a constant. No document, request or environment variable can
//    change it; the launch argument builder reads it from here.
//  * A path is admitted only after `~` expansion and standardisation, and the two
//    files this node will execute are re-checked *after* symlink resolution so a
//    link inside the install cannot point at `/usr/bin/env`.
//  * Tool names are classified conservatively. A name that is not recognisably a
//    read is a write; a read-looking name that also contains a write verb is a write.
//    `MCPTool.safety` may tighten this further, and the bridge gate never loosens it.
//
//  This file also carries the statements the console shows beside the card, so the
//  privacy and licence wording is an artifact of the module rather than a comment
//  somebody has to remember to copy into the page.
//

import Foundation

public enum GodsEyeViewPolicy {
    // MARK: Fixed contract

    /// The only host this bridge ever passes to the local program.
    public static let bindHost = "127.0.0.1"
    public static let defaultPort = 18931
    public static let minimumPort = 1024
    public static let maximumPort = 65535
    public static let healthPath = "/"
    public static let defaultPinnedVersion = "1.0.0"

    /// The MCP id this bridge owns. An existing entry with the same id is replaced;
    /// every other entry in the file is left exactly as the owner wrote it.
    public static let serverID = "godseyeview"
    public static let serverLabel = "God's Eye View · 全球情报地图"

    /// The integration contract with the local program.
    public static let packageName = "gods-eye-view"
    public static let packageFile = "package.json"
    public static let entryFile = "server.js"
    public static let mcpEntryFile = "mcp-server.js"
    public static let maximumPackageBytes = 1_048_576
    public static let minimumNodeMajor = 20

    public static let boundaryStatement =
        "仅 127.0.0.1 回环 / loopback only: this bridge cannot bind or target a LAN or public address."
    public static let dataSourceStatement =
        "实时航班、船舶、卫星与天气数据由你本机的 God's Eye View 程序按各数据源条款直连；本节点只保管可选的 Keychain 引用，不代理也不缓存这些数据。 / Live flight, vessel, satellite and weather feeds are fetched by your local God's Eye View program under each provider's terms; this node only holds optional Keychain references and never proxies or caches that data."
    public static let licenceStatement =
        "God's Eye View 是独立的第三方程序，拥有自己的许可证；本仓库只包含 Swift 桥接代码，不包含其 JavaScript、地图瓦片或任何数据。 / God's Eye View is a separate third-party program under its own licence; this repository contains only the Swift bridge — none of its JavaScript, map tiles or data."

    // MARK: Ports and URLs

    public static func isValidPort(_ port: Int) -> Bool {
        (minimumPort...maximumPort).contains(port)
    }

    /// The admitted origin, built through the same loopback guard the other bridges
    /// use. Keeping this as the only construction site means a future edit that
    /// wanted a configurable host would have to delete a refusal, not add a field.
    public static func origin(port: Int) -> EdgeEndpoint? {
        guard isValidPort(port) else { return nil }
        return try? EdgeBoundary.resolve(url: "http://\(bindHost):\(port)", policy: .loopbackOnly)
    }

    public static func healthURL(port: Int) -> URL? {
        origin(port: port)?.url(path: healthPath)
    }

    /// Arguments after the Node binary. The `--host` value is the constant above.
    public static func launchArguments(entryPath: String, port: Int) -> [String] {
        [entryPath, "--host", bindHost, "--port", String(port)]
    }

    /// Arguments for the STDIO MCP child. It is told where the running instance is,
    /// so the child never binds a port of its own and never guesses one.
    public static func mcpArguments(mcpEntryPath: String, port: Int) -> [String] {
        [mcpEntryPath, "--base-url", "http://\(bindHost):\(port)"]
    }

    // MARK: Paths

    /// `nil` for anything that is not an absolute, standardised, non-sensitive path.
    public static func resolveInstallPath(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\0") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if text == "~" { text = home }
        else if text.hasPrefix("~/") { text = home + String(text.dropFirst()) }
        guard text.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: text).standardizedFileURL
        let path = url.path
        guard path != "/" else { return nil }
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        // A directory that the system owns is never an install target: a typo there
        // is not a bad configuration, it is damage waiting for a click.
        let forbiddenPrefixes = [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/Volumes",
            home + "/.ssh", home + "/.gnupg", home + "/Library/Keychains",
            AppPaths.root.standardizedFileURL.path
        ]
        for prefix in forbiddenPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return nil }
        }
        return url
    }

    /// Whether a source URL is an HTTPS URL without credentials, query or fragment.
    /// Query and fragment are refused because the URL is echoed (host-only) into the
    /// audit log and shown on the card: they are the usual place a token rides in.
    /// Hand-rolled rather than `EdgeBoundary`: this is the one place the node may
    /// name a public host, and it is never used to open a socket itself — `git` does,
    /// after the owner clicked install with the switch on.
    public static func isHTTPSource(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil, components.query == nil else { return false }
        return true
    }

    public static func sourceHost(_ text: String) -> String {
        URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
    }

    /// A file inside `root` after symlink resolution. Used for `package.json` and both
    /// entry scripts; a symlink to somewhere outside the admitted directory answers nil.
    public static func containedFile(_ name: String, in root: URL) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    // MARK: Node

    public static func isVersion(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 6 && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    public static func isCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit }
    }

    public static func nodeMajor(_ banner: String) -> Int? {
        var text = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
        guard let first = text.split(separator: ".").first, let value = Int(first) else { return nil }
        return value
    }

    /// The environment handed to the local program. Only four host variables survive,
    /// plus the keys of the sources the owner switched on; a token cannot arrive from
    /// the node's own environment by accident.
    public static func launchEnvironment(
        host: [String: String],
        secrets: [GodsEyeDataSource: String]
    ) -> [String: String] {
        var environment: [String: String] = [:]
        if let path = host["PATH"], !path.isEmpty {
            let merged = (path.split(separator: ":").map(String.init) + Shell.searchPaths)
                .reduce(into: [String]()) { acc, item in if !acc.contains(item) { acc.append(item) } }
            environment["PATH"] = merged.joined(separator: ":")
        } else {
            environment["PATH"] = Shell.searchPaths.joined(separator: ":")
        }
        for name in ["HOME", "LANG", "TMPDIR"] where host[name] != nil { environment[name] = host[name] }
        for (source, value) in secrets where !value.isEmpty {
            environment[source.environmentName] = value
        }
        // No `NODE_OPTIONS`, no `NODE_EXTRA_CA_CERTS`, no proxy variable: the program
        // gets the run it was verified as, not whatever this app was launched with.
        return environment
    }

    // MARK: Tool classification

    /// Verbs that change state, the shared canvas or a file. Any one of them makes a
    /// tool mutating regardless of the other tokens.
    static let writeTokens: Set<String> = [
        "add", "annotate", "append", "clear", "configure", "create", "delete", "disable",
        "draw", "edit", "enable", "export", "import", "insert", "install", "mark", "move",
        "patch", "pin", "plot", "post", "publish", "push", "record", "remove", "rename",
        "report", "run", "save", "send", "set", "share", "start", "stop", "store", "sync",
        "toggle", "trigger", "uninstall", "update", "upload", "write"
    ]

    /// Verbs that read. Only a *leading* read verb is decisive, so `list_markers` is a
    /// read while `markers` alone stays ambiguous and is refused as a write.
    static let readVerbs: Set<String> = [
        "describe", "fetch", "find", "get", "info", "list", "locate", "lookup", "query",
        "read", "scan", "search", "show", "status", "track", "view", "watch"
    ]

    /// Domain nouns that are a read when they are the whole name or lead it.
    static let readNouns: Set<String> = [
        "aircraft", "earthquakes", "fires", "flights", "globe", "infrastructure", "layers",
        "map", "satellites", "ships", "sources", "storms", "traffic", "typhoons", "vessels",
        "weather"
    ]

    /// Default-deny. The MCP layer's own hint may tighten this; nothing may loosen it.
    public static func classify(toolName: String) -> MCPToolSafety {
        let tokens = toolName.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard let first = tokens.first else { return .mutating }
        if tokens.contains(where: { writeTokens.contains($0) }) { return .mutating }
        if readVerbs.contains(first) { return .readOnly }
        if readNouns.contains(first) { return .readOnly }
        return .mutating
    }

    // MARK: Verification

    /// Proves what a directory contains without executing any of it.
    public static func verifyInstall(at url: URL, expectedVersion: String) -> GodsEyeInstallVerification {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .refused("安装目录不存在 / the install directory does not exist: \(AppPaths.anonymise(root.path))")
        }
        guard let manifestURL = containedFile(packageFile, in: root) else {
            return .refused("缺少 package.json，或它指向目录外 / package.json is missing or points outside the directory")
        }
        guard let data = try? Data(contentsOf: manifestURL), data.count <= maximumPackageBytes,
              let manifest = NodeJSON.decode(GodsEyePackageManifest.self, from: data) else {
            return .refused("package.json 无法解析 / package.json did not parse")
        }
        guard manifest.name == packageName else {
            return .refused("包名不符 / package name is \(manifest.name.isEmpty ? "empty" : manifest.name), expected \(packageName)")
        }
        let wanted = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinned = wanted.hasPrefix("v") ? String(wanted.dropFirst()) : wanted
        guard isVersion(pinned), manifest.version == pinned else {
            return .refused("版本不符 / version is \(manifest.version.isEmpty ? "empty" : manifest.version), expected \(pinned)")
        }
        guard let entry = containedFile(entryFile, in: root) else {
            return .refused("缺少入口 \(entryFile)，或它指向目录外 / \(entryFile) is missing or points outside")
        }
        guard let mcpEntry = containedFile(mcpEntryFile, in: root) else {
            return .refused("缺少 MCP 入口 \(mcpEntryFile)，或它指向目录外 / \(mcpEntryFile) is missing or points outside")
        }
        guard let entryData = try? Data(contentsOf: entry),
              let mcpData = try? Data(contentsOf: mcpEntry) else {
            return .refused("入口文件无法读取 / an entry script could not be read")
        }
        return GodsEyeInstallVerification(
            ok: true,
            detail: "已校验 \(packageName) \(pinned) / verified",
            path: root.path,
            packageName: packageName,
            version: pinned,
            entryPath: entry.path,
            mcpEntryPath: mcpEntry.path,
            entryDigest: Digest.sha256Hex(entryData),
            mcpEntryDigest: Digest.sha256Hex(mcpData)
        )
    }
}

/// The only fields this bridge reads from `package.json`. A full manifest can carry
/// scripts and dependencies this code must never look at, let alone run.
struct GodsEyePackageManifest: Codable, Sendable, Equatable {
    var name: String
    var version: String

    init(name: String = "", version: String = "") {
        self.name = name
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case name, version }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
    }
}

// MARK: - The MCP gate

/// Tightens the tier of the GodsEye server's tools and leaves every other server
/// alone. `MCPBridge` may only combine this with the server's own hint by taking the
/// stricter answer, so a server cannot talk its way down from `.mutating`.
public struct GodsEyeViewToolGate: MCPToolGate {
    public let serverID: String

    public init(serverID: String = GodsEyeViewPolicy.serverID) {
        self.serverID = serverID
    }

    public func effectiveSafety(serverID: String, tool: MCPTool) -> MCPToolSafety {
        guard serverID == self.serverID else { return tool.safety }
        if tool.safety == .mutating { return .mutating }
        return GodsEyeViewPolicy.classify(toolName: tool.name)
    }
}
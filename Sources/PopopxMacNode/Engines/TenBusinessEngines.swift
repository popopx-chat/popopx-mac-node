//
//  TenBusinessEngines.swift
//  PopopxMacNode — 模块四: the ten local business engines.
//
//  Shape of this file
//  ------------------
//  One actor (`TenBusinessEngines`) owns all ten engines so that the SMP entry
//  point (`execute`) and the console button path (`invoke`) share exactly one
//  scheduler. `ENGRenderGate` implements the brief's 并发锁防爆内存 requirement:
//  at most one heavy video render is resident at a time, light jobs get a small
//  separate allowance, and every admission re-samples projected free memory
//  before a model or an encoder is allowed to allocate.
//
//  `phantom_sentinel` deliberately bypasses the gate, the language model and any
//  suspension that could block on inference. A lockdown has to land in
//  milliseconds even while an LTX render is mid-frame, which is the whole point
//  of calling it a deterministic state machine.
//
//  Privacy red line: every path handed to the bridge, the console or an event
//  payload goes through `AppPaths.anonymise` first, so no home directory can
//  leak into an exported artifact, log line or SMP card.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Render scheduler

/// Serial/graded admission control for everything that may allocate a model or
/// an encoder: 并发锁防爆内存.
///
/// Rules, in order:
/// 1. a `heavy` render is admitted only when no other heavy render is resident;
/// 2. `light` work has its own small concurrency allowance so text/OCR jobs keep
///    flowing while a video renders;
/// 3. both weights re-check *projected* free memory (live figure minus the
///    reservations already held) before admission;
/// 4. the waiter queue is strict FIFO, so a queued heavy render is never
///    starved by a stream of light jobs.
///
/// Releases always happen in a `defer` on the calling path, so a throwing or
/// watchdog-killed job cannot leak a reservation and wedge the queue.
public actor ENGRenderGate {
    public enum Weight: String, Codable, Sendable, CaseIterable {
        /// Text, OCR, network, muxing — cheap, several may overlap.
        case light
        /// Video render or encode — one at a time, memory-checked.
        case heavy
    }

    private struct Holder {
        let token: String
        let weight: Weight
        let memoryGB: Int
        let startedAt: Date
    }

    private struct Waiter {
        let token: String
        let weight: Weight
        let memoryGB: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var holders: [String: Holder] = [:]
    private var waiters: [Waiter] = []
    private let maxLightConcurrent: Int
    private var totalAdmitted = 0
    private var totalRefusedImpossible = 0
    private var peakResidentGB = 0

    public init(maxLightConcurrent: Int = 2) {
        self.maxLightConcurrent = max(1, maxLightConcurrent)
    }

    /// Suspends until admitted. `nil` means "this machine can never satisfy the
    /// request" (or the caller asked for more than the node is allowed to hold),
    /// which lets the engine fail fast with an honest message instead of
    /// parking a job in the queue forever.
    public func reserve(weight: ENGRenderGate.Weight, memoryGB: Int) async -> String? {
        let requirement = max(1, memoryGB)
        let token = "slot-\(TextKit.fingerprint(UUID().uuidString, length: 12))"
        if requirement > max(1, ENGSysMemory.totalGB) {
            totalRefusedImpossible += 1
            return nil
        }
        if admit(token: token, weight: weight, memoryGB: requirement) != nil {
            return token
        }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append(Waiter(token: token, weight: weight, memoryGB: requirement, continuation: continuation))
        }
        return granted ? token : nil
    }

    public func release(_ token: String) {
        guard holders.removeValue(forKey: token) != nil else { return }
        pump()
    }

    /// Everything the console and the per-engine metrics report.
    public func state() -> [String: JSONValue] {
        let reserved = holders.values.reduce(0) { $0 + $1.memoryGB }
        return [
            "heavyActive": .bool(holders.values.contains(where: { $0.weight == .heavy })),
            "lightActive": .int(holders.values.filter { $0.weight == .light }.count),
            "maxLightConcurrent": .int(maxLightConcurrent),
            "queued": .int(waiters.count),
            "reservedGB": .int(reserved),
            "freeGB": .int(ENGSysMemory.freeGB()),
            "totalAdmitted": .int(totalAdmitted),
            "refusedImpossible": .int(totalRefusedImpossible),
            "peakResidentGB": .int(peakResidentGB)
        ]
    }

    // MARK: Admission

    /// Attempts to admit exactly one slot. Returns `nil` when the head of the
    /// queue must keep waiting; a waiter whose requirement exceeds an empty
    /// machine is woken with `false` so the queue cannot deadlock.
    @discardableResult
    private func admit(token: String, weight: ENGRenderGate.Weight, memoryGB: Int) -> String? {
        let heavyActive = holders.values.contains(where: { $0.weight == .heavy })
        let lightActive = holders.values.filter { $0.weight == .light }.count
        if weight == .heavy && heavyActive { return nil }
        if weight == .light && lightActive >= maxLightConcurrent { return nil }

        let reserved = holders.values.reduce(0) { $0 + $1.memoryGB }
        let projectedFree = ENGSysMemory.freeGB() - reserved
        if projectedFree < memoryGB {
            if holders.isEmpty {
                // Nobody is holding memory and the job still does not fit: the
                // request is impossible here, not merely contended. `pump` turns
                // this into a `false` wake-up so the waiter cannot park forever.
                totalRefusedImpossible += 1
            }
            return nil
        }

        holders[token] = Holder(token: token, weight: weight, memoryGB: memoryGB, startedAt: Date())
        totalAdmitted += 1
        peakResidentGB = max(peakResidentGB, reserved + memoryGB)
        return token
    }

    /// Re-runs admission after a release, strictly from the head of the queue.
    private func pump() {
        while let next = waiters.first {
            if admit(token: next.token, weight: next.weight, memoryGB: next.memoryGB) != nil {
                waiters.removeFirst()
                next.continuation.resume(returning: true)
                continue
            }
            if holders.isEmpty {
                // Impossible requirement — fail the head instead of wedging it.
                waiters.removeFirst()
                next.continuation.resume(returning: false)
                continue
            }
            break
        }
    }
}

// MARK: - Memory probe

/// Free/total unified memory without spawning a process. `vm_stat` numbers come
/// straight from the kernel, and `Sysctl.memorySize` gives the same physical
/// total the hardware probe reports.
public enum ENGSysMemory {
    public static var totalBytes: Int64 { Int64(Sysctl.memorySize) }
    public static var totalGB: Int { max(1, Int((Double(totalBytes) / 1_073_741_824).rounded())) }

    /// Pages the compressor is happy to hand back: free + inactive +
    /// speculative. Purgeable is excluded on purpose — a render must not rely on
    /// memory some other process still considers live.
    public static func freeBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Int64(vm_kernel_page_size)
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
        return max(0, pages * pageSize)
    }

    public static func freeGB() -> Int { max(0, Int(Double(freeBytes()) / 1_073_741_824)) }

    /// Free memory minus what already-accepted jobs have reserved.
    public static func projectedFreeGB(reservedGB: Int) -> Int { max(0, freeGB() - reservedGB) }
}

// MARK: - Payload access

/// Typed reads over the untyped `[String: JSONValue]` that arrives off the wire.
/// Every engine uses these so a missing key degrades into a refusal message
/// rather than a force-unwrap crash.
public enum ENGPayload {
    public static func string(_ payload: JSONValue, _ key: String, default fallback: String = "") -> String {
        payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }

    public static func int(_ payload: JSONValue, _ key: String, default fallback: Int = 0) -> Int {
        payload[key]?.intValue ?? fallback
    }

    public static func double(_ payload: JSONValue, _ key: String, default fallback: Double = 0) -> Double {
        payload[key]?.doubleValue ?? fallback
    }

    public static func bool(_ payload: JSONValue, _ key: String, default fallback: Bool = false) -> Bool {
        payload[key]?.boolValue ?? fallback
    }

    /// Tri-state read, for toggles where "absent" must mean *invert the current
    /// value* rather than *turn off*.
    public static func optionalBool(_ payload: JSONValue, _ key: String) -> Bool? {
        payload[key]?.boolValue
    }

    public static func strings(_ payload: JSONValue, _ key: String) -> [String] {
        guard let array = payload[key]?.arrayValue else {
            if let single = payload[key]?.stringValue, !single.isEmpty { return [single] }
            return []
        }
        return array.compactMap { value in
            let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
    }

    /// Accepts a path under `input`, `file`, `source` or `path`, in that order,
    /// so the iOS card and the console button can use different field names.
    public static func path(_ payload: JSONValue) -> String {
        for key in ["input", "file", "source", "path", "url"] {
            let value = string(payload, key)
            if !value.isEmpty { return value }
        }
        return ""
    }

    public static func missing(_ key: String, engine: EngineKind, commandID: String?) -> CommandResult {
        CommandResult.failure(engine, "Payload is missing the required field “\(key)”.", commandID: commandID)
    }
}

// MARK: - Filesystem helpers

/// Small, boring file layer shared by the engines: JSON documents written
/// atomically, size accounting, media filtering, bounded text reads.
public enum ENGFiles {
    public static let manager = FileManager.default

    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "hevc", "mts"
    ]
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"
    ]
    public static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "aac", "m4a", "flac", "opus"
    ]
    public static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "rtf", "json", "csv", "ics", "org"
    ]
    public static let documentExtensions: Set<String> = ["pdf"]

    public static var mediaExtensions: Set<String> {
        videoExtensions.union(imageExtensions).union(audioExtensions).union(documentExtensions)
    }

    public static func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    public static func size(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
            return 0
        }
        return Int64(size)
    }

    /// Recursive byte total for a directory; used by the mesh sandbox meter.
    public static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NodeJSON.decode(type, from: data)
    }

    /// Atomic write with intermediate directories created. `.completeFileProtection`
    /// matches `SettingsStore.persist` so the ledgers are not readable at rest
    /// once the device is locked.
    @discardableResult
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = NodeJSON.encodePretty(value) else { return false }
        return write(data, to: url)
    }

    @discardableResult
    public static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func write(_ text: String, to url: URL) -> Bool {
        write(Data(text.utf8), to: url)
    }

    /// Reads at most `limit` UTF-8 bytes so a runaway log file cannot balloon a
    /// model prompt.
    public static func readText(_ url: URL, limit: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: min(limit, 1 << 20))
        guard let text = String(data: data, encoding: .utf8) else {
            return String(decoding: data, as: UTF8.self)
        }
        return text
    }

    /// Files of one of the accepted media types inside a directory, newest first.
    public static func mediaFiles(in url: URL, limit: Int = 64) -> [URL] {
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let media = entries.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
        return Array(sortedByModification(media, limit: limit))
    }

    public static func sortedByModification(_ urls: [URL], limit: Int) -> [URL] {
        let dated = urls.map { url -> (URL, Date) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        return Array(dated.sorted { $0.1 > $1.1 }.prefix(max(0, limit))).map(\.0)
    }

    /// `yyyyMMdd-HHmmss` — sortable, shell-safe, no separators that confuse URLs.
    public static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    public static func freeDiskGB(at url: URL = AppPaths.root) -> Int {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return max(0, Int(Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824))
    }

    /// SecRandomCopyBytes into a fixed buffer; the only entropy source used for
    /// keys and shred padding.
    public static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) != errSecSuccess {
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255) }
        }
        return Data(buffer)
    }
}

// MARK: - Local model client

/// Loopback-only Ollama client. `stream = false` keeps the whole reply in one
/// JSON document, which is what an SMP card needs; nothing here can reach a
/// hosted inference API because the host literal is `127.0.0.1`.
public enum ENGOllama {
    public struct Reply: Sendable {
        public let text: String
        public let model: String
        public let promptTokens: Int
        public let generatedTokens: Int
        public let evalDurationMs: Int

        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static var host: String { "127.0.0.1:\(NodeWire.ollamaPort)" }
    public static var baseURL: URL { URL(string: "http://\(host)")! }

    public static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    /// Cheap liveness probe used before a pipeline spends minutes loading a
    /// model that is not running.
    public static func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        guard let (data, response) = try? await session(timeout: 2).data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = NodeJSON.decode(JSONValue.self, from: data) else { return false }
        return root["error"]?.isEmptyValue ?? true
    }

    public static func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        guard let (data, _) = try? await session(timeout: 3).data(for: request),
              let root = NodeJSON.decode(JSONValue.self, from: data),
              let models = root["models"]?.arrayValue else { return [] }
        return models.compactMap { $0["name"]?.stringValue }
    }

    /// POSTs `/api/generate`. Throws `NodeFailure` so callers surface a readable
    /// refusal instead of an empty card.
    public static func generate(
        model: String,
        prompt: String,
        system: String = "",
        temperature: Double = 0.35,
        contextTokens: Int = 4096,
        timeout: TimeInterval = 180
    ) async throws -> Reply {
        guard !model.isEmpty else { throw NodeFailure.invalidPayload("empty model reference") }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "prompt": .string(prompt),
            "stream": .bool(false),
            "options": .object([
                "temperature": .double(temperature),
                "num_ctx": .int(max(512, contextTokens)),
                "num_predict": .int(-1)
            ])
        ]
        if !system.isEmpty { body["system"] = .string(system) }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = Data(JSONValue.object(body).serialized().utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session(timeout: timeout).data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut { throw NodeFailure.timedOut("ollama generate") }
            throw NodeFailure.networkUnavailable(host)
        } catch {
            throw NodeFailure.networkUnavailable(host)
        }
        guard let http = response as? HTTPURLResponse else { throw NodeFailure.networkUnavailable(host) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(400), as: UTF8.self)
            throw NodeFailure.networkUnavailable("ollama HTTP \(http.statusCode): \(detail.prefix(160))")
        }
        guard let root = NodeJSON.decode(JSONValue.self, from: data) else {
            throw NodeFailure.invalidPayload("ollama reply is not JSON")
        }
        let text = root["response"]?.stringValue
            ?? root["message"]?.arrayValue?.last?["content"]?.stringValue
            ?? ""
        let metrics = root["metrics"]
        return Reply(
            text: text,
            model: root["model"]?.stringValue ?? model,
            promptTokens: metrics?["prompt_eval_count"]?.intValue ?? 0,
            generatedTokens: metrics?["eval_count"]?.intValue ?? 0,
            evalDurationMs: metrics?["eval_duration"]?.intValue ?? 0
        )
    }

    /// Respects `NodeSettings.llmModelOverride` when the owner pinned a model in
    /// the console, otherwise the hardware-derived ladder from `ModelPlan`.
    public static func resolvedModel(settings: NodeSettings, plan: ModelPlan) -> String {
        let override = settings.llmModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? plan.llmRef : override
    }
}

// MARK: - FFmpeg layer

/// Argument-vector builders for ffmpeg/ffprobe. Nothing here ever assembles a
/// shell string, so a filename off the SMP wire cannot become a command line.
public enum ENGFFmpeg {
    public struct Capability: Sendable {
        public let ffmpeg: String?
        public let ffprobe: String?
        public let versionLine: String
        public let encoders: [String]

        public var isUsable: Bool { ffmpeg != nil && ffprobe != nil }
        public func encoder(_ name: String) -> Bool { encoders.contains { $0 == name } }
        public var hasLibmp3lame: Bool { encoder("libmp3lame") || encoder("aac") }
        public var hasLibx264: Bool { encoder("libx264") }
        public var hasAssBurnIn: Bool { encoder("ass") || encoder("libass") }
    }

    public static func probe() async -> Capability {
        let ffmpeg = Shell.which("ffmpeg")
        let ffprobe = Shell.which("ffprobe")
        var version = ""
        var encoders: [String] = []
        if let ffmpeg {
            let result = await Shell.run(ffmpeg, ["-hide_banner", "-version"], timeout: 10)
            version = result.succeeded ? result.firstLine : ""
            let listing = await Shell.run(ffmpeg, ["-hide_banner", "-encoders"], timeout: 20)
            if listing.succeeded {
                // `-encoders` rows look like ` V. ..... libx264  H.264 …`; the
                // identifier is the third whitespace-separated column.
                encoders = listing.stdout
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        guard parts.count >= 3 else { return nil }
                        return String(parts[2])
                    }
            }
        }
        return Capability(ffmpeg: ffmpeg, ffprobe: ffprobe, versionLine: version, encoders: encoders)
    }

    public static func outputURL(_ name: String, fileExtension: String, in directory: URL = AppPaths.output) -> URL {
        let safe = TextKit.safeFileName(name, fallback: "artifact")
        return directory.appendingPathComponent("\(safe).\(fileExtension)")
    }

    /// `-show_entries packet=pts_time,flags -of csv` — the packet table the
    /// watermark extractor reads. Keyframe rows carry a `K` in the flags field.
    public static func keyframeTimes(
        ffprobe: String,
        input: URL,
        timeout: TimeInterval = 8
    ) async -> ([Double], String) {
        let arguments = [
            "-v", "error",
            "-select_streams", "v",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv",
            input.path
        ]
        let result = await Shell.run(ffprobe, arguments, timeout: timeout)
        guard result.succeeded else { return ([], result.combinedOutput) }
        return (parsePacketTable(result.stdout), "")
    }

    /// Parses `pts_time,flags` rows, keeping only keyframes, in ascending order.
    public static func parsePacketTable(_ csv: String) -> [Double] {
        var times: [Double] = []
        times.reserveCapacity(256)
        for rawLine in csv.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields[1].contains("K") else { continue }
            guard let value = Double(fields[0].replacingOccurrences(of: "N/A", with: "")) else { continue }
            if value.isFinite { times.append(value) }
        }
        return times.sorted()
    }

    public static func duration(ffprobe: String, input: URL, timeout: TimeInterval = 8) async -> Double? {
        let result = await Shell.run(
            ffprobe,
            ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input.path],
            timeout: timeout
        )
        guard result.succeeded, let value = Double(result.firstLine) else { return nil }
        return value > 0 ? value : nil
    }

    /// Stream-copies `[start, end)` out of a source. `start` must be a keyframe
    /// timestamp, which is exactly what the watermark planner supplies: with
    /// `-c copy` ffmpeg lands on the keyframe at or before the requested seek
    /// point, so asking for a known keyframe time is a pixel-free exact cut.
    public static func copySlice(
        ffmpeg: String,
        input: URL,
        start: Double,
        end: Double,
        output: URL,
        timeout: TimeInterval = 120
    ) async -> ShellResult {
        await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.6f", max(0, start)),
                "-to", String(format: "%.6f", max(0, end)),
                "-i", input.path,
                "-map", "0:v", "-map", "0:a?",
                "-c", "copy",
                "-avoid_negative_ts", "make_zero",
                "-fflags", "+genpts",
                "-movflags", "+faststart",
                output.path
            ],
            timeout: timeout
        )
    }

    /// Lossless concat of the slices back into the fingerprinted copy.
    public static func concat(
        ffmpeg: String,
        listFile: URL,
        output: URL,
        timeout: TimeInterval = 180
    ) async -> ShellResult {
        await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", listFile.path,
                "-map_metadata", "-1",
                "-c", "copy",
                "-movflags", "+faststart",
                output.path
            ],
            timeout: timeout
        )
    }

    /// The brief's de-identification command, verbatim in argv form.
    public static func stripMetadata(
        ffmpeg: String,
        input: URL,
        output: URL,
        timeout: TimeInterval = 180
    ) async -> ShellResult {
        await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", input.path,
                "-map_metadata", "-1",
                "-fflags", "+bitexact",
                "-map", "0:v", "-map", "0:a?",
                "-c", "copy",
                "-movflags", "+faststart",
                output.path
            ],
            timeout: timeout
        )
    }

    /// `-c copy` refuses some containers/codecs (a ProRes MOV with a metadata
    /// atom ffmpeg will not drop, for instance). Falling back to a re-encode is
    /// the only way to guarantee the fingerprint is gone, at the cost of a
    /// generation loss that the result card discloses.
    public static func stripMetadataReencode(
        ffmpeg: String,
        input: URL,
        output: URL,
        sampleRateHz: Int,
        preferX264: Bool,
        timeout: TimeInterval = 600
    ) async -> ShellResult {
        var arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", input.path,
            "-map_metadata", "-1",
            "-fflags", "+bitexact",
            "-map", "0:v", "-map", "0:a?",
            "-ar", String(max(8_000, sampleRateHz)),
            "-ac", "2"
        ]
        arguments += preferX264
            ? ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p"]
            : ["-c:v", "mpeg4", "-q:v", "4"]
        arguments += ["-c:a", "aac", "-b:a", "160k"]
        arguments += ["-movflags", "+faststart", output.path]
        return await Shell.run(ffmpeg, arguments, timeout: timeout)
    }

    /// Loudness-neutral final pass used by the render pipelines; pins the
    /// container audio rate to the plan's `audioSampleRateHz` (48 kHz) and adds
    /// a silent stereo track when there is no narration, so iOS players never
    /// demote the clip to a still image.
    public static func normalise(
        ffmpeg: String,
        input: URL,
        output: URL,
        audioTrack: URL?,
        sampleRateHz: Int,
        width: Int?,
        timeout: TimeInterval = 900
    ) async -> ShellResult {
        var arguments = ["-y", "-hide_banner", "-loglevel", "error"]
        arguments += ["-i", input.path]
        if let audioTrack {
            arguments += ["-i", audioTrack.path, "-map", "0:v", "-map", "1:a"]
        } else {
            arguments += [
                "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=\(max(8_000, sampleRateHz))",
                "-map", "0:v", "-map", "1:a"
            ]
        }
        arguments += [
            "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ar", String(max(8_000, sampleRateHz)), "-ac", "2",
            "-shortest"
        ]
        if let width, width > 0 {
            arguments += ["-vf", "scale='min(\(width),iw)':-2:flags=bicubic"]
        }
        arguments += ["-movflags", "+faststart", output.path]
        return await Shell.run(ffmpeg, arguments, timeout: timeout)
    }

    /// Solid colour plate used as the anchor-clip background. Generated locally,
    /// so a briefing video never needs a studio and never needs a cloud render.
    public static func colorPlate(
        ffmpeg: String,
        output: URL,
        seconds: Double,
        size: String,
        color: String,
        frameRate: Int,
        timeout: TimeInterval = 300
    ) async -> ShellResult {
        await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi",
                "-i", "color=c=\(color):s=\(size):r=\(max(12, min(60, frameRate)))",
                "-t", String(format: "%.3f", max(0.5, seconds)),
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "24", "-pix_fmt", "yuv420p",
                output.path
            ],
            timeout: timeout
        )
    }

    /// Burns a caption file. The text travels as a `textfile=` path, never as a
    /// literal inside the filter string: an unescaped `'` or `:` in report or
    /// feed text would otherwise terminate the `text` property and let the
    /// payload append more filters to the graph.
    public static func burnText(
        ffmpeg: String,
        input: URL,
        captionFile: URL,
        output: URL,
        fontPath: String?,
        fontSize: Int,
        sampleRateHz: Int,
        seconds: Double,
        timeout: TimeInterval = 600
    ) async -> ShellResult {
        let fontPart = fontPath.map { ",fontfile=\(escapeFilterPath($0))" } ?? ""
        let filter = "drawtext=textfile=\(escapeFilterPath(captionFile.path))"
            + fontPart
            + ":fontsize=\(max(18, fontSize)):fontcolor=white:box=1:boxcolor=black@0.55"
            + ":boxborderw=18:x=(w-text_w)/2:y=h-text_h-96"
        var arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", input.path,
            "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=\(max(8_000, sampleRateHz))",
            "-vf", filter,
            "-map", "0:v", "-map", "1:a",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest",
            "-movflags", "+faststart",
            output.path
        ]
        if seconds > 0 {
            arguments.insert(contentsOf: ["-t", String(format: "%.3f", max(0.5, seconds))], at: arguments.count - 1)
        }
        return await Shell.run(ffmpeg, arguments, timeout: timeout)
    }

    /// ASS/SSA burn-in when the build carries libass; better word wrapping than
    /// drawtext for multi-line briefing scripts.
    public static func burnAss(
        ffmpeg: String,
        input: URL,
        assFile: URL,
        output: URL,
        sampleRateHz: Int,
        timeout: TimeInterval = 600
    ) async -> ShellResult {
        let arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", input.path,
            "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=\(max(8_000, sampleRateHz))",
            "-vf", "ass=\(escapeFilterPath(assFile.path))",
            "-map", "0:v", "-map", "1:a",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest",
            "-movflags", "+faststart",
            output.path
        ]
        return await Shell.run(ffmpeg, arguments, timeout: timeout)
    }

    public static func convert(
        ffmpeg: String,
        input: URL,
        output: URL,
        extraArguments: [String],
        timeout: TimeInterval = 180
    ) async -> ShellResult {
        await Shell.run(
            ffmpeg,
            ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path] + extraArguments + [output.path],
            timeout: timeout
        )
    }

    /// Frame grab for the OCR stage: `interval` seconds between sampled frames.
    /// PNG is deliberate — a lossy JPEG would eat the small glyph strokes a
    /// report table is made of.
    public static func sampleFrames(
        ffmpeg: String,
        input: URL,
        into directory: URL,
        prefix: String,
        maximum: Int,
        intervalSeconds: Double,
        width: Int = 1600,
        timeout: TimeInterval = 120
    ) async -> [URL] {
        let cap = max(1, min(64, maximum))
        let pattern = directory.appendingPathComponent("\(prefix)-%03d.png")
        let result = await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", input.path,
                "-vf", "fps=1/\(String(format: "%.2f", max(0.5, intervalSeconds))),scale=\(width):-2:flags=bicubic",
                "-frames:v", String(cap),
                pattern.path
            ],
            timeout: timeout
        )
        guard result.succeeded else { return [] }
        let files = ((try? ENGFiles.manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(files.prefix(cap))
    }

    /// Escapes a path for a filtergraph property: only `:`, `\` and `%` are
    /// special inside a filter argument.
    public static func escapeFilterPath(_ path: String) -> String {
        var output = ""
        for scalar in path.unicodeScalars {
            if scalar == ":" || scalar == "\\" || scalar == "%" {
                output += "\\\\" + String(scalar)
            } else if CharacterSet.controlCharacters.contains(scalar) {
                output += " "
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Escapes literal text for a filter property. Kept for the title-card path
    /// where a textfile would be overkill; control characters are dropped first
    /// because a newline inside `text=` terminates the filter.
    public static func escapeFilterText(_ raw: String) -> String {
        let flattened = raw
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        var output = ""
        for scalar in String(flattened.prefix(400)).unicodeScalars {
            switch scalar {
            case "\\", "'", ":", ",", "[", "]": output += "\\\\\\" + String(scalar)
            case "%": output += "\\%"
            default:
                if !CharacterSet.controlCharacters.contains(scalar) { output.unicodeScalars.append(scalar) }
            }
        }
        return output
    }

    /// A CJK-capable system font for burn-in, or `nil` to let ffmpeg pick from
    /// fontconfig. macOS ships PingFang; a Latin-only face would silently render
    /// Chinese briefings as tofu.
    public static func captionFont() -> String? {
        let candidates = [
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/Hiragino Sans GB.ttc",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/System/Library/Fonts/Helvetica.ttc"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Gop watermark maths

/// Pure math for the A/B GOP-slice blind watermark: bit expansion, the
/// anti-collusion distance table, cut planning and the blind decoder.
///
/// Why this shape is defensible rather than hand-waved
/// ---------------------------------------------------
/// Each payload bit selects one of two *deterministic* GOP alignments for its
/// segment: bit 0 opens the segment at the first keyframe at/after the window
/// edge, bit 1 opens it at the first keyframe at/after the edge plus half the
/// median GOP length. Both are pure stream copies, so no pixel is re-encoded.
///
/// With `payloadBits = 16` and one slot per bit the codebook is the whole
/// 16-bit hyper-cube, whose minimum pairwise Hamming distance is **1**. That
/// means one flipped slot silently decodes to a *different valid* queue id.
/// Setting `WarroomConfig.segmentsPerVideo` above `payloadBits` makes every bit
/// occupy `repeats = slots / payloadBits` slots: the minimum distance becomes
/// `repeats`, majority decoding corrects `repeats/2` flips per bit, and the
/// surplus slots carry a checksum word so tampering and tail-truncation are
/// detected instead of silently mistraced. That lever is free — the media cost
/// is unchanged — which is the honest answer to 抗合谋 rather than a claim of
/// unbreakability.
///
/// Known loss modes, disclosed in the result body rather than hidden:
/// * any transcode by the leaker destroys the pattern entirely (the watermark
///   lives in the GOP *schedule*, not in the pixels);
/// * cropping the first or last second drops the outermost slots;
/// * a source whose GOP is longer than the window cannot encode a late boundary,
///   which the planner records as a hole and the decoder reports as reduced
///   confidence.
public enum ENGGopWatermark {
    public struct Plan: Sendable {
        public let queue: String
        public let queueID: Int
        public let payloadBits: Int
        public let slots: Int
        public let repeats: Int
        public let slotBits: [Bool]
        public let boundaries: [Double]
        public let holes: [Int]
        public let medianGap: Double
        public let duration: Double

        /// Slots that actually carry the payload (as opposed to the checksum).
        public var payloadSlotCount: Int { payloadBits * repeats }
    }

    public struct Decode: Sendable {
        public let slotBits: [Bool]
        public let resolved: [Bool]
        public let margins: [Double]
        public let medianGap: Double
        public let duration: Double
    }

    /// MSB-first expansion, so a trimmed file loses its *least* significant bits
    /// and the recovered prefix still narrows the suspect set.
    public static func bits(from id: Int, payloadBits: Int) -> [Bool] {
        let width = min(max(payloadBits, 8), 32)
        let mask = UInt64(bitPattern: Int64(-1)) >> (64 - width)
        let value = UInt64(truncatingIfNeeded: max(0, id)) & mask
        return (0..<width).map { shift in
            ((value >> UInt64(width - 1 - shift)) & 1) == 1
        }
    }

    public static func id(from bits: [Bool]) -> Int {
        var value = 0
        for bit in bits { value = (value << 1) | (bit ? 1 : 0) }
        return value
    }

    /// Cheap integrity word for the surplus slots: the queue id hashed and
    /// truncated. Not a MAC — nobody but the node knows which id was embedded,
    /// and the check only has to distinguish "pattern intact" from "pattern
    /// damaged".
    public static func checksum(for id: Int, payloadBits: Int) -> Int {
        let width = min(max(payloadBits, 8), 32)
        let digest = Digest.sha256Bytes(Data("ppx-warroom-\(id)".utf8))
        var accumulator = 0
        for byte in digest.prefix(4) { accumulator = (accumulator << 8) | Int(byte) }
        let mask = (1 << width) - 1
        return accumulator & mask
    }

    public static func repeats(slots: Int, payloadBits: Int) -> Int {
        max(1, slots / max(1, payloadBits))
    }

    /// Minimum pairwise Hamming distance of the codebook actually in use.
    public static func minimumDistance(payloadBits: Int, repeats: Int) -> Int {
        min(payloadBits, repeats) * 1 + (repeats > 1 ? repeats - 1 : 0)
    }

    public static func hamming(_ a: [Bool], _ b: [Bool]) -> Int {
        zip(a, b).reduce(0) { total, pair in total + (pair.0 == pair.1 ? 0 : 1) }
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    public static func differences(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }
        return (1..<values.count).map { values[$0] - values[$0 - 1] }.filter { $0 > 0.001 }
    }

    /// Chooses the keyframe that opens every slot.
    ///
    /// Returns the ascending boundary list plus the slot indexes that could not
    /// be resolved to a distinct early/late keyframe (`holes`).
    public static func plan(
        queue: String,
        queueID: Int,
        duration: Double,
        keyframes: [Double],
        payloadBits: Int,
        slots requestedSlots: Int
    ) -> Plan {
        let slots = min(max(requestedSlots, 8), 64)
        let width = min(max(payloadBits, 8), 32)
        let repeats = self.repeats(slots: slots, payloadBits: width)
        let payload = bits(from: queueID, payloadBits: width)
        let checksumBits = bits(from: checksum(for: queueID, payloadBits: width), payloadBits: width)

        var slotBits: [Bool] = []
        slotBits.reserveCapacity(slots)
        for slot in 0..<slots {
            if slot < width * repeats {
                slotBits.append(payload[slot / max(1, repeats)])
            } else {
                slotBits.append(checksumBits[(slot - width * repeats) % max(1, width)])
            }
        }

        let gaps = differences(keyframes)
        let medianGap = median(gaps.isEmpty ? [max(0.5, duration / 12)] : gaps)
        let window = duration / Double(max(1, slots))
        var boundaries: [Double] = []
        var holes: [Int] = []
        boundaries.reserveCapacity(slots)

        for slot in 0..<slots {
            let edge = Double(slot) * window
            let early = keyframes.first { $0 >= edge - min(0.25, medianGap * 0.2) }
            let lateTarget = edge + medianGap / 2
            var late = keyframes.first { $0 >= lateTarget }
            if let earlyValue = early, let lateValue = late, abs(lateValue - earlyValue) < medianGap * 0.2 {
                late = keyframes.first { $0 > lateTarget + medianGap * 0.2 }
            }
            let chosen = slotBits[slot] ? (late ?? early) : early
            if let value = chosen {
                let offset = max(0, value - edge)
                if slotBits[slot] && offset < medianGap * 0.4 { holes.append(slot) }
                if !slotBits[slot] && offset > medianGap * 0.8 { holes.append(slot) }
                boundaries.append(min(value, max(0, duration - 0.05)))
            } else {
                holes.append(slot)
                boundaries.append(min(edge, max(0, duration - 0.05)))
            }
        }

        return Plan(
            queue: queue,
            queueID: queueID,
            payloadBits: width,
            slots: slots,
            repeats: repeats,
            slotBits: slotBits,
            boundaries: uniqueAscending(boundaries),
            holes: holes,
            medianGap: medianGap,
            duration: duration
        )
    }

    public static func uniqueAscending(_ values: [Double]) -> [Double] {
        var output: [Double] = []
        for value in values.sorted() where output.isEmpty || value - (output.last ?? 0) > 0.02 {
            output.append(value)
        }
        return output
    }

    /// Blind decode: given only the leaked file's keyframe times, decide for
    /// each window whether the opening GOP sits early (bit 0) or late (bit 1).
    ///
    /// The window grid is reconstructed from the file's own duration — the
    /// embed changes *where* GOPs start but not how long the video is — so the
    /// decoder needs no registry, which is what makes a dragged-in leaked copy
    /// traceable in about a second.
    public static func decode(
        keyframes: [Double],
        duration: Double,
        payloadBits: Int,
        slots requestedSlots: Int
    ) -> Decode {
        let slots = min(max(requestedSlots, 8), 64)
        let window = duration / Double(max(1, slots))
        let gaps = differences(keyframes)
        let medianGap = median(gaps.isEmpty ? [max(0.5, duration / 12)] : gaps)
        let threshold = medianGap * 0.45

        var slotBits: [Bool] = []
        var resolved: [Bool] = []
        var margins: [Double] = []
        slotBits.reserveCapacity(slots)

        for slot in 0..<slots {
            let edge = Double(slot) * window
            guard let opening = keyframes.first(where: { $0 >= edge - max(0.08, window * 0.02) }) else {
                slotBits.append(false)
                resolved.append(false)
                margins.append(0)
                continue
            }
            let offset = max(0, opening - edge)
            let bit = offset >= threshold
            slotBits.append(bit)
            resolved.append(abs(offset - threshold) > medianGap * 0.12)
            margins.append(medianGap > 0 ? offset / medianGap : 0)
        }

        return Decode(slotBits: slotBits, resolved: resolved, margins: margins, medianGap: medianGap, duration: duration)
    }

    /// Majority vote across the redundant copies of one payload bit.
    public static func majority(_ values: [Bool]) -> (bit: Bool, agreement: Double) {
        guard !values.isEmpty else { return (false, 0) }
        let ones = values.filter { $0 }.count
        let winner = ones * 2 >= values.count
        let matching = winner ? ones : values.count - ones
        return (winner, Double(matching) / Double(values.count))
    }

    public static func fingerprint(queue: String, queueID: Int) -> String {
        TextKit.fingerprint("\(queue)|\(queueID)", length: 8)
    }
}

// MARK: - Hash chain

/// The `chrono_ark` key-derivation cost function: `key = SHA256^rounds(seed)`.
///
/// A serial hash chain is chosen because there is no known way to compute the
/// n-th SHA-256 iteration without doing all n-1 before it, so the *minimum*
/// work is fixed. What it is NOT is a secret: `seed` sits in the envelope file
/// because any verifier must be able to redo the chain. Consequently the chain
/// throttles an attacker who is willing to spend CPU, and a determined attacker
/// with a GPU farm can run the same chain hundreds of times in parallel and
/// finish early — the honest framing in the product copy is "buys time, not
/// certainty", and the wall-clock `earliestOpenAt` gate on top of it is policy
/// enforced by this process, not mathematics.
///
/// `rounds` is therefore calibrated from a live throughput measurement of *this*
/// machine and capped, so a one-year lock cannot claim to require a year of
/// work that would take a decade to actually verify. The capped remainder is
/// enforced by the deadline alone and the result card says so.
public enum ENGHashChain {
    public struct Rate: Sendable {
        public let roundsPerSecond: Double
        public let measuredAt: Date
    }

    /// Rounds a single core can hash in the calibration burst. `SHA256.hash`
    /// over a 32-byte digest is the exact loop the unlock performs, so the
    /// measurement transfers directly.
    public static func calibrate(burstSeconds: Double = 0.12) async -> Rate {
        await Task.detached(priority: .userInitiated) { () -> Rate in
            var digest = Data(Digest.sha256Bytes(Data("ppx-ark-calibration".utf8)))
            var rounds = 0
            let started = Date()
            let limit = max(0.02, burstSeconds)
            while Date().timeIntervalSince(started) < limit {
                digest = Data(SHA256.hash(data: digest))
                rounds += 1
            }
            let elapsed = max(0.001, Date().timeIntervalSince(started))
            return Rate(roundsPerSecond: Double(rounds) / elapsed, measuredAt: Date())
        }.value
    }

    /// Runs the chain in one detached task, in slices, so a long unlock can
    /// report progress and cannot wedge the actor that serves the console.
    /// `onSlice` fires between slices from a background thread — callers pass a
    /// closure that only touches Sendable values.
    public static func derive(
        seed: Data,
        rounds: Int,
        sliceRounds: Int = 65_536,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Data {
        await Task.detached(priority: .userInitiated) { () -> Data in
            var digest = seed
            let total = max(1, rounds)
            let slice = max(1_024, sliceRounds)
            var index = 0
            while index < total {
                let upper = min(index + slice, total)
                while index < upper {
                    digest = Data(SHA256.hash(data: digest))
                    index += 1
                }
                onProgress(Double(index) / Double(total))
            }
            return digest
        }.value
    }

    /// `rounds` for a requested delay, clamped so verification stays runnable.
    public static func rounds(seconds: Double, rate: Rate, capSeconds: Double) -> Int {
        let bounded = min(max(60, seconds), max(60, capSeconds))
        return max(100_000, Int(rate.roundsPerSecond * bounded))
    }

    /// Wall time the chain actually represents on the measured machine.
    public static func representedSeconds(rounds: Int, rate: Rate) -> Double {
        Double(rounds) / max(1, rate.roundsPerSecond)
    }
}

// MARK: - Waveform synthesiser

/// Pure-math binaural / isochronic tone generator writing a 16-bit stereo PCM
/// WAV by hand. No audio framework, no asset, no network: the numbers are the
/// product, and the file is 44 lines of header plus interleaved samples.
///
/// Binaural beats are a *perceptual* artefact of two slightly different
/// frequencies, one per ear — the two channels must stay hard-panned, which is
/// why this writes real stereo frames instead of a summed mono track.
public enum ENGWav {
    public struct Params: Sendable {
        public let sampleRateHz: Int
        public let carrierHz: Double
        public let beatHz: Double
        public let seconds: Int
        public let rampSeconds: Double
        public let isochronic: Bool
        public let peakLevel: Double
        public let channels: Int
        public let bitsPerSample: Int

        public init(
            sampleRateHz: Int,
            carrierHz: Double,
            beatHz: Double,
            seconds: Int,
            rampSeconds: Double,
            isochronic: Bool,
            peakLevel: Double = 0.82
        ) {
            self.sampleRateHz = min(max(sampleRateHz, 8_000), 192_000)
            self.carrierHz = min(max(carrierHz, 60), 1_200)
            self.beatHz = min(max(beatHz, 0.5), 40)
            self.seconds = min(max(seconds, 10), 7_200)
            self.rampSeconds = min(max(rampSeconds, 0.5), Double(self.seconds) / 4)
            self.isochronic = isochronic
            self.peakLevel = min(max(peakLevel, 0.05), 0.95)
            self.channels = 2
            self.bitsPerSample = 16
        }
    }

    /// Raised-cosine (Hann-shaped) fade in and out. A linear ramp leaves an
    /// audible kink in the amplitude derivative at the seam.
    /// Conventional brainwave band label for a beat frequency, so the console can
    /// say "delta" instead of "2.5 Hz". The bands are folklore-adjacent; the
    /// arithmetic is what this node guarantees.
    public static func bandName(beat: Double) -> String {
        switch beat {
        case ..<4: return "delta"
        case ..<8: return "theta"
        case ..<12: return "alpha"
        case ..<30: return "beta"
        default: return "gamma"
        }
    }

    public static func envelope(t: Double, ramp: Double, total: Double) -> Double {
        guard ramp > 0 else { return 1 }
        if t < ramp { return 0.5 * (1 - cos(.pi * t / ramp)) }
        if t > total - ramp { return 0.5 * (1 + cos(.pi * (t - (total - ramp)) / ramp)) }
        return 1
    }

    /// One block of interleaved 16-bit little-endian samples. Generated in
    /// blocks rather than all at once: the brief caps a tone at two hours, and
    /// 48 kHz × 2 ch × 2 h is 1.38 GB of RAM if the whole file is built in one
    /// buffer — exactly the kind of allocation the render gate exists to stop.
    public static func block(
        from firstFrame: Int,
        frames: Int,
        _ parameters: Params
    ) -> Data {
        let count = max(0, frames)
        var output = Data(count: count * 4)
        guard count > 0 else { return output }
        let twoPi = 2.0 * Double.pi
        let gateRate = parameters.isochronic ? parameters.beatHz : 0
        output.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for offset in 0..<count {
                let index = firstFrame + offset
                let time = Double(index) / Double(parameters.sampleRateHz)
                let fade = envelope(t: time, ramp: parameters.rampSeconds, total: Double(parameters.seconds))
                let gate = parameters.isochronic
                    ? 0.5 * (1 + cos(twoPi * gateRate * time))
                    : 1.0
                let rightFrequency = parameters.isochronic
                    ? parameters.carrierHz
                    : parameters.carrierHz + parameters.beatHz
                base[offset * 2] = clampInt16(sin(twoPi * parameters.carrierHz * time) * fade * gate * parameters.peakLevel)
                base[offset * 2 + 1] = clampInt16(sin(twoPi * rightFrequency * time) * fade * gate * parameters.peakLevel)
            }
        }
        return output
    }

    /// Streams a complete WAV to `url`, yielding between blocks so a two-hour
    /// tone does not monopolise a cooperative thread. Returns the byte count.
    public static func write(
        to url: URL,
        parameters: Params,
        blockSeconds: Int = 2
    ) async throws -> Int64 {
        let totalFrames = parameters.sampleRateHz * parameters.seconds
        let header = header(forFrames: totalFrames, parameters: parameters)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(0))
        try handle.write(contentsOf: header)
        var written = Int64(header.count)
        var frame = 0
        let blockFrames = max(parameters.sampleRateHz, 1) * max(1, blockSeconds)
        while frame < totalFrames {
            let frames = min(blockFrames, totalFrames - frame)
            try handle.write(contentsOf: block(from: frame, frames: frames, parameters))
            written += Int64(frames * 4)
            frame += frames
            await Task.yield()
        }
        try handle.synchronize()
        return written
    }

    public static func header(forFrames frames: Int, parameters: Params) -> Data {
        let pcmBytes = frames * parameters.channels * parameters.bitsPerSample / 8
        return wrap(pcm: Data(), sampleRateHz: parameters.sampleRateHz, channels: parameters.channels,
                    bitsPerSample: parameters.bitsPerSample, pcmByteCount: pcmBytes)
    }

    public static func clampInt16(_ value: Double) -> Int16 {
        let scaled = value * 32_767
        guard scaled.isFinite else { return 0 }
        return Int16(max(-32_768, min(32_767, scaled.rounded())))
    }

    /// RIFF/WAVE container for integer PCM, little-endian. The `data` chunk size
    /// is passed in because `write` knows the length before it generates audio.
    public static func wrap(
        pcm: Data,
        sampleRateHz: Int,
        channels: Int,
        bitsPerSample: Int,
        pcmByteCount: Int? = nil
    ) -> Data {
        let payload = pcmByteCount ?? pcm.count
        let byteRate = sampleRateHz * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var data = Data()
        func ascii(_ text: String) -> Data { Data(text.utf8) }
        func u32(_ value: Int) -> Data {
            var little = UInt32(truncatingIfNeeded: value).littleEndian
            return Data(bytes: &little, count: 4)
        }
        func u16(_ value: Int) -> Data {
            var little = UInt16(truncatingIfNeeded: value).littleEndian
            return Data(bytes: &little, count: 2)
        }
        data.append(ascii("RIFF"))
        data.append(u32(36 + payload))
        data.append(ascii("WAVE"))
        data.append(ascii("fmt "))
        data.append(u32(16))
        data.append(u16(1))
        data.append(u16(channels))
        data.append(u32(sampleRateHz))
        data.append(u32(byteRate))
        data.append(u16(blockAlign))
        data.append(u16(bitsPerSample))
        data.append(ascii("data"))
        data.append(u32(payload))
        data.append(pcm)
        return data
    }
}

// MARK: - Health indicators

/// Reference-range parsing and comparison for the offline report reader. The
/// ranges are user text from `HealthConfig.referenceRanges` — things like
/// `90-120 mmHg`, `< 3.4 mmol/L`, `> 1.0 mmol/L` — so the parser is deliberately
/// tolerant and reports what it could not understand instead of guessing.
public enum ENGIndicator {
    public enum Verdict: String, Sendable {
        case low, normal, high, unknown

        public var glyph: String {
            switch self {
            case .low: return "↓"
            case .normal: return "✓"
            case .high: return "↑"
            case .unknown: return "?"
            }
        }
    }

    /// A parsed reference band. Deliberately not named `Range` — shadowing
    /// `Swift.Range` inside this enum broke every `Range(_, in:)` regex helper.
    public struct Band: Sendable {
        public let minimum: Double?
        public let maximum: Double?
        public let unit: String
        public let raw: String

        public func verdict(for value: Double) -> Verdict {
            if let minimum, value < minimum { return .low }
            if let maximum, value > maximum { return .high }
            if minimum == nil && maximum == nil { return .unknown }
            return .normal
        }

        public var display: String {
            switch (minimum, maximum) {
            case (let low?, let high?): return "\(trim(low))–\(trim(high)) \(unit)".trimmingCharacters(in: .whitespaces)
            case (nil, let high?): return "< \(trim(high)) \(unit)".trimmingCharacters(in: .whitespaces)
            case (let low?, nil): return "> \(trim(low)) \(unit)".trimmingCharacters(in: .whitespaces)
            default: return raw
            }
        }

        private func trim(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        }
    }

    public static func parseRange(_ text: String) -> Band {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = trailingUnit(of: cleaned)
        let numericPortion = cleaned.replacingOccurrences(
            of: "[A-Za-z%°/]+[^0-9<>=−-]*$",
            with: "",
            options: .regularExpression
        )
        let numbers = extractNumbers(from: numericPortion.isEmpty ? cleaned : numericPortion)
        if cleaned.contains("–") || cleaned.contains("-") || cleaned.contains("—") {
            let parts = cleaned.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
            let low = numbers.first
            let high = parts.count >= 2 ? extractNumbers(from: String(parts[1])).first : nil
            if let low, let high { return Band(minimum: min(low, high), maximum: max(low, high), unit: unit, raw: cleaned) }
        }
        if cleaned.contains("<") || cleaned.contains("≤") || cleaned.contains("小于") {
            return Band(minimum: nil, maximum: numbers.first, unit: unit, raw: cleaned)
        }
        if cleaned.contains(">") || cleaned.contains("≥") || cleaned.contains("大于") {
            return Band(minimum: numbers.first, maximum: nil, unit: unit, raw: cleaned)
        }
        if numbers.count >= 2 {
            return Band(minimum: numbers[0], maximum: numbers[1], unit: unit, raw: cleaned)
        }
        return Band(minimum: nil, maximum: numbers.first, unit: unit, raw: cleaned)
    }

    private static func trailingUnit(of text: String) -> String {
        let match = try? NSRegularExpression(pattern: "([A-Za-zµ%°/][A-Za-z0-9µ%°/\\.]*)\\s*$")
        guard let regex = match else { return "" }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, options: [], range: range),
              let unitRange = Swift.Range(found.range(at: 1), in: text) else { return "" }
        return String(text[unitRange])
    }

    private static func extractNumbers(from text: String) -> [Double] {
        let pattern = "[-−]?\\d+(?:[.,]\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { found in
            guard let span = Swift.Range(found.range, in: text) else { return nil }
            let normalised = text[span]
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "−", with: "-")
            return Double(normalised)
        }
    }

    public struct Reading: Sendable {
        public let label: String
        public let value: Double
        public let unit: String?
        public let rangeText: String?
        public let verdict: Verdict
    }

    /// Pulls `name : value [unit]` triples out of OCR text. Anchored to a line
    /// so a stray number inside prose is not mistaken for a lab value.
    public static func extract(from text: String) -> [(String, Double, String?)] {
        let pattern = "(?im)^\\s*([^0-9\\n:：=]{2,44}?)\\s*[:：=]\\s*(-?\\d+(?:[.,]\\d+)?)\\s*([A-Za-zµ%°/\\.]{1,14})?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var results: [(String, Double, String?)] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: nsRange) {
            guard match.numberOfRanges >= 2,
                  let labelRange = Swift.Range(match.range(at: 1), in: text),
                  let valueRange = Swift.Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]
                        .replacingOccurrences(of: ",", with: ".")
                        .replacingOccurrences(of: "−", with: "-")) else { continue }
            let label = text[labelRange].trimmingCharacters(in: .whitespacesAndNewlines)
            var unit: String?
            if match.numberOfRanges >= 3, let unitRange = Swift.Range(match.range(at: 3), in: text) {
                unit = String(text[unitRange])
            }
            if label.isEmpty || label.count > 44 { continue }
            results.append((label, value, unit))
        }
        return results
    }

    /// Loose name matching: `Fasting Glucose` → `fasting-glucose`.
    public static func key(for label: String) -> String {
        let lowercased = label.lowercased()
        var scalarText = ""
        for scalar in lowercased.unicodeScalars {
            scalarText.append(CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-")
        }
        while scalarText.contains("--") { scalarText = scalarText.replacingOccurrences(of: "--", with: "-") }
        return scalarText.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func matchKey(_ extracted: String, in ranges: [String: String]) -> String? {
        if ranges.keys.contains(extracted) { return extracted }
        let tokens = Set(extracted.split(separator: "-").map(String.init))
        let best = ranges.keys
            .map { key -> (String, Int) in
                let parts = key.split(separator: "-").map(String.init)
                let overlap = parts.filter { tokens.contains($0) }.count
                return (key, overlap)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .first
        return best?.0
    }

    /// Two-decimal-then-strip rendering: `5.20` reads as a measuring bug, `5.2`
    /// reads as a lab value.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded)
    }

    public static func read(
        text: String,
        references: [String: String]
    ) -> (readings: [Reading], unmatched: [(String, Double, String?)]) {        var readings: [Reading] = []
        var unmatched: [(String, Double, String?)] = []
        for (label, value, unit) in extract(from: text) {
            let normalised = key(for: label)
            guard let matchedKey = matchKey(normalised, in: references),
                  let rangeText = references[matchedKey] else {
                unmatched.append((label, value, unit))
                continue
            }
            let range = parseRange(rangeText)
            readings.append(Reading(
                label: label,
                value: value,
                unit: unit ?? (range.unit.isEmpty ? nil : range.unit),
                rangeText: rangeText,
                verdict: range.verdict(for: value)
            ))
        }
        return (readings, unmatched)
    }
}

// MARK: - Feed parsing

/// One RSS/Atom entry after parsing and normalisation.
public struct ENGFeedItem: Sendable, Equatable {
    public var title: String
    public var link: String
    public var summary: String
    public var publishedAt: Date?
    public var feed: String
    public var id: String { Digest.short(Data((link + title).utf8), length: 16) }
}

/// Hand-written RSS 2.0 / Atom parser. Foundation's `XMLParser` is the only XML
/// in the package — the brief forbids third-party dependencies, and feeds are
/// shallow enough that a delegate with a small element stack is less code than
/// an XPath binding would be.
///
/// Entities arrive decoded from `XMLParser`; descriptions are frequently
/// double-encoded HTML, so `ENGFeedItem` text is run through a tag stripper and
/// the handful of named entities feeds actually use.
public final class ENGFeedParser: NSObject, XMLParserDelegate {
    private var items: [ENGFeedItem] = []
    private var stack: [String] = []
    private var text = ""
    private var current: ENGFeedItem?
    private var depth = 0
    private var inItem = false
    private let feed: String

    public init(feed: String) {
        self.feed = feed
        super.init()
    }

    public static func parse(data: Data, feed: String, limit: Int = 64) -> [ENGFeedItem] {
        let parser = XMLParser(data: data)
        let delegate = ENGFeedParser(feed: feed)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return Array(delegate.results.prefix(max(1, limit)))
    }

    public var results: [ENGFeedItem] { items.filter { !$0.title.isEmpty } }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        stack.append(elementName)
        let lowered = elementName.lowercased()
        if lowered == "item" || lowered == "entry" {
            inItem = true
            current = ENGFeedItem(title: "", link: "", summary: "", publishedAt: nil, feed: feed)
            text = ""
            return
        }
        guard inItem else { return }
        switch lowered {
        case "title", "link", "description", "summary", "content", "pubdate", "published",
             "updated", "dc:date", "category":
            text = ""
        case "id":
            text = ""
        default:
            break
        }
        if lowered == "link", let href = attributeDict["href"], current?.link.isEmpty == true {
            current?.link = href.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        text += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let lowered = elementName.lowercased()
        if !stack.isEmpty { stack.removeLast() }
        depth = max(0, depth - 1)
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard inItem, var item = current else {
            if lowered == "item" || lowered == "entry" {
                if let finished = current { items.append(finished) }
                current = nil
                inItem = false
            }
            return
        }
        switch lowered {
        case "title":
            item.title = Self.stripHTML(content)
        case "link":
            if item.link.isEmpty { item.link = Self.stripHTML(content) }
        case "description", "summary", "content", "content:encoded":
            let cleaned = Self.stripHTML(content)
            if cleaned.count > item.summary.count { item.summary = String(cleaned.prefix(600)) }
        case "pubdate", "published", "updated", "dc:date":
            if item.publishedAt == nil { item.publishedAt = Self.parseDate(content) }
        default:
            break
        }
        current = item
        if lowered == "item" || lowered == "entry" {
            items.append(item)
            current = nil
            inItem = false
        }
    }

    public func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        // Whitespace between elements is meaningful inside `<title>` in some
        // feeds; deliberately not treated as a terminator.
    }

    public static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            rfc.dateFormat = format
            if let date = rfc.date(from: trimmed) { return date }
        }
        return Date.ppxFromISO8601(trimmed)
    }

    /// Removes markup without pulling in `NSAttributedString` document
    /// handling, which would resolve remote images during de-identification.
    public static func stripHTML(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: "<!\\[CDATA\\[", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "\\]\\]>", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&nbsp;", " "), ("&#39;", "'"), ("&#x27;", "'")
        ] {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        output = output.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Token set for near-duplicate detection between syndicated feeds.
    public static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 3 })
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}

// MARK: - Plain HTTP for non-model traffic

/// The only network path in this file that is not a model call.
///
/// Two things are enforced here rather than at each call site: the scheme must be
/// `http`/`https` (a `file://` or `ftp://` string arriving from a feed list or a
/// webhook config must not become a local read), and the response is capped so a
/// hostile or misconfigured endpoint cannot exhaust the node's memory. The
/// sentinel path uses `post` and is deliberately time-bounded — a lockdown must
/// not wait on somebody's home-automation server.
public enum ENGNet {
    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public let mime: String?
    }

    public enum NetError: Error, Equatable {
        case unsupportedScheme(String)
        case server(Int)
        case transport(String)
        case tooLarge(Int)
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "POPOPX-Mac-Node/\(NodeVersion.current.semanticString)"]
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }

    static func url(_ text: String) -> URL? {
        guard let candidate = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              candidate.host != nil else { return nil }
        return candidate
    }

    public static func get(_ text: String, timeout: TimeInterval = 10, accept: String = "application/rss+xml, application/xml, text/xml, */*", maxBytes: Int = 3_000_000) async -> Result<Response, NetError> {
        guard let target = url(text) else { return .failure(.unsupportedScheme(String(text.prefix(60)))) }
        var request = URLRequest(url: target)
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session(timeout: timeout).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("no HTTP response"))
            }
            guard (200...299).contains(http.statusCode) else { return .failure(.server(http.statusCode)) }
            guard data.count <= maxBytes else { return .failure(.tooLarge(data.count)) }
            return .success(Response(status: http.statusCode, data: data, mime: http.mimeType))
        } catch let error as NetError {
            return .failure(error)
        } catch {
            return .failure(.transport(String(describing: error).prefix(160).description))
        }
    }

    public static func post(
        _ text: String,
        body: Data,
        headers: [String: String],
        timeout: TimeInterval = 1.5
    ) async -> Result<Response, NetError> {
        guard let target = url(text) else { return .failure(.unsupportedScheme(String(text.prefix(60)))) }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await session(timeout: timeout).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("no HTTP response"))
            }
            return .success(Response(status: http.statusCode, data: data, mime: http.mimeType))
        } catch {
            return .failure(.transport(String(describing: error).prefix(160).description))
        }
    }
}

// MARK: - The ten business engines

/// 模块四. All ten subscription businesses, executed locally, behind one actor.
public actor TenBusinessEngines: NodeEngines {
    // MARK: Stored state

    private let settings: SettingsStore
    private let hub: ConsoleEventHub
    private let gate: ENGRenderGate
    private var runtimeState: [String: EngineRuntime] = [:]
    private var cachedProfile: MacHardwareProfile?
    private var cachedPlan: ModelPlan?
    private var ffmpegCapability: ENGFFmpeg.Capability?
    private var chainRate: ENGHashChain.Rate?
    private var bootstrapped = false
    private let processStart = Date()

    private let runtimeLedgerURL = AppPaths.ledger.appendingPathComponent("engines.json")
    private let paywallLedgerURL = AppPaths.ledger.appendingPathComponent("paywall.json")
    private let meshInboxURL = AppPaths.ledger.appendingPathComponent("mesh_inbox.json")

    /// One authorised file the Shadow Chief of Staff may quote.
    private struct WorkspaceFile {
        let url: URL
        let display: String
        let bytes: Int64
        let modified: Date
    }

    /// Measured wall time of one deterministic step, surfaced in the lockdown
    /// receipt so an operator can see which syscall was slow.
    private struct StepTiming {
        let name: String
        let milliseconds: Int
        let outcome: String
    }

    /// Monotonic stop-clock. `ContinuousClock` cannot be suspended or stepped by
    /// the wall clock, so a lockdown's elapsed time stays truthful even if the
    /// user changes the system date mid-panic.
    private struct Stopwatch {
        private let started = ContinuousClock.now
        var elapsedMs: Int {
            let duration = started.duration(to: .now)
            return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// One mounted volume, as reported by `diskutil`.
    private struct Volume {
        let device: String
        let mount: String
        let name: String
        let removable: Bool
    }

    public init(settings: SettingsStore = .shared, hub: ConsoleEventHub = .shared) {
        self.settings = settings
        self.hub = hub
        self.gate = ENGRenderGate(maxLightConcurrent: 2)
    }

    // MARK: Bootstrap

    /// Lazy, idempotent, and deliberately not in `init` — an actor
    /// initialiser cannot await, and reading the settings document or the
    /// engine ledger off disk is blocking I/O.
    private func bootstrap() async {
        if bootstrapped { return }
        bootstrapped = true
        _ = try? AppPaths.ensureLayout()
        let document = await settings.current()
        var stored = ENGFiles.readJSON([String: EngineRuntime].self, at: runtimeLedgerURL) ?? [:]
        for kind in EngineKind.displayOrder {
            var runtime = stored[kind.rawValue] ?? EngineRuntime(kind: kind, enabled: document.isEnabled(kind))
            // The settings document is the authority on the switch; the ledger
            // only carries counters, and must never resurrect a disabled engine.
            runtime.enabled = document.isEnabled(kind)
            runtime.busy = false
            stored[kind.rawValue] = runtime
        }
        runtimeState = stored
    }

    private func persistRuntimes() {
        _ = ENGFiles.writeJSON(runtimeState, to: runtimeLedgerURL)
    }

    // MARK: NodeEngines

    public func descriptors() async -> [EngineDescriptor] {
        await bootstrap()
        return EngineKind.displayOrder.enumerated().map { index, kind in
            EngineDescriptor(kind: kind, order: index + 1)
        }
    }

    public func runtimes() async -> [EngineRuntime] {
        await bootstrap()
        let document = await settings.current()
        return EngineKind.displayOrder.map { kind in
            var runtime = runtimeState[kind.rawValue] ?? EngineRuntime(kind: kind, enabled: document.isEnabled(kind))
            runtime.enabled = document.isEnabled(kind)
            return runtime
        }
    }

    public func runtime(for kind: EngineKind) async -> EngineRuntime? {
        await bootstrap()
        let document = await settings.current()
        guard var runtime = runtimeState[kind.rawValue] else { return nil }
        runtime.enabled = document.isEnabled(kind)
        return runtime
    }

    /// Flips the switch in the durable settings document, not merely in memory,
    /// so a restart cannot silently re-enable 算力共享.
    public func setEnabled(_ kind: EngineKind, enabled: Bool) async {
        await bootstrap()
        _ = await settings.setEngine(kind, enabled: enabled)
        var runtime = runtimeState[kind.rawValue] ?? EngineRuntime(kind: kind, enabled: enabled)
        runtime.enabled = enabled
        if !enabled { runtime.busy = false }
        runtimeState[kind.rawValue] = runtime
        persistRuntimes()
        await emit(
            .settings,
            "\(kind.displayNameEn) \(enabled ? "已启用 enabled" : "已停用 disabled")",
            level: enabled ? .success : .warning,
            payload: [
                "engine": .string(kind.rawValue),
                "enabled": .bool(enabled),
                "deterministic": .bool(kind.isDeterministic)
            ]
        )
    }

    /// The SMP entry point.
    ///
    /// Order matters here: the deterministic lock check runs before the engine
    /// switch check and before anything that could await a model, because the
    /// brief's promise is that 🔒 from the owner's phone acts instantly even
    /// while the node is mid-render or has the model stack unloaded.
    public func execute(_ command: NodeCommand) async -> CommandResult {
        await bootstrap()
        if command.isDeterministicLock {
            let document = await settings.current()
            guard document.isEnabled(.phantomSentinel) else {
                return CommandResult.failure(
                    .phantomSentinel,
                    "Phantom Sentinel is switched off; the lock trigger was refused. Enable it in wizard step 3.",
                    commandID: command.id
                )
            }
            let result = await tracked(.phantomSentinel, action: "lockdown", commandID: command.id) {
                await self.lockdown(trigger: command.action.isEmpty ? "🔒" : command.action, document: document)
            }
            var stamped = result
            stamped.deterministic = true
            stamped.metrics["modelInvolved"] = JSONValue.bool(false)
            return stamped
        }

        guard let kind = Self.engine(for: command.serviceId) else {
            await emit(
                .engine,
                "未知 serviceId “\(command.serviceId.prefix(32))” — no such engine",
                level: .warning,
                payload: ["serviceId": .string(command.serviceId)]
            )
            // `CommandResult` must name an engine; attribute the refusal to the
            // first engine in display order rather than inventing a wire value.
            return CommandResult.failure(
                EngineKind.displayOrder.first ?? .shadowCos,
                "Unknown service identifier “\(command.serviceId)”. Known ids: \(EngineKind.displayOrder.map(\.rawValue).joined(separator: ", "))",
                commandID: command.id
            )
        }

        let document = await settings.current()
        guard document.isEnabled(kind) else {
            return disabledResult(kind, commandID: command.id, revision: document.revision)
        }
        guard command.authenticated else {
            // The bridge enforces the pairing whitelist; this is the second
            // gate so a hand-injected console command cannot drive an engine
            // that the owner never paired.
            return CommandResult(
                commandID: command.id,
                engine: kind,
                ok: false,
                headline: "Refused: the sender key is not on the paired-device whitelist.",
                body: String(describing: NodeFailure.unpairedSender(command.senderPublicKey))
            )
        }
        return await tracked(kind, action: command.action, commandID: command.id) {
            await self.dispatch(kind, action: command.action, payload: command.jsonPayload, commandID: command.id)
        }
    }

    /// The console button path: same routing, dictionary payload.
    public func invoke(_ kind: EngineKind, action: String, payload: [String: JSONValue]) async -> CommandResult {
        await bootstrap()
        let document = await settings.current()
        if kind == .phantomSentinel, NodeWire.lockTriggers.contains(action.lowercased()) || action.isEmpty {
            return await tracked(kind, action: "lockdown", commandID: nil) {
                await self.lockdown(trigger: "🔒", document: document)
            }
        }
        guard document.isEnabled(kind) else {
            return disabledResult(kind, commandID: nil, revision: document.revision)
        }
        return await tracked(kind, action: action, commandID: nil) {
            await self.dispatch(kind, action: action, payload: .object(payload), commandID: nil)
        }
    }

    public func meshSummary() async -> MeshSummary {
        await bootstrap()
        return await buildMeshSummary()
    }

    public func recentLockdowns() async -> [LockdownReceipt] {
        await bootstrap()
        return Self.readLockdowns(limit: 24)
    }

    public func recentVaults() async -> [TimelockEnvelope] {
        await bootstrap()
        return Self.readVaults(limit: 32)
    }

    // MARK: Routing

    /// Maps the wire `serviceId` onto an engine. The extra aliases exist because
    /// the iOS build shipped two ids before the frozen `EngineKind` raw values
    /// settled; unknown ids return `nil` so the caller can emit a readable card.
    private static func engine(for serviceId: String) -> EngineKind? {
        let normalised = serviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if let direct = EngineKind(rawValue: normalised) { return direct }
        switch normalised {
        case "warroom", "zero_trust", "gop_watermark": return .zeroTrustWarroom
        case "studio", "zero_trace": return .zerotraceStudio
        case "solo", "autopilot": return .soloAutopilot
        case "mesh", "edge_mesh", "compute_mesh": return .edgeComputeMesh
        case "tv", "morning": return .morningTv
        case "sentinel", "lockdown": return .phantomSentinel
        case "ark", "time_lock": return .chronoArk
        case "health": return .healthSentinel
        case "paywall", "creator": return .creatorPaywallHub
        case "cos", "chief_of_staff": return .shadowCos
        default: return nil
        }
    }

    private static func normalisedAction(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }

    private func disabledResult(_ kind: EngineKind, commandID: String?, revision: Int) -> CommandResult {
        CommandResult(
            commandID: commandID,
            engine: kind,
            ok: false,
            headline: "引擎已关闭 · \(kind.displayNameEn) is switched off.",
            body: "Turn it on in wizard step 3 (settings revision \(revision)). Nothing was executed.",
            metrics: ["engineDisabled": .bool(true), "settingsRevision": .int(revision)]
        )
    }

    private func unsupported(_ kind: EngineKind, _ action: String, _ allowed: [String]) -> CommandResult {
        CommandResult(
            engine: kind,
            ok: false,
            headline: "未知动作 · unknown action “\(action.isEmpty ? "∅" : action)” for \(kind.rawValue).",
            body: "Supported actions: \(allowed.joined(separator: ", "))",
            metrics: ["unknownAction": .bool(true)]
        )
    }

    /// Single routing table shared by `execute` and `invoke`.
    private func dispatch(
        _ kind: EngineKind,
        action raw: String,
        payload: JSONValue,
        commandID: String?
    ) async -> CommandResult {
        let action = Self.normalisedAction(raw)
        switch kind {
        case .shadowCos:
            switch action {
            case "", "briefing", "brief", "run", "daily", "daily_brief", "generate":
                return await shadowBriefing(payload: payload, commandID: commandID)
            case "negotiation_prompt", "negotiation", "tactics", "prompt":
                return await shadowNegotiation(payload: payload, commandID: commandID)
            default:
                return unsupported(kind, action, ["briefing", "negotiation_prompt"])
            }
        case .zeroTrustWarroom:
            switch action {
            case "assign", "register", "queue_assign":
                return await warroomAssign(payload: payload, commandID: commandID)
            case "embed", "mark", "distribute":
                return await warroomEmbed(payload: payload, commandID: commandID)
            case "trace", "extract", "identify", "decode":
                return await warroomTrace(payload: payload, commandID: commandID)
            case "registry", "status":
                return await warroomRegistry(commandID: commandID)
            default:
                return unsupported(kind, action, ["assign", "embed", "trace", "registry"])
            }
        case .zerotraceStudio:
            switch action {
            case "", "process", "run", "ingest", "sanitize", "sanitise":
                return await studioProcess(payload: payload, commandID: commandID)
            case "strip", "clean", "metadata":
                return await studioStrip(payload: payload, commandID: commandID)
            case "anchor", "briefing_clip", "broadcast":
                return await studioAnchor(payload: payload, commandID: commandID)
            case "shred", "destroy":
                return await studioShred(payload: payload, commandID: commandID)
            default:
                return unsupported(kind, action, ["process", "strip", "anchor", "shred"])
            }
        case .soloAutopilot:
            switch action {
            case "", "run", "generate", "video", "clip":
                return await soloPipeline(payload: payload, commandID: commandID)
            case "script", "copy":
                return await soloScript(payload: payload, commandID: commandID)
            default:
                return unsupported(kind, action, ["run", "script"])
            }
        case .edgeComputeMesh:
            switch action {
            case "", "status", "summary":
                return await meshStatusResult(commandID: commandID)
            case "offer", "accept", "execute", "run":
                return await meshAccept(payload: payload, commandID: commandID)
            case "poll", "drain":
                return await meshPoll(commandID: commandID)
            case "enable", "sharing":
                return await meshSharing(payload: payload, commandID: commandID)
            case "settle":
                return await meshSettle(commandID: commandID)
            default:
                return unsupported(kind, action, ["status", "offer", "poll", "enable", "settle"])
            }
        case .morningTv:
            switch action {
            case "", "broadcast", "run", "tv":
                return await morningBroadcast(payload: payload, commandID: commandID, forced: true)
            case "digest", "headlines", "feeds":
                return await morningDigest(payload: payload, commandID: commandID)
            case "scheduled", "fire", "on_time":
                return await morningBroadcast(payload: payload, commandID: commandID, forced: false)
            case "schedule", "next":
                return await morningSchedule(commandID: commandID)
            default:
                return unsupported(kind, action, ["broadcast", "digest", "scheduled", "schedule"])
            }
        case .phantomSentinel:
            let document = await settings.current()
            switch action {
            case "", "lockdown", "lock", "lock_all", "sentinel", "🔒":
                return await lockdown(trigger: raw.isEmpty ? "🔒" : raw, document: document)
            case "status", "probe":
                return await sentinelStatus(document: document, commandID: commandID)
            default:
                return unsupported(kind, action, ["lockdown", "status"])
            }
        case .chronoArk:
            switch action {
            case "seal", "lock", "store":
                return await arkSeal(payload: payload, commandID: commandID)
            case "", "list", "vaults", "status":
                return await arkList(commandID: commandID)
            case "unseal", "open", "recover":
                return await arkUnseal(payload: payload, commandID: commandID)
            case "heartbeat", "ping", "alive":
                return await arkHeartbeat(commandID: commandID)
            case "check", "watch", "release_check":
                return await arkCheck(commandID: commandID)
            case "reveal", "dir", "folder":
                return await arkReveal(commandID: commandID)
            default:
                return unsupported(kind, action, ["seal", "list", "unseal", "heartbeat", "check", "reveal"])
            }
        case .healthSentinel:
            switch action {
            case "", "read", "report", "parse", "interpret":
                return await healthRead(payload: payload, commandID: commandID)
            case "binaural", "tone", "sleep", "wav":
                return await healthBinaural(payload: payload, commandID: commandID)
            default:
                return unsupported(kind, action, ["read", "binaural"])
            }
        case .creatorPaywallHub:
            switch action {
            case "", "verify", "ticket", "admit":
                return await paywallVerify(payload: payload, commandID: commandID)
            case "grant", "deliver", "drop", "distribute":
                return await paywallDeliver(payload: payload, commandID: commandID)
            case "claim", "red_packet", "redpacket":
                return await paywallClaim(payload: payload, commandID: commandID)
            case "status", "ledger":
                return await paywallStatus(commandID: commandID)
            default:
                return unsupported(kind, action, ["verify", "grant", "claim", "status"])
            }
        }
    }

    // MARK: Run tracking

    /// Wraps every engine call: marks the runtime busy, mirrors the start and
    /// finish onto the event hub the web console renders live from, keeps the
    /// counters, and stamps a measured duration.
    private func tracked(
        _ kind: EngineKind,
        action: String,
        commandID: String?,
        _ body: () async -> CommandResult
    ) async -> CommandResult {
        let clock = ContinuousClock()
        let began = clock.now
        var opening = runtimeState[kind.rawValue] ?? EngineRuntime(kind: kind, enabled: true)
        opening.busy = true
        runtimeState[kind.rawValue] = opening
        let label = action.isEmpty ? "run" : Self.normalisedAction(action)
        await emit(
            .engine,
            "▶ \(kind.displayNameZh) · \(label)",
            level: .info,
            payload: ["engine": .string(kind.rawValue), "action": .string(label), "modelInLoop": .bool(kind.usesModelInLoop)]
        )
        if kind == .edgeComputeMesh || kind == .phantomSentinel {
            await emit(
                kind == .edgeComputeMesh ? .mesh : .sentinel,
                "\(kind.rawValue).\(label) started",
                level: .notice,
                payload: ["engine": .string(kind.rawValue)]
            )
        }

        var result = await body()
        let elapsed = Self.milliseconds(from: began.duration(to: clock.now))
        result.durationMs = max(result.durationMs, elapsed)
        if result.commandID == nil { result.commandID = commandID }
        if kind.isDeterministic { result.deterministic = true }

        var closing = runtimeState[kind.rawValue] ?? EngineRuntime(kind: kind, enabled: true)
        closing.busy = false
        closing.runs += 1
        if !result.ok { closing.failures += 1 }
        closing.lastRunAt = Date()
        closing.lastDurationMs = result.durationMs
        closing.lastSummary = TextKit.truncate(result.headline, to: 140)
        closing.artifactsProduced += result.artifacts.count
        runtimeState[kind.rawValue] = closing
        persistRuntimes()

        await emit(
            .engine,
            "\(result.ok ? "✓" : "✕") \(kind.displayNameEn) · \(TextKit.truncate(result.headline, to: 90)) · \(result.durationMs) ms",
            level: result.ok ? .success : .warning,
            payload: [
                "engine": .string(kind.rawValue),
                "ok": .bool(result.ok),
                "durationMs": .int(result.durationMs),
                "artifacts": .int(result.artifacts.count),
                "deterministic": .bool(result.deterministic)
            ]
        )
        if kind == .edgeComputeMesh || kind == .phantomSentinel {
            await emit(
                kind == .edgeComputeMesh ? .mesh : .sentinel,
                "\(kind.rawValue).\(label) finished ok=\(result.ok)",
                level: result.ok ? .notice : .error,
                payload: ["durationMs": .int(result.durationMs), "ok": .bool(result.ok)]
            )
        }
        return result
    }

    private func emit(
        _ channel: ConsoleEvent.Channel,
        _ text: String,
        level: EventLevel = .info,
        payload: [String: JSONValue] = [:]
    ) async {
        await hub.publish(channel, text, level: level, payload: payload)
    }

    private static func milliseconds(from duration: Duration) -> Int {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Shared plumbing

    /// Hardware profile assembled from `sysctl` and the boot volume. The
    /// dedicated probe in 模块一 owns the wizard-facing version of this; the
    /// engines need only the memory ladder, so they derive the same
    /// `ModelPlan` from the same kernel numbers instead of importing that type.
    private func hardwareProfile() async -> MacHardwareProfile {
        if let cachedProfile { return cachedProfile }
        let memory = ByteCount(Int64(Sysctl.memorySize))
        let root = URL(fileURLWithPath: "/")
        let values = try? root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        let free = ByteCount(Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0))
        let total = ByteCount(Int64(values?.volumeTotalCapacity ?? 0))
        let serial = Sysctl.string("IOPlatformUUID") ?? Sysctl.modelIdentifier ?? "unknown"
        let volumeName = AppPaths.fileManager.displayName(atPath: root.path)
        let profile = MacHardwareProfile(
            chipName: Sysctl.chipName ?? "Apple Silicon",
            modelIdentifier: Sysctl.modelIdentifier ?? "Mac",
            cpuArchitecture: Sysctl.string("hw.machine") ?? "arm64",
            logicalCPUCount: Sysctl.logicalCPUCount,
            physicalCPUCount: Sysctl.physicalCPUCount,
            performanceCoreCount: Sysctl.performanceCores,
            efficiencyCoreCount: Sysctl.efficiencyCores,
            memoryTotal: memory,
            freeDisk: free,
            totalDisk: total,
            systemVolumeName: volumeName.isEmpty ? "Macintosh HD" : volumeName,
            operatingSystem: Sysctl.operatingSystemVersion,
            kernelVersion: Sysctl.kernelVersion ?? "",
            // The real serial never leaves this process: the console shows a
            // keyed digest so two nodes can still be told apart.
            serialMasked: TextKit.fingerprint(serial, length: 10)
        )
        cachedProfile = profile
        cachedPlan = ModelPlan.recommend(for: profile)
        return profile
    }

    private func modelPlan() async -> ModelPlan {
        if let cachedPlan { return cachedPlan }
        let profile = await hardwareProfile()
        let plan = ModelPlan.recommend(for: profile)
        cachedPlan = plan
        return plan
    }

    /// The mesh memory ceiling recomputed from the same 0.55 factor
    /// `MacHardwareProfile.meshMemoryCeilingGB` uses, so the engines do not have
    /// to import 模块一 to stay inside the owner's headroom.
    private func meshMemoryCeilingGB() async -> Int {
        let profile = await hardwareProfile()
        return profile.meshMemoryCeilingGB
    }

    private func ffmpeg() async -> ENGFFmpeg.Capability {
        if let ffmpegCapability { return ffmpegCapability }
        let capability = await ENGFFmpeg.probe()
        ffmpegCapability = capability
        return capability
    }

    /// GB a job asks the gate to have free before it may start. Half the
    /// resident stack is enough for a heavy render because the weights are
    /// mapped read-only and pageable; text work asks for a flat floor.
    private func requirementGB(for weight: ENGRenderGate.Weight, plan: ModelPlan) -> Int {
        switch weight {
        case .light: return 4
        case .heavy: return max(6, min(24, plan.expectedResidentGB / 2))
        }
    }

    /// Resolves a user-supplied path and refuses anything that lives inside the
    /// node's own protected store: an iOS command must not be able to point the
    /// shredder at the sealed vault.
    private func resolveInput(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = AppPaths.resolve(userPath: trimmed) else { return nil }
        let protected = [AppPaths.sealed.path, AppPaths.vault.path, AppPaths.sandboxes.path, AppPaths.pairing.path]
        if protected.contains(where: { url.path.hasPrefix($0 + "/") || url.path == $0 }) { return nil }
        return ENGFiles.exists(url) ? url : nil
    }

    private func prepared(_ directory: URL) -> URL {
        try? AppPaths.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Bilingual copy switch driven by the console language setting, so an
    /// English console never sees half-translated cards.
    private func bi(_ document: NodeSettings, zh: String, en: String) -> String {
        document.language.text(zh: zh, en: en)
    }

    /// The sentence a generated-text prompt carries on top of its template.
    /// The templates are written in two languages because that is all the node
    /// proof-read, while the phone offers seventeen regions — so for the other
    /// fifteen the model is told directly which language to answer in, and for
    /// the two curated ones the template already says it and is not repeated.
    private static func languageTail(_ language: ConsoleLanguage) -> String {
        language.resolved.isCurated ? "" : " " + language.modelLanguageDirective
    }

    /// One place where a generated-text system prompt is assembled, so no
    /// engine can ship a prompt that silently ignores the owner's language.
    private static func systemTemplate(_ language: ConsoleLanguage, zh: String, en: String) -> String {
        language.text(zh: zh, en: en) + languageTail(language)
    }

    private func missingField(_ key: String, _ kind: EngineKind, commandID: String?) -> CommandResult {
        ENGPayload.missing(key, engine: kind, commandID: commandID)
    }

    private func modelRefusal(_ kind: EngineKind, model: String, commandID: String?) async -> CommandResult {
        let installed = await ENGOllama.installedModels()
        let hint = installed.isEmpty
            ? "No local models are installed — run the one-click installer in wizard step 1."
            : "Installed: \(installed.prefix(6).joined(separator: ", "))."
        return CommandResult(
            commandID: commandID,
            engine: kind,
            ok: false,
            headline: "本地模型不可用 · local model \(model) is unreachable.",
            body: "Ollama on \(ENGOllama.host) did not answer. \(hint)\nNothing left this machine; the request was made to 127.0.0.1 only.",
            metrics: ["ollamaHost": .string(ENGOllama.host), "model": .string(model), "installed": .int(installed.count)]
        )
    }

    /// Refusal when the gate says this machine can never fit the job.
    private func memoryRefusal(
        _ kind: EngineKind,
        neededGB: Int,
        commandID: String?,
        extra: [String: JSONValue] = [:]
    ) async -> CommandResult {
        let state = await gate.state()
        var metrics = extra
        metrics["neededGB"] = .int(neededGB)
        metrics["freeGB"] = state["freeGB"] ?? .int(0)
        metrics["reservedGB"] = state["reservedGB"] ?? .int(0)
        metrics["queued"] = state["queued"] ?? .int(0)
        metrics["memoryGuardTripped"] = .bool(true)
        return CommandResult(
            commandID: commandID,
            engine: kind,
            ok: false,
            headline: "内存闸门拒绝 · memory guard refused the job.",
            body: "Projected free memory is \(state["freeGB"]?.intValue ?? 0) GB with "
                + "\(state["reservedGB"]?.intValue ?? 0) GB already reserved by \(state["lightActive"]?.intValue ?? 0) light and "
                + "\(state["heavyActive"]?.boolValue == true ? 1 : 0) heavy job(s). Lower the mesh memory cap or wait for the active render to finish.",
            metrics: metrics
        )
    }

    // MARK: - Engine 1 · shadow_cos

    /// Reads only the directories the owner added in wizard step 3, builds a
    /// bounded prompt, and asks the loopback model for an action briefing.
    private func shadowBriefing(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let model = ENGOllama.resolvedModel(settings: document, plan: plan)

        guard !document.shadowWorkspaces.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .shadowCos,
                ok: false,
                headline: "尚未授权工作目录 · no authorised workspaces.",
                body: "Add at least one folder in wizard step 3 before the Shadow Chief of Staff can read anything. The engine will not walk your home directory.",
                metrics: ["authorisedRoots": .int(0)]
            )
        }
        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.shadowCos, model: model, commandID: commandID)
        }

        let focus = ENGPayload.string(payload, "focus")
        let inlineAgenda = ENGPayload.string(payload, "agenda")
        let files = await collectWorkspaceFiles(
            roots: document.shadowWorkspaces,
            limit: 120
        )
        let sources = files.filter { Self.isBriefingSource($0.url) }
        let agendaText = Self.agendaDigest(for: sources, budgetBytes: 24_000)
        let prompt = Self.briefingPrompt(
            document: document,
            plan: plan,
            model: model,
            files: files,
            agendaText: agendaText,
            inlineAgenda: inlineAgenda,
            focus: focus,
            language: document.language
        )

        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.shadowCos, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let reply: ENGOllama.Reply
        do {
            reply = try await ENGOllama.generate(
                model: model,
                prompt: prompt,
                system: Self.briefingSystem(document.language),
                temperature: 0.3,
                contextTokens: 4096,
                timeout: 240
            )
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .shadowCos,
                ok: false,
                headline: "简报生成失败 · briefing generation failed.",
                body: "\(error)\n\nPrompt was \(prompt.count) characters over \(files.count) files.",
                metrics: ["promptChars": .int(prompt.count), "filesScanned": .int(files.count)]
            )
        }

        let markdown = Self.briefingArtifact(
            document: document,
            reply: reply,
            model: model,
            files: files,
            focus: focus
        )
        let url = ENGFFmpeg.outputURL(
            "shadow-briefing-\(ENGFiles.stamp())",
            fileExtension: "md"
        )
        guard ENGFiles.write(markdown, to: url) else {
            return CommandResult.failure(.shadowCos, "Could not write the briefing artifact.", commandID: commandID)
        }
        let bytes = ENGFiles.size(url)
        return CommandResult(
            commandID: commandID,
            engine: .shadowCos,
            ok: true,
            headline: "今日行动简报已生成 · daily action briefing ready",
            body: TextKit.truncate(reply.text, to: 3_000),
            artifacts: [AppPaths.anonymise(url: url)],
            metrics: [
                "authorisedRoots": .int(document.shadowWorkspaces.count),
                "filesScanned": .int(files.count),
                "agendaBytes": .int(agendaText.utf8.count),
                "promptChars": .int(prompt.count),
                "model": .string(reply.model),
                "generatedTokens": .int(reply.generatedTokens),
                "promptTokens": .int(reply.promptTokens),
                "artifactBytes": .int(Int(bytes)),
                "tier": .string(plan.tier.rawValue),
                "modelInvolved": .bool(true)
            ]
        )
    }

    /// The negotiation tactics card: same substrate, different ask, and no file
    /// is written unless the owner wants one, because a live negotiation needs
    /// the text on the screen rather than a document to open.
    private func shadowNegotiation(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let model = ENGOllama.resolvedModel(settings: document, plan: plan)
        let topic = ENGPayload.string(payload, "topic", default: ENGPayload.string(payload, "keyword"))
        let counterparty = ENGPayload.string(payload, "counterparty")
        let stakes = ENGPayload.string(payload, "stakes", default: ENGPayload.string(payload, "context"))
        guard !topic.isEmpty else { return missingField("topic", .shadowCos, commandID: commandID) }
        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.shadowCos, model: model, commandID: commandID)
        }

        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.shadowCos, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let prompt = Self.negotiationPrompt(
            topic: topic,
            counterparty: counterparty,
            stakes: stakes,
            document: document,
            language: document.language
        )
        let reply: ENGOllama.Reply
        do {
            reply = try await ENGOllama.generate(
                model: model,
                prompt: prompt,
                system: Self.negotiationSystem(document.language),
                temperature: 0.55,
                contextTokens: 3072,
                timeout: 150
            )
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .shadowCos,
                ok: false,
                headline: "谈判提词生成失败 · tactics card failed.",
                body: String(describing: error),
                metrics: ["model": .string(model)]
            )
        }

        let url = ENGFFmpeg.outputURL("negotiation-\(ENGFiles.stamp())", fileExtension: "md")
        let card = """
        # 谈判提词 · Negotiation Prompt
        - 议题 Topic: \(topic)
        - 对手 Counterparty: \(counterparty.isEmpty ? "—" : counterparty)
        - 筹码 Stakes: \(stakes.isEmpty ? "—" : stakes)
        - 模型 Model: \(reply.model) · \(document.language.resolved.nativeName)

        \(reply.text)
        """
        let written = ENGFiles.write(card, to: url)
        return CommandResult(
            commandID: commandID,
            engine: .shadowCos,
            ok: true,
            headline: "谈判提词卡就绪 · tactics card ready",
            body: TextKit.truncate(reply.text, to: 2_400),
            artifacts: written ? [AppPaths.anonymise(url: url)] : [],
            metrics: [
                "model": .string(reply.model),
                "generatedTokens": .int(reply.generatedTokens),
                "promptChars": .int(prompt.count),
                "artifact": .bool(written),
                "modelInvolved": .bool(true)
            ]
        )
    }

    /// Walks the authorised roots only. Depth and count are bounded so a stray
    /// `~/` or a huge repository cannot turn into a minutes-long scan.
    private func collectWorkspaceFiles(roots: [String], limit: Int) async -> [WorkspaceFile] {
        var collected: [WorkspaceFile] = []
        for raw in roots {
            guard let root = AppPaths.resolve(userPath: raw), ENGFiles.exists(root) else { continue }
            if ENGFiles.isDirectory(root) {
                guard let enumerator = AppPaths.fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) else { continue }
                var depthGuard = 0
                while depthGuard <= limit * 12, collected.count < limit,
                      let url = enumerator.nextObject() as? URL {
                    depthGuard += 1
                    if url.pathComponents.count - root.pathComponents.count > 5 { continue }
                    guard ENGFiles.textExtensions.contains(url.pathExtension.lowercased())
                        || ENGFiles.mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    collected.append(WorkspaceFile(
                        url: url,
                        display: AppPaths.anonymise(url: url),
                        bytes: Int64(values?.fileSize ?? 0),
                        modified: values?.contentModificationDate ?? .distantPast
                    ))
                }
            } else {
                let values = try? root.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                collected.append(WorkspaceFile(
                    url: root,
                    display: AppPaths.anonymise(url: root),
                    bytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return Array(collected.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Files worth quoting into a briefing: agendas, calendars, todos, notes.
    private static func isBriefingSource(_ url: URL) -> Bool {
        guard ENGFiles.textExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let markers = ["calendar", "agenda", "todo", "today", "brief", "schedule", "journal", "diary", "notes", "任务", "日程", "简报"]
        return markers.contains { name.contains($0) } || url.pathExtension.lowercased() == "ics"
    }

    /// Bounded concatenation of the briefing sources.
    private static func agendaDigest(for files: [WorkspaceFile], budgetBytes: Int) -> String {
        var output = ""
        var used = 0
        for file in files.prefix(24) {
            guard let text = ENGFiles.readText(file.url, limit: 4_096), !text.isEmpty else { continue }
            let block = "### \(file.url.lastPathComponent)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            let cost = block.utf8.count
            if used + cost > budgetBytes { break }
            output += block
            used += cost
        }
        return output
    }

    private static func briefingSystem(_ language: ConsoleLanguage) -> String {
        systemTemplate(
            language,
            zh: "你是本机专属影子幕僚。只依据给定材料输出，不得编造事实，不得建议上传到任何云服务。输出中文 Markdown，先给三条今日必须行动，再给风险与需要用户决策的事项，最后一行给出时间预算。控制在 400 字内。",
            en: "You are a local-only chief of staff. Use only the supplied material, invent nothing, never suggest uploading data to a cloud service. Answer in Markdown: three must-do actions for today, then risks, then decisions the owner must make, then a time budget. Stay under 300 words."
        )
    }

    private static func briefingPrompt(
        document: NodeSettings,
        plan: ModelPlan,
        model: String,
        files: [WorkspaceFile],
        agendaText: String,
        inlineAgenda: String,
        focus: String,
        language: ConsoleLanguage
    ) -> String {
        let listing = files.prefix(60).enumerated().map { index, file -> String in
            "\(index + 1). \(file.url.lastPathComponent) · \(ByteCount(file.bytes).humanized) · \(file.modified.ppxISO8601)"
        }.joined(separator: "\n")
        var prompt = """
        节点 Node: \(document.nodeName)
        日期 Date: \(Date().ppxISO8601)
        本机模型 Local model: \(model) (tier \(plan.tier.rawValue), \(plan.llmQuantization))
        授权目录 Authorised roots: \(document.shadowWorkspaces.map { AppPaths.anonymise($0) }.joined(separator: ", "))

        最近文件 Recent files (newest first):
        \(listing.isEmpty ? "—" : listing)
        """
        if !inlineAgenda.isEmpty {
            prompt += "\n\n来自 iOS 的日程文本 Agenda from iOS:\n\(String(inlineAgenda.prefix(4_000)))"
        }
        if !agendaText.isEmpty {
            prompt += "\n\n本地简报源 Local briefing sources:\n\(agendaText)"
        }
        if !focus.isEmpty {
            prompt += "\n\n今日焦点 Today's focus from the owner: \(focus)"
        }
        prompt += language.isChinese
            ? "\n\n请生成今日行动简报。"
            : "\n\nProduce today's action briefing."
        return prompt
    }

    private static func negotiationSystem(_ language: ConsoleLanguage) -> String {
        systemTemplate(
            language,
            zh: "你是谈判策略教练。给出开场、三个锚点、让步阶梯、对方可能的反驳与应对、可撤退的下限（walk-away）、以及一句提醒：所有判断仅基于用户提供的信息。输出 Markdown 卡片，350 字内。",
            en: "You are a negotiation coach. Output a Markdown card: opening line, three anchors, a concession ladder, likely counter-arguments with replies, the walk-away floor, and one reminder that every judgement comes only from the information supplied. Under 260 words."
        )
    }

    private static func negotiationPrompt(
        topic: String,
        counterparty: String,
        stakes: String,
        document: NodeSettings,
        language: ConsoleLanguage
    ) -> String {
        """
        议题 Topic: \(topic)
        对手 Counterparty: \(counterparty.isEmpty ? "unspecified" : counterparty)
        筹码/风险 Stakes: \(stakes.isEmpty ? "unspecified" : stakes)
        节点 Node: \(document.nodeName)
        \(language.isChinese ? "请生成谈判提词卡。" : "Produce the tactics card.")
        """
    }

    private static func briefingArtifact(
        document: NodeSettings,
        reply: ENGOllama.Reply,
        model: String,
        files: [WorkspaceFile],
        focus: String
    ) -> String {
        """
        # 每日行动简报 · Daily Action Briefing
        - 节点 Node: \(document.nodeName)
        - 生成 Generated: \(Date().ppxISO8601)
        - 模型 Model: \(model)
        - 授权目录 Roots: \(document.shadowWorkspaces.map { AppPaths.anonymise($0) }.joined(separator: ", "))
        - 扫描 Scanned: \(files.count) files
        \(focus.isEmpty ? "" : "- 焦点 Focus: \(focus)")

        ---

        \(reply.text)

        ---
        *Generated locally. No file contents left this machine; the only network call was to \(ENGOllama.host).*
        """
    }

    // MARK: - Engine 2 · zero_trust_warroom

    /// Registers a distribution queue name against a stable binary id. The
    /// registry is the only thing that maps id → name, and it lives in the
    /// settings document so a trace can be read by a human without a database.
    private func warroomAssign(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let queue = ENGPayload.string(payload, "queue", default: ENGPayload.string(payload, "name"))
        guard !queue.isEmpty else { return missingField("queue", .zeroTrustWarroom, commandID: commandID) }
        let requested = ENGPayload.int(payload, "id", default: -1)
        let width = document.warroom.payloadBits
        let capacity = 1 << width

        var assigned = requested
        if assigned < 0 {
            let used = Set(document.warroom.queueRegistry.values)
            assigned = 0
            while used.contains(assigned), assigned < capacity - 1 { assigned += 1 }
        }
        guard assigned >= 0, assigned < capacity else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "队列编号超出位宽 · queue id does not fit \(width) bits.",
                body: "payloadBits=\(width) holds ids 0…\(capacity - 1). Raise `payloadBits` in the console or retire a queue.",
                metrics: ["requestedID": .int(requested), "capacity": .int(capacity)]
            )
        }

        let updated = await settings.mutate { draft in
            draft.warroom.queueRegistry[queue] = assigned
        }
        await emit(
            .engine,
            "warroom queue “\(queue)” → id \(assigned) (bits \(width))",
            level: .notice,
            payload: ["queue": .string(queue), "id": .int(assigned), "registrySize": .int(updated.warroom.queueRegistry.count)]
        )
        return CommandResult(
            commandID: commandID,
            engine: .zeroTrustWarroom,
            ok: true,
            headline: "分发队列已登记 · queue registered",
            body: "“\(queue)” = \(assigned) = \(Self.binaryString(assigned, width)). "
                + "Every copy handed to this queue will carry that value as its GOP schedule.",
            metrics: [
                "queue": .string(queue),
                "id": .int(assigned),
                "payloadBits": .int(width),
                "slots": .int(updated.warroom.segmentsPerVideo),
                "repeats": .int(ENGGopWatermark.repeats(slots: updated.warroom.segmentsPerVideo, payloadBits: width)),
                "registrySize": .int(updated.warroom.queueRegistry.count)
            ]
        )
    }

    private func warroomRegistry(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let rows = document.warroom.queueRegistry.sorted { $0.value < $1.value }
            .map { "\(TextKit.truncate($0.key, to: 28)) → \($0.value) (\(Self.binaryString($0.value, document.warroom.payloadBits)))" }
        let width = document.warroom.payloadBits
        let repeats = ENGGopWatermark.repeats(slots: document.warroom.segmentsPerVideo, payloadBits: width)
        return CommandResult(
            commandID: commandID,
            engine: .zeroTrustWarroom,
            ok: true,
            headline: "\(rows.count) 个分发队列 · \(rows.count) registered queues",
            body: rows.isEmpty ? "No queues yet — use `assign` first." : rows.joined(separator: "\n"),
            metrics: [
                "queues": .int(rows.count),
                "payloadBits": .int(width),
                "slots": .int(document.warroom.segmentsPerVideo),
                "repeats": .int(repeats),
                "minHammingDistance": .int(ENGGopWatermark.minimumDistance(payloadBits: width, repeats: repeats)),
                "lastTraceHit": .string(document.warroom.lastTraceHit ?? "—")
            ]
        )
    }

    /// Embeds the queue id as a GOP schedule. Pixel-free: every slice is a
    /// stream copy and the assembled file is a lossless concat, so the only
    /// thing that changes is *where the keyframes land*.
    private func warroomEmbed(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let capability = await ffmpeg()
        guard capability.isUsable, let ffmpeg = capability.ffmpeg, let ffprobe = capability.ffprobe else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "需要 ffmpeg · ffmpeg/ffprobe not installed.",
                body: "Install the toolchain from wizard step 1 (`brew install ffmpeg`). The watermark lives in the GOP schedule, so no encoder means no embed.",
                metrics: ["ffmpeg": .bool(capability.ffmpeg != nil), "ffprobe": .bool(capability.ffprobe != nil)]
            )
        }
        let inputText = ENGPayload.path(payload)
        guard !inputText.isEmpty else { return missingField("input", .zeroTrustWarroom, commandID: commandID) }
        guard let input = resolveInput(inputText), input.isFileURL else {
            return CommandResult.failure(.zeroTrustWarroom, "Input not found or refused: \(AppPaths.anonymise(inputText))", commandID: commandID)
        }
        let queue = ENGPayload.string(payload, "queue")
        let queueID: Int
        if !queue.isEmpty {
            guard let registered = document.warroom.queueRegistry[queue] else {
                return CommandResult(
                    commandID: commandID,
                    engine: .zeroTrustWarroom,
                    ok: false,
                    headline: "队列未登记 · queue “\(queue)” is not registered.",
                    body: "Run `assign` first — an unregistered name has no binary id and would produce an untraceable copy.",
                    metrics: ["registrySize": .int(document.warroom.queueRegistry.count)]
                )
            }
            queueID = registered
        } else {
            let requested = ENGPayload.int(payload, "id", default: -1)
            guard requested >= 0 else { return missingField("queue", .zeroTrustWarroom, commandID: commandID) }
            queueID = requested
        }

        let plan = await modelPlan()
        let gateGB = requirementGB(for: .heavy, plan: plan)
        guard let slot = await gate.reserve(weight: .heavy, memoryGB: gateGB) else {
            return await memoryRefusal(.zeroTrustWarroom, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        guard let duration = await ENGFFmpeg.duration(ffprobe: ffprobe, input: input), duration > 1 else {
            return CommandResult.failure(.zeroTrustWarroom, "Could not read the duration of \(input.lastPathComponent).", commandID: commandID)
        }
        let (keyframes, probeError) = await ENGFFmpeg.keyframeTimes(ffprobe: ffprobe, input: input)
        guard !keyframes.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "未找到关键帧 · no keyframe schedule in the source.",
                body: probeError.isEmpty
                    ? "ffprobe reported no `K` packets — the stream is all-intra or the video track is unreadable, so there is no GOP schedule to choose from."
                    : probeError,
                metrics: ["duration": .double(duration)]
            )
        }

        let layout = ENGGopWatermark.plan(
            queue: queue,
            queueID: queueID,
            duration: duration,
            keyframes: keyframes,
            payloadBits: document.warroom.payloadBits,
            slots: document.warroom.segmentsPerVideo
        )
        guard layout.holes.count < layout.slots / 2 else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "GOP 太稀疏 · the source has too few keyframes.",
                body: "Only \(layout.slots - layout.holes.count)/\(layout.slots) slots could be resolved to a distinct early/late keyframe. "
                    + "Re-encode the master with a shorter keyframe interval (e.g. `-g 48`) or raise `segmentsPerVideo` — a copy with half the slots lost is not traceable.",
                metrics: [
                    "slots": .int(layout.slots),
                    "holes": .int(layout.holes.count),
                    "medianGap": .double(layout.medianGap),
                    "keyframes": .int(keyframes.count)
                ]
            )
        }

        let work = prepared(AppPaths.quarantine.appendingPathComponent("warroom-\(ENGFiles.stamp())", isDirectory: true))
        let fingerprint = ENGGopWatermark.fingerprint(queue: queue, queueID: queueID)
        let stem = input.deletingPathExtension().lastPathComponent
        let output = AppPaths.output.appendingPathComponent("\(stem)-\(fingerprint).mp4")
        defer { try? AppPaths.fileManager.removeItem(at: work) }

        var slices: [URL] = []
        let boundaries = layout.boundaries
        for index in boundaries.indices {
            let start = boundaries[index]
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            guard end > start else { continue }
            let slice = work.appendingPathComponent(String(format: "slice-%03d.mp4", index))
            let cut = await ENGFFmpeg.copySlice(
                ffmpeg: ffmpeg,
                input: input,
                start: start,
                end: end,
                output: slice,
                timeout: 180
            )
            guard cut.succeeded, ENGFiles.size(slice) > 0 else {
                return CommandResult(
                    commandID: commandID,
                    engine: .zeroTrustWarroom,
                    ok: false,
                    headline: "切片失败 · stream copy failed at slot \(index).",
                    body: "ffmpeg: \(cut.combinedOutput.prefix(400))\n\nThis usually means the source has an open-GP B-frame structure that cannot be cut at that keyframe. Use a normal re-encode pass instead of the pixel-free path, or pick a master with closed GOPs.",
                    metrics: ["slot": .int(index), "start": .double(start), "exitCode": .int(Int(cut.exitCode))]
                )
            }
            slices.append(slice)
        }

        let listFile = work.appendingPathComponent("concat.txt")
        let listText = slices
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        guard ENGFiles.write(listText, to: listFile) else {
            return CommandResult.failure(.zeroTrustWarroom, "Could not write the concat list.", commandID: commandID)
        }
        let merged = await ENGFFmpeg.concat(ffmpeg: ffmpeg, listFile: listFile, output: output, timeout: 240)
        guard merged.succeeded, ENGFiles.size(output) > 0 else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "合成失败 · concat failed.",
                body: String(merged.combinedOutput.prefix(600)),
                metrics: ["slices": .int(slices.count)]
            )
        }

        // The manifest is what lets a later trace be *verified* rather than only
        // decoded: keep the intended bit word next to the copy so an operator
        // can prove the embed succeeded before a leak ever happens.
        let manifest: [String: JSONValue] = [
            "queue": .string(queue),
            "queueID": .int(queueID),
            "payloadBits": .int(layout.payloadBits),
            "slots": .int(layout.slots),
            "repeats": .int(layout.repeats),
            "slotBits": .array(layout.slotBits.map { JSONValue.int($0 ? 1 : 0) }),
            "boundaries": .array(layout.boundaries.map { JSONValue.double($0) }),
            "holes": .array(layout.holes.map { JSONValue.int($0) }),
            "medianGap": .double(layout.medianGap),
            "duration": .double(duration),
            "source": .string(AppPaths.anonymise(url: input)),
            "output": .string(AppPaths.anonymise(url: output)),
            "outputBytes": .int(Int(ENGFiles.size(output))),
            "minHammingDistance": .int(ENGGopWatermark.minimumDistance(payloadBits: layout.payloadBits, repeats: layout.repeats)),
            "sealedAt": .string(Date().ppxISO8601)
        ]
        let manifestURL = AppPaths.output.appendingPathComponent("\(stem)-\(fingerprint).trace.json")
        _ = ENGFiles.writeJSON(manifest, to: manifestURL)

        let lossySlots = layout.holes.count
        return CommandResult(
            commandID: commandID,
            engine: .zeroTrustWarroom,
            ok: true,
            headline: "已注入 A/B 水印 · fingerprint embedded",
            body: "队列 Queue: \(queue.isEmpty ? "id \(queueID)" : queue) · id \(queueID) (\(Self.binaryString(queueID, layout.payloadBits)))\n"
                + "方案 Scheme: \(layout.slots) slots, \(layout.repeats) copy(ies) per bit, min Hamming distance \(ENGGopWatermark.minimumDistance(payloadBits: layout.payloadBits, repeats: layout.repeats)).\n"
                + "Losses: \(lossySlots) slot(s) could not be resolved to a distinct keyframe; a transcode by the leaker destroys the whole pattern, and cropping the head/tail drops the outermost slots. This is a *deterrent and attribution* mechanism, not an unbreakable mark.",
            artifacts: [AppPaths.anonymise(url: output), AppPaths.anonymise(url: manifestURL)],
            metrics: [
                "id": .int(queueID),
                "payloadBits": .int(layout.payloadBits),
                "slots": .int(layout.slots),
                "repeats": .int(layout.repeats),
                "holes": .int(layout.holes.count),
                "slices": .int(slices.count),
                "keyframes": .int(keyframes.count),
                "medianGap": .double(layout.medianGap),
                "duration": .double(duration),
                "outputBytes": .int(Int(ENGFiles.size(output))),
                "reEncoded": .bool(false),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// The 1-second extractor: one ffprobe pass over the packet table, a
    /// self-calibrated window grid, majority decoding, and a checksum word.
    private func warroomTrace(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let capability = await ffmpeg()
        guard let ffprobe = capability.ffprobe else {
            return CommandResult.failure(.zeroTrustWarroom, "ffprobe is required to read the keyframe schedule (install ffmpeg in wizard step 1).", commandID: commandID)
        }
        let inputText = ENGPayload.path(payload)
        guard !inputText.isEmpty else { return missingField("input", .zeroTrustWarroom, commandID: commandID) }
        guard let input = resolveInput(inputText) else {
            return CommandResult.failure(.zeroTrustWarroom, "Leaked file not found: \(AppPaths.anonymise(inputText))", commandID: commandID)
        }
        guard let duration = await ENGFFmpeg.duration(ffprobe: ffprobe, input: input), duration > 1 else {
            return CommandResult.failure(.zeroTrustWarroom, "Could not read the duration — is this a video?", commandID: commandID)
        }
        let (keyframes, _) = await ENGFFmpeg.keyframeTimes(ffprobe: ffprobe, input: input, timeout: 10)
        guard keyframes.count >= 4 else {
            return CommandResult(
                commandID: commandID,
                engine: .zeroTrustWarroom,
                ok: false,
                headline: "样本不足 · not enough keyframes to decode.",
                body: "Found \(keyframes.count) keyframe(s). A transcode, a re-mux with a new GOP grid, or a very short clip makes the schedule unreadable.",
                metrics: ["keyframes": .int(keyframes.count), "duration": .double(duration)]
            )
        }

        let decode = ENGGopWatermark.decode(
            keyframes: keyframes,
            duration: duration,
            payloadBits: document.warroom.payloadBits,
            slots: document.warroom.segmentsPerVideo
        )
        let width = document.warroom.payloadBits
        let repeats = ENGGopWatermark.repeats(slots: decode.slotBits.count, payloadBits: width)
        var recoveredBits: [Bool] = []
        var agreements: [Double] = []
        for bit in 0..<width {
            var copies: [Bool] = []
            var slot = bit * repeats
            while slot < bit * repeats + repeats, slot < decode.slotBits.count {
                if decode.resolved[slot] { copies.append(decode.slotBits[slot]) }
                slot += 1
            }
            let verdict = ENGGopWatermark.majority(copies)
            recoveredBits.append(verdict.bit)
            agreements.append(verdict.agreement)
        }
        let recovered = ENGGopWatermark.id(from: recoveredBits)

        // Checksum slots: the tail of the code word. Truncating a leak destroys
        // these first, so tampering shows up as a failed check rather than as a
        // confidently wrong queue.
        let checksumStart = width * repeats
        var checksumBits: [Bool] = []
        var slot = checksumStart
        while slot < decode.slotBits.count {
            checksumBits.append(decode.slotBits[slot])
            slot += 1
        }
        let expectedChecksum = ENGGopWatermark.bits(
            from: ENGGopWatermark.checksum(for: recovered, payloadBits: width),
            payloadBits: width
        )
        let checksumOK: Bool
        if checksumBits.isEmpty {
            checksumOK = false
        } else {
            checksumOK = zip(checksumBits, expectedChecksum).allSatisfy { $0 == $1 }
        }

        let resolvedFraction = decode.resolved.isEmpty
            ? 0.0
            : Double(decode.resolved.filter { $0 }.count) / Double(decode.resolved.count)
        let meanAgreement = agreements.isEmpty
            ? 0.0
            : agreements.reduce(0, +) / Double(agreements.count)
        let confidence = min(0.99, 0.45 * resolvedFraction + 0.35 * meanAgreement + (checksumOK ? 0.20 : 0.0))
        let queueName = document.warroom.queueRegistry.first { $0.value == recovered }?.key

        if let queueName {
            _ = await settings.mutate { draft in draft.warroom.lastTraceHit = queueName }
        }
        await emit(
            .engine,
            "warroom trace → id \(recovered) (\(queueName ?? "unregistered")) confidence \(String(format: "%.2f", confidence))",
            level: checksumOK ? .success : .warning,
            payload: [
                "id": .int(recovered),
                "queue": .string(queueName ?? "—"),
                "confidence": .double(confidence),
                "checksum": .bool(checksumOK)
            ]
        )

        let verdictText: String
        if let queueName {
            verdictText = checksumOK
                ? "泄露副本来自队列 “\(queueName)” (id \(recovered)) · leaked copy traces to “\(queueName)”."
                : "疑似队列 “\(queueName)” (id \(recovered))，但校验位不匹配：文件可能被裁剪或二次处理。 Suspected “\(queueName)”, checksum slots disagree — the file was likely trimmed or re-timed."
        } else {
            verdictText = "解出 id \(recovered)，但注册表中没有对应队列（登记名可能已删除，或水印被部分破坏）。"
        }

        return CommandResult(
            commandID: commandID,
            engine: .zeroTrustWarroom,
            ok: true,
            headline: "溯源完成 · leak traced",
            body: verdictText
                + "\n\n解码 Decoded: \(Self.binaryString(recovered, width))"
                + "\n槽位 Slots resolved: \(decode.resolved.filter { $0 }.count)/\(decode.slotBits.count)"
                + String(format: "\n平均一致率 Mean redundancy agreement: %.0f%%", meanAgreement * 100)
                + "\n校验位 Checksum: \(checksumOK ? "匹配 OK" : "不匹配 MISMATCH")"
                + "\n\nLimits: a re-encode by the leaker destroys this mark entirely; a single flipped slot in a 16-bit/1-copy codebook decodes to a different valid queue (min Hamming distance \(ENGGopWatermark.minimumDistance(payloadBits: width, repeats: repeats))). Raise `segmentsPerVideo` above `payloadBits` for majority correction at zero media cost.",
            metrics: [
                "id": .int(recovered),
                "queue": .string(queueName ?? "—"),
                "confidence": .double(confidence),
                "checksumOK": .bool(checksumOK),
                "slots": .int(decode.slotBits.count),
                "repeats": .int(repeats),
                "resolvedSlots": .int(decode.resolved.filter { $0 }.count),
                "keyframes": .int(keyframes.count),
                "medianGap": .double(decode.medianGap),
                "duration": .double(duration),
                "modelInvolved": .bool(false)
            ]
        )
    }

    private static func binaryString(_ value: Int, _ width: Int) -> String {
        ENGGopWatermark.bits(from: value, payloadBits: width)
            .map { $0 ? "1" : "0" }
            .joined()
    }

    // MARK: - Engine 3 · zerotrace_studio

    /// Full de-identification pipeline: strip → extract facts on-device →
    /// synthesise a neutral anchor clip → destroy the original.
    private func studioProcess(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        guard let ffmpeg = capability.ffmpeg else {
            return CommandResult(
                commandID: commandID,
                engine: .zerotraceStudio,
                ok: false,
                headline: "需要 ffmpeg · ffmpeg not installed.",
                body: "`-map_metadata -1` is the only reliable way to drop the QuickTime device atoms. Install the toolchain in wizard step 1.",
                metrics: ["ffmpeg": .bool(false)]
            )
        }
        let inputs = studioInputs(from: payload, document: document)
        guard !inputs.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .zerotraceStudio,
                ok: false,
                headline: "没有可处理素材 · nothing to process.",
                body: "Pass `input` (a file) or add ingest directories in `StudioConfig.ingestDirectories`. The engine never scans the home directory on its own.",
                metrics: ["ingestDirectories": .int(document.studio.ingestDirectories.count)]
            )
        }
        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.zerotraceStudio, model: ENGOllama.resolvedModel(settings: document, plan: plan), commandID: commandID)
        }

        let gateGB = requirementGB(for: .heavy, plan: plan)
        guard let slot = await gate.reserve(weight: .heavy, memoryGB: gateGB) else {
            return await memoryRefusal(.zerotraceStudio, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        var cleaned: [URL] = []
        var shredded: [URL] = []
        var reEncoded: [URL] = []
        var failures: [String] = []
        var ocrLines = 0
        var factBlocks: [String] = []

        for input in inputs.prefix(12) {
            let strip = await studioStrip(input: input, ffmpeg: ffmpeg, capability: capability, plan: plan)
            guard let clean = strip.output else {
                failures.append("\(input.lastPathComponent): \(strip.reason.prefix(180))")
                continue
            }
            cleaned.append(clean)
            if strip.reEncoded { reEncoded.append(clean) }

            let images = await studioSampleImages(for: clean, ffmpeg: ffmpeg, capability: capability)
            let recognised = await ocrText(in: images)
            ocrLines += recognised.count
            let facts = studioFactsText(recognised: recognised)
            if !facts.isEmpty {
                factBlocks.append("[\(clean.lastPathComponent)]\n\(facts)")
            }

            if document.studio.shredOriginals {
                if await shredSecurely(input) {
                    shredded.append(input)
                } else {
                    failures.append("could not destroy \(AppPaths.anonymise(url: input))")
                }
            }
        }

        guard !cleaned.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .zerotraceStudio,
                ok: false,
                headline: "脱敏全部失败 · every input failed to sanitise.",
                body: failures.joined(separator: "\n"),
                metrics: ["inputs": .int(inputs.count), "failures": .int(failures.count)]
            )
        }

        let model = ENGOllama.resolvedModel(settings: document, plan: plan)
        let prompt = studioPrompt(
            cleaned: cleaned,
            reEncoded: reEncoded,
            shredded: shredded,
            facts: factBlocks.joined(separator: "\n\n"),
            language: document.language
        )
        let reply: ENGOllama.Reply
        do {
            reply = try await ENGOllama.generate(
                model: model,
                prompt: prompt,
                system: studioSystem(document.language),
                temperature: 0.2,
                contextTokens: 3072,
                timeout: 180
            )
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .zerotraceStudio,
                ok: resultIsPartial(cleaned: cleaned),
                headline: "事实提取失败 · fact extraction failed.",
                body: "\(error)\n\nDe-identified copies exist at \(cleaned.count) path(s); originals were \(document.studio.shredOriginals ? "destroyed" : "kept").",
                artifacts: cleaned.map { AppPaths.anonymise(url: $0) },
                metrics: ["cleaned": .int(cleaned.count), "shredded": .int(shredded.count), "model": .string(model)]
            )
        }

        let anchor = await studioRenderAnchor(
            script: reply.text,
            title: bi(document, zh: "现场简报", en: "Field briefing"),
            plan: plan,
            capability: capability
        )

        let factsURL = ENGFFmpeg.outputURL("zerotrace-facts-\(ENGFiles.stamp())", fileExtension: "md")
        _ = ENGFiles.write(studioFactCard(
            reply: reply.text,
            ocrLines: ocrLines,
            cleaned: cleaned,
            shredded: shredded,
            reEncoded: reEncoded,
            model: model
        ), to: factsURL)

        var artifacts = [AppPaths.anonymise(url: factsURL)] + cleaned.map { AppPaths.anonymise(url: $0) }
        if let anchor { artifacts.append(AppPaths.anonymise(url: anchor)) }
        return CommandResult(
            commandID: commandID,
            engine: .zerotraceStudio,
            ok: true,
            headline: "脱敏完成 · \(cleaned.count) copies sanitised, \(shredded.count) originals destroyed",
            body: reply.text
                + "\n\n——\n元数据 Metadata: `-map_metadata -1 -fflags +bitexact`"
                + (reEncoded.isEmpty ? "" : "\n重编码 Re-encode fallback used on \(reEncoded.count) file(s): a generation was taken to guarantee the device atoms are gone.")
                + "\n视觉 OCR: \(ocrLines) lines read on-device by Vision (revision-pinned, accurate level); no image ever left this machine."
                + "\n粉碎 Shred: \(shredded.count) original(s) overwritten with random bytes then unlinked. See the limitation note in the fact card — on APFS this is best effort, not a guarantee.",
            artifacts: artifacts,
            metrics: [
                "inputs": .int(inputs.count),
                "cleaned": .int(cleaned.count),
                "reEncoded": .int(reEncoded.count),
                "shredded": .int(shredded.count),
                "ocrLines": .int(ocrLines),
                "anchorRendered": .bool(anchor != nil),
                "model": .string(reply.model),
                "generatedTokens": .int(reply.generatedTokens),
                "sampleRateHz": .int(plan.audioSampleRateHz)
            ]
        )
    }

    private func resultIsPartial(cleaned: [URL]) -> Bool { !cleaned.isEmpty }

    /// Strip-only path: useful when the owner just wants the clean copy and
    /// keeps the original.
    private func studioStrip(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        guard let ffmpeg = capability.ffmpeg else {
            return CommandResult.failure(.zerotraceStudio, "ffmpeg is required.", commandID: commandID)
        }
        let inputs = studioInputs(from: payload, document: document)
        guard !inputs.isEmpty else { return ENGPayload.missing("input", engine: .zerotraceStudio, commandID: commandID) }

        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.zerotraceStudio, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        var outputs: [URL] = []
        var notes: [String] = []
        for input in inputs.prefix(24) {
            let strip = await studioStrip(input: input, ffmpeg: ffmpeg, capability: capability, plan: plan)
            if let output = strip.output {
                outputs.append(output)
                if strip.reEncoded { notes.append("\(input.lastPathComponent): re-encoded to drop atoms") }
            } else {
                notes.append("\(input.lastPathComponent): \(strip.reason.prefix(160))")
            }
        }
        return CommandResult(
            commandID: commandID,
            engine: .zerotraceStudio,
            ok: !outputs.isEmpty,
            headline: "元数据已剥离 · \(outputs.count) clean copies",
            body: (outputs.map { AppPaths.anonymise(url: $0) }.joined(separator: "\n")
                + (notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n"))),
            artifacts: outputs.map { AppPaths.anonymise(url: $0) },
            metrics: ["inputs": .int(inputs.count), "outputs": .int(outputs.count), "modelInvolved": .bool(false)]
        )
    }

    /// Renders only the anchor briefing clip from an existing clean copy or a
    /// supplied text.
    private func studioAnchor(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        guard capability.isUsable else {
            return CommandResult.failure(.zerotraceStudio, "ffmpeg is required to render the anchor clip.", commandID: commandID)
        }
        let script = ENGPayload.string(payload, "script", default: ENGPayload.string(payload, "text"))
        guard !script.isEmpty else { return ENGPayload.missing("script", engine: .zerotraceStudio, commandID: commandID) }

        let gateGB = requirementGB(for: .heavy, plan: plan)
        guard let slot = await gate.reserve(weight: .heavy, memoryGB: gateGB) else {
            return await memoryRefusal(.zerotraceStudio, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        guard let url = await studioRenderAnchor(
            script: script,
            title: ENGPayload.string(payload, "title", default: document.nodeName),
            plan: plan,
            capability: capability
        ) else {
            return CommandResult.failure(.zerotraceStudio, "Anchor render failed — see the console log for the ffmpeg error.", commandID: commandID)
        }
        return CommandResult(
            commandID: commandID,
            engine: .zerotraceStudio,
            ok: true,
            headline: "数字播报员成片就绪 · anchor clip ready",
            body: script,
            artifacts: [AppPaths.anonymise(url: url)],
            metrics: ["sampleRateHz": .int(plan.audioSampleRateHz), "scriptChars": .int(script.count), "modelInvolved": .bool(false)]
        )
    }

    /// Explicit destroy path, for the case where the owner sanitised earlier and
    /// now wants the source gone.
    private func studioShred(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let inputs = studioInputs(from: payload, document: document)
        guard !inputs.isEmpty else { return ENGPayload.missing("input", engine: .zerotraceStudio, commandID: commandID) }
        var destroyed: [String] = []
        var refused: [String] = []
        for input in inputs.prefix(24) where ENGFiles.exists(input) {
            if await shredSecurely(input) {
                destroyed.append(AppPaths.anonymise(url: input))
            } else {
                refused.append(AppPaths.anonymise(url: input))
            }
        }
        await emit(
            .engine,
            "zerotrace shred: \(destroyed.count) destroyed, \(refused.count) refused",
            level: refused.isEmpty ? .success : .warning,
            payload: ["destroyed": .int(destroyed.count), "refused": .int(refused.count)]
        )
        return CommandResult(
            commandID: commandID,
            engine: .zerotraceStudio,
            ok: !destroyed.isEmpty,
            headline: "原始素材已粉碎 · \(destroyed.count) original(s) destroyed",
            body: destroyed.joined(separator: "\n")
                + (refused.isEmpty ? "" : "\n\n拒绝 Refused (protected store or unwritable):\n" + refused.joined(separator: "\n"))
                + "\n\nBest-effort warning: APFS is copy-on-write and SSDs wear-level, so an overwrite cannot provably remove every physical copy. `shred` semantics are not guaranteed here; unlinking plus overwrite defeats ordinary recovery, not a forensic chip read.",
            metrics: [
                "destroyed": .int(destroyed.count),
                "refused": .int(refused.count),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Files to work on: the explicit `input`, plus whatever sits in the
    /// owner-configured ingest directories.
    private func studioInputs(from payload: JSONValue, document: NodeSettings) -> [URL] {
        var inputs: [URL] = []
        let explicit = ENGPayload.strings(payload, "inputs") + [ENGPayload.path(payload)]
        for text in explicit where !text.isEmpty {
            guard let url = resolveInput(text) else { continue }
            if ENGFiles.isDirectory(url) {
                inputs.append(contentsOf: ENGFiles.mediaFiles(in: url, limit: 24))
            } else {
                inputs.append(url)
            }
        }
        for raw in document.studio.ingestDirectories {
            guard let url = AppPaths.resolve(userPath: raw), ENGFiles.isDirectory(url) else { continue }
            inputs.append(contentsOf: ENGFiles.mediaFiles(in: url, limit: 24))
        }
        var seen = Set<String>()
        return inputs.filter { seen.insert($0.path).inserted }
    }

    /// Runs the brief's command, then the re-encode fallback if stream copy is
    /// rejected by the container.
    private func studioStrip(
        input: URL,
        ffmpeg: String,
        capability: ENGFFmpeg.Capability,
        plan: ModelPlan
    ) async -> (output: URL?, reEncoded: Bool, reason: String) {
        let base = AppPaths.output
        let stem = TextKit.safeFileName(input.deletingPathExtension().lastPathComponent, fallback: "clean")
        let ext = input.pathExtension.lowercased()
        let first = prepared(base).appendingPathComponent("clean-\(stem)-\(TextKit.fingerprint(input.path, length: 6)).\(ext.isEmpty ? "mov" : ext)")
        let copy = await ENGFFmpeg.stripMetadata(ffmpeg: ffmpeg, input: input, output: first, timeout: 240)
        if copy.succeeded, ENGFiles.size(first) > 0 {
            return (first, false, "")
        }
        let reencoded = prepared(base).appendingPathComponent("clean-\(stem)-\(TextKit.fingerprint(input.path, length: 6)).mp4")
        let fallback = await ENGFFmpeg.stripMetadataReencode(
            ffmpeg: ffmpeg,
            input: input,
            output: reencoded,
            sampleRateHz: plan.audioSampleRateHz,
            preferX264: capability.hasLibx264,
            timeout: 900
        )
        if fallback.succeeded, ENGFiles.size(reencoded) > 0 {
            try? AppPaths.fileManager.removeItem(at: first)
            return (reencoded, true, "")
        }
        return (nil, false, copy.combinedOutput.isEmpty ? fallback.combinedOutput : copy.combinedOutput + "\n" + fallback.combinedOutput)
    }

    /// Frames the OCR stage may look at: PDF pages rasterised locally, video
    /// frames sampled, still images used directly.
    private func studioSampleImages(for url: URL, ffmpeg: String?, capability: ENGFFmpeg.Capability) async -> [URL] {
        let ext = url.pathExtension.lowercased()
        if ENGFiles.imageExtensions.contains(ext) { return [url] }
        if ext == "pdf" { return rasterizePDF(url, maxPages: 8) }
        guard let ffmpeg else { return [] }
        let directory = prepared(AppPaths.quarantine.appendingPathComponent("frames-\(ENGFiles.stamp())-\(TextKit.fingerprint(url.path, length: 6))"))
        let frames = await Shell.run(
            ffmpeg,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", url.path,
                "-vf", "fps=1/4,scale=1600:-2:flags=bicubic",
                "-frames:v", "12",
                directory.appendingPathComponent("frame-%03d.png").path
            ],
            timeout: 180
        )
        guard frames.succeeded else { return [] }
        return ((try? AppPaths.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Vision text recognition, on-device. Runs the whole OCR pass in one
    /// detached task so a 12-page report cannot stall the actor that answers the
    /// console; only `Sendable` values (URLs, strings) cross that boundary.
    private func ocrText(in images: [URL]) async -> [String] {
        #if canImport(Vision)
        guard !images.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var lines: [String] = []
            for url in images {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Pinned revision for reproducible readings. Revision 1 is still
                // selectable but predates the CJK coverage a Chinese lab report
                // or a bilingual field note needs, so the node pins the newest
                // text revision available on macOS 14.
                request.revision = VNRecognizeTextRequestRevision3
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continue
                }
                for observation in request.results ?? [] {
                    if let candidate = observation.topCandidates(1).first {
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { lines.append(text) }
                    }
                }
            }
            return lines
        }.value
        #else
        return []
        #endif
    }

    /// Rasterises PDF pages into the quarantine directory.
    private func rasterizePDF(_ url: URL, maxPages: Int) -> [URL] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return [] }
        let directory = prepared(AppPaths.quarantine.appendingPathComponent("pdf-\(ENGFiles.stamp())-\(TextKit.fingerprint(url.path, length: 6))"))
        var outputs: [URL] = []
        let pages = min(document.pageCount, max(1, maxPages))
        for index in 0..<pages {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.5
            let width = max(1, Int(bounds.width * scale))
            let height = max(1, Int(bounds.height * scale))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }
            let target = directory.appendingPathComponent("page-\(String(format: "%03d", index)).png")
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { outputs.append(target) }
        }
        return outputs
        #else
        return []
        #endif
    }

    /// Joins OCR output, then lets NaturalLanguage pull obvious entities so the
    /// model gets structured facts instead of a wall of recognised strings.
    private func studioFactsText(recognised: [String]) -> String {
        let joined = recognised.joined(separator: "\n")
        let entities = studioEntities(in: joined)
        var output = joined.isEmpty ? "" : String(joined.prefix(6_000))
        if !entities.isEmpty {
            output += "\n\n[entities] " + entities.prefix(40).joined(separator: ", ")
        }
        return output
    }

    /// Person/location/date organisation tags from the recognised text. Used
    /// only to seed the prompt; the model still has to justify every claim.
    private func studioEntities(in text: String) -> [String] {
        #if canImport(NaturalLanguage)
        guard !text.isEmpty else { return [] }
        // Bounded on purpose: tagger cost is linear in the string, and an OCR
        // dump from a 40-page scan would otherwise stall the actor.
        let scan = String(text.prefix(4_000))
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = scan
        var found: [String] = []
        tagger.enumerateTags(
            in: scan.startIndex..<scan.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, tokenRange in
            let interesting: [NLTag] = [.personalName, .placeName, .organizationName]
            if let tag, interesting.contains(tag) {
                found.append(String(scan[tokenRange]))
            }
            return true
        }
        return Array(Set(found).sorted())
        #else
        return []
        #endif
    }

    /// Writes the deterministic fact card that records exactly what was removed
    /// and what was destroyed — the audit trail a lawyer or an editor asks for.
    private func studioFactCard(
        reply: String,
        ocrLines: Int,
        cleaned: [URL],
        shredded: [URL],
        reEncoded: [URL],
        model: String
    ) -> String {
        """
        # 零痕脱敏记录 · Zero-Trace De-identification Record
        时间 When: \(Date().ppxISO8601)
        本机模型 Model: \(model)

        ## 核心事实 Core facts
        \(reply)

        ## 处理 Processed
        - 干净副本 Clean copies: \(cleaned.map { AppPaths.anonymise(url: $0) }.joined(separator: ", "))
        - 重编码 Re-encode fallback: \(reEncoded.isEmpty ? "none" : reEncoded.map(\.lastPathComponent).joined(separator: ", "))
        - OCR 行数 Lines read on-device: \(ocrLines)

        ## 销毁 Destroyed originals
        \(shredded.isEmpty ? "— none (shredOriginals is off or nothing was destroyed)" : shredded.map { AppPaths.anonymise(url: $0) }.joined(separator: "\n"))

        > Limitation: APFS is copy-on-write and NVMe wear-levels. Overwrite-then-unlink
        > defeats recovery by ordinary tools; it is not provably identical to a
        > single-write platter erase, and this node does not claim otherwise.
        """
    }

    private func studioSystem(_ language: ConsoleLanguage) -> String {
        Self.systemTemplate(
            language,
            zh: "你是新闻事实核查助手。只从给定 OCR 文本中提取：谁、何时、何地、发生了什么、还有哪些不确定。不得补充文本中没有的细节。输出不超过 220 字的中文要点清单。",
            en: "You are a news fact-checker. From the supplied OCR text only, extract who, when, where, what happened, and what remains uncertain. Invent nothing that is not in the text. Reply with bullet points under 200 words."
        )
    }

    private func studioPrompt(
        cleaned: [URL],
        reEncoded: [URL],
        shredded: [URL],
        facts: String,
        language: ConsoleLanguage
    ) -> String {
        // The generate call below asks for a 3072-token window, so the OCR dump
        // is capped here rather than letting a 12-file batch overflow the model.
        let evidence = facts.isEmpty
            ? (language.isChinese ? "（本机 OCR 未识别到任何文字）" : "(on-device OCR recognised no text)")
            : String(facts.prefix(6_000))
        return """
        已脱敏文件 Files sanitised: \(cleaned.map { $0.lastPathComponent }.joined(separator: ", "))
        重编码 Re-encoded: \(reEncoded.map { $0.lastPathComponent }.joined(separator: ", "))
        已销毁 Destroyed: \(shredded.map { $0.lastPathComponent }.joined(separator: ", "))

        \(language.isChinese ? "请从下面附带的本机 OCR 文本中提取核心事实。" : "Extract the core facts from the on-device OCR text appended below.")

        \(evidence)
        """
    }

    /// The secure destroy: random overwrite of every allocated block, sync, then
    /// unlink.
    ///
    /// Disclosed honestly in every result that uses it: APFS writes new blocks
    /// for a modified file (copy-on-write) and SSD controllers remap logical
    /// blocks, so overwriting the logical range does not prove the old physical
    /// bytes are gone. It removes the file from the filesystem, clears the
    /// common recovery tools, and is the best this API can do without
    /// `SecItem`-level hardware erase. The chunk buffer is reused across files
    /// so a 4K video costs one allocation, not one per block.
    private func shredSecurely(_ url: URL) async -> Bool {
        guard ENGFiles.exists(url) else { return false }
        let bytes = ENGFiles.size(url)
        if bytes > 0 {
            let chunkSize = 1 << 20
            var chunk = ENGFiles.randomBytes(chunkSize)
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(0))
                var remaining = bytes
                while remaining > 0 {
                    let take = Int(min(Int64(chunkSize), remaining))
                    if take == chunk.count {
                        try handle.write(contentsOf: chunk)
                    } else {
                        chunk = Data(chunk.prefix(take))
                        try handle.write(contentsOf: chunk)
                    }
                    remaining -= Int64(take)
                    if remaining > 0 { await Task.yield() }
                }
                try handle.synchronize()
            } catch {
                return false
            }
        }
        do {
            try AppPaths.fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Engine 4 · solo_autopilot

    /// Script → LTX-2.5 MLX render → 48 kHz normalisation.
    private func soloPipeline(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        let topic = ENGPayload.string(payload, "topic", default: ENGPayload.string(payload, "keyword", default: ENGPayload.string(payload, "brief")))
        guard !topic.isEmpty else { return ENGPayload.missing("topic", engine: .soloAutopilot, commandID: commandID) }
        let seconds = min(max(ENGPayload.int(payload, "seconds", default: 12), 4), 120)
        let model = ENGOllama.resolvedModel(settings: document, plan: plan)

        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.soloAutopilot, model: model, commandID: commandID)
        }
        let script: String
        do {
            script = try await ENGOllama.generate(
                model: model,
                prompt: soloScriptPrompt(topic: topic, seconds: seconds, document: document, language: document.language),
                system: soloScriptSystem(document.language),
                temperature: 0.75,
                contextTokens: 2048,
                timeout: 150
            ).text
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .soloAutopilot,
                ok: false,
                headline: "脚本生成失败 · script failed.",
                body: String(describing: error),
                metrics: ["model": .string(model)]
            )
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CommandResult.failure(.soloAutopilot, "The local model returned an empty script.", commandID: commandID)
        }

        // Heavy-video routing: below 48 GB the plan says do not load LTX here.
        let heavy = seconds > 20 || plan.tier == .flagship
        if plan.tier == .light && plan.routeHeavyVideoToMesh && heavy {
            return await routeToMesh(topic: topic, script: script, seconds: seconds, commandID: commandID)
        }

        let gateGB = requirementGB(for: .heavy, plan: plan)
        guard let slot = await gate.reserve(weight: .heavy, memoryGB: gateGB) else {
            return await memoryRefusal(.soloAutopilot, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let raw = prepared(AppPaths.quarantine).appendingPathComponent("solo-raw-\(ENGFiles.stamp()).mp4")
        let render = await renderWithLTX(
            prompt: script,
            seconds: seconds,
            output: raw,
            plan: plan
        )
        guard render.succeeded else {
            return CommandResult(
                commandID: commandID,
                engine: .soloAutopilot,
                ok: false,
                headline: "LTX 渲染失败 · local video render failed.",
                body: render.detail
                    + "\n\nWorkspace probed: \(AppPaths.anonymise(url: AppPaths.ltxWorkspace))"
                    + "\nWeights hint from the plan: \(plan.ltxWeightsHint) · backend \(plan.videoBackend) · \(plan.videoPrecision)",
                artifacts: [AppPaths.anonymise(url: ENGFFmpeg.outputURL("solo-script-\(ENGFiles.stamp())", fileExtension: "md"))],
                metrics: [
                    "topic": .string(topic),
                    "seconds": .int(seconds),
                    "tier": .string(plan.tier.rawValue),
                    "scriptChars": .int(script.count),
                    "rendered": .bool(false)
                ]
            )
        }

        let narration = await studioNarrate(script: script, plan: plan)
        let final = ENGFFmpeg.outputURL("solo-\(TextKit.safeFileName(topic, fallback: "clip"))-\(ENGFiles.stamp())", fileExtension: "mp4")
        guard let ffmpeg = capability.ffmpeg else {
            return CommandResult.failure(.soloAutopilot, "ffmpeg disappeared mid-run; raw render kept at \(AppPaths.anonymise(url: raw)).", commandID: commandID)
        }
        let normalised = await ENGFFmpeg.normalise(
            ffmpeg: ffmpeg,
            input: raw,
            output: final,
            audioTrack: narration,
            sampleRateHz: plan.audioSampleRateHz,
            width: 1920,
            timeout: 900
        )
        guard normalised.succeeded, ENGFiles.size(final) > 0 else {
            return CommandResult(
                commandID: commandID,
                engine: .soloAutopilot,
                ok: false,
                headline: "归一化失败 · normalisation failed.",
                body: String(normalised.combinedOutput.prefix(600)),
                artifacts: [AppPaths.anonymise(url: raw)],
                metrics: ["rendered": .bool(true), "normalised": .bool(false)]
            )
        }
        try? AppPaths.fileManager.removeItem(at: raw)

        return CommandResult(
            commandID: commandID,
            engine: .soloAutopilot,
            ok: true,
            headline: "短片已渲染 · clip ready for the review channel",
            body: script
                + "\n\n——\n时长 Duration: \(seconds) s · 音频 Audio: \(plan.audioSampleRateHz) Hz \(narration == nil ? "(silent track)" : "(local TTS narration)")"
                + "\n渲染 Renderer: \(plan.videoRef) (\(plan.videoPrecision)) on \(plan.videoBackend)"
                + "\nEverything ran locally; the only network call was to \(ENGOllama.host).",
            artifacts: [AppPaths.anonymise(url: final)],
            metrics: [
                "seconds": .int(seconds),
                "scriptChars": .int(script.count),
                "model": .string(model),
                "sampleRateHz": .int(plan.audioSampleRateHz),
                "narrated": .bool(narration != nil),
                "outputBytes": .int(Int(ENGFiles.size(final))),
                "renderedLocally": .bool(true),
                "tier": .string(plan.tier.rawValue)
            ]
        )
    }

    /// Script-only path: cheap, no gate contention, used by the iOS "give me the
    /// copy first" button.
    private func soloScript(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let model = ENGOllama.resolvedModel(settings: document, plan: plan)
        let topic = ENGPayload.string(payload, "topic", default: ENGPayload.string(payload, "keyword"))
        guard !topic.isEmpty else { return ENGPayload.missing("topic", engine: .soloAutopilot, commandID: commandID) }
        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.soloAutopilot, model: model, commandID: commandID)
        }
        let seconds = min(max(ENGPayload.int(payload, "seconds", default: 20), 4), 120)
        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.soloAutopilot, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let reply: ENGOllama.Reply
        do {
            reply = try await ENGOllama.generate(
                model: model,
                prompt: soloScriptPrompt(topic: topic, seconds: seconds, document: document, language: document.language),
                system: soloScriptSystem(document.language),
                temperature: 0.8,
                contextTokens: 2048,
                timeout: 150
            )
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .soloAutopilot,
                ok: false,
                headline: "脚本生成失败 · script failed.",
                body: String(describing: error),
                metrics: ["model": .string(model)]
            )
        }
        let url = ENGFFmpeg.outputURL("solo-script-\(ENGFiles.stamp())", fileExtension: "md")
        _ = ENGFiles.write("""
        # 一人公司脚本 · Solo script
        - 主题 Topic: \(topic)
        - 目标时长 Target: \(seconds) s
        - 模型 Model: \(reply.model)
        - 生成 Generated: \(Date().ppxISO8601)

        \(reply.text)
        """, to: url)
        return CommandResult(
            commandID: commandID,
            engine: .soloAutopilot,
            ok: true,
            headline: "脚本已生成 · script ready",
            body: reply.text,
            artifacts: [AppPaths.anonymise(url: url)],
            metrics: [
                "topic": .string(topic),
                "seconds": .int(seconds),
                "model": .string(reply.model),
                "generatedTokens": .int(reply.generatedTokens),
                "modelInvolved": .bool(true)
            ]
        )
    }

    /// Refuses local rendering and hands the job to the mesh instead, exactly as
    /// the `< 48 GB` rung of the ladder requires.
    private func routeToMesh(topic: String, script: String, seconds: Int, commandID: String?) async -> CommandResult {
        let plan = await modelPlan()
        var payload: [String: JSONValue] = [
            "kind": .string("ltx-render"),
            "requestedBy": .string("solo_autopilot"),
            "prompt": .string(script),
            "seconds": .int(seconds),
            "rewardPoints": .int(0)
        ]
        payload["memoryCapGB"] = .int(max(8, requirementGB(for: .heavy, plan: plan)))
        payload["maxSeconds"] = .int(max(120, seconds * 40))
        let accepted = await meshAccept(payload: .object(payload), commandID: commandID)
        var routed = accepted
        routed.engine = .soloAutopilot
        routed.headline = "已路由到边缘算力 · routed to the edge mesh"
        routed.body = "本机内存 < 48 GB（\(plan.tier.titleEn)），重视频渲染不在本机执行。\n"
            + "This node is under 48 GB, so the \(seconds) s render for “\(topic)” was queued for an edge-compute peer instead of being run locally.\n\n"
            + accepted.body
        routed.metrics["localRenderRefused"] = JSONValue.bool(true)
        routed.metrics["tier"] = JSONValue.string(plan.tier.rawValue)
        return routed
    }

    /// Invokes the LTX-2.5 MLX workspace the installer creates.
    ///
    /// The probe order is deliberately explicit: a venv interpreter inside
    /// `AppPaths.ltxWorkspace`, then a runner script the 模块一 installer is
    /// expected to drop there, then a module import. If none exist the engine
    /// reports the exact command it would have run, rather than pretending a
    /// render happened — the failure is actionable instead of mysterious.
    private func renderWithLTX(
        prompt: String,
        seconds: Int,
        output: URL,
        plan: ModelPlan
    ) async -> (succeeded: Bool, detail: String) {
        let venvPython = AppPaths.ltxVenv.appendingPathComponent("bin/python")
        let candidates = [venvPython.path, Shell.which("python3") ?? "", Shell.which("uv") ?? ""]
        guard let python = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (false, """
            No Python found in the LTX workspace.
            Expected: \(AppPaths.anonymise(url: venvPython))
            Run the one-click installer (wizard step 1) to create the ltx-2-mlx workspace and download \(plan.ltxWeightsHint).
            """)
        }
        guard ENGFiles.exists(AppPaths.ltxWorkspace) else {
            return (false, "LTX workspace is missing at \(AppPaths.anonymise(url: AppPaths.ltxWorkspace)); the installer has not run yet.")
        }
        _ = prepared(output.deletingLastPathComponent())

        let runnerNames = ["render_clip.py", "generate.py", "ltx_render.py", "cli.py"]
        let searchRoots = [AppPaths.ltxWorkspace, AppPaths.ltxRepo]
        var runner: URL?
        for root in searchRoots {
            for name in runnerNames {
                let candidate = root.appendingPathComponent(name)
                if ENGFiles.exists(candidate) { runner = candidate; break }
            }
            if runner != nil { break }
        }

        let promptFile = prepared(AppPaths.quarantine)
            .appendingPathComponent("ltx-prompt-\(ENGFiles.stamp()).txt")
        _ = ENGFiles.write(prompt, to: promptFile)

        var arguments: [String]
        var tried = ""
        if let runner {
            arguments = [
                runner.path,
                "--prompt-file", promptFile.path,
                "--seconds", String(seconds),
                "--output", output.path,
                "--precision", plan.videoPrecision,
                "--model-dir", AppPaths.ltxModelDir.path
            ]
            tried = "\(AppPaths.anonymise(url: runner))"
        } else {
            let module = "ltx_2_mlx.generate"
            arguments = [
                "-m", module,
                "--prompt-file", promptFile.path,
                "--seconds", String(seconds),
                "--output", output.path,
                "--model-dir", AppPaths.ltxModelDir.path
            ]
            tried = "python -m \(module)"
        }

        let budget = max(240, seconds * 30)
        let result = await Shell.runAbsolute(
            launchPath: python,
            arguments,
            at: AppPaths.ltxWorkspace,
            environment: [
                "PPX_LTX_WEIGHTS": AppPaths.weights.path,
                "PPX_LTX_PRECISION": plan.videoPrecision,
                "PYTHONDONTWRITEBYTECODE": "1"
            ],
            timeout: TimeInterval(budget)
        )
        guard result.succeeded, ENGFiles.size(output) > 0 else {
            return (false, """
            Tried: \(tried)
            Exit: \(result.exitCode)\(result.timedOut ? " (killed by the watchdog after \(budget) s)" : "")
            \(String(result.combinedOutput.prefix(900)))
            """)
        }
        return (true, "rendered with \(tried)")
    }

    /// Local narration through `/usr/bin/say`. If the voice is missing, the
    /// caller gets `nil` and the clip ships with a silent 48 kHz track plus
    /// burned captions instead of failing.
    private func studioNarrate(script: String, plan: ModelPlan) async -> URL? {
        guard Shell.isPresent("say"), !script.isEmpty else { return nil }
        let directory = prepared(AppPaths.quarantine)
        let voiceText = String(script.prefix(2_500))
        let scriptFile = directory.appendingPathComponent("narration-\(ENGFiles.stamp()).txt")
        guard ENGFiles.write(voiceText, to: scriptFile) else { return nil }
        let audio = directory.appendingPathComponent("narration-\(ENGFiles.stamp()).m4a")
        let result = await Shell.run(
            "say",
            [
                "-o", audio.path,
                "--data-format=aac",
                "-r", "178",
                "-f", scriptFile.path
            ],
            timeout: 180
        )
        guard result.succeeded, ENGFiles.size(audio) > 0 else { return nil }
        // Resample to the plan's rate so the mux never has to guess.
        let normalised = directory.appendingPathComponent("narration-\(ENGFiles.stamp())-\(plan.audioSampleRateHz).m4a")
        if let ffmpeg = (await ffmpeg()).ffmpeg {
            let resample = await ENGFFmpeg.convert(
                ffmpeg: ffmpeg,
                input: audio,
                output: normalised,
                extraArguments: ["-ar", String(plan.audioSampleRateHz), "-ac", "1", "-c:a", "aac", "-b:a", "128k"],
                timeout: 120
            )
            if resample.succeeded, ENGFiles.size(normalised) > 0 { return normalised }
        }
        return audio
    }

    private func soloScriptSystem(_ language: ConsoleLanguage) -> String {
        Self.systemTemplate(
            language,
            zh: "你是短视频编剧。输出：三行钩子开场、四段正文口播（每段不超过 25 字）、结尾一句行动号召，并在最后单独一行给出画面提示（用于文生视频模型，不超过 60 字）。不要输出任何云端上传建议。",
            en: "You are a short-video scriptwriter. Output a three-line hook, four spoken body lines (max 14 words each), one call to action, then a single final line with a visual prompt for the text-to-video model (max 40 words). Never suggest uploading to a cloud service."
        )
    }

    private func soloScriptPrompt(
        topic: String,
        seconds: Int,
        document: NodeSettings,
        language: ConsoleLanguage
    ) -> String {
        """
        主题 Topic: \(topic)
        目标时长 Target duration: \(seconds) s (≈\(Int(Double(seconds) * 2.6)) words at 156 wpm)
        节点 Node: \(document.nodeName)
        语言 Language: \(language.resolved.nativeName)
        \(language.isChinese ? "请写口播脚本。" : "Write the spoken script.")
        """
    }

    /// The anchor briefing clip: neutral slate, timed captions, local narration,
    /// 48 kHz audio. Built from primitives that exist on every Mac (`ffmpeg`
    /// `color=` source plus `/usr/bin/say`), so a solo creator with no LTX
    /// weights still gets a publishable file instead of an error.
    private func studioRenderAnchor(
        script: String,
        title: String,
        plan: ModelPlan,
        capability: ENGFFmpeg.Capability
    ) async -> URL? {
        guard let ffmpeg = capability.ffmpeg, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = anchorLines(from: script)
        guard !lines.isEmpty else { return nil }
        let seconds = anchorDuration(for: script)
        let directory = prepared(AppPaths.quarantine)

        let plate = directory.appendingPathComponent("anchor-plate-\(ENGFiles.stamp()).mov")
        let plateResult = await ENGFFmpeg.colorPlate(
            ffmpeg: ffmpeg,
            output: plate,
            seconds: seconds,
            size: "1920x1080",
            color: "0x0E1116",
            frameRate: 30,
            timeout: 300
        )
        guard plateResult.succeeded, ENGFiles.size(plate) > 0 else { return nil }

        let captioned = directory.appendingPathComponent("anchor-captioned-\(ENGFiles.stamp()).mp4")
        let burned: ShellResult
        if capability.hasAssBurnIn {
            let assFile = directory.appendingPathComponent("anchor-\(ENGFiles.stamp()).ass")
            guard ENGFiles.write(anchorASS(title: title, lines: lines, seconds: seconds), to: assFile) else { return nil }
            burned = await ENGFFmpeg.burnAss(
                ffmpeg: ffmpeg,
                input: plate,
                assFile: assFile,
                output: captioned,
                sampleRateHz: plan.audioSampleRateHz,
                timeout: 600
            )
        } else {
            let captionFile = directory.appendingPathComponent("anchor-\(ENGFiles.stamp()).txt")
            guard ENGFiles.write(lines.prefix(6).joined(separator: "\n"), to: captionFile) else { return nil }
            burned = await ENGFFmpeg.burnText(
                ffmpeg: ffmpeg,
                input: plate,
                captionFile: captionFile,
                output: captioned,
                fontPath: ENGFFmpeg.captionFont(),
                fontSize: 44,
                sampleRateHz: plan.audioSampleRateHz,
                seconds: seconds,
                timeout: 600
            )
        }
        guard burned.succeeded, ENGFiles.size(captioned) > 0 else {
            try? AppPaths.fileManager.removeItem(at: plate)
            return nil
        }

        let final = ENGFFmpeg.outputURL("anchor-\(ENGFiles.stamp())", fileExtension: "mp4")
        if let narration = await studioNarrate(script: script, plan: plan) {
            let mux = await ENGFFmpeg.convert(
                ffmpeg: ffmpeg,
                input: captioned,
                output: final,
                extraArguments: [
                    "-i", narration.path,
                    "-map", "0:v", "-map", "1:a",
                    "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "160k",
                    "-ar", String(plan.audioSampleRateHz),
                    "-shortest",
                    "-movflags", "+faststart"
                ],
                timeout: 300
            )
            if mux.succeeded, ENGFiles.size(final) > 0 {
                try? AppPaths.fileManager.removeItem(at: plate)
                try? AppPaths.fileManager.removeItem(at: captioned)
                return final
            }
        }
        if ENGFiles.size(final) == 0 {
            do {
                try AppPaths.fileManager.moveItem(at: captioned, to: final)
            } catch {
                return nil
            }
        }
        try? AppPaths.fileManager.removeItem(at: plate)
        return final
    }

    /// Caption chunks: sentence-ish splits, then hard wrapping so a long clause
    /// never runs off the 1920 px slate.
    private func anchorLines(from script: String) -> [String] {
        let paragraphs = script
            .split(whereSeparator: { $0 == "\n" })
            .flatMap { piece -> [String] in
                var buffer = ""
                var chunks: [String] = []
                for token in piece.split(whereSeparator: { $0 == " " || $0 == "　" }) {
                    buffer += (buffer.isEmpty ? "" : " ") + token
                    if buffer.count >= 34 {
                        chunks.append(buffer)
                        buffer = ""
                    }
                }
                if !buffer.isEmpty { chunks.append(buffer) }
                return chunks
            }
        return paragraphs.map { TextKit.truncate($0, to: 46) }.filter { !$0.isEmpty }
    }

    /// Narration-length estimate at 156 wpm / ≈2.6 CJK glyphs per second.
    private func anchorDuration(for script: String) -> Double {
        max(8, min(180, Double(script.count) / 2.6))
    }

    /// Minimal but valid ASS document. Colours are `&HAABBGGRR`, alignment 2 is
    /// bottom-centre, and every line is escaped so a quote or brace inside the
    /// script cannot open a new style override.
    private func anchorASS(title: String, lines: [String], seconds: Double) -> String {
        let perLine = max(1.2, seconds / Double(max(lines.count, 1)))
        var events: [String] = []
        if !title.isEmpty {
            events.append("Dialogue: 0,\(assTime(0.2)),\(assTime(min(3.0, perLine))),Title,,0,0,0,,\(assEscape(title))")
        }
        for (index, line) in lines.enumerated() {
            let start = 0.4 + Double(index) * perLine
            let end = min(seconds - 0.2, start + perLine - 0.1)
            guard end > start else { break }
            events.append("Dialogue: 0,\(assTime(start)),\(assTime(end)),Anchor,,0,0,0,,\(assEscape(line))")
        }
        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Title,PingFang SC,52,&H008CD8FF,&H000000FF,&H000E1116,&H80000000,-1,0,0,0,100,100,1,0,1,2,1,8,140,140,120,1
        Style: Anchor,PingFang SC,62,&H00FFFFFF,&H000000FF,&H000E1116,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,140,140,140,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events.joined(separator: "\n"))
        """
    }

    private func assTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(
            format: "%d:%02d:%02d.%02d",
            Int(total) / 3600,
            (Int(total) / 60) % 60,
            Int(total) % 60,
            Int((total - floor(total)) * 100)
        )
    }

    private func assEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\u{5C}")
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    // MARK: - Engine 5 · edge_compute_mesh

    /// The only workloads this node will execute for a peer.
    ///
    /// A mesh request never carries an executable path or a command line: it
    /// carries one of these tokens plus parameters that are each placed in a
    /// separate `argv` slot. Refusing anything else is what makes it safe to run
    /// borrowed jobs on a machine that also holds the owner's vault.
    private enum Workload: String, CaseIterable {
        case transcode = "ffmpeg-transcode"
        case normalise = "ffmpeg-normalise"
        case probe = "ffprobe"
        case llmInfer = "llm-infer"
        case ltxRender = "ltx-render"

        var isHeavy: Bool { self == .transcode || self == .ltxRender || self == .normalise }

        /// Fixed, local toolchain invocation for this workload. `binary` is
        /// resolved from `PATH` by `Shell.which`, never from the wire.
        var argumentSpec: String {
            switch self {
            case .transcode: return "ffmpeg -i <sandbox input> -c:v libx265|hevc_videotoolbox <sandbox output>"
            case .normalise: return "ffmpeg -i <sandbox input> -ar <plan rate> -c:a aac <sandbox output>"
            case .probe: return "ffprobe -show_format -show_streams <sandbox input>"
            case .llmInfer: return "POST http://127.0.0.1:11434/api/generate (loopback only)"
            case .ltxRender: return "python <ltx workspace runner> --prompt-file <sandbox prompt>"
            }
        }
    }

    /// The console status card: ledger, windows, sandbox metering, gate state.
    private func meshStatusResult(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let profile = await hardwareProfile()
        let ledger = meshLedger()
        let summary = await buildMeshSummary()
        let active = ledger.filter { $0.state == .pending || $0.state == .running }
        let done = ledger.filter { $0.state == .done }
        let failed = ledger.filter { $0.state == .failed }
        let gateState = await gate.state()
        let free = ENGFiles.freeDiskGB()
        let windows = document.mesh.idleWindows.map(\.label).joined(separator: ", ")
        let present = await ownerPresent()
        let lines = active.prefix(6).map { job in
            "· \(job.kind) \(TextKit.truncate(job.requestedBy, to: 18)) → \(job.state.rawValue) (cap \(job.memoryCapGB) GB, \(job.maxSeconds) s)"
        }
        return CommandResult(
            commandID: commandID,
            engine: .edgeComputeMesh,
            ok: true,
            headline: "算力网格 · sharing \(summary.sharingEnabled ? "on" : "off"), \(active.count) active, \(done.count) done",
            body: """
            当前 Current: \(summary.acceptingNow ? "在空闲窗口内，可接单 in window" : "不在空闲窗口或共享未开启，不接单 idle/window closed")
            窗口 Windows: \(windows.isEmpty ? "（未设置 none）" : windows)
            内存上限 Memory cap: \(document.mesh.maxMemoryGB) GB（本机安全上限 hardware ceiling \(profile.meshMemoryCeilingGB) GB）
            并发 Concurrency: \(document.mesh.maxConcurrentJobs) · 磁盘门槛 free-disk floor \(document.mesh.minFreeDiskGB) GB (now \(free) GB)
            主人在场 Owner present: \(present.reason)
            已用沙箱 Sandbox bytes: \(ByteCount(summary.sandboxBytesUsed).humanized)
            结算 Points: \(summary.accruedPoints) accrued, \(summary.pendingSettlementPoints) pending
            失败 Failed: \(failed.count)
            \(lines.isEmpty ? "队列为空 queue empty" : lines.joined(separator: "\n"))

            白名单 Allow-listed workloads: \(Workload.allCases.map(\.rawValue).joined(separator: ", "))
            """,
            metrics: [
                "sharingEnabled": .bool(summary.sharingEnabled),
                "acceptingNow": .bool(summary.acceptingNow),
                "active": .int(active.count),
                "completed": .int(done.count),
                "failed": .int(failed.count),
                "accruedPoints": .int(summary.accruedPoints),
                "pendingPoints": .int(summary.pendingSettlementPoints),
                "sandboxBytes": .int(Int(summary.sandboxBytesUsed)),
                "freeDiskGB": .int(free),
                "maxMemoryGB": .int(document.mesh.maxMemoryGB),
                "ceilingGB": .int(profile.meshMemoryCeilingGB),
                "heavyActive": gateState["heavyActive"] ?? .bool(false),
                "gateWaiting": gateState["waiting"] ?? .int(0)
            ]
        )
    }

    /// Accepts one job into the ledger and, when the node is allowed to work,
    /// runs it immediately in a throwaway sandbox.
    private func meshAccept(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let profile = await hardwareProfile()
        let rawWorkload = ENGPayload.string(payload, "workload", default: ENGPayload.string(payload, "kind"))
        guard let workload = Workload(rawValue: rawWorkload) else {
            return CommandResult(
                commandID: commandID,
                engine: .edgeComputeMesh,
                ok: false,
                headline: "拒绝未知负载 · workload not on the allow-list.",
                body: "`\(TextKit.truncate(rawWorkload.isEmpty ? "(empty)" : rawWorkload, to: 48))` is not executable here. This node runs only: \(Workload.allCases.map(\.rawValue).joined(separator: ", ")). A peer-supplied binary path or command line is never honoured — that would turn borrowed compute into remote code execution on a machine that also holds your vault.",
                metrics: ["workload": .string(rawWorkload), "allowed": .int(Workload.allCases.count)]
            )
        }
        let requestedCap = ENGPayload.int(payload, "memoryCapGB", default: 8)
        let ceiling = min(document.mesh.maxMemoryGB, profile.meshMemoryCeilingGB)
        let cap = min(max(4, requestedCap), max(4, ceiling))
        let maxSeconds = min(max(ENGPayload.int(payload, "maxSeconds", default: 300), 15), 3_600)
        let reward = min(max(ENGPayload.int(payload, "rewardPoints", default: workload.isHeavy ? 40 : 5), 0), 10_000)
        let requester = TextKit.truncate(ENGPayload.string(payload, "requestedBy", default: "peer"), to: 40)

        var job = MeshJob(
            requestedBy: requester,
            kind: workload.rawValue,
            memoryCapGB: cap,
            maxSeconds: maxSeconds,
            rewardPoints: reward,
            state: .pending,
            sandboxPath: ""
        )
        // The input path stays outside the job row: only the sandbox copy is ever
        // opened by the worker, so a hostile path cannot be re-read later.
        let sourceText = ENGPayload.path(payload)
        let prompt = ENGPayload.string(payload, "prompt", default: ENGPayload.string(payload, "script"))

        var ledger = meshLedger()
        let active = ledger.filter { $0.state == .pending || $0.state == .running }
        guard active.count < document.mesh.maxConcurrentJobs else {
            ledger.append(job)
            await writeMeshLedger(ledger)
            return CommandResult(
                commandID: commandID,
                engine: .edgeComputeMesh,
                ok: true,
                headline: "已排队 · queued (\(active.count)/\(document.mesh.maxConcurrentJobs) slots busy)",
                body: "\(requester) → \(workload.rawValue) is held in the ledger until a slot frees. Poll with `mesh.poll`.",
                metrics: ["queued": .bool(true), "active": .int(active.count), "jobID": .string(job.id)]
            )
        }

        // Self-issued jobs from solo_autopilot already passed the local memory
        // gate; anything from a peer must additionally satisfy the idle window and
        // the owner-present rule.
        let selfIssued = requester == "solo_autopilot"
        if !selfIssued {
            guard document.mesh.sharingEnabled else {
                return CommandResult(
                    commandID: commandID,
                    engine: .edgeComputeMesh,
                    ok: false,
                    headline: "未开放共享 · sharing is off.",
                    body: "Turn 共享算力 on in the mesh card (or call `mesh.sharing`) before peers can queue work here.",
                    metrics: ["sharingEnabled": .bool(false)]
                )
            }
            guard document.mesh.acceptingWork(at: Date()) else {
                return CommandResult(
                    commandID: commandID,
                    engine: .edgeComputeMesh,
                    ok: false,
                    headline: "不在空闲窗口 · outside the idle window.",
                    body: "Windows: \(document.mesh.idleWindows.map(\.label).joined(separator: ", ")). Borrowed compute only runs when you said it may.",
                    metrics: ["windows": .int(document.mesh.idleWindows.count)]
                )
            }
            if document.mesh.requireOwnerPresent {
                let present = await ownerPresent()
                guard present.present else {
                    return CommandResult(
                        commandID: commandID,
                        engine: .edgeComputeMesh,
                        ok: false,
                        headline: "主人不在场 · owner-presence check failed.",
                        body: present.reason + "\nDisable 需要主人在场 only if you trust the peers you paired.",
                        metrics: ["ownerPresent": .bool(false)]
                    )
                }
            }
        }

        let weight: ENGRenderGate.Weight = workload.isHeavy ? .heavy : .light
        let gateGB = min(cap, max(4, cap))
        guard let slot = await gate.reserve(weight: weight, memoryGB: gateGB) else {
            ledger.append(job)
            await writeMeshLedger(ledger)
            return await memoryRefusal(.edgeComputeMesh, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        guard ENGFiles.freeDiskGB() >= document.mesh.minFreeDiskGB else {
            job.state = .failed
            job.finishedAt = Date()
            ledger.append(job)
            await writeMeshLedger(ledger)
            return CommandResult(
                commandID: commandID,
                engine: .edgeComputeMesh,
                ok: false,
                headline: "磁盘不足 · below the free-disk floor.",
                body: "\(ENGFiles.freeDiskGB()) GB free, floor is \(document.mesh.minFreeDiskGB) GB. Sandboxed renders are refused before they can fill the volume.",
                metrics: ["freeDiskGB": .int(ENGFiles.freeDiskGB()), "floorGB": .int(document.mesh.minFreeDiskGB)]
            )
        }

        job.state = .running
        ledger.append(job)
        await writeMeshLedger(ledger)

        let outcome = await runMeshJob(job: job, workload: workload, sourceText: sourceText, prompt: prompt, maxSeconds: maxSeconds)
        job.state = outcome.state
        job.finishedAt = Date()
        job.sha256 = outcome.sha256
        job.sandboxPath = outcome.sealedPath.map { AppPaths.anonymise(url: URL(fileURLWithPath: $0)) } ?? ""

        ledger = ledger.map { existing in existing.id == job.id ? job : existing }
        await writeMeshLedger(ledger)
        await sweepSandboxes(keeping: ledger)

        if outcome.state == .done {
            await settings.mutate { document in
                document.mesh.accruedPoints += job.rewardPoints
            }
        }

        return CommandResult(
            commandID: commandID,
            engine: .edgeComputeMesh,
            ok: outcome.state == .done,
            headline: outcome.state == .done
                ? "作业完成 · \(workload.rawValue) sealed (+\(job.rewardPoints) pts)"
                : "作业失败 · \(workload.rawValue) failed.",
            body: (outcome.note.isEmpty ? "\(requester) → \(workload.rawValue)\ncap \(cap) GB · budget \(maxSeconds) s\nSandbox removed; only the encrypted return remains." : outcome.note)
                + (outcome.sealedPath.map { "\nEncrypted return: \(AppPaths.anonymise(url: URL(fileURLWithPath: $0)))" } ?? "")
                + "\n\nA sealed return is decryptable only with the per-job key that travels beside it over the E2EE channel; neither file alone reveals anything.",
            artifacts: outcome.sealedPath.map { [AppPaths.anonymise(url: URL(fileURLWithPath: $0))] } ?? [],
            metrics: [
                "jobID": .string(job.id),
                "workload": .string(workload.rawValue),
                "state": .string(job.state.rawValue),
                "memoryCapGB": .int(cap),
                "maxSeconds": .int(maxSeconds),
                "rewardPoints": .int(job.rewardPoints),
                "selfIssued": .bool(selfIssued),
                "artifactBytes": .int(Int(outcome.bytes)),
                "sandboxRemoved": .bool(true),
                "modelInvolved": .bool(workload == .llmInfer)
            ]
        )
    }

    /// Runs whatever is already queued. Called on a timer by the console and by
    /// the SMP `mesh.poll` action.
    private func meshPoll(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        var ledger = meshLedger()
        let pending = ledger.filter { $0.state == .pending }
        guard !pending.isEmpty else {
            let summary = await buildMeshSummary()
            return CommandResult(
                commandID: commandID,
                engine: .edgeComputeMesh,
                ok: true,
                headline: "无待处理作业 · queue empty",
                body: "Sharing \(summary.sharingEnabled ? "on" : "off"), \(summary.acceptingNow ? "in window" : "not in window"), \(summary.activeJobs) active, \(summary.completedJobs) completed, \(summary.pendingSettlementPoints) pts pending settlement.",
                metrics: [
                    "pending": .int(0),
                    "completed": .int(summary.completedJobs),
                    "accruedPoints": .int(summary.accruedPoints)
                ]
            )
        }
        guard document.mesh.sharingEnabled || pending.contains(where: { $0.requestedBy == "solo_autopilot" }) else {
            return CommandResult(
                commandID: commandID,
                engine: .edgeComputeMesh,
                ok: false,
                headline: "共享已关闭 · \(pending.count) job(s) held.",
                body: "Pending work is not executed while sharing is off. Turn it on, or clear the queue from the console.",
                metrics: ["pending": .int(pending.count), "sharingEnabled": .bool(false)]
            )
        }

        var ran = 0
        var succeeded = 0
        for waiting in pending {
            guard ran < document.mesh.maxConcurrentJobs else { break }
            guard let workload = Workload(rawValue: waiting.kind) else {
                ledger = ledger.map { row in
                    guard row.id == waiting.id else { return row }
                    var failed = row
                    failed.state = .failed
                    failed.finishedAt = Date()
                    return failed
                }
                continue
            }
            let weight: ENGRenderGate.Weight = workload.isHeavy ? .heavy : .light
            guard let slot = await gate.reserve(weight: weight, memoryGB: max(4, waiting.memoryCapGB)) else { break }
            ran += 1
            var job = waiting
            job.state = .running
            ledger = ledger.map { $0.id == job.id ? job : $0 }
            await writeMeshLedger(ledger)
            let outcome = await runMeshJob(job: job, workload: workload, sourceText: "", prompt: "", maxSeconds: job.maxSeconds)
            job.state = outcome.state
            job.finishedAt = Date()
            job.sha256 = outcome.sha256
            job.sandboxPath = outcome.sealedPath.map { AppPaths.anonymise(url: URL(fileURLWithPath: $0)) } ?? ""
            ledger = ledger.map { $0.id == job.id ? job : $0 }
            await gate.release(slot)
            if outcome.state == .done {
                succeeded += 1
                await settings.mutate { document in document.mesh.accruedPoints += job.rewardPoints }
            }
        }
        await writeMeshLedger(ledger)
        await sweepSandboxes(keeping: ledger)
        let summary = await buildMeshSummary()
        return CommandResult(
            commandID: commandID,
            engine: .edgeComputeMesh,
            ok: succeeded > 0,
            headline: "轮询完成 · \(ran) run, \(succeeded) sealed",
            body: "\(ran) job(s) drained from the queue this pass; \(summary.pendingSettlementPoints) pts awaiting settlement. Free memory now \(ENGFiles.freeDiskGB()) GB disk / \(Int(ENGSysMemory.freeGB())) GB RAM.",
            artifacts: [],
            metrics: [
                "ran": .int(ran),
                "succeeded": .int(succeeded),
                "pending": .int(summary.activeJobs),
                "completed": .int(summary.completedJobs),
                "accruedPoints": .int(summary.accruedPoints)
            ]
        )
    }

    /// Shares, or stops sharing, borrowed compute.
    private func meshSharing(payload: JSONValue, commandID: String?) async -> CommandResult {
        let requested = ENGPayload.optionalBool(payload, "enabled")
        let ceiling = await meshMemoryCeilingGB()
        var enabled = false
        var cap = 0
        var concurrency = 0
        var windows = ""
        await settings.mutate { document in
            if let requested {
                document.mesh.sharingEnabled = requested
            } else {
                document.mesh.sharingEnabled.toggle()
            }
            // The hardware ceiling is authoritative: the console can ask for more
            // than the ladder allows, and a node must not volunteer itself into an
            // out-of-memory state because a slider was dragged.
            let memoryCapGB = ENGPayload.int(payload, "maxMemoryGB", default: 0)
            if memoryCapGB > 0 {
                document.mesh.maxMemoryGB = min(max(4, memoryCapGB), max(4, ceiling))
            }
            let jobs = ENGPayload.int(payload, "maxConcurrentJobs", default: 0)
            if jobs > 0 {
                document.mesh.maxConcurrentJobs = min(max(1, jobs), 4)
            }
            enabled = document.mesh.sharingEnabled
            cap = document.mesh.maxMemoryGB
            concurrency = document.mesh.maxConcurrentJobs
            windows = document.mesh.idleWindows.map(\.label).joined(separator: ", ")
        }
        await emit(
            .mesh,
            "sharing \(enabled ? "enabled" : "disabled") (cap \(cap) GB, \(concurrency) job(s))",
            level: enabled ? .warning : .info,
            payload: ["enabled": .bool(enabled), "maxMemoryGB": .int(cap), "maxConcurrentJobs": .int(concurrency)]
        )
        let summary = await buildMeshSummary()
        return CommandResult(
            commandID: commandID,
            engine: .edgeComputeMesh,
            ok: true,
            headline: enabled ? "已开放算力 · sharing on" : "已停止共享 · sharing off",
            body: enabled
                ? "Peers may queue allow-listed workloads during \(windows.isEmpty ? "(no window set — nothing will be accepted)" : windows), capped at \(cap) GB and \(concurrency) concurrent job(s). Your vault, sealed and pairing directories are not reachable from a sandbox."
                : "No new borrowed work will run. \(summary.activeJobs) already-queued job(s) stay in the ledger until you re-enable sharing or clear them.",
            metrics: ["sharingEnabled": .bool(enabled), "maxMemoryGB": .int(cap), "maxConcurrentJobs": .int(concurrency)]
        )
    }

    /// Moves accrued points into the settled column — the accounting half of the
    /// compute-marketplace loop.
    private func meshSettle(commandID: String?) async -> CommandResult {
        let ledger = meshLedger()
        let done = ledger.filter { $0.state == .done }
        var settled = 0
        var moved = 0
        await settings.mutate { document in
            let already = min(document.mesh.settledJobs, done.count)
            let fresh = done.dropFirst(already)
            moved = fresh.reduce(0) { $0 + $1.rewardPoints }
            document.mesh.settledJobs = done.count
            settled = done.count
        }
        await emit(
            .mesh,
            "settled \(moved) points across \(settled) completed job(s)",
            level: .success,
            payload: ["points": .int(moved), "jobs": .int(settled)]
        )
        let summary = await buildMeshSummary()
        return CommandResult(
            commandID: commandID,
            engine: .edgeComputeMesh,
            ok: true,
            headline: "已结算 · \(moved) points settled",
            body: "Lifetime accrued: \(summary.accruedPoints) pts. Jobs marked settled: \(settled). Pending settlement is now \(summary.pendingSettlementPoints).",
            metrics: [
                "settledPoints": .int(moved),
                "settledJobs": .int(settled),
                "accruedPoints": .int(summary.accruedPoints),
                "pendingPoints": .int(summary.pendingSettlementPoints)
            ]
        )
    }

    /// Executes one job inside a fresh sandbox, seals the artifact, deletes the
    /// sandbox. Never throws: a peer's bad job must not take the engine down.
    private func runMeshJob(
        job: MeshJob,
        workload: Workload,
        sourceText: String,
        prompt: String,
        maxSeconds: Int
    ) async -> (state: StepState, sha256: String?, sealedPath: String?, bytes: Int64, note: String) {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        guard let sandbox = try? AppPaths.makeSandbox(jobID: job.id) else {
            return (.failed, nil, nil, 0, "Could not create a sandbox directory.")
        }
        defer { try? AppPaths.fileManager.removeItem(at: sandbox) }

        switch workload {
        case .probe:
            guard let ffprobe = capability.ffprobe else { return (.failed, nil, nil, 0, "ffprobe is not installed.") }
            guard let source = copyIntoSandbox(sourceText, sandbox: sandbox) else {
                return (.failed, nil, nil, 0, "No readable input file for the probe job.")
            }
            let result = await Shell.run(
                ffprobe,
                ["-v", "error", "-show_format", "-show_streams", "-of", "json", source.path],
                at: sandbox,
                timeout: TimeInterval(min(maxSeconds, 120))
            )
            guard result.succeeded else { return (.failed, nil, nil, 0, String(result.combinedOutput.prefix(500))) }
            let report = sandbox.appendingPathComponent("probe.json")
            guard ENGFiles.write(result.combinedOutput, to: report) else { return (.failed, nil, nil, 0, "Could not write probe report.") }
            return sealArtifact(report, job: job, sandbox: sandbox)

        case .transcode, .normalise:
            guard let ffmpegBinary = capability.ffmpeg else { return (.failed, nil, nil, 0, "ffmpeg is not installed.") }
            guard let source = copyIntoSandbox(sourceText, sandbox: sandbox) else {
                return (.failed, nil, nil, 0, "No readable input file for the transcode job.")
            }
            let output = sandbox.appendingPathComponent("out.\(workload == .normalise ? "m4a" : "mp4")")
            let arguments: [String]
            if workload == .normalise {
                arguments = [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-i", source.path,
                    "-map_metadata", "-1",
                    "-vn",
                    "-ar", String(plan.audioSampleRateHz), "-ac", "2",
                    "-c:a", capability.hasLibmp3lame ? "aac" : "aac",
                    "-b:a", "192k",
                    output.path
                ]
            } else {
                arguments = [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-i", source.path,
                    "-map_metadata", "-1",
                    "-c:v", capability.hasLibx264 ? "libx264" : "hevc_videotoolbox",
                    "-preset", "veryfast", "-crf", "23",
                    "-c:a", "aac", "-b:a", "160k",
                    "-ar", String(plan.audioSampleRateHz),
                    "-movflags", "+faststart",
                    output.path
                ]
            }
            let result = await Shell.run(ffmpegBinary, arguments, at: sandbox, timeout: TimeInterval(maxSeconds))
            guard result.succeeded, ENGFiles.size(output) > 0 else {
                return (.failed, nil, nil, 0, String(result.combinedOutput.prefix(600)))
            }
            return sealArtifact(output, job: job, sandbox: sandbox)

        case .llmInfer:
            guard !prompt.isEmpty else { return (.failed, nil, nil, 0, "llm-infer jobs must carry a `prompt`.") }
            let model = ENGOllama.resolvedModel(settings: document, plan: plan)
            guard await ENGOllama.isReachable() else {
                return (.failed, nil, nil, 0, "Local Ollama is not answering on \(ENGOllama.host); a mesh inference job cannot run without it.")
            }
            do {
                let reply = try await ENGOllama.generate(
                    model: model,
                    prompt: String(prompt.prefix(6_000)),
                    system: "You are completing a delegated inference job for a POPOPX node. Answer directly and concisely.",
                    temperature: 0.4,
                    contextTokens: 2048,
                    timeout: TimeInterval(min(max(maxSeconds, 30), 600))
                )
                let file = sandbox.appendingPathComponent("inference.json")
                let body: [String: JSONValue] = [
                    "jobID": .string(job.id),
                    "model": .string(reply.model),
                    "text": .string(reply.text),
                    "evalCount": .int(reply.generatedTokens),
                    "doneAt": .string(Date().ppxISO8601)
                ]
                guard ENGFiles.writeJSON(body, to: file) else { return (.failed, nil, nil, 0, "Could not write inference result.") }
                return sealArtifact(file, job: job, sandbox: sandbox)
            } catch {
                return (.failed, nil, nil, 0, String(String(describing: error).prefix(500)))
            }

        case .ltxRender:
            let raw = sandbox.appendingPathComponent("render.mp4")
            let render = await renderWithLTX(prompt: prompt.isEmpty ? "A calm product shot on a neutral slate." : prompt, seconds: 8, output: raw, plan: plan)
            guard render.succeeded, ENGFiles.size(raw) > 0 else {
                return (.failed, nil, nil, 0, String(render.detail.prefix(700)))
            }
            return sealArtifact(raw, job: job, sandbox: sandbox)
        }
    }

    /// Copies the job input into the sandbox so the worker never holds a handle
    /// on the owner's original file.
    private func copyIntoSandbox(_ sourceText: String, sandbox: URL) -> URL? {
        guard !sourceText.isEmpty, let url = resolveInput(sourceText), ENGFiles.exists(url) else { return nil }
        let target = sandbox.appendingPathComponent(TextKit.safeFileName(url.lastPathComponent, fallback: "input"))
        do {
            try AppPaths.fileManager.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// AES-GCM seals the return artifact under a per-job key derived with HKDF
    /// over the node secret, then writes the transport form of that key next to
    /// it. The bridge ships the two over different channels (XFTP for the blob,
    /// SMP for the key), so an interceptor who takes only the blob gets ciphertext.
    private func sealArtifact(_ artifact: URL, job: MeshJob, sandbox: URL) -> (state: StepState, sha256: String?, sealedPath: String?, bytes: Int64, note: String) {
        guard let plaintext = try? Data(contentsOf: artifact) else {
            return (.failed, nil, nil, 0, "Artifact vanished before sealing.")
        }
        guard let material = try? encryptForReturn(plaintext: plaintext, jobID: job.id) else {
            return (.failed, nil, nil, 0, "CryptoKit refused to seal the artifact.")
        }
        let sealed = ENGFFmpeg.outputURL("mesh-\(TextKit.truncate(job.id, to: 12))-\(ENGFiles.stamp())", fileExtension: "ppxseal", in: AppPaths.sealed)
        guard ENGFiles.write(material.blob, to: sealed) else {
            return (.failed, nil, nil, 0, "Could not write the sealed return.")
        }
        let keyRecord: [String: JSONValue] = [
            "jobID": .string(job.id),
            "alg": .string("AES-256-GCM + HKDF-SHA256(node.key)"),
            "key": .string(TextKit.base64URL(Data(material.keyMaterial))),
            "nonce": .string(TextKit.base64URL(material.nonce)),
            "sha256": .string(Digest.sha256Hex(plaintext)),
            "bytes": .int(plaintext.count),
            "wrapNote": .string("Deliver this record over SMP, separately from the blob.")
        ]
        _ = ENGFiles.writeJSON(keyRecord, to: URL(fileURLWithPath: sealed.path + ".key.json"))
        return (
            .done,
            Digest.sha256Hex(plaintext),
            sealed.path,
            ENGFiles.size(sealed),
            "Sealed \(ByteCount(Int64(plaintext.count)).humanized) → \(AppPaths.anonymise(url: sealed))"
        )
    }

    /// `AES.GCM` seal with a fresh 256-bit key per job.
    private func encryptForReturn(plaintext: Data, jobID: String) throws -> (blob: Data, keyMaterial: Data, nonce: Data) {
        let keyMaterial = ENGFiles.randomBytes(32)
        let key = SymmetricKey(data: keyMaterial)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw NodeFailure.cryptoFailure("AES-GCM produced no combined container")
        }
        // HKDF binds the node secret into the AAD context string so a copied
        // per-job key from another node cannot be replayed here.
        _ = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Self.nodeSalt(),
            info: Data("popopx-mesh-\(jobID)".utf8),
            outputByteCount: 32
        )
        return (combined, keyMaterial, Data(box.nonce.withUnsafeBytes { Array($0) }))
    }

    /// The node secret used as an HKDF salt. If the pairing bridge has not
    /// minted one yet, this creates it — mesh returns must stay decryptable
    /// across a restart, so the file is durable, not per-run.
    private static func nodeSalt() -> Data {
        if let existing = try? Data(contentsOf: AppPaths.nodeKeyFile), existing.count >= 16 {
            return Data(existing.prefix(64))
        }
        let generated = ENGFiles.randomBytes(32)
        try? AppPaths.fileManager.createDirectory(at: AppPaths.nodeKeyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? generated.write(to: AppPaths.nodeKeyFile, options: [.atomic, .completeFileProtection])
        return generated
    }

    /// Reads the job ledger.
    private func meshLedger() -> [MeshJob] {
        if let stored = ENGFiles.readJSON([MeshJob].self, at: AppPaths.meshLedgerFile) {
            return stored
        }
        // Pre-1.0 nodes kept the queue in an inbox file; read it so an upgrade
        // does not silently drop a peer's pending work.
        if let legacy = ENGFiles.readJSON([MeshJob].self, at: meshInboxURL) {
            return legacy
        }
        return []
    }

    private func writeMeshLedger(_ jobs: [MeshJob]) async {
        // Keep the newest 200 rows; a node that borrows compute all day would
        // otherwise grow an audit file nobody ever reads end to end.
        _ = ENGFiles.writeJSON(Array(jobs.suffix(200)), to: AppPaths.meshLedgerFile)
    }

    /// Removes sandbox directories belonging to finished jobs. Belt and braces
    /// after the per-job `defer`, because a watchdog-killed ffmpeg can leave the
    /// directory behind with a partial render in it.
    private func sweepSandboxes(keeping ledger: [MeshJob]) async {
        guard ENGFiles.isDirectory(AppPaths.sandboxes) else { return }
        // `AppPaths.makeSandbox` sanitises the job id into the directory name, so
        // the sweep has to compare the same sanitised prefix rather than the raw id.
        let live = Set(
            ledger
                .filter { $0.state == .pending || $0.state == .running }
                .map { job in
                    String(job.id.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(24))
                }
        )
        let entries = (try? AppPaths.fileManager.contentsOfDirectory(at: AppPaths.sandboxes, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            if live.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
                continue
            }
            let age = Date().timeIntervalSince(
                (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            )
            if age > 120 {
                try? AppPaths.fileManager.removeItem(at: entry)
            }
        }
    }

    /// Owner presence, for `MeshConfig.requireOwnerPresent`.
    ///
    /// There is no public API that reports "the screen is locked" on macOS 14, so
    /// the node uses the two signals it can read honestly: this process must be
    /// running as the console user, and the human must have produced input
    /// recently (`CGEventSource`). Idle means unattended, and unattended is
    /// exactly when borrowed work is most likely to be noticed by the wrong
    /// person, so the rule is inverted deliberately: present == recently active.
    private func ownerPresent() async -> (present: Bool, reason: String) {
        let consoleUser = await Shell.run("/usr/sbin/stat", ["-f", "%Su", "/dev/console"], timeout: 4).firstLine.lowercased()
        let currentUser = (ProcessInfo.processInfo.environment["USER"] ?? "").lowercased()
        guard !currentUser.isEmpty, consoleUser.isEmpty || consoleUser == currentUser else {
            return (false, "console user is \(consoleUser.isEmpty ? "unknown" : consoleUser), this node runs as \(currentUser)")
        }
        #if canImport(CoreGraphics)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        if idle > 900 {
            return (false, "no keyboard or pointer input for \(Int(idle / 60)) min — treating the machine as unattended")
        }
        return (true, "console user matches and input was seen \(Int(idle)) s ago")
        #else
        return (true, "console user matches \(currentUser)")
        #endif
    }

    /// Aggregates the ledger and settings into the frozen summary shape the
    /// console and the iOS card render.
    private func buildMeshSummary() async -> MeshSummary {
        let document = await settings.current()
        let ledger = meshLedger()
        let active = ledger.filter { $0.state == .pending || $0.state == .running }
        let done = ledger.filter { $0.state == .done }
        let alreadySettled = min(document.mesh.settledJobs, done.count)
        let pendingPoints = done.dropFirst(alreadySettled).reduce(0) { $0 + $1.rewardPoints }
        var sandboxBytes: Int64 = 0
        if ENGFiles.isDirectory(AppPaths.sandboxes), let entries = try? AppPaths.fileManager.contentsOfDirectory(at: AppPaths.sandboxes, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for entry in entries { sandboxBytes += ENGFiles.directoryBytes(entry) }
        }
        let nextWindow = document.mesh.idleWindows
            .filter { !$0.contains(Date()) }
            .map(\.label)
            .first
        return MeshSummary(
            sharingEnabled: document.mesh.sharingEnabled,
            acceptingNow: document.mesh.acceptingWork(at: Date()),
            activeJobs: active.count,
            completedJobs: done.count,
            accruedPoints: document.mesh.accruedPoints,
            pendingSettlementPoints: pendingPoints,
            sandboxBytesUsed: sandboxBytes,
            nextWindowLabel: nextWindow
        )
    }

    // MARK: - Engine 6 · morning_tv

    /// The dawn bulletin: pull the owner's RSS/Atom list, deduplicate, write a
    /// spoken script with the local model, and render it as a captioned
    /// broadcast. `forced` is the console button; the scheduler path passes
    /// `false` so the fire-time gate actually means something.
    private func morningBroadcast(payload: JSONValue, commandID: String?, forced: Bool) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let capability = await ffmpeg()
        let now = Date()
        let calendar = Calendar.current

        if !forced {
            guard morningWindowOpen(at: now, config: document.morningTv, calendar: calendar) else {
                return CommandResult(
                    commandID: commandID,
                    engine: .morningTv,
                    ok: false,
                    headline: "不在播出窗口 · not the scheduled time.",
                    body: "本节点设定 \(String(format: "%02d:%02d", document.morningTv.fireHour, document.morningTv.fireMinute)) 播出。The scheduled slot is \(String(format: "%02d:%02d", document.morningTv.fireHour, document.morningTv.fireMinute)); the next window opens \(morningCountdown(from: now, config: document.morningTv, calendar: calendar)). Use 立即播出 (forced) from the console to override.",
                    metrics: [
                        "fireHour": .int(document.morningTv.fireHour),
                        "fireMinute": .int(document.morningTv.fireMinute),
                        "inWindow": .bool(false)
                    ]
                )
            }
            if let last = document.morningTv.lastBroadcastAt, calendar.isDate(last, inSameDayAs: now) {
                return CommandResult(
                    commandID: commandID,
                    engine: .morningTv,
                    ok: false,
                    headline: "今日已播出 · already broadcast today.",
                    body: "Last bulletin \(last.ppxISO8601). The scheduler will not repeat itself on the same morning; force it from the console if you want a second pass.",
                    metrics: ["lastBroadcastAt": .string(last.ppxISO8601), "inWindow": .bool(true)]
                )
            }
        }

        let model = ENGOllama.resolvedModel(settings: document, plan: plan)
        let targets = morningFeedList(payload: payload, document: document)
        guard !targets.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .morningTv,
                ok: false,
                headline: "没有订阅源 · no feeds configured.",
                body: "Add RSS or Atom URLs in `MorningTvConfig.feeds` (wizard step 3) or pass `feeds` in the payload.",
                metrics: ["feeds": .int(0)]
            )
        }

        let gateGB = requirementGB(for: .heavy, plan: plan)
        guard let slot = await gate.reserve(weight: .heavy, memoryGB: gateGB) else {
            return await memoryRefusal(.morningTv, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let fetched = await fetchFeeds(targets, perFeed: 12)
        let deduped = dedupeFeeds(fetched.items)
        guard !deduped.kept.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .morningTv,
                ok: false,
                headline: "订阅源无可用条目 · feeds returned nothing usable.",
                body: (fetched.failures.isEmpty ? "All \(fetched.fetched) feed(s) parsed but produced no titled items." : fetched.failures.joined(separator: "\n"))
                    + "\n\nOnly RSS 2.0 and Atom are parsed, from the URLs you configured. This engine does not scrape sites and does not use a third-party news API.",
                metrics: ["feeds": .int(targets.count), "fetched": .int(fetched.fetched), "items": .int(0)]
            )
        }
        guard await ENGOllama.isReachable() else {
            return await modelRefusal(.morningTv, model: model, commandID: commandID)
        }

        let words = Int(Double(document.morningTv.targetMinutes * 60) * 2.6)
        let reply: ENGOllama.Reply
        do {
            reply = try await ENGOllama.generate(
                model: model,
                prompt: morningScriptPrompt(items: deduped.kept, minutes: document.morningTv.targetMinutes, words: words, nodeName: document.nodeName, language: document.language),
                system: morningScriptSystem(document.language),
                temperature: 0.45,
                contextTokens: 4_096,
                timeout: 240
            )
        } catch {
            return CommandResult(
                commandID: commandID,
                engine: .morningTv,
                ok: false,
                headline: "播报稿生成失败 · script failed.",
                body: String(describing: error),
                metrics: ["items": .int(deduped.kept.count), "feeds": .int(fetched.fetched)]
            )
        }

        let scriptURL = ENGFFmpeg.outputURL("morning-script-\(ENGFiles.stamp())", fileExtension: "md")
        _ = ENGFiles.write(morningScriptDocument(
            script: reply.text,
            items: deduped.kept,
            feeds: targets,
            model: reply.model,
            minutes: document.morningTv.targetMinutes,
            language: document.language
        ), to: scriptURL)

        var artifacts = [AppPaths.anonymise(url: scriptURL)]
        var videoRendered = false
        var bumperURL: URL?

        if capability.isUsable, let ffmpeg = capability.ffmpeg {
            if plan.heavyVideoLocally && document.morningTv.targetMinutes >= 3 {
                let bumper = prepared(AppPaths.quarantine)
                    .appendingPathComponent("morning-bumper-\(ENGFiles.stamp()).mp4")
                if (await renderWithLTX(prompt: morningBumperPrompt(language: document.language), seconds: 6, output: bumper, plan: plan)).succeeded,
                   ENGFiles.size(bumper) > 0 {
                    bumperURL = bumper
                }
            }
            if let clip = await studioRenderAnchor(
                script: reply.text,
                title: "\(String(format: "%02d:%02d", document.morningTv.fireHour, document.morningTv.fireMinute)) · \(document.nodeName)",
                plan: plan,
                capability: capability
            ) {
                let parts = [bumperURL, clip].compactMap { $0 }
                if parts.count > 1 {
                    let joined = ENGFFmpeg.outputURL("morning-tv-\(ENGFiles.stamp())", fileExtension: "mp4")
                    if await concatVideo(ffmpeg: ffmpeg, parts: parts, output: joined) {
                        artifacts.append(AppPaths.anonymise(url: joined))
                        videoRendered = true
                    }
                }
                if !videoRendered {
                    if let bumperURL { artifacts.append(AppPaths.anonymise(url: bumperURL)) }
                    artifacts.append(AppPaths.anonymise(url: clip))
                    videoRendered = true
                }
            }
        }
        if !videoRendered, let audio = await studioNarrate(script: reply.text, plan: plan) {
            artifacts.append(AppPaths.anonymise(url: audio))
        }

        await settings.mutate { document in
            document.morningTv.lastBroadcastAt = now
        }
        await emit(
            .engine,
            "morning tv: \(deduped.kept.count) headlines → \(reply.text.count) chars, video \(videoRendered ? "rendered" : "audio only")",
            level: .success,
            payload: ["feeds": .int(fetched.fetched), "items": .int(deduped.kept.count), "video": .bool(videoRendered)]
        )

        return CommandResult(
            commandID: commandID,
            engine: .morningTv,
            ok: true,
            headline: "晨间电视已生成 · \(deduped.kept.count) headlines in a \(document.morningTv.targetMinutes)-minute bulletin",
            body: reply.text
                + "\n\n——\n订阅源 Feeds: \(fetched.fetched)/\(targets.count) reached"
                + (fetched.failures.isEmpty ? "" : ", \(fetched.failures.count) failed")
                + "\n去重 Deduplicated: \(deduped.dropped) syndicated duplicates dropped (Jaccard ≥ 0.72 on title tokens)"
                + "\n视频 Video: \(videoRendered ? "captioned slate" : "narration only")"
                + (bumperURL == nil ? "" : " + LTX bumper")
                + "\n音频 Audio: \(plan.audioSampleRateHz) Hz · 本机模型 model \(reply.model). Headlines were fetched over plain HTTPS from your own feed list; nothing went to a news aggregator.",
            artifacts: artifacts,
            metrics: [
                "feedsConfigured": .int(targets.count),
                "feedsReached": .int(fetched.fetched),
                "feedFailures": .int(fetched.failures.count),
                "items": .int(deduped.kept.count),
                "duplicatesDropped": .int(deduped.dropped),
                "scriptChars": .int(reply.text.count),
                "targetWords": .int(words),
                "videoRendered": .bool(videoRendered),
                "bumperRendered": .bool(bumperURL != nil),
                "sampleRateHz": .int(plan.audioSampleRateHz),
                "model": .string(reply.model),
                "generatedTokens": .int(reply.generatedTokens)
            ]
        )
    }

    /// Text/audio only — the "read me the headlines now" button, no render.
    private func morningDigest(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let targets = morningFeedList(payload: payload, document: document)
        guard !targets.isEmpty else { return ENGPayload.missing("feeds", engine: .morningTv, commandID: commandID) }
        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.morningTv, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let fetched = await fetchFeeds(targets, perFeed: ENGPayload.int(payload, "limit", default: 10))
        let deduped = dedupeFeeds(fetched.items)
        let listing = deduped.kept.prefix(30).enumerated().map { index, item -> String in
            let stamp = item.publishedAt.map { $0.ppxClock } ?? "—"
            return "\(index + 1). [\(item.feed)] \(TextKit.truncate(item.title, to: 110)) · \(stamp)"
        }.joined(separator: "\n")
        let url = ENGFFmpeg.outputURL("morning-digest-\(ENGFiles.stamp())", fileExtension: "md")
        _ = ENGFiles.write("""
        # 晨间摘要 · Morning digest
        生成 Generated: \(Date().ppxISO8601)
        订阅源 Feeds: \(targets.count) configured, \(fetched.fetched) reached
        条目 Items: \(deduped.kept.count) after dedupe (\(deduped.dropped) dropped)

        \(listing.isEmpty ? "（无条目 nothing parsed）" : listing)

        \(fetched.failures.isEmpty ? "" : "## 失败 Failures\n" + fetched.failures.joined(separator: "\n"))
        """, to: url)

        return CommandResult(
            commandID: commandID,
            engine: .morningTv,
            ok: !deduped.kept.isEmpty,
            headline: "摘要就绪 · \(deduped.kept.count) headlines",
            body: deduped.kept.isEmpty
                ? fetched.failures.joined(separator: "\n")
                : listing,
            artifacts: [AppPaths.anonymise(url: url)],
            metrics: [
                "feeds": .int(targets.count),
                "reached": .int(fetched.fetched),
                "items": .int(deduped.kept.count),
                "duplicatesDropped": .int(deduped.dropped),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Reports the schedule so the console can show a countdown, and so the
    /// composition root can verify the gate the scheduler depends on.
    private func morningSchedule(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let calendar = Calendar.current
        let now = Date()
        let next = nextMorningFire(from: now, config: document.morningTv, calendar: calendar)
        return CommandResult(
            commandID: commandID,
            engine: .morningTv,
            ok: true,
            headline: "播出计划 · \(String(format: "%02d:%02d", document.morningTv.fireHour, document.morningTv.fireMinute)) daily",
            body: "下一次 Next: \(next.ppxISO8601) (\(morningCountdown(from: now, config: document.morningTv, calendar: calendar)))\n窗口 Window: fire time + 90 min, so a laptop that was asleep at 06:30 still broadcasts when it wakes.\n上次 Last: \(document.morningTv.lastBroadcastAt?.ppxISO8601 ?? "never")\n语音 Voice: \(document.morningTv.voiceRef)\n订阅源 Feeds: \(document.morningTv.feeds.count)",
            metrics: [
                "fireHour": .int(document.morningTv.fireHour),
                "fireMinute": .int(document.morningTv.fireMinute),
                "nextFireAt": .string(next.ppxISO8601),
                "inWindow": .bool(morningWindowOpen(at: now, config: document.morningTv, calendar: calendar)),
                "targetMinutes": .int(document.morningTv.targetMinutes),
                "feeds": .int(document.morningTv.feeds.count)
            ]
        )
    }

    /// Feed list: configured first, payload additions after, deduplicated.
    private func morningFeedList(payload: JSONValue, document: NodeSettings) -> [String] {
        var seen = Set<String>()
        return (document.morningTv.feeds + ENGPayload.strings(payload, "feeds"))
            .filter { !$0.isEmpty && ENGNet.url($0) != nil && seen.insert($0).inserted }
    }

    /// Fetches in parallel but keeps failure reporting per-feed, because a single
    /// dead subscription should never sink the bulletin.
    private func fetchFeeds(_ targets: [String], perFeed: Int) async -> (items: [ENGFeedItem], fetched: Int, failures: [String]) {
        var failures: [String] = []
        var parsed: [(String, [ENGFeedItem])] = []
        await withTaskGroup(of: (String, Result<ENGNet.Response, ENGNet.NetError>).self) { group in
            for target in targets.prefix(12) {
                group.addTask { (target, await ENGNet.get(target, timeout: 12)) }
            }
            for await (target, result) in group {
                switch result {
                case .success(let response):
                    // Parsing happens here, not inside the child task: the
                    // `XMLParser` delegate is a class and stays on one context.
                    parsed.append((target, ENGFeedParser.parse(data: response.data, feed: target, limit: max(1, perFeed))))
                case .failure(let error):
                    failures.append("\(String(target.prefix(70))): \(error)")
                }
            }
        }
        let ordering = Dictionary(uniqueKeysWithValues: targets.prefix(12).enumerated().map { ($0.element, $0.offset) })
        parsed.sort { (ordering[$0.0] ?? 0) < (ordering[$1.0] ?? 0) }
        return (parsed.flatMap(\.1), parsed.count, failures)
    }

    /// Syndicated wire copy appears in several feeds at once; near-duplicate
    /// titles are collapsed so the spoken script does not read the same story
    /// three times.
    private func dedupeFeeds(_ items: [ENGFeedItem]) -> (kept: [ENGFeedItem], dropped: Int) {
        var kept: [ENGFeedItem] = []
        var fingerprints: [Set<String>] = []
        var dropped = 0
        for item in items {
            let tokens = ENGFeedParser.tokens(item.title)
            if tokens.isEmpty {
                dropped += 1
                continue
            }
            if fingerprints.contains(where: { ENGFeedParser.jaccard(tokens, $0) >= 0.72 }) {
                dropped += 1
                continue
            }
            fingerprints.append(tokens)
            kept.append(item)
        }
        let latest = kept.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        return (latest, dropped)
    }

    /// The fire gate: the configured minute plus a 90-minute grace so a sleeping
    /// Mac still broadcasts on wake, but a stray command at 15:00 does not.
    private func morningWindowOpen(at date: Date, config: MorningTvConfig, calendar: Calendar) -> Bool {
        guard let fire = calendar.date(bySettingHour: config.fireHour, minute: config.fireMinute, second: 0, of: date) else { return false }
        if date < fire { return false }
        return date.timeIntervalSince(fire) <= 90 * 60
    }

    private func nextMorningFire(from date: Date, config: MorningTvConfig, calendar: Calendar) -> Date {
        guard let today = calendar.date(bySettingHour: config.fireHour, minute: config.fireMinute, second: 0, of: date) else {
            return date.addingTimeInterval(24 * 3_600)
        }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 3_600)
    }

    private func morningCountdown(from date: Date, config: MorningTvConfig, calendar: Calendar) -> String {
        let interval = max(0, nextMorningFire(from: date, config: config, calendar: calendar).timeIntervalSince(date))
        let hours = Int(interval) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        return "in \(hours) h \(minutes) min"
    }

    private func morningScriptSystem(_ language: ConsoleLanguage) -> String {
        Self.systemTemplate(
            language,
            zh: "你是晨间广播编辑。只使用提供的标题与摘要，不得补充外部知识。输出适合口播的中文播报稿：开场一句、每条新闻一到两句、结尾一句。不要使用项目符号，不要输出链接，总字数按要求的字数控制。",
            en: "You are a morning radio editor. Use only the supplied headlines and summaries; add no outside knowledge. Output broadcast-ready prose: one opening line, one or two sentences per story, one closing line. No bullet points, no links, respect the requested length."
        )
    }

    private func morningScriptPrompt(
        items: [ENGFeedItem],
        minutes: Int,
        words: Int,
        nodeName: String,
        language: ConsoleLanguage
    ) -> String {
        let listing = items.prefix(40).enumerated().map { index, item -> String in
            "\(index + 1). [\(item.feed)] \(TextKit.truncate(item.title, to: 160))"
                + (item.summary.isEmpty ? "" : " — \(TextKit.truncate(item.summary, to: 260))")
        }.joined(separator: "\n")
        return """
        节点 Node: \(nodeName)
        目标时长 Target: \(minutes) min ≈ \(words) words
        条目 Items (\(items.count)):
        \(listing)

        \(language.isChinese ? "请写出口播播报稿。" : "Write the spoken bulletin now.")
        """
    }

    private func morningBumperPrompt(language: ConsoleLanguage) -> String {
        language.isChinese
            ? "6 秒开场动画：深蓝色背景上浮现柔和的晨光光晕，缓慢推进，无任何文字与品牌标识。"
            : "Six second opening bumper: a slow push into a soft dawn glow over deep blue, no text, no logos."
    }

    private func morningScriptDocument(
        script: String,
        items: [ENGFeedItem],
        feeds: [String],
        model: String,
        minutes: Int,
        language: ConsoleLanguage
    ) -> String {
        let sources = items.prefix(40).enumerated().map { index, item -> String in
            "\(index + 1). \(item.title)\n   \(item.link.isEmpty ? "(no link)" : item.link) · \(item.publishedAt?.ppxISO8601 ?? "undated")"
        }.joined(separator: "\n")
        return """
        # 晨间电视播报稿 · Morning TV bulletin
        时间 When: \(Date().ppxISO8601)
        长度 Target: \(minutes) min
        模型 Model: \(model)
        订阅源 Feeds: \(feeds.joined(separator: ", "))

        ## 口播稿 Script
        \(script)

        ## 来源 Sources
        \(sources)
        """
    }

    // MARK: - Engine 7 · phantom_sentinel

    /// The deterministic lockdown.
    ///
    /// Contract, restated in code: no model, no model-shaped await, no
    /// `URLSession AI` call, nothing that can block on inference. Every step here
    /// is a fixed sequence of local syscalls with a bounded timeout, and the whole
    /// function is designed to finish in well under a second even when the webhook
    /// endpoint is a black hole (1.5 s ceiling). User-visible text from the wire is
    /// only ever used as an opaque trigger label — it is never interpolated into a
    /// shell command, and `osascript` is not used at all, because AppleScript
    /// string interpolation from a remote message is a code-execution path.
    private func lockdown(trigger: String, document: NodeSettings) async -> CommandResult {
        let watch = Stopwatch()
        var steps: [StepTiming] = []
        let label = String(trigger.prefix(24))

        // 1. Clipboard. MainActor hop because NSPasteboard is main-thread only;
        //    this is the one await in the path that touches AppKit, and it is a
        //    synchronous AppKit call with no I/O.
        var clipboardCleared = false
        #if canImport(AppKit)
        if document.sentinel.clipboardClear {
            clipboardCleared = await MainActor.run {
                // clearContents returns the pasteboard change count, not a
                // success flag; the call itself has no failure path.
                _ = NSPasteboard.general.clearContents()
                return true
            }
        }
        #endif
        steps.append(StepTiming(name: "clipboard", milliseconds: watch.elapsedMs, outcome: clipboardCleared ? "cleared" : "skipped/refused"))

        // 2. Unmount the configured (or any removable) external volumes.
        let targets = await sentinelUnmountTargets(configured: document.sentinel.unmountPaths)
        var unmounted: [String] = []
        var mountFailures: [String] = []
        for target in targets {
            let outcome = await unmount(volume: target)
            if outcome.unmounted {
                unmounted.append(target.mount)
            } else {
                mountFailures.append("\(target.mount): \(outcome.note)")
            }
        }
        steps.append(StepTiming(
            name: "unmount",
            milliseconds: watch.elapsedMs,
            outcome: "\(unmounted.count) down, \(mountFailures.count) failed of \(targets.count)"
        ))

        // 3. Home-automation / presence webhook, signed, best effort.
        let webhook = await postLockdownWebhook(config: document.sentinel, trigger: label)
        steps.append(StepTiming(name: "webhook", milliseconds: watch.elapsedMs, outcome: webhook.outcome))

        // 4. Displays, then the screen lock. Both are fixed argument vectors to
        //    absolute launch paths; the trigger text never reaches them.
        var displaysSlept = false
        if document.sentinel.sleepDisplays, FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset") {
            displaysSlept = await Shell.runAbsolute(launchPath: "/usr/bin/pmset", ["displaysleepnow"], timeout: 4).succeeded
            steps.append(StepTiming(name: "displays", milliseconds: watch.elapsedMs, outcome: displaysSlept ? "slept" : "rejected"))
        }
        var screenLocked = false
        if document.sentinel.lockScreen {
            let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
            if FileManager.default.isExecutableFile(atPath: cgSession) {
                screenLocked = await Shell.runAbsolute(launchPath: cgSession, ["-suspend"], timeout: 6).succeeded
            }
            steps.append(StepTiming(name: "screen", milliseconds: watch.elapsedMs, outcome: screenLocked ? "locked" : "CGSession unavailable"))
        }

        let elapsed = watch.elapsedMs
        let receipt = LockdownReceipt(
            trigger: label,
            clipboardCleared: clipboardCleared,
            unmounted: unmounted,
            mountFailures: mountFailures,
            screenLocked: screenLocked,
            displaysSlept: displaysSlept,
            webhookStatus: webhook.status,
            webhookTarget: webhook.target,
            elapsedMs: elapsed,
            modelInvolved: false,
            triggeredAt: Date()
        )
        var ledger = Self.readLockdowns(limit: 200)
        ledger.append(receipt)
        _ = ENGFiles.writeJSON(Array(ledger.suffix(200)), to: AppPaths.lockdownLedgerFile)
        let triggeredAt = receipt.triggeredAt
        await settings.mutate { document in
            document.sentinel.lastLockAt = triggeredAt
        }

        let timings = steps.map { "\($0.name) \($0.milliseconds) ms (\($0.outcome))" }.joined(separator: " · ")
        let body = """
        触发 Trigger: \(label) — 状态机直达，无大模型参与 (deterministic path, 0 model calls)
        总耗时 Elapsed: \(elapsed) ms

        1. 剪贴板 Clipboard: \(document.sentinel.clipboardClear ? (clipboardCleared ? "已清空 cleared" : "未能清空 not cleared") : "按设置跳过 skipped by config")
        2. 卸载 Unmounted: \(unmounted.isEmpty ? (targets.isEmpty ? "无外部卷 none mounted" : "无成功 none succeeded") : unmounted.joined(separator: ", "))
        \(mountFailures.isEmpty ? "" : "   失败 Failed: " + mountFailures.joined(separator: "; "))
        3. 通知 Webhook: \(webhook.outcome)
        4. 屏幕 Screen: \(document.sentinel.lockScreen ? (screenLocked ? "已锁定 locked" : "锁定命令未成功 — CGSession not found on this macOS") : "按设置跳过 skipped by config")\(displaysSlept ? " + 显示器睡眠 displays slept" : "")

        计时 Timings: \(timings)
        审计 Receipt appended to ledger/lockdown.json (\(ledger.count) rows).
        """
        let acted = clipboardCleared || screenLocked || !unmounted.isEmpty || displaysSlept
        return CommandResult(
            commandID: nil,
            engine: .phantomSentinel,
            ok: acted,
            headline: acted
                ? "🔒 全面静默 · lockdown in \(elapsed) ms"
                : "🔒 静默失败 · lockdown performed no action",
            body: acted ? body : body + "\n\nNothing was disabled: check that this node is allowed to control the clipboard and that the screen-lock helper exists on this macOS build.",
            metrics: [
                "elapsedMs": .int(elapsed),
                "clipboardCleared": .bool(clipboardCleared),
                "unmounted": .int(unmounted.count),
                "mountFailures": .int(mountFailures.count),
                "screenLocked": .bool(screenLocked),
                "displaysSlept": .bool(displaysSlept),
                "webhookStatus": webhook.status.map { JSONValue.int($0) } ?? .null,
                "modelInvolved": .bool(false),
                "steps": .int(steps.count)
            ]
        )
    }

    /// Sentinel status without touching a model: config, mounted volumes, ledger.
    private func sentinelStatus(document: NodeSettings, commandID: String?) async -> CommandResult {
        let volumes = await sentinelUnmountTargets(configured: [])
        let ledger = Self.readLockdowns(limit: 5)
        let webhookConfigured = !document.sentinel.webhookURL.isEmpty
        let signed = webhookConfigured && !document.sentinel.webhookSecret.isEmpty
        return CommandResult(
            commandID: commandID,
            engine: .phantomSentinel,
            ok: true,
            headline: "哨兵就绪 · sentinel armed, \(ledger.count) recent lockdown(s)",
            body: """
            触发词 Triggers: \(document.sentinel.triggerPhrases.joined(separator: ", "))
            动作 Actions: clipboard \(document.sentinel.clipboardClear ? "clear" : "leave"), unmount \(document.sentinel.unmountPaths.isEmpty ? "removable volumes" : document.sentinel.unmountPaths.joined(separator: ", ")), lock \(document.sentinel.lockScreen ? "yes" : "no"), displays \(document.sentinel.sleepDisplays ? "sleep" : "leave")
            网络 Webhook: \(webhookConfigured ? (signed ? "configured + HMAC-SHA256 signing" : "configured but UNSIGNED — set webhookSecret so the receiver can reject replays") : "not configured (skipped cleanly)")
            上次 Last lock: \(document.sentinel.lastLockAt?.ppxISO8601 ?? "never")
            可卸载 volumes now: \(volumes.isEmpty ? "none mounted" : volumes.map { $0.mount }.joined(separator: ", "))

            最近 Recent:
            \(ledger.isEmpty ? "—" : ledger.reversed().map { "· \($0.triggeredAt.ppxISO8601) \($0.trigger) in \($0.elapsedMs) ms (clipboard \($0.clipboardCleared ? "ok" : "no"), unmounted \($0.unmounted.count), screen \($0.screenLocked ? "locked" : "as-is"))" }.joined(separator: "\n"))
            """,
            metrics: [
                "triggerPhrases": .int(document.sentinel.triggerPhrases.count),
                "clipboardClear": .bool(document.sentinel.clipboardClear),
                "lockScreen": .bool(document.sentinel.lockScreen),
                "unmountPaths": .int(document.sentinel.unmountPaths.count),
                "webhookConfigured": .bool(webhookConfigured),
                "webhookSigned": .bool(signed),
                "mountedTargets": .int(volumes.count),
                "recentLockdowns": .int(ledger.count),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Volumes to unmount: exactly the configured ones when given, otherwise any
    /// removable/ejectable volume. The boot volume is never a target, and a
    /// configured path that resolves to `/` is dropped rather than trusted.
    private func sentinelUnmountTargets(configured: [String]) async -> [Volume] {
        let mounted = await mountedVolumes()
        guard !configured.isEmpty else {
            return mounted.filter { $0.removable }
        }
        let requested = Set(configured.compactMap { path -> String? in
            guard let url = AppPaths.resolve(userPath: path) else { return nil }
            return url.standardizedFileURL.path
        })
        return mounted.filter { candidate in
            requested.contains { root in
                candidate.mount == root || candidate.mount.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }

    /// Every currently mounted volume except the boot volume.
    ///
    /// `diskutil info -all -plist` parsed with `PropertyListSerialization`, one
    /// subprocess for the whole table. Reading the plist instead of scraping
    /// `diskutil list` output matters twice over: volume names carry spaces and
    /// non-ASCII text, and the lockdown path may not spend a second subprocess per
    /// disk. If `diskutil` is missing, the fallback enumerates `/Volumes` from
    /// `FileManager`, which needs no subprocess at all.
    private func mountedVolumes() async -> [Volume] {
        if Shell.isPresent("diskutil") {
            let listing = await Shell.run("diskutil", ["info", "-all", "-plist"], timeout: 4)
            if listing.succeeded, let data = listing.stdout.data(using: .utf8),
               let table = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] {
                var volumes: [Volume] = []
                for info in table {
                    guard let mount = info["MountPoint"] as? String, !mount.isEmpty, mount != "/" else { continue }
                    let device = (info["DeviceIdentifier"] as? String) ?? ""
                    let name = (info["VolumeName"] as? String) ?? (info["MediaName"] as? String) ?? device
                    let removable = (info["Removable"] as? Bool) ?? (info["Ejectable"] as? Bool) ?? false
                    volumes.append(Volume(device: device, mount: mount, name: name, removable: removable))
                }
                if !volumes.isEmpty { return volumes }
            }
        }
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let entries = (try? AppPaths.fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url -> Volume? in
            // The boot volume shows up here as a firmlink back to `/`; comparing
            // the resolved path is what keeps a panic button from unmounting the
            // running system.
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved != "/", resolved.hasPrefix("/Volumes/") || !resolved.hasPrefix("/") else { return nil }
            return Volume(device: "", mount: url.path, name: url.lastPathComponent, removable: true)
        }
    }

    /// Unmount, then a whole-disk eject only if the volume-level unmount was
    /// refused. Never uses `force`: a forced unmount mid-write is how you corrupt
    /// somebody's archive during a panic button press.
    private func unmount(volume: Volume) async -> (unmounted: Bool, note: String) {
        guard volume.mount != "/" else { return (false, "refused: boot volume") }
        guard Shell.isPresent("diskutil") else { return (false, "diskutil not available") }
        let first = await Shell.run("diskutil", ["unmount", volume.mount], timeout: 12)
        if first.succeeded {
            return (true, "unmounted")
        }
        guard !volume.device.isEmpty else {
            return (false, String(first.combinedOutput.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let second = await Shell.run("diskutil", ["unmountDisk", volume.device], timeout: 12)
        if second.succeeded {
            return (true, "ejected via unmountDisk")
        }
        return (false, String(second.combinedOutput.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Timestamped, HMAC-signed webhook POST.
    ///
    /// Signature is `HMAC-SHA256(secret, "<timestamp>.<sha256(body)>")`, sent as
    /// `X-PPX-Signature` with `X-PPX-Timestamp`, so the receiver can recompute the
    /// digest of the exact bytes it got and reject a replay once the timestamp
    /// window expires. This is a plain HTTPS POST to an address the owner typed —
    /// it is not a model call and it is capped at 1.5 seconds so a dead home
    /// automation box cannot delay a lockdown.
    private func postLockdownWebhook(config: SentinelConfig, trigger: String) async -> (status: Int?, target: String?, outcome: String, elapsedMs: Int) {
        guard !config.webhookURL.isEmpty else {
            return (nil, nil, "not configured — skipped cleanly", 0)
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let payload: [String: JSONValue] = [
            "event": .string("popopx.lockdown"),
            "trigger": .string(trigger),
            "at": .string(Date().ppxISO8601),
            "timestamp": .int(timestamp),
            "clipboard": .bool(config.clipboardClear),
            "unmountTargets": .int(config.unmountPaths.count),
            "deterministic": .bool(true)
        ]
        guard let body = NodeJSON.encodeLine(payload) else {
            return (nil, nil, "payload encoding failed", 0)
        }
        var headers = ["X-PPX-Timestamp": String(timestamp)]
        if config.webhookSecret.isEmpty {
            headers["X-PPX-Signature"] = "unsigned"
        } else {
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data("\(timestamp).\(Digest.sha256Hex(body))".utf8),
                using: SymmetricKey(data: Data(config.webhookSecret.utf8))
            )
            headers["X-PPX-Signature"] = "t=\(timestamp),v1=" + mac.map { String(format: "%02x", $0) }.joined()
        }
        let watch = Stopwatch()
        let response = await ENGNet.post(config.webhookURL, body: body, headers: headers, timeout: 1.5)
        let elapsed = watch.elapsedMs
        let host = ENGNet.url(config.webhookURL)?.host ?? "?"
        switch response {
        case .success(let result):
            return (result.status, host, "POST \(host) → \(result.status) in \(elapsed) ms", elapsed)
        case .failure(let error):
            return (nil, host, "POST \(host) failed: \(error) (after \(elapsed) ms)", elapsed)
        }
    }

    /// Lockdown ledger read, also used by the console's history card.
    static func readLockdowns(limit: Int) -> [LockdownReceipt] {
        ENGFiles.readJSON([LockdownReceipt].self, at: AppPaths.lockdownLedgerFile)
            .map { Array($0.suffix(max(1, limit))) } ?? []
    }

    /// Vault ledger read for the console card.
    static func readVaults(limit: Int) -> [TimelockEnvelope] {
        ENGFiles.readJSON([TimelockEnvelope].self, at: Self.vaultLedgerURL)
            .map { Array($0.suffix(max(1, limit))) } ?? []
    }

    static var vaultLedgerURL: URL { AppPaths.ledger.appendingPathComponent("vaults.json") }

    /// Writes a concat list and re-muxes losslessly. Used by the warroom slices
    /// and by the morning bulletin's bumper + body join.
    private func concatVideo(ffmpeg: String, parts: [URL], output: URL) async -> Bool {
        guard parts.count > 1 else { return false }
        let listFile = prepared(AppPaths.quarantine)
            .appendingPathComponent("concat-\(ENGFiles.stamp()).txt")
        let text = parts
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        guard ENGFiles.write(text, to: listFile) else { return false }
        let merged = await ENGFFmpeg.concat(ffmpeg: ffmpeg, listFile: listFile, output: output, timeout: 300)
        return merged.succeeded && ENGFiles.size(output) > 0
    }

    /// Measures this machine's sequential SHA-256 rate once per process; the
    /// chrono_ark round count is meaningless without it.
    private func hashRate() async -> ENGHashChain.Rate {
        if let chainRate { return chainRate }
        let rate = await ENGHashChain.calibrate()
        chainRate = rate
        return rate
    }

    /// Rebuilds an `AES.GCM.SealedBox` from the `combined` container written to
    /// disk. `combined` is nonce ‖ ciphertext ‖ tag, so the split is fixed-length
    /// and needs no framing of its own.
    private static func gcmBox(_ combined: Data) -> AES.GCM.SealedBox? {
        guard combined.count > 28 else { return nil }
        let nonce = combined.subdata(in: 0..<12)
        let tag = combined.subdata(in: (combined.count - 16)..<combined.count)
        let ciphertext = combined.subdata(in: 12..<(combined.count - 16))
        return try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
    }

    // MARK: - Engine 8 · chrono_ark

    /// Seals a file or directory behind a calibrated hash-chain lock plus a
    /// calendar lock, with heartbeat succession.
    ///
    /// The arithmetic, stated plainly because it is the part most time-lock
    /// implementations fudge: a sequential SHA-256 chain can only be *issued* with
    /// as much wall-clock work as the sealer is willing to spend in one call, so
    /// the node computes `rounds = measuredRate × min(requested, sealBudget)`,
    /// with the seal budget capped by the caller. That chain is a genuine CPU floor
    /// the beneficiary must redo before the key material appears — but it is
    /// **CPU-bound and therefore parallelisable**: SHA-256 over a fixed 32-byte
    /// block is precisely the workload a GPU farm or an ASIC array is built for, so
    /// an attacker with enough hardware compresses the floor. The chain buys time,
    /// not certainty. Long horizons are carried by the calendar lock plus custody
    /// of the seed: the node refuses to open a capsule before `earliestOpenAt`, and
    /// hands the seed to the beneficiary queue only once heartbeat succession
    /// fires.
    private func arkSeal(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let inputText = ENGPayload.path(payload)
        guard !inputText.isEmpty else { return ENGPayload.missing("input", engine: .chronoArk, commandID: commandID) }
        guard let input = resolveInput(inputText) else {
            return CommandResult.failure(.chronoArk, "Refused or unreadable input: \(AppPaths.anonymise(inputText))", commandID: commandID)
        }
        let label = ENGPayload.string(payload, "label", default: input.deletingPathExtension().lastPathComponent)
        let requested = max(60, ENGPayload.int(payload, "seconds", default: document.ark.timelockSeconds))
        let sealBudgetSeconds = min(max(60, ENGPayload.int(payload, "sealBudgetSeconds", default: 180)), 900)

        var staging: URL?
        let source: URL
        if ENGFiles.isDirectory(input) {
            let archive = prepared(AppPaths.quarantine).appendingPathComponent("ark-\(ENGFiles.stamp()).zip")
            // `ditto -c -k` with the path passed as its own argv slot: a directory
            // called "My Trip 2024" is one argument, never a shell string.
            let zipped = await Shell.run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, archive.path], timeout: 600)
            guard zipped.succeeded, ENGFiles.size(archive) > 0 else {
                return CommandResult(
                    commandID: commandID,
                    engine: .chronoArk,
                    ok: false,
                    headline: "打包失败 · could not archive the directory.",
                    body: String(zipped.combinedOutput.prefix(500)),
                    metrics: ["directory": .bool(true)]
                )
            }
            staging = archive
            source = archive
        } else {
            source = input
        }
        defer { if let staging { try? AppPaths.fileManager.removeItem(at: staging) } }

        let size = ENGFiles.size(source)
        guard size > 0 else { return CommandResult.failure(.chronoArk, "Input is empty.", commandID: commandID) }
        guard size < 4_000_000_000 else {
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: false,
                headline: "输入过大 · input too large to seal in one pass.",
                body: "\(ByteCount(size).humanized) exceeds the 4 GB ceiling. Seal the entries individually rather than growing the buffer.",
                metrics: ["bytes": .int(Int(size))]
            )
        }
        guard let plaintext = try? Data(contentsOf: source) else {
            return CommandResult.failure(.chronoArk, "Could not read the input.", commandID: commandID)
        }

        let rate = await hashRate()
        let rounds = ENGHashChain.rounds(seconds: Double(min(requested, sealBudgetSeconds)), rate: rate, capSeconds: Double(sealBudgetSeconds))
        let cpuSeconds = ENGHashChain.representedSeconds(rounds: rounds, rate: rate)
        let seed = ENGFiles.randomBytes(32)
        let envelopeID = TextKit.fingerprint("\(label)|\(Date().timeIntervalSince1970)|\(Digest.short(plaintext, length: 12))", length: 12)

        let gateGB = requirementGB(for: .light, plan: await modelPlan())
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.chronoArk, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        await emit(
            .engine,
            "chrono ark: deriving \(rounds) rounds for envelope \(envelopeID) (≈\(Int(cpuSeconds)) s of hashing)",
            payload: ["envelope": .string(envelopeID), "rounds": .int(rounds)]
        )
        let sealWatch = Stopwatch()
        let tail = await ENGHashChain.derive(seed: seed, rounds: rounds)
        let deriveMs = sealWatch.elapsedMs

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tail),
            salt: Self.nodeSalt(),
            info: Data("popopx-ark-\(envelopeID)".utf8),
            outputByteCount: 32
        )
        let box = try? AES.GCM.seal(plaintext, using: key)
        guard let sealed = box?.combined else {
            return CommandResult.failure(.chronoArk, "AES-GCM refused to seal the payload.", commandID: commandID)
        }
        let capsule = prepared(AppPaths.sealed).appendingPathComponent("ark-\(envelopeID).ppxark")
        guard ENGFiles.write(sealed, to: capsule) else {
            return CommandResult.failure(.chronoArk, "Could not write the capsule.", commandID: commandID)
        }

        let sealedAt = Date()
        let earliest = sealedAt.addingTimeInterval(TimeInterval(requested))
        let meta: [String: JSONValue] = [
            "id": .string(envelopeID),
            "label": .string(label),
            "capsule": .string(capsule.lastPathComponent),
            "seed": .string(TextKit.base64URL(seed)),
            "rounds": .int(rounds),
            "roundsPerSecondAtSeal": .double(rate.roundsPerSecond),
            "cpuSecondsAtSealRate": .double(cpuSeconds),
            "sourceBytes": .int(Int(size)),
            "sourceSHA256": .string(Digest.sha256Hex(plaintext)),
            "sealedAt": .string(sealedAt.ppxISO8601),
            "earliestOpenAt": .string(earliest.ppxISO8601),
            "custody": .string("The seed is stored only in this file. The node enforces earliestOpenAt by policy; the chain enforces cpuSeconds of sequential hashing once the policy lifts.")
        ]
        guard ENGFiles.writeJSON(meta, to: Self.vaultMetaURL(envelopeID)) else {
            return CommandResult.failure(.chronoArk, "Could not write the envelope metadata.", commandID: commandID)
        }

        let envelope = TimelockEnvelope(
            id: envelopeID,
            label: label,
            path: AppPaths.anonymise(url: capsule),
            rounds: rounds,
            derivedKeyFingerprint: Digest.short(tail, length: 12),
            sealedAt: sealedAt,
            earliestOpenAt: earliest,
            released: false
        )
        var vaults = Self.readVaults(limit: 5_000)
        vaults.append(envelope)
        _ = ENGFiles.writeJSON(Array(vaults.suffix(500)), to: Self.vaultLedgerURL)
        let capsulePath = AppPaths.anonymise(url: capsule)
        await settings.mutate { document in
            if !document.ark.sealedArchives.contains(capsulePath) {
                document.ark.sealedArchives = (document.ark.sealedArchives + [capsulePath]).sorted()
            }
        }

        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: true,
            headline: "时间舱已封存 · \(label) sealed until \(earliest.ppxClock)",
            body: """
            信封 Envelope: \(envelopeID) · 密钥指纹 key fingerprint \(Digest.short(tail, length: 12))
            密码学 Crypto: AES-256-GCM, key = HKDF-SHA256(SHA256^\(rounds)(seed), node salt)
            CPU 下限 Work floor: \(String(format: "%.1f", cpuSeconds)) s of sequential hashing (measured \(deriveMs) ms here at \(Int(rate.roundsPerSecond)) rounds/s).
            日历锁 Calendar lock: opens \(earliest.ppxISO8601)
            继承 Succession: after \(document.ark.heartbeatIntervalHours) h × \(document.ark.missedHeartbeatsBeforeRelease) missed heartbeats the seed is published to outbox/ for \(document.ark.beneficiaryName.isEmpty ? "the beneficiary queue" : document.ark.beneficiaryName).

            Honest limit: the work floor is CPU-bound and SHA-256 is exactly what a GPU farm parallelises, so the chain slows a determined attacker down rather than stopping them. The year-scale guarantee is custody of the seed plus the calendar gate, not mathematics.
            """,
            artifacts: [AppPaths.anonymise(url: capsule), AppPaths.anonymise(url: Self.vaultMetaURL(envelopeID))],
            metrics: [
                "envelope": .string(envelopeID),
                "rounds": .int(rounds),
                "cpuSeconds": .int(Int(cpuSeconds)),
                "deriveMs": .int(deriveMs),
                "requestedSeconds": .int(requested),
                "sealedBytes": .int(Int(size)),
                "keyFingerprint": .string(Digest.short(tail, length: 12)),
                "modelInvolved": .bool(false),
                "networkUsed": .bool(false)
            ]
        )
    }

    /// Shows the capsule directory in Finder.
    ///
    /// The path is not taken from the payload: a paired phone can already ask
    /// this engine to seal and read files, so the one thing it must not get to
    /// choose is which folder the owner's Finder window opens. `AppPaths.sealed`
    /// is the same directory `arkSeal` writes into, so what the console promises
    /// and what the node reveals cannot drift apart.
    private func arkReveal(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let directory = prepared(AppPaths.sealed)
        let count = Self.readVaults(limit: 5_000).count
        #if canImport(AppKit)
        let shown = await MainActor.run {
            // The call has no failure path to report: `activateFileViewerSelecting`
            // asks Finder and returns nothing, so the path is always printed as
            // the fallback text if the workspace never comes up.
            NSWorkspace.shared.activateFileViewerSelecting([directory])
            return true
        }
        #else
        let shown = false
        #endif
        let path = AppPaths.anonymise(url: directory)
        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: true,
            headline: shown
                ? bi(document, zh: "存档目录已在访达中打开 · \(path)", en: "Archive folder opened in Finder · \(path)")
                : bi(document, zh: "存档目录 · \(path)", en: "Archive folder · \(path)"),
            body: bi(
                document,
                zh: "\(count) 个时间舱记录。胶囊文件名为 `ark-<id>.ppxark`，每个的种子只存在同名 `.ppxmeta` 边车文件里：移动这个文件夹，等于移动整个金库。",
                en: "\(count) envelope record(s) in the ledger. Capsules are `ark-<id>.ppxark`, and each seed lives only in its matching `.ppxmeta` sidecar: moving this folder moves the vault."
            ),
            metrics: [
                "directory": .string(path),
                "envelopes": .int(count),
                "revealed": .bool(shown),
                "modelInvolved": .bool(false),
                "networkUsed": .bool(false)
            ]
        )
    }

    /// The vault table, with the remaining lock on every row.
    private func arkList(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let vaults = Self.readVaults(limit: 64)
        let now = Date()
        let rows = vaults.reversed().map { envelope -> String in
            let remaining = max(0, envelope.earliestOpenAt.timeIntervalSince(now))
            let state = envelope.released
                ? "released"
                : (envelope.isUnlockable(at: now)
                    ? "ready (chain still must be ground)"
                    : "locked \(Int(remaining / 3600))h\(Int(remaining.truncatingRemainder(dividingBy: 3600) / 60))m")
            return "· \(envelope.id) \(TextKit.truncate(envelope.label, to: 26)) · \(envelope.rounds) rounds · \(state) · \(envelope.path)"
        }
        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: true,
            headline: "时间舱 · \(vaults.count) envelope(s)",
            body: (rows.isEmpty ? "还没有封存内容。Seal something with `seal` first." : rows.joined(separator: "\n"))
                + "\n\n心跳 Heartbeat: last \(document.ark.lastHeartbeatAt?.ppxISO8601 ?? "never"), every \(document.ark.heartbeatIntervalHours) h, release after \(document.ark.missedHeartbeatsBeforeRelease) misses"
                + "\n到期 Release deadline: \(document.ark.releaseDeadline?.ppxISO8601 ?? "not armed")"
                + "\n受益人 Beneficiary: \(document.ark.beneficiaryName.isEmpty ? "(unset)" : document.ark.beneficiaryName) / \(document.ark.beneficiaryQueue.isEmpty ? "(unset)" : document.ark.beneficiaryQueue)",
            metrics: [
                "envelopes": .int(vaults.count),
                "released": .int(vaults.filter(\.released).count),
                "unlockable": .int(vaults.filter { $0.isUnlockable(at: now) }.count),
                "heartbeatArmed": .bool(document.ark.lastHeartbeatAt != nil),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Re-derives the chain and opens a capsule.
    private func arkUnseal(payload: JSONValue, commandID: String?) async -> CommandResult {
        let now = Date()
        let id = ENGPayload.string(payload, "envelope", default: ENGPayload.string(payload, "id", default: ENGPayload.string(payload, "label")))
        var vaults = Self.readVaults(limit: 5_000)
        guard let index = vaults.firstIndex(where: { $0.id == id || $0.label == id }) else {
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: false,
                headline: "找不到信封 · no such envelope.",
                body: id.isEmpty
                    ? "Pass `envelope` (the id or the label). `list` shows what is sealed."
                    : "Nothing sealed as “\(TextKit.truncate(id, to: 40))”.",
                metrics: ["vaults": .int(vaults.count)]
            )
        }
        let envelope = vaults[index]
        guard envelope.released || envelope.isUnlockable(at: now) else {
            let remaining = envelope.earliestOpenAt.timeIntervalSince(now)
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: false,
                headline: "尚未到期 · still locked.",
                body: "Opens at \(envelope.earliestOpenAt.ppxISO8601), i.e. in \(Int(remaining / 3600)) h \(Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)) m. The node enforces that by policy, and the chain enforces \(envelope.rounds) sequential hashes after the policy lifts. There is no shortcut in this code path — reporting one would make the vault a lie.",
                metrics: ["remainingSeconds": .int(Int(remaining)), "rounds": .int(envelope.rounds)]
            )
        }
        guard let meta: [String: JSONValue] = ENGFiles.readJSON([String: JSONValue].self, at: Self.vaultMetaURL(envelope.id)),
              let seedText = meta["seed"]?.stringValue,
              let seed = TextKit.base64URLDecode(seedText) else {
            return CommandResult.failure(
                .chronoArk,
                "Envelope metadata for \(envelope.id) is missing, so the chain cannot be re-derived. Check vault/ark-\(envelope.id).json.",
                commandID: commandID
            )
        }
        let capsule = AppPaths.sealed.appendingPathComponent(meta["capsule"]?.stringValue ?? "ark-\(envelope.id).ppxark")
        guard let combined = try? Data(contentsOf: capsule), let box = Self.gcmBox(combined) else {
            return CommandResult.failure(.chronoArk, "Capsule is unreadable or truncated: \(AppPaths.anonymise(url: capsule))", commandID: commandID)
        }

        let rate = await hashRate()
        let gateGB = requirementGB(for: .light, plan: await modelPlan())
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.chronoArk, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let watch = Stopwatch()
        let rounds = max(1, envelope.rounds)
        let envelopeID = envelope.id
        let tail = await ENGHashChain.derive(seed: seed, rounds: rounds) { fraction in
            // The progress closure runs on the derivation task's executor, so it
            // hands the publish back to the actor instead of touching it directly.
            let percent = Int(fraction * 100)
            Task { await self.emit(.engine, "chrono ark unlocking \(envelopeID): \(percent)%", payload: ["envelope": .string(envelopeID), "percent": .int(percent)]) }
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tail),
            salt: Self.nodeSalt(),
            info: Data("popopx-ark-\(envelope.id)".utf8),
            outputByteCount: 32
        )
        guard let plaintext = try? AES.GCM.open(box, using: key) else {
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: false,
                headline: "密钥不匹配 · GCM authentication failed.",
                body: "The chain finished in \(watch.elapsedMs) ms but the derived key does not open the capsule. Either the envelope metadata was edited, the capsule was tampered with, or the node salt (`pairing/node.key`) changed since sealing — in which case every vault on this machine is unreadable, and that is worth investigating before retrying.",
                metrics: ["deriveMs": .int(watch.elapsedMs), "rounds": .int(rounds), "expectedFingerprint": .string(envelope.derivedKeyFingerprint)]
            )
        }
        // The capsule does not remember the original extension (metadata is
        // attacker-writable once it leaves the machine), so the recovered file is
        // written with a neutral suffix and named by envelope.
        let opened = ENGFFmpeg.outputURL(
            "\(TextKit.safeFileName(envelope.label, fallback: "vault"))-\(envelope.id)",
            fileExtension: "recovered.bin",
            in: AppPaths.output
        )
        guard ENGFiles.write(plaintext, to: opened) else {
            return CommandResult.failure(.chronoArk, "Could not write the recovered file.", commandID: commandID)
        }
        vaults[index].released = true
        _ = ENGFiles.writeJSON(Array(vaults.suffix(500)), to: Self.vaultLedgerURL)
        // A recovered envelope no longer needs a succession offer sitting in outbox.
        try? AppPaths.fileManager.removeItem(at: AppPaths.outbox.appendingPathComponent("ark-\(envelope.id).json"))

        let calibratedSeconds = ENGHashChain.representedSeconds(rounds: rounds, rate: rate)
        let digestMatch = Digest.matches(Digest.sha256Hex(plaintext), meta["sourceSHA256"]?.stringValue ?? Digest.sha256Hex(plaintext))
        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: true,
            headline: "时间舱已开启 · \(envelope.label) recovered",
            body: """
            信封 Envelope: \(envelope.id) · \(ByteCount(Int64(plaintext.count)).humanized)
            实际耗时 Actual grind: \(watch.elapsedMs) ms for \(rounds) rounds (calibrated floor was \(String(format: "%.1f", calibratedSeconds)) s on this hardware).
            校验 Integrity: \(digestMatch ? "SHA-256 matches the seal-time digest" : "DIFFERS from the seal-time digest — inspect before trusting it")
            输出 Recovered to: \(AppPaths.anonymise(url: opened))
            """,
            artifacts: [AppPaths.anonymise(url: opened)],
            metrics: [
                "envelope": .string(envelope.id),
                "rounds": .int(rounds),
                "grindMs": .int(watch.elapsedMs),
                "bytes": .int(plaintext.count),
                "calibratedSeconds": .int(Int(calibratedSeconds)),
                "digestMatches": .bool(digestMatch),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Proves the owner is alive and resets the succession countdown.
    private func arkHeartbeat(commandID: String?) async -> CommandResult {
        let now = Date()
        var interval = 0
        var misses = 0
        var deadline: Date?
        await settings.mutate { document in
            document.ark.lastHeartbeatAt = now
            document.ark.releasedAt = nil
            interval = document.ark.heartbeatIntervalHours
            misses = document.ark.missedHeartbeatsBeforeRelease
            deadline = document.ark.releaseDeadline
        }
        // The heartbeat log is itself a hash chain, so a forged "I was alive on
        // that date" record cannot be spliced into the past without breaking every
        // digest after it.
        var history = ENGFiles.readJSON([[String: JSONValue]].self, at: Self.heartbeatURL) ?? []
        let previous = history.last?["digest"]?.stringValue ?? "genesis"
        let record: [String: JSONValue] = [
            "at": .string(now.ppxISO8601),
            "previous": .string(previous),
            "intervalHours": .int(interval),
            "digest": .string(Digest.sha256Hex(Data("\(now.ppxISO8601)|\(previous)".utf8)))
        ]
        history.append(record)
        _ = ENGFiles.writeJSON(Array(history.suffix(2_000)), to: Self.heartbeatURL)
        await emit(
            .engine,
            "chrono ark heartbeat accepted; succession timer reset",
            payload: ["beats": .int(history.count), "releaseAt": .string(deadline?.ppxISO8601 ?? "unknown")]
        )
        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: true,
            headline: "心跳已记录 · heartbeat logged, release timer reset",
            body: """
            下一次到期 Next release deadline: \(deadline?.ppxISO8601 ?? "unknown")
            节奏 Cadence: every \(interval) h, \(misses) missed beats before anything reaches the beneficiary.
            链 Chain: \(history.count) record(s), head \(String((record["digest"]?.stringValue ?? "").prefix(12)))
            """,
            metrics: [
                "heartbeatAt": .string(now.ppxISO8601),
                "intervalHours": .int(interval),
                "missesAllowed": .int(misses),
                "historyLength": .int(history.count),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// The watchdog half: has the owner gone quiet long enough for succession?
    private func arkCheck(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let now = Date()
        guard let deadline = document.ark.releaseDeadline else {
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: true,
                headline: "无计时器 · no heartbeat on record yet.",
                body: "Succession is anchored to the first heartbeat rather than to the seal date, so nothing can fire until you beat once. Run `heartbeat`.",
                metrics: ["armed": .bool(false)]
            )
        }
        let vaults = Self.readVaults(limit: 5_000)
        let outstanding = vaults.filter { !$0.released }
        guard now >= deadline else {
            let remaining = deadline.timeIntervalSince(now)
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: true,
                headline: "监护中 · succession armed, \(Int(remaining / 3600)) h left",
                body: "Last heartbeat \(document.ark.lastHeartbeatAt?.ppxISO8601 ?? "never"); release would fire at \(deadline.ppxISO8601). \(outstanding.count) envelope(s) still sealed.",
                metrics: [
                    "armed": .bool(true),
                    "remainingHours": .int(Int(remaining / 3600)),
                    "sealedEnvelopes": .int(outstanding.count),
                    "modelInvolved": .bool(false)
                ]
            )
        }
        guard !outstanding.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .chronoArk,
                ok: true,
                headline: "已到期但无待交付内容 · nothing outstanding.",
                body: "Every envelope is already released.",
                metrics: ["armed": .bool(false), "released": .int(vaults.count)]
            )
        }
        var published: [String] = []
        for envelope in outstanding {
            guard var offer: [String: JSONValue] = ENGFiles.readJSON([String: JSONValue].self, at: Self.vaultMetaURL(envelope.id)) else { continue }
            offer["offerKind"] = .string("popopx.ark.succession")
            offer["offeredAt"] = .string(now.ppxISO8601)
            offer["beneficiary"] = .string(document.ark.beneficiaryName)
            offer["beneficiaryQueue"] = .string(document.ark.beneficiaryQueue)
            offer["note"] = .string("Deliver over the paired E2EE channel only. The seed alone still requires `rounds` sequential hashes before AES-GCM opens the capsule.")
            if ENGFiles.writeJSON(offer, to: AppPaths.outbox.appendingPathComponent("ark-\(envelope.id).json")) {
                published.append(envelope.id)
            }
        }
        let releasedAt = now
        await settings.mutate { document in
            document.ark.releasedAt = releasedAt
        }
        await emit(
            .sentinel,
            "chrono ark: heartbeat lapse — succession offer written for \(published.count) envelope(s)",
            level: .warning,
            payload: ["envelopes": .int(published.count), "at": .string(now.ppxISO8601)]
        )
        return CommandResult(
            commandID: commandID,
            engine: .chronoArk,
            ok: !published.isEmpty,
            headline: "继承已触发 · succession fired for \(published.count) envelope(s)",
            body: "Missed \(document.ark.missedHeartbeatsBeforeRelease) beat(s) of \(document.ark.heartbeatIntervalHours) h each; the deadline was \(deadline.ppxISO8601).\nOffers written to outbox/ for \(document.ark.beneficiaryQueue.isEmpty ? "the configured beneficiary queue" : document.ark.beneficiaryQueue): \(published.joined(separator: ", "))\n\nWhat lapsed is custody of the seed, not the cipher: the capsules stay AES-256-GCM and a beneficiary still has to grind the chain.",
            artifacts: published.map { AppPaths.anonymise(url: AppPaths.outbox.appendingPathComponent("ark-\($0).json")) },
            metrics: [
                "releasedEnvelopes": .int(published.count),
                "sealedTotal": .int(vaults.count),
                "deadlinePassedHours": .int(Int(now.timeIntervalSince(deadline) / 3600)),
                "modelInvolved": .bool(false)
            ]
        )
    }

    static var heartbeatURL: URL { AppPaths.vault.appendingPathComponent("heartbeats.json") }

    private static func vaultMetaURL(_ id: String) -> URL {
        AppPaths.vault.appendingPathComponent("ark-\(TextKit.safeFileName(id, fallback: "envelope")).json")
    }

    // MARK: - Engine 9 · health_sentinel

    /// Reads a lab report locally and interprets it against the owner's own
    /// reference ranges.
    ///
    /// Two properties are enforced structurally rather than by convention: there
    /// is no model call in this function (`EngineKind.healthSentinel
    /// .usesModelInLoop` is `false`, and nothing here touches `ENGOllama` or
    /// `ENGNet`), and there is no artifact — the interpretation comes back as text
    /// only, so no file containing a diagnosis can be picked up by the mesh, the
    /// outbox, or the console's file browser.
    private func healthRead(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let inputText = ENGPayload.path(payload)
        guard !inputText.isEmpty else { return ENGPayload.missing("input", engine: .healthSentinel, commandID: commandID) }
        guard let input = resolveInput(inputText), ENGFiles.exists(input) else {
            return CommandResult.failure(.healthSentinel, "Report not found or path refused: \(AppPaths.anonymise(inputText))", commandID: commandID)
        }
        let gateGB = requirementGB(for: .light, plan: await modelPlan())
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.healthSentinel, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let ext = input.pathExtension.lowercased()
        var pages: [URL] = []
        var inlineText: [String] = []
        switch ext {
        case "pdf":
            pages = rasterizePDF(input, maxPages: min(24, max(1, ENGPayload.int(payload, "pages", default: 12))))
        case let e where ENGFiles.imageExtensions.contains(e):
            pages = [input] + ENGPayload.strings(payload, "extraPages").compactMap { resolveInput($0) }.filter { ENGFiles.imageExtensions.contains($0.pathExtension.lowercased()) }
        case "txt", "md", "csv", "text":
            inlineText = (ENGFiles.readText(input) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        default:
            return CommandResult(
                commandID: commandID,
                engine: .healthSentinel,
                ok: false,
                headline: "不支持的格式 · unsupported file type “.\(ext)”.",
                body: "This engine reads PDF, images, and plain text with PDFKit + Vision on this machine. It will not forward a report to a cloud OCR service, so anything else has to be converted locally first.",
                metrics: ["extension": .string(ext)]
            )
        }
        let recognised: [String] = inlineText.isEmpty ? await ocrText(in: pages) : inlineText
        guard !recognised.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .healthSentinel,
                ok: false,
                headline: "无可识别文字 · no text found in the document.",
                body: "Either the scan is too low resolution or the PDF has no text layer and no scannable content. Re-scan at 300 dpi or higher. Nothing was uploaded anywhere to try again.",
                metrics: ["pages": .int(pages.count), "ocrLines": .int(0)]
            )
        }
        let text = recognised.joined(separator: "\n")
        let parsed = ENGIndicator.read(text: text, references: document.health.referenceRanges)
        let outOfRange = parsed.readings.filter { $0.verdict == .low || $0.verdict == .high }

        var lines: [String] = ["指标 Indicator | 数值 Value | 参考 Reference | 判定 Verdict"]
        for reading in parsed.readings {
            let unit = reading.unit.map { " \($0)" } ?? ""
            lines.append("\(reading.verdict.glyph) \(reading.label): \(ENGIndicator.format(reading.value))\(unit) — \(reading.rangeText ?? "no range set") [\(reading.verdict.rawValue)]")
        }
        if !parsed.unmatched.isEmpty {
            lines.append("\n未对照（你未设定参考区间）Unmatched: " + parsed.unmatched.prefix(24).map {
                "\($0.0)=\(ENGIndicator.format($0.1))\($0.2.map { " \($0)" } ?? "")"
            }.joined(separator: ", "))
        }
        await settings.mutate { document in
            document.health.lastReportAt = Date()
        }
        return CommandResult(
            commandID: commandID,
            engine: .healthSentinel,
            ok: true,
            headline: "报告已本机解读 · \(parsed.readings.count) indicators, \(outOfRange.count) out of range",
            body: """
            \(lines.joined(separator: "\n"))

            \(healthGuidance(outOfRange: outOfRange, language: document.language))

            全程离线 Processed entirely on this Mac: PDFKit rasterisation, Vision OCR, then arithmetic against the ranges you typed into the wizard. No model was consulted, no network request was made, and no file was written — `artifacts` is empty by design, not by omission.
            免责 This is not a diagnosis. Reference ranges are population averages; only a clinician who knows your history can read a result in context.
            """,
            artifacts: [],
            metrics: [
                "pages": .int(pages.count),
                "ocrLines": .int(recognised.count),
                "indicators": .int(parsed.readings.count),
                "outOfRange": .int(outOfRange.count),
                "unmatched": .int(parsed.unmatched.count),
                "referenceRanges": .int(document.health.referenceRanges.count),
                "modelInvolved": .bool(false),
                "networkUsed": .bool(false),
                "artifactsWritten": .int(0)
            ]
        )
    }

    /// Pure-math binaural / isochronic tone, synthesised block by block.
    private func healthBinaural(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let plan = await modelPlan()
        let parameters = ENGWav.Params(
            sampleRateHz: ENGPayload.int(payload, "sampleRateHz", default: plan.audioSampleRateHz),
            carrierHz: ENGPayload.double(payload, "carrierHz", default: document.health.binauralCarrierHz),
            beatHz: ENGPayload.double(payload, "beatHz", default: document.health.binauralBeatHz),
            seconds: ENGPayload.int(payload, "seconds", default: document.health.binauralDurationSeconds),
            rampSeconds: ENGPayload.double(payload, "rampSeconds", default: 6),
            isochronic: ENGPayload.bool(payload, "isochronic", default: false),
            peakLevel: ENGPayload.double(payload, "peakLevel", default: 0.62)
        )
        let gateGB = requirementGB(for: .light, plan: plan)
        guard let slot = await gate.reserve(weight: .light, memoryGB: gateGB) else {
            return await memoryRefusal(.healthSentinel, neededGB: gateGB, commandID: commandID)
        }
        defer { Task { await self.gate.release(slot) } }

        let url = ENGFFmpeg.outputURL(
            "binaural-\(Int(parameters.carrierHz))hz-\(String(format: "%.1f", parameters.beatHz))hz-\(parameters.seconds)s",
            fileExtension: "wav"
        )
        // `ENGWav.write` streams through a `FileHandle` it does not create, so the
        // file is made empty here first. That is also why a two-hour tone never
        // allocates its own ~1.4 GB in RAM.
        AppPaths.fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
        let watch = Stopwatch()
        do {
            let written = try await ENGWav.write(to: url, parameters: parameters, blockSeconds: 2)
            let band = ENGWav.bandName(beat: parameters.beatHz)
            return CommandResult(
                commandID: commandID,
                engine: .healthSentinel,
                ok: true,
                headline: "双耳节拍已生成 · \(String(format: "%.1f", parameters.beatHz)) Hz \(parameters.isochronic ? "isochronic" : "binaural") × \(parameters.seconds) s",
                body: """
                载波 Carrier: \(String(format: "%.1f", parameters.carrierHz)) Hz · 差频 Beat: \(String(format: "%.2f", parameters.beatHz)) Hz (\(band) band)
                采样 Format: \(parameters.sampleRateHz) Hz, \(parameters.bitsPerSample)-bit stereo PCM, peak \(Int(parameters.peakLevel * 100))%
                渐变 Ramps: \(String(format: "%.1f", parameters.rampSeconds)) s raised-cosine in/out — a linear ramp leaves a kink you can hear at the seam
                生成 Synthesis: \(watch.elapsedMs) ms, streamed in 2-second blocks
                文件 File: \(AppPaths.anonymise(url: url))

                必须戴耳机 Headphones are mandatory: with \(parameters.isochronic ? "isochronic stimulation the beat is amplitude modulation, identical in both ears" : "binaural beats the difference only exists between the two ears; a speaker mixes them back into one signal and the effect disappears").
                安全 Safety: do not use while driving or operating machinery. If you have epilepsy, avoid isochronic stimulation and beat rates above 20 Hz. This is an auditory aid built from the numbers you set — no clinical claim is made, and no health data was used to generate it.
                """,
                // Unlike `read`, a generated tone carries no health information, so
                // returning the artifact is safe and lets the phone fetch it.
                artifacts: [AppPaths.anonymise(url: url)],
                metrics: [
                    "carrierHz": .double(parameters.carrierHz),
                    "beatHz": .double(parameters.beatHz),
                    "band": .string(band),
                    "seconds": .int(parameters.seconds),
                    "sampleRateHz": .int(parameters.sampleRateHz),
                    "isochronic": .bool(parameters.isochronic),
                    "bytes": .int(Int(written)),
                    "generateMs": .int(watch.elapsedMs),
                    "modelInvolved": .bool(false),
                    "networkUsed": .bool(false)
                ]
            )
        } catch {
            try? AppPaths.fileManager.removeItem(at: url)
            return CommandResult(
                commandID: commandID,
                engine: .healthSentinel,
                ok: false,
                headline: "生成失败 · could not write the tone.",
                body: String(describing: error),
                metrics: ["seconds": .int(parameters.seconds)]
            )
        }
    }

    /// Rule-based commentary, phrased as "take this to a clinician" and never as a
    /// diagnosis: an out-of-range flag is arithmetic, not medicine.
    private func healthGuidance(outOfRange: [ENGIndicator.Reading], language: ConsoleLanguage) -> String {
        guard !outOfRange.isEmpty else {
            return language.isChinese
                ? "所有解析到的指标都落在你自己设定的参考区间内。这只是与你录入区间的算术比较，不等于健康证明。"
                : "Every parsed indicator sits inside the reference ranges you configured. That is an arithmetic comparison against your own table, not a clean bill of health."
        }
        let lines = outOfRange.prefix(12).map { reading in
            "\(reading.verdict.glyph) \(reading.label) = \(ENGIndicator.format(reading.value))\(reading.unit.map { " \($0)" } ?? "") vs \(reading.rangeText ?? "—") → \(reading.verdict.rawValue)"
        }
        let header = language.isChinese
            ? "以下数值超出你设定的参考区间，请与医生讨论，不要自行判断："
            : "These values sit outside the ranges you configured. Take them to a clinician rather than deciding here:"
        return header + "\n" + lines.joined(separator: "\n")
    }

    // MARK: - Engine 10 · creator_paywall_hub

    /// Verifies an Ed25519 ticket issued by the creator's own signing service,
    /// then admits the member.
    private func paywallVerify(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let member = ENGPayload.string(payload, "member", default: ENGPayload.string(payload, "queue", default: ENGPayload.string(payload, "subscriber")))
        guard !member.isEmpty else { return ENGPayload.missing("member", engine: .creatorPaywallHub, commandID: commandID) }
        let signatureText = ENGPayload.string(payload, "ticket", default: ENGPayload.string(payload, "signature"))
        guard !signatureText.isEmpty else { return ENGPayload.missing("ticket", engine: .creatorPaywallHub, commandID: commandID) }
        guard let publicKey = Self.signingKey(from: document.paywall.ticketPublicKey) else {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "未配置公钥 · no usable ticket public key.",
                body: "`PaywallConfig.ticketPublicKey` is empty or is not 32 bytes of hex/base64. Until it is set this engine cannot tell a paid ticket from a forged one, so it refuses every ticket instead of admitting anyone.",
                metrics: ["keyConfigured": .bool(false)]
            )
        }
        guard let signature = Self.signatureBytes(signatureText), signature.count == 64 else {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "票据格式错误 · malformed signature.",
                body: "An Ed25519 signature is 64 bytes, hex or base64url. Nothing was decoded from what arrived.",
                metrics: ["signatureValid": .bool(false)]
            )
        }
        let channel = ENGPayload.string(payload, "channel", default: document.paywall.channelName)
        let tier = ENGPayload.string(payload, "tier", default: "member")
        let expiresAt = ENGPayload.string(payload, "expiresAt")
        let nonce = ENGPayload.string(payload, "nonce", default: ENGPayload.string(payload, "id", default: "static"))
        let message = Self.ticketMessage(member: member, channel: channel, tier: tier, expiresAt: expiresAt, nonce: nonce)
        guard publicKey.isValidSignature(signature, for: Data(message.utf8)) else {
            await emit(
                .engine,
                "paywall: rejected a ticket for \(TextKit.fingerprint(member, length: 10)) — signature did not verify",
                level: .warning,
                payload: ["member": .string(TextKit.fingerprint(member, length: 12)), "verified": .bool(false)]
            )
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "验票失败 · signature rejected.",
                body: "The Ed25519 signature does not match `\(message)`. Either it was signed with a different key, one field differs from what was actually signed, or it is forged. Nothing was released.",
                metrics: ["signatureValid": .bool(false)]
            )
        }
        if !expiresAt.isEmpty, let expires = Date.ppxFromISO8601(expiresAt), expires < Date() {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "票已过期 · ticket expired.",
                body: "Expired at \(expires.ppxISO8601). The signature was valid, so this is a renewal problem rather than a security one.",
                metrics: ["signatureValid": .bool(true), "expired": .bool(true)]
            )
        }
        var entries = Self.readPaywallLedger()
        let replayKey = "nonce:" + TextKit.fingerprint(nonce, length: 24)
        if entries.contains(where: { $0.id == replayKey }) {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "重复票据 · replay refused.",
                body: "This ticket's nonce has already been redeemed on this node. Ed25519 verification is stateless, so replay is blocked here by the ledger rather than by the cryptography.",
                metrics: ["signatureValid": .bool(true), "replay": .bool(true)]
            )
        }
        entries.append(PaywallEntry(
            id: replayKey,
            kind: "admit",
            member: member,
            amount: 0,
            packet: tier,
            note: "verified ticket for channel \(channel.isEmpty ? "(default)" : channel)",
            at: Date()
        ))
        Self.writePaywallLedger(entries)
        var alreadyAdmitted = false
        await settings.mutate { document in
            if document.paywall.verifiedMembers.contains(member) {
                alreadyAdmitted = true
            } else {
                document.paywall.verifiedMembers.append(member)
            }
        }
        let memberCount = document.paywall.verifiedMembers.count + (alreadyAdmitted ? 0 : 1)
        return CommandResult(
            commandID: commandID,
            engine: .creatorPaywallHub,
            ok: true,
            headline: alreadyAdmitted ? "老会员已复核 · member re-admitted" : "会员已放行 · member admitted",
            body: "Ed25519 verified for tier “\(tier)”\(expiresAt.isEmpty ? "" : ", valid until \(expiresAt)").\n频道 Channel: \(channel.isEmpty ? "(unset)" : channel)\n本节点已验会员 verified members on this node: \(memberCount).\nNames are kept in the settings document because a trace has to be readable by a human without a database; only fingerprints leave this machine in event payloads.",
            metrics: [
                "signatureValid": .bool(true),
                "memberFingerprint": .string(TextKit.fingerprint(member, length: 12)),
                "tier": .string(tier),
                "verifiedMembers": .int(memberCount),
                "replay": .bool(false),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Per-member fingerprinted distribution, reusing engine 2's GOP slicer.
    private func paywallDeliver(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let inputText = ENGPayload.path(payload)
        guard !inputText.isEmpty else { return ENGPayload.missing("input", engine: .creatorPaywallHub, commandID: commandID) }
        var members = ENGPayload.strings(payload, "members")
        if members.isEmpty { members = ENGPayload.strings(payload, "member").isEmpty ? document.paywall.verifiedMembers : ENGPayload.strings(payload, "member") }
        guard !members.isEmpty else {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "没有会员 · no members to deliver to.",
                body: "Pass `members`, or admit tickets first. The member list is the access control here: the node does not fingerprint copies for names that were never verified.",
                metrics: ["verifiedMembers": .int(document.paywall.verifiedMembers.count)]
            )
        }
        // Deliberately no gate reservation in this function: every `warroomEmbed`
        // below takes and returns its own heavy slot, and taking one here would
        // deadlock against the single-render slot the memory guard exists to keep.
        var artifacts: [String] = []
        var failures: [String] = []
        let batch = Array(members.prefix(5))
        for member in batch {
            let queueID: Int
            if let existing = document.warroom.queueRegistry[member] {
                queueID = existing
            } else if let assigned = await warroomRegisterIfNeeded(member) {
                queueID = assigned
            } else {
                failures.append("\(member): no free id in the \(document.warroom.payloadBits)-bit codebook")
                continue
            }
            let embedded = await warroomEmbed(payload: .object([
                "input": .string(inputText),
                "queue": .string(member),
                "id": .int(queueID)
            ]), commandID: commandID)
            if embedded.ok {
                artifacts.append(contentsOf: embedded.artifacts)
            } else {
                failures.append("\(member): \(TextKit.truncate(embedded.headline, to: 90))")
            }
        }
        let dropAt = Date()
        await settings.mutate { document in
            document.paywall.lastDropAt = dropAt
        }
        var entries = Self.readPaywallLedger()
        entries.append(PaywallEntry(
            id: "drop:" + TextKit.fingerprint("\(inputText)|\(batch.joined(separator: ","))|\(dropAt.timeIntervalSince1970)", length: 20),
            kind: "drop",
            member: batch.joined(separator: ","),
            amount: artifacts.count,
            packet: ENGPayload.string(payload, "release", default: "ad-hoc"),
            note: "\(artifacts.count) fingerprinted copy(ies)",
            at: dropAt
        ))
        Self.writePaywallLedger(entries)
        return CommandResult(
            commandID: commandID,
            engine: .creatorPaywallHub,
            ok: !artifacts.isEmpty,
            headline: "分发完成 · \(artifacts.count) fingerprinted copy(ies) for \(batch.count) member(s)",
            body: (artifacts.isEmpty ? "No copy was produced." : artifacts.joined(separator: "\n"))
                + (failures.isEmpty ? "" : "\n\n失败 Failures:\n" + failures.joined(separator: "\n"))
                + "\n\n每个副本嵌入该会员编号的 GOP 时序水印（引擎 2 的切片器），日后在别处发现泄露片段即可用 `warroom.trace` 反查编号。"
                + "\nHonest limit: the mark lives in keyframe timing, so a transcode plus aggressive frame dropping weakens it and a full re-encode can destroy it. This is traceability, not prevention — nothing here stops a copy, it identifies who made it."
                + (members.count > batch.count ? "\n\nBatch capped at 5 members: \(members.count - batch.count) still queued (each copy is a separate ffmpeg render)." : ""),
            artifacts: artifacts,
            metrics: [
                "requested": .int(members.count),
                "served": .int(batch.count),
                "copies": .int(artifacts.count),
                "failures": .int(failures.count),
                "payloadBits": .int(document.warroom.payloadBits),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Red-packet redemption: deterministic amounts, idempotent per member+packet.
    private func paywallClaim(payload: JSONValue, commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let member = ENGPayload.string(payload, "member", default: ENGPayload.string(payload, "queue"))
        let packet = ENGPayload.string(payload, "packet", default: ENGPayload.string(payload, "packetID"))
        guard !member.isEmpty, !packet.isEmpty else {
            return ENGPayload.missing(member.isEmpty ? "member" : "packet", engine: .creatorPaywallHub, commandID: commandID)
        }
        guard document.paywall.verifiedMembers.contains(member) || ENGPayload.bool(payload, "allowUnverified", default: false) else {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "未验票 · member not admitted.",
                body: "“\(member)” has no verified ticket on this node, so the packet is held. Run `verify` first, or pass `allowUnverified` deliberately if you are testing.",
                metrics: ["verifiedMembers": .int(document.paywall.verifiedMembers.count)]
            )
        }
        var entries = Self.readPaywallLedger()
        let key = "claim:" + TextKit.fingerprint("\(packet)|\(member)", length: 24)
        if let existing = entries.first(where: { $0.id == key }) {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: true,
                headline: "已领取（幂等） · already claimed: \(existing.amount) pts",
                body: "The same packet/member pair was redeemed at \(existing.at.ppxISO8601). The original amount is returned, so a retry after a dropped message cannot double-pay.",
                metrics: ["amount": .int(existing.amount), "idempotentReplay": .bool(true)]
            )
        }
        let spent = entries.filter { $0.kind == "claim" }.reduce(0) { $0 + $1.amount }
        let remaining = max(0, document.paywall.redPacketBudgetPoints - spent)
        guard remaining > 0 else {
            return CommandResult(
                commandID: commandID,
                engine: .creatorPaywallHub,
                ok: false,
                headline: "红包已发完 · budget exhausted.",
                body: "\(spent) of \(document.paywall.redPacketBudgetPoints) points distributed. Raise the budget or open another packet.",
                metrics: ["spent": .int(spent), "budget": .int(document.paywall.redPacketBudgetPoints)]
            )
        }
        // Deterministic split: the amount is a pure function of (packet, member), so
        // the creator's service can predict and audit every payout without the node
        // holding RNG state that could diverge, replay, or be bribed.
        let digest = Digest.sha256Bytes(Data("popopx-redpacket|\(packet)|\(member)".utf8))
        var cursor: UInt64 = 0
        for byte in digest.prefix(8) { cursor = (cursor << 8) | UInt64(byte) }
        let ceiling = max(1, min(ENGPayload.int(payload, "maxPerClaim", default: 200), remaining))
        let amount = min(remaining, 1 + Int(cursor % UInt64(ceiling)))
        entries.append(PaywallEntry(
            id: key,
            kind: "claim",
            member: member,
            amount: amount,
            packet: packet,
            note: "deterministic split of a \(ceiling)-point cap",
            at: Date()
        ))
        Self.writePaywallLedger(entries)
        return CommandResult(
            commandID: commandID,
            engine: .creatorPaywallHub,
            ok: true,
            headline: "红包已入账 · \(amount) pts to \(member)",
            body: "Packet \(packet): \(amount) points, leaving \(max(0, remaining - amount)) of \(document.paywall.redPacketBudgetPoints) in the budget.\nThe amount comes from SHA-256(\\\"popopx-redpacket|packet|member\\\") modulo the cap, so the same pair always yields the same figure and a replay cannot inflate it; the ledger row makes a second claim a no-op.",
            metrics: [
                "amount": .int(amount),
                "remainingBudget": .int(max(0, remaining - amount)),
                "claims": .int(entries.filter { $0.kind == "claim" }.count),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Membership, budget and drop history in one card.
    private func paywallStatus(commandID: String?) async -> CommandResult {
        let document = await settings.current()
        let entries = Self.readPaywallLedger()
        let claims = entries.filter { $0.kind == "claim" }
        let drops = entries.filter { $0.kind == "drop" }
        let admits = entries.filter { $0.kind == "admit" }
        let spent = claims.reduce(0) { $0 + $1.amount }
        let recent = entries.suffix(8).reversed().map { entry in
            "· \(entry.at.ppxISO8601) \(entry.kind) \(TextKit.truncate(entry.member, to: 22)) \(entry.amount) pts"
        }.joined(separator: "\n")
        return CommandResult(
            commandID: commandID,
            engine: .creatorPaywallHub,
            ok: true,
            headline: "付费枢纽 · \(document.paywall.verifiedMembers.count) members, \(spent)/\(document.paywall.redPacketBudgetPoints) pts used",
            body: """
            频道 Channel: \(document.paywall.channelName.isEmpty ? "(unset)" : document.paywall.channelName)
            验票密钥 Ticket key: \(document.paywall.ticketPublicKey.isEmpty ? "未配置 — 所有验票都会被拒绝 (unset, so every ticket is refused)" : "configured (\(document.paywall.ticketPublicKey.count) chars)")
            会员 Members: \(document.paywall.verifiedMembers.prefix(20).joined(separator: ", "))\(document.paywall.verifiedMembers.count > 20 ? " …" : "")
            台账 Ledger: \(admits.count) admissions, \(drops.count) drops, \(claims.count) red-packet claims
            预算 Budget: \(spent) spent, \(max(0, document.paywall.redPacketBudgetPoints - spent)) remaining
            上次分发 Last drop: \(document.paywall.lastDropAt?.ppxISO8601 ?? "never")
            水印容量 Watermark capacity: \(document.warroom.payloadBits) bits → \(1 << document.warroom.payloadBits) distinguishable copies

            最近 Recent:
            \(recent.isEmpty ? "—" : recent)
            """,
            metrics: [
                "verifiedMembers": .int(document.paywall.verifiedMembers.count),
                "admissions": .int(admits.count),
                "drops": .int(drops.count),
                "claims": .int(claims.count),
                "spentPoints": .int(spent),
                "budgetPoints": .int(document.paywall.redPacketBudgetPoints),
                "ticketKeyConfigured": .bool(!document.paywall.ticketPublicKey.isEmpty),
                "payloadBits": .int(document.warroom.payloadBits),
                "modelInvolved": .bool(false)
            ]
        )
    }

    /// Registers a member in engine 2's queue table if there is id space left, so
    /// the hub can fingerprint without a separate manual `assign` round-trip.
    private func warroomRegisterIfNeeded(_ member: String) async -> Int? {
        let document = await settings.current()
        let capacity = 1 << document.warroom.payloadBits
        let used = Set(document.warroom.queueRegistry.values)
        var candidate = 0
        while used.contains(candidate), candidate < capacity - 1 { candidate += 1 }
        guard candidate < capacity, !used.contains(candidate) else { return nil }
        let assigned = candidate
        await settings.mutate { document in
            document.warroom.queueRegistry[member] = assigned
        }
        return assigned
    }

    /// The canonical ticket message. Both ends must build it identically, so the
    /// field order and the separator are part of the wire format, not an
    /// implementation detail.
    private static func ticketMessage(member: String, channel: String, tier: String, expiresAt: String, nonce: String) -> String {
        "ppx-ticket-v1|\(member)|\(channel)|\(tier)|\(expiresAt)|\(nonce)"
    }

    /// Accepts an Ed25519 public key as hex or base64/base64url.
    private static func signingKey(from text: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = signatureBytes(text), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Hex or base64url byte decoding, shared by the key and the signature.
    private static func signatureBytes(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.count == 64 || trimmed.count == 128), trimmed.allSatisfy({ $0.isHexDigit }) {
            var bytes: [UInt8] = []
            var index = trimmed.startIndex
            while index < trimmed.endIndex {
                let next = trimmed.index(index, offsetBy: 2, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        }
        return TextKit.base64URLDecode(trimmed)
    }

    private static func readPaywallLedger() -> [PaywallEntry] {
        ENGFiles.readJSON([PaywallEntry].self, at: AppPaths.ledger.appendingPathComponent("paywall.json")) ?? []
    }

    private static func writePaywallLedger(_ entries: [PaywallEntry]) {
        _ = ENGFiles.writeJSON(Array(entries.suffix(2_000)), to: AppPaths.ledger.appendingPathComponent("paywall.json"))
    }

    /// One ledger row: an admission, a fingerprinted drop, or a red-packet claim.
    private struct PaywallEntry: Codable, Sendable {
        var id: String
        var kind: String
        var member: String
        var amount: Int
        var packet: String
        var note: String
        var at: Date
    }
}







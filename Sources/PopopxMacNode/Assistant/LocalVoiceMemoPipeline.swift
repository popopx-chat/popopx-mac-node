//
//  LocalVoiceMemoPipeline.swift
//  PopopxMacNode — phone voice memos, transcribed without leaving the Mac.
//
//  The pipeline has three deliberately separate stages:
//
//    ingest      a quarantined audio file, path-checked against the folders this
//                node accepts inbound files in;
//    transcribe   Apple's on-device recognizer, or a whisper.cpp server that the
//                edge boundary has proved is 127.0.0.1;
//    propose      deterministic extraction of todos / schedule hints / reply
//                drafts. Each one is an `AssistantActionKind.voiceTask` proposal.
//
//  The transcript is *not* written to the episodic index at ingest time. Indexing
//  is a write, so it waits for the owner's receipt; until then the text lives in
//  this actor's memory only. That is the same rule the mail bridge follows.
//

import Foundation

#if canImport(Speech)
import Speech
#endif

// MARK: - Transcripts

public struct VoiceTranscript: Sendable, Equatable {
    public var text: String
    public var engine: String
    public var onDevice: Bool

    public init(text: String, engine: String, onDevice: Bool) {
        self.text = text
        self.engine = engine
        self.onDevice = onDevice
    }
}

public protocol VoiceTranscribing: Sendable {
    var engineName: String { get }
    var isOnDevice: Bool { get }
    func isAvailable() async -> Bool
    func transcribe(audioURL: URL, locale: Locale) async throws -> VoiceTranscript
}

public enum VoiceTranscriptionError: Error, Equatable, CustomStringConvertible {
    case unavailable
    case refused(String)
    case timedOut
    case empty

    public var description: String {
        switch self {
        case .unavailable: return "本机语音识别不可用 / on-device speech is unavailable"
        case .refused(let reason): return "语音识别被拒绝 / speech refused: \(reason)"
        case .timedOut: return "语音识别超时 / speech timed out"
        case .empty: return "没有识别到语音 / no speech was recognized"
        }
    }
}

// MARK: - Actions

public enum VoiceActionKind: String, Codable, Sendable, CaseIterable {
    case todo
    case schedule
    case replyDraft = "reply_draft"

    public var labelZh: String {
        switch self {
        case .todo: return "待办"
        case .schedule: return "日程建议"
        case .replyDraft: return "回复草稿"
        }
    }
}

public struct VoiceActionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { target }
    public var target: String
    public var kind: VoiceActionKind
    public var title: String
    public var detail: String
    public var digest: String
    public var sourceHash: String
    public var createdAt: Date

    public init(
        target: String,
        kind: VoiceActionKind,
        title: String,
        detail: String,
        digest: String,
        sourceHash: String,
        createdAt: Date
    ) {
        self.target = target
        self.kind = kind
        self.title = title
        self.detail = detail
        self.digest = digest
        self.sourceHash = sourceHash
        self.createdAt = createdAt
    }
}

public struct VoiceIngestReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public var engine: String
    public var onDevice: Bool
    public var transcriptCharacters: Int
    public var actions: [VoiceActionItem]
    public var audioHash: String
    public var boundary: String

    public init(
        ok: Bool = false,
        detail: String = "",
        engine: String = "",
        onDevice: Bool = false,
        transcriptCharacters: Int = 0,
        actions: [VoiceActionItem] = [],
        audioHash: String = "",
        boundary: String = "零上云：仅 Apple 本机识别或 127.0.0.1 whisper / no cloud: Apple on-device or loopback whisper only"
    ) {
        self.ok = ok
        self.detail = detail
        self.engine = engine
        self.onDevice = onDevice
        self.transcriptCharacters = transcriptCharacters
        self.actions = actions
        self.audioHash = audioHash
        self.boundary = boundary
    }

    public static let empty = VoiceIngestReport()
}

public struct VoiceMemoCard: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var engine: String
    public var onDevice: Bool
    public var pendingActions: Int
    public var ingested: Int
    public var lastIngestedAt: Date?
    public var lastDetail: String
    public var boundary: String

    public init(
        enabled: Bool = false,
        engine: String = "",
        onDevice: Bool = true,
        pendingActions: Int = 0,
        ingested: Int = 0,
        lastIngestedAt: Date? = nil,
        lastDetail: String = "",
        boundary: String = "手机音频 → 隔离目录 → 本机识别 → 审批后才写入索引 / phone audio → quarantine → local speech → index only after approval"
    ) {
        self.enabled = enabled
        self.engine = engine
        self.onDevice = onDevice
        self.pendingActions = pendingActions
        self.ingested = ingested
        self.lastIngestedAt = lastIngestedAt
        self.lastDetail = lastDetail
        self.boundary = boundary
    }

    public static let empty = VoiceMemoCard()
}

// MARK: - Pipeline

public actor LocalVoiceMemoPipeline {
    public static let maximumAudioBytes = 25 * 1_024 * 1_024
    public static let maximumTranscriptCharacters = 8_000
    public static let maximumActions = 5
    public static let maximumPendingActions = 48

    private let transcribers: [any VoiceTranscribing]
    private let rag: LocalEpisodicRAG?
    private let store: AssistantAuditStore
    private let inboxRoots: [URL]
    private let whisper: (any VoiceTranscribing)?
    private var actions: [String: VoiceActionItem] = [:]
    private var transcriptByTarget: [String: String] = [:]
    private var lastIngestAt: Date?
    private var lastDetail = ""
    private var ingested = 0
    private var activeEngine = ""
    private var activeOnDevice = true

    public init(
        transcribers: [any VoiceTranscribing],
        rag: LocalEpisodicRAG? = nil,
        store: AssistantAuditStore,
        inboxRoots: [URL] = [AppPaths.quarantine],
        whisper: (any VoiceTranscribing)? = nil
    ) {
        self.transcribers = transcribers
        self.rag = rag
        self.store = store
        self.inboxRoots = inboxRoots
        self.whisper = whisper
    }

    // MARK: Ingest

    /// Validates the quarantined file, transcribes it, and returns the actions
    /// that should become proposals. No proposal is created here: the manager owns
    /// the gate, and one place minting receipts is one place to audit.
    public func ingest(audioURL: URL, now: Date = Date()) async -> VoiceIngestReport {
        let validated = validate(audioURL)
        guard case .success(let url) = validated else {
            await store.record(
                channel: "voice",
                event: "ingest_refused",
                detail: (try? validated.get()) == nil ? "path or format refused" : "refused",
                outcome: "refused",
                at: now
            )
            return VoiceIngestReport(ok: false, detail: "音频被拒绝 / audio refused")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return VoiceIngestReport(ok: false, detail: "无法读取音频 / the audio file could not be read")
        }
        let audioHash = Digest.sha256Hex(data).prefix(16).description
        _ = size
        var lastReason = ""
        var tried: [String] = []
        for transcriber in transcribers + (whisper.map { [$0] } ?? []) {
            guard await transcriber.isAvailable() else {
                tried.append("\(transcriber.engineName): unavailable")
                continue
            }
            do {
                let transcript = try await transcribe(transcriber, url: url)
                let clean = String(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maximumTranscriptCharacters))
                guard !clean.isEmpty else { throw VoiceTranscriptionError.empty }
                let extracted = Self.extract(from: clean, createdAt: now)
                for item in extracted {
                    if actions.count >= Self.maximumPendingActions {
                        actions.removeValue(forKey: actions.keys.first ?? "")
                        transcriptByTarget.removeValue(forKey: transcriptByTarget.keys.first ?? "")
                    }
                    actions[item.target] = item
                    transcriptByTarget[item.target] = clean
                }
                ingested += 1
                lastIngestAt = now
                lastDetail = "\(clean.count) 字 · \(extracted.count) 个行动项 · \(transcript.engine)"
                activeEngine = transcript.engine
                activeOnDevice = transcript.onDevice
                await store.record(
                    channel: "voice",
                    event: "transcribed",
                    detail: "chars \(clean.count) · actions \(extracted.count) · engine \(transcript.engine) · audio \(audioHash)",
                    outcome: "ok",
                    at: now
                )
                return VoiceIngestReport(
                    ok: true,
                    detail: "转录完成 · \(extracted.count) 个行动项待审批 / transcribed · \(extracted.count) pending actions",
                    engine: transcript.engine,
                    onDevice: transcript.onDevice,
                    transcriptCharacters: clean.count,
                    actions: extracted,
                    audioHash: String(audioHash)
                )
            } catch {
                lastReason = AssistantRedaction.scrub(String(describing: error))
                tried.append("\(transcriber.engineName): \(lastReason)")
            }
        }
        lastDetail = lastReason.isEmpty ? "没有可用的本机识别器 / no on-device recognizer" : lastReason
        await store.record(
            channel: "voice",
            event: "transcribe_failed",
            detail: tried.joined(separator: " | "),
            outcome: "failed",
            at: now
        )
        return VoiceIngestReport(
            ok: false,
            detail: "转录失败 / transcription failed · \(lastDetail)",
            audioHash: String(audioHash)
        )
    }

    /// Called by the manager after `AssistantApprovalGate.validateExecution`
    /// succeeded. Re-checks the binding against the action it kept in memory, then
    /// writes the transcript to the sealed index — the one write in this pipeline.
    public func perform(target: String, binding: AssistantApprovalBinding, now: Date = Date()) async -> (ok: Bool, detail: String) {
        guard binding.kind == .voiceTask, binding.target == target else {
            return (false, "审批绑定与语音行动项不一致 / the binding does not match this voice action")
        }
        guard let item = actions[target], item.digest == binding.digest else {
            return (false, "语音行动项不存在或已变化 / the voice action is gone or changed")
        }
        guard let transcript = transcriptByTarget[target], let rag else {
            return (false, "本地索引不可用 / the local index is unavailable")
        }
        let stored = await rag.record(
            kind: .voice,
            title: item.title,
            body: transcript,
            source: "voice/\(item.sourceHash)",
            occurredAt: now
        )
        guard stored != nil else {
            return (false, "本地索引写入失败 / the local index refused the write")
        }
        actions.removeValue(forKey: target)
        transcriptByTarget.removeValue(forKey: target)
        await store.record(
            channel: "voice",
            event: "executed",
            detail: "\(item.kind.rawValue) · \(item.target) · chars \(transcript.count)",
            outcome: "ok",
            at: now
        )
        return (true, "已写入本地加密索引 / written to the local sealed index")
    }

    public func dismiss(target: String, now: Date = Date()) async {
        actions.removeValue(forKey: target)
        transcriptByTarget.removeValue(forKey: target)
        await store.record(
            channel: "voice",
            event: "rejected",
            detail: target,
            outcome: "rejected",
            at: now
        )
    }

    public func card() -> VoiceMemoCard {
        VoiceMemoCard(
            enabled: !transcribers.isEmpty || whisper != nil,
            engine: activeEngine.isEmpty
                ? (transcribers.first?.engineName ?? whisper?.engineName ?? "")
                : activeEngine,
            onDevice: activeOnDevice,
            pendingActions: actions.count,
            ingested: ingested,
            lastIngestedAt: lastIngestAt,
            lastDetail: lastDetail
        )
    }

    public func pendingCount() -> Int { actions.count }

    // MARK: Validation and transcription

    private func validate(_ audioURL: URL) -> Result<URL, VoiceTranscriptionError> {
        let allowed = ["m4a", "mp3", "wav", "caf", "aif", "aiff", "mp4", "flac", "ogg"]
        guard allowed.contains(audioURL.pathExtension.lowercased()) else {
            return .failure(.refused("unsupported audio extension"))
        }
        let resolved = audioURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .failure(.refused("the audio file does not exist"))
        }
        let scoped = inboxRoots.contains { root in
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.path == canonical || resolved.path.hasPrefix(canonical + "/")
        }
        guard scoped else {
            return .failure(.refused("the audio file is outside the inbound quarantine"))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= Self.maximumAudioBytes else {
            return .failure(.refused("audio size out of range"))
        }
        return .success(resolved)
    }

    private func transcribe(_ transcriber: any VoiceTranscribing, url: URL) async throws -> VoiceTranscript {
        try await withThrowingTaskGroup(of: VoiceTranscript.self) { group in
            group.addTask {
                try await transcriber.transcribe(audioURL: url, locale: Locale(identifier: "zh-Hans"))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                throw VoiceTranscriptionError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VoiceTranscriptionError.empty }
            return first
        }
    }

    // MARK: Extraction

    /// Deterministic and deliberately conservative: it never invents a time or a
    /// recipient. A sentence without an action verb becomes a todo summary rather
    /// than a calendar write.
    static func extract(from transcript: String, createdAt: Date) -> [VoiceActionItem] {
        let segments = transcript
            .split(whereSeparator: { $0 == "\n" || $0 == "。" || $0 == "!" || $0 == "？" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var items: [VoiceActionItem] = []
        var seen: Set<String> = []
        for segment in segments {
            let lowered = segment.lowercased()
            let kind: VoiceActionKind
            if lowered.hasPrefix("todo") || lowered.contains("待办") || lowered.contains("记得")
                || lowered.contains("remember to") || lowered.contains("remind me") || lowered.contains("提醒我") {
                kind = .todo
            } else if lowered.contains("安排") || lowered.contains("schedule") || lowered.contains("明天")
                || lowered.contains("tomorrow") || lowered.contains("下周") || lowered.contains("next week")
                || lowered.contains("点") && (lowered.contains("上午") || lowered.contains("下午")) {
                kind = .schedule
            } else if lowered.contains("回复") || lowered.contains("reply") || lowered.contains("答复") {
                kind = .replyDraft
            } else {
                continue
            }
            let clean = segment
                .replacingOccurrences(of: "待办：", with: "")
                .replacingOccurrences(of: "TODO:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(clean.prefix(120))
            guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { continue }
            let sourceHash = AssistantDigest.sha256(transcript).prefix(16).description
            let target = "voice/\(AssistantDigest.sha256("\(kind.rawValue)|\(title)|\(sourceHash)").prefix(16))"
            let digest = AssistantDigest.sha256("assistant.voice.v1|\(target)|\(kind.rawValue)|\(title)|\(sourceHash)")
            items.append(VoiceActionItem(
                target: target,
                kind: kind,
                title: title,
                detail: "\(kind.labelZh) · 来自手机语音备忘 / from a phone voice memo",
                digest: digest,
                sourceHash: sourceHash,
                createdAt: createdAt
            ))
            if items.count >= maximumActions { break }
        }
        if items.isEmpty, let first = segments.first {
            let title = String(first.prefix(120))
            let sourceHash = AssistantDigest.sha256(transcript).prefix(16).description
            let target = "voice/\(AssistantDigest.sha256("summary|\(title)|\(sourceHash)").prefix(16))"
            let digest = AssistantDigest.sha256("assistant.voice.v1|\(target)|todo|\(title)|\(sourceHash)")
            items.append(VoiceActionItem(
                target: target,
                kind: .todo,
                title: title,
                detail: "语音备忘摘要 · 待机主确认 / voice memo summary awaiting the owner",
                digest: digest,
                sourceHash: sourceHash,
                createdAt: createdAt
            ))
        }
        return items
    }
}

// MARK: - Apple Speech

#if canImport(Speech)
/// `requiresOnDeviceRecognition = true` is the whole contract: if the asset for
/// the locale is not installed, the request fails rather than silently using
/// Apple's servers.
public struct AppleOnDeviceSpeechTranscriber: VoiceTranscribing {
    public let engineName = "Apple Speech · on-device"
    public let isOnDevice = true

    public init() {}

    public func isAvailable() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
            ?? SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer else { return false }
        let authorization = SFSpeechRecognizer.authorizationStatus()
        guard authorization != .denied, authorization != .restricted else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    public func transcribe(audioURL: URL, locale: Locale) async throws -> VoiceTranscript {
        guard Bundle.main.bundleIdentifier != nil else { throw VoiceTranscriptionError.unavailable }
        try await requestAuthorization()
        let recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw VoiceTranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = SpeechContinuation(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.finish(.failure(VoiceTranscriptionError.refused(error.localizedDescription)))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    once.finish(.success(result.bestTranscription.formattedString))
                }
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceTranscriptionError.empty
        }
        return VoiceTranscript(text: text, engine: engineName, onDevice: true)
    }

    private func requestAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw VoiceTranscriptionError.refused("speech recognition is not authorized")
        case .notDetermined:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else {
                throw VoiceTranscriptionError.refused("speech recognition is not authorized")
            }
        @unknown default:
            throw VoiceTranscriptionError.refused("unknown speech authorization")
        }
    }
}

/// One continuation, once. The recognizer's callback is not documented as
/// single-shot, and a double resume traps the process.
private final class SpeechContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
#endif

// MARK: - Loopback whisper.cpp

public struct LoopbackWhisperTranscriber: VoiceTranscribing {
    public let engineName = "whisper.cpp · 127.0.0.1"
    public let isOnDevice = true
    private let endpoint: EdgeEndpoint?
    private let path: String

    public init(url: String = "http://127.0.0.1:8080/inference") {
        let resolved = try? EdgeBoundary.resolve(url: url, policy: .loopbackOnly)
        self.endpoint = resolved
        self.path = URLComponents(string: url)?.path ?? "/inference"
    }

    public func isAvailable() async -> Bool {
        guard let endpoint, let url = endpoint.url(path: path) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    public func transcribe(audioURL: URL, locale: Locale) async throws -> VoiceTranscript {
        guard let endpoint, let url = endpoint.url(path: path) else {
            throw VoiceTranscriptionError.unavailable
        }
        let data = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= LocalVoiceMemoPipeline.maximumAudioBytes else {
            throw VoiceTranscriptionError.refused("audio size out of range")
        }
        let boundary = "ppx-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"memo.\(audioURL.pathExtension)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceTranscriptionError.refused("the loopback server refused the request")
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let text = object["text"] as? String
        else {
            throw VoiceTranscriptionError.refused("the loopback server returned no transcript")
        }
        return VoiceTranscript(text: text, engine: engineName, onDevice: true)
    }
}
//
//  MailAssistantBridge.swift
//  PopopxMacNode — read-only mail triage, reply drafts, and an approval-gated send.
//
//  The bridge never touches a network itself; the transport is injected. That is
//  what lets the tests drive a fake IMAP/SMTP server without opening a socket, and
//  it keeps the security decisions in one place:
//
//  * **Reading is read-only.** The IMAP session opens `EXAMINE`, searches, and
//    fetches `BODY.PEEK[...]`, so a triage never marks a message as read.
//  * **The full body is transient.** It is used to classify and to build a
//    bounded snippet, then dropped. No snapshot, card or audit row can carry it.
//  * **Sending is an executor.** `sendApproved` calls `AssistantApprovalGate`
//    before it reads a credential or calls the transport. A pending, rejected,
//    expired, re-used or re-bound approval is refused there — not by asking a
//    model nicely.
//

import Foundation

// MARK: - Transport contract

public struct MailFetchedMessage: Sendable, Equatable {
    public var id: String
    public var subject: String
    public var from: String
    public var receivedAt: Date
    public var body: String
    public var unread: Bool

    public init(
        id: String,
        subject: String,
        from: String,
        receivedAt: Date,
        body: String,
        unread: Bool = true
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.receivedAt = receivedAt
        self.body = body
        self.unread = unread
    }
}

public protocol MailTransporting: Sendable {
    /// Fetches recent unread messages without mutating server state.
    func fetchRecent(
        account: MailAssistantConfig,
        password: String,
        since: Date,
        limit: Int
    ) async throws -> [MailFetchedMessage]

    /// Sends one approved draft over implicit TLS.
    func send(
        draft: MailOutgoingDraft,
        account: MailAssistantConfig,
        password: String
    ) async throws
}

// MARK: - Classifier seam

public struct MailClassifierMessage: Sendable, Equatable {
    public var id: String
    public var subject: String
    public var from: String
    public var snippet: String

    public init(id: String, subject: String, from: String, snippet: String) {
        self.id = id
        self.subject = subject
        self.from = from
        self.snippet = snippet
    }
}

public struct MailClassificationHint: Sendable, Equatable {
    public var category: MailCategory?
    public var amount: String?
    public var deadline: String?

    public init(category: MailCategory? = nil, amount: String? = nil, deadline: String? = nil) {
        self.category = category
        self.amount = amount
        self.deadline = deadline
    }
}

/// A local model may refine the rule result. It is an *injection point*, not a
/// requirement: when it is absent or fails, the structured rules below are the
/// answer. Nothing here sends mail text off the Mac — a production implementation
/// is expected to use the loopback Ollama endpoint.
public protocol MailBatchClassifying: Sendable {
    func classify(_ messages: [MailClassifierMessage]) async -> [String: MailClassificationHint]
}

// MARK: - Outcomes

public struct MailSendOutcome: Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public var proposalID: String

    public init(ok: Bool, detail: String, proposalID: String = "") {
        self.ok = ok
        self.detail = detail
        self.proposalID = proposalID
    }
}

// MARK: - Bridge

public actor MailAssistantBridge {
    public static let maximumBodyCharacters = 20_000
    public static let maximumSubjectCharacters = 180
    public static let maximumSnippetCharacters = 160
    public static let maximumMessagesInSnapshot = 20

    private var config: MailAssistantConfig
    private let secrets: HubSecretStoring
    private let transport: any MailTransporting
    private let gate: AssistantApprovalGate
    private let store: AssistantAuditStore
    private let clock: AssistantClock
    private var classifier: (any MailBatchClassifying)?

    private var messages: [AssistantMailMessageCard] = []
    private var drafts: [String: MailOutgoingDraft] = [:]
    private var draftOrder: [String] = []
    private var lastReadAt: Date?
    private var lastSendAt: Date?
    private var lastError = ""

    public init(
        config: MailAssistantConfig = MailAssistantConfig(),
        secrets: HubSecretStoring,
        transport: any MailTransporting,
        gate: AssistantApprovalGate,
        store: AssistantAuditStore,
        clock: AssistantClock = SystemAssistantClock(),
        classifier: (any MailBatchClassifying)? = nil
    ) {
        self.config = config.normalised
        self.secrets = secrets
        self.transport = transport
        self.gate = gate
        self.store = store
        self.clock = clock
        self.classifier = classifier
    }

    public func update(config next: MailAssistantConfig) {
        config = next.normalised
        if !config.enabled || !config.usable {
            // A draft made under an older account must not outlive a reconfiguration.
            drafts.removeAll()
            draftOrder.removeAll()
            messages = []
        }
    }

    public func setClassifier(_ next: (any MailBatchClassifying)?) {
        classifier = next
    }

    // MARK: - Read

    /// Fetches, classifies and drafts. This is `read` + `propose`; it never opens
    /// a write path and never creates an approval card.
    public func triage(now: Date? = nil) async -> AssistantMailTriage {
        let moment = now ?? clock.now
        guard config.enabled else {
            return AssistantMailTriage(summaryLines: ["邮件助手未启用 / mail is off"], fetchedAt: moment)
        }
        guard config.usable else {
            lastError = "地址、用户名或 TLS 端口不完整 / mail account is incomplete"
            await store.record(channel: "mail", event: "read_refused", detail: lastError, outcome: "refused", at: moment)
            return AssistantMailTriage(summaryLines: ["邮箱配置不完整 / mail account is incomplete"], fetchedAt: moment)
        }
        guard let password = secrets.secret(for: config.imapPasswordRef) else {
            lastError = "IMAP 口令未存入钥匙串 / the IMAP password is not in the Keychain"
            await store.record(channel: "mail", event: "read_refused", detail: lastError, outcome: "refused", at: moment)
            return AssistantMailTriage(summaryLines: ["IMAP 口令缺失 / IMAP password missing"], fetchedAt: moment)
        }

        let since = moment.addingTimeInterval(-Double(config.lookbackDays) * 86_400)
        await store.record(
            channel: "mail",
            event: "read_start",
            detail: "\(config.imapHost):993 · lookback \(config.lookbackDays)d · limit \(config.maxMessages)",
            at: moment
        )
        let fetched: [MailFetchedMessage]
        do {
            fetched = try await transport.fetchRecent(
                account: config,
                password: password,
                since: since,
                limit: config.maxMessages
            )
        } catch {
            lastError = AssistantRedaction.scrub(String(describing: error))
            await store.record(channel: "mail", event: "read_failed", detail: lastError, outcome: "failed", at: moment)
            return AssistantMailTriage(summaryLines: ["邮件读取失败 / mail fetch failed"], fetchedAt: moment)
        }

        let draftsBuilt = buildDrafts(from: fetched, now: moment)
        var hints: [String: MailClassificationHint] = [:]
        if let classifier {
            let inputs = fetched.prefix(config.maxMessages).map {
                MailClassifierMessage(
                    id: $0.id,
                    subject: String($0.subject.prefix(120)),
                    from: String($0.from.prefix(120)),
                    snippet: snippet($0.body)
                )
            }
            hints = await classifier.classify(Array(inputs))
        }

        var cards: [AssistantMailMessageCard] = []
        for message in fetched.prefix(config.maxMessages) {
            let cleanSnippet = snippet(message.body)
            let ruled = classify(subject: message.subject, from: message.from, snippet: cleanSnippet)
            let hint = hints[message.id]
            let category = hint?.category ?? ruled.category
            let amount = hint?.amount?.isEmpty == false ? hint!.amount! : extractAmount(message.subject + "\n" + cleanSnippet)
            let deadline = hint?.deadline?.isEmpty == false ? hint!.deadline! : extractDeadline(message.subject + "\n" + cleanSnippet)
            cards.append(AssistantMailMessageCard(
                id: message.id,
                subject: String(message.subject.prefix(160)),
                from: String(displaySender(message.from).prefix(120)),
                receivedAt: message.receivedAt,
                category: category,
                amount: String(amount.prefix(32)),
                deadline: String(deadline.prefix(40)),
                snippet: cleanSnippet,
                needsReply: category == .needsReply
            ))
        }

        messages = Array(cards.prefix(Self.maximumMessagesInSnapshot))
        lastReadAt = moment
        lastError = ""
        let counts = Dictionary(grouping: cards, by: { $0.category })
            .mapValues(\.count)
        let summaryLines = [
            "待回复 \(counts[.needsReply] ?? 0) · 账单 \(counts[.bill] ?? 0) · 邀请 \(counts[.invitation] ?? 0) · 通知 \(counts[.notification] ?? 0)",
            "回复草稿 \(draftsBuilt.count) 封，等待批准后发送"
        ]
        await store.record(
            channel: "mail",
            event: "read_done",
            detail: "\(cards.count) messages · \(draftsBuilt.count) drafts · \(counts.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: " "))",
            outcome: "ok",
            at: moment
        )
        return AssistantMailTriage(
            messages: cards,
            drafts: draftsBuilt,
            summaryLines: summaryLines,
            fetchedAt: moment
        )
    }

    public func recentMessages() -> [AssistantMailMessageCard] { messages }

    // MARK: - Propose send

    /// Wraps one draft in a receipt-bound proposal. The returned ticket's receipt
    /// goes to the phone card and is never part of a snapshot.
    public func propose(draft: MailOutgoingDraft, now: Date? = nil) async -> AssistantApprovalTicket? {
        let moment = now ?? clock.now
        guard config.enabled, config.usable else {
            await store.record(channel: "mail", event: "propose_refused", detail: "mail is off or incomplete", outcome: "refused", at: moment)
            return nil
        }
        guard secrets.secret(for: config.smtpPasswordRef) != nil else {
            lastError = "SMTP 口令未存入钥匙串 / the SMTP password is not in the Keychain"
            await store.record(channel: "mail", event: "propose_refused", detail: lastError, outcome: "refused", at: moment)
            return nil
        }
        let cleanTo = MailAssistantConfig.mailbox(draft.to)
        let cleanSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body
        guard !cleanTo.isEmpty else {
            await store.record(channel: "mail", event: "propose_refused", detail: "recipient", outcome: "refused", at: moment)
            return nil
        }
        guard !cleanSubject.isEmpty, cleanSubject.count <= Self.maximumSubjectCharacters else {
            await store.record(channel: "mail", event: "propose_refused", detail: "subject", outcome: "refused", at: moment)
            return nil
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.count <= Self.maximumBodyCharacters else {
            await store.record(channel: "mail", event: "propose_refused", detail: "body", outcome: "refused", at: moment)
            return nil
        }

        var canonical = draft
        canonical.to = cleanTo
        canonical.subject = cleanSubject
        let digest = canonical.digest
        do {
            let ticket = try await gate.propose(
                kind: .mailSend,
                target: cleanTo,
                digest: digest,
                title: "发送邮件 · \(cleanSubject)",
                detail: "To: \(cleanTo) · \(canonical.preview)",
                ttl: AssistantApprovalGate.defaultLifetime,
                now: moment
            )
            canonical.proposalID = ticket.proposalID
            drafts[ticket.proposalID] = canonical
            draftOrder.append(ticket.proposalID)
            await store.record(
                channel: "mail",
                event: "draft_proposed",
                detail: "\(cleanTo) · \(digest.prefix(12)) · \(canonical.body.count) chars",
                at: moment
            )
            return ticket
        } catch {
            lastError = AssistantRedaction.scrub(String(describing: error))
            await store.record(channel: "mail", event: "propose_refused", detail: lastError, outcome: "refused", at: moment)
            return nil
        }
    }

    public func draft(id: String) -> MailOutgoingDraft? { drafts[id] }

    public func draftCards() -> [AssistantDraftCard] {
        draftOrder.compactMap { id -> AssistantDraftCard? in
            guard let draft = drafts[id] else { return nil }
            return AssistantDraftCard(
                id: id,
                to: draft.to,
                subject: draft.subject,
                preview: draft.preview,
                digest: draft.digest,
                createdAt: clock.now
            )
        }
    }

    // MARK: - Execute send

    /// The executor entry. The gate check happens before the transport, the
    /// Keychain lookup and even the config check, so an unapproved or tampered
    /// request cannot learn anything about the account.
    public func sendApproved(
        _ draft: MailOutgoingDraft,
        approval: AssistantApproval,
        now: Date? = nil
    ) async -> MailSendOutcome {
        let moment = now ?? clock.now
        let canonical = draft
        let cleanTo = canonical.canonicalTarget
        let digest = canonical.digest
        do {
            _ = try await gate.validateExecution(
                id: approval.proposalID,
                receipt: approval.receipt,
                kind: .mailSend,
                target: cleanTo,
                digest: digest,
                now: moment
            )
        } catch {
            let detail = AssistantRedaction.scrub(String(describing: error))
            await store.record(
                channel: "mail",
                event: "send_refused",
                detail: "\(approval.proposalID.prefix(8)) · \(detail)",
                outcome: "refused",
                at: moment
            )
            return MailSendOutcome(ok: false, detail: detail, proposalID: approval.proposalID)
        }

        guard canonical.proposalID == approval.proposalID else {
            await gate.complete(id: approval.proposalID, ok: false, detail: "proposal id mismatch", now: moment)
            return MailSendOutcome(ok: false, detail: "提案标识不一致 / proposal id mismatch", proposalID: approval.proposalID)
        }
        guard config.enabled, config.usable else {
            await gate.complete(id: approval.proposalID, ok: false, detail: "mail off", now: moment)
            return MailSendOutcome(ok: false, detail: "邮件助手未启用 / mail is off", proposalID: approval.proposalID)
        }
        guard let password = secrets.secret(for: config.smtpPasswordRef) else {
            await gate.complete(id: approval.proposalID, ok: false, detail: "smtp credential missing", now: moment)
            return MailSendOutcome(ok: false, detail: "SMTP 口令缺失 / SMTP password missing", proposalID: approval.proposalID)
        }
        guard let stored = drafts[approval.proposalID], stored.digest == canonical.digest else {
            await gate.complete(id: approval.proposalID, ok: false, detail: "draft no longer present", now: moment)
            return MailSendOutcome(ok: false, detail: "草稿已失效 / the draft is no longer available", proposalID: approval.proposalID)
        }

        do {
            try await transport.send(draft: canonical, account: config, password: password)
        } catch {
            let detail = AssistantRedaction.scrub(String(describing: error))
            lastError = detail
            await gate.complete(id: approval.proposalID, ok: false, detail: detail, now: moment)
            await store.record(channel: "mail", event: "send_failed", detail: detail, outcome: "failed", at: moment)
            return MailSendOutcome(ok: false, detail: detail, proposalID: approval.proposalID)
        }

        lastSendAt = moment
        lastError = ""
        drafts.removeValue(forKey: approval.proposalID)
        draftOrder.removeAll { $0 == approval.proposalID }
        await gate.complete(id: approval.proposalID, ok: true, detail: "\(cleanTo) · \(digest.prefix(12))", now: moment)
        await store.record(
            channel: "mail",
            event: "sent",
            detail: "\(cleanTo) · \(digest.prefix(12)) · \(canonical.body.count) chars",
            outcome: "ok",
            at: moment
        )
        return MailSendOutcome(ok: true, detail: "已发送 / sent", proposalID: approval.proposalID)
    }

    // MARK: - Status

    public func status() -> AssistantMailCard {
        let value = config
        let imapStored = secrets.secret(for: value.imapPasswordRef) != nil
        let smtpStored = secrets.secret(for: value.smtpPasswordRef) != nil
        return AssistantMailCard(
            enabled: value.enabled,
            configured: value.hasAccount,
            usable: value.usable && imapStored && smtpStored,
            imapHost: value.imapHost,
            imapPort: value.imapPort,
            smtpHost: value.smtpHost,
            smtpPort: value.smtpPort,
            username: value.username,
            fromAddress: value.fromAddress,
            imapPasswordRef: value.imapPasswordRef,
            smtpPasswordRef: value.smtpPasswordRef,
            imapStored: imapStored,
            smtpStored: smtpStored,
            credentialBacking: secrets.backingName,
            lookbackDays: value.lookbackDays,
            maxMessages: value.maxMessages,
            lastReadAt: lastReadAt,
            lastSendAt: lastSendAt,
            lastError: lastError,
            triagedCount: messages.count,
            draftCount: drafts.count,
            messages: Array(messages.prefix(Self.maximumMessagesInSnapshot)),
            boundary: "IMAP 993 / SMTP 465 · implicit TLS · owner-pinned host · named egress exception"
        )
    }

    /// Drops drafts and cached summaries when the assistant is switched off or the
    /// account changes. Pending proposals are invalidated by the manager's gate.
    public func reset() {
        drafts.removeAll()
        draftOrder.removeAll()
        messages = []
        lastError = ""
    }

    // MARK: - Rules

    private func buildDrafts(from messages: [MailFetchedMessage], now: Date) -> [MailOutgoingDraft] {
        messages.compactMap { message in
            let snippetText = snippet(message.body)
            let category = classify(subject: message.subject, from: message.from, snippet: snippetText).category
            guard category == .needsReply else { return nil }
            guard let recipient = senderMailbox(message.from) else { return nil }
            let cleanSubject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = cleanSubject.lowercased().hasPrefix("re:")
                ? cleanSubject
                : "Re: " + String(cleanSubject.prefix(Self.maximumSubjectCharacters - 4))
            let short = String(cleanSubject.prefix(80))
            let body = """
            您好，

            已收到您关于「\(short)」的邮件，我会尽快回复。

            Hello, thank you for your message about "\(short)". I will reply shortly.

            —— POPOPX 私人助手 / Private Assistant（经机主批准后发送 / sent after owner approval）
            """
            return MailOutgoingDraft(to: recipient, subject: subject, body: body, inReplyTo: message.id)
        }
    }

    private func classify(subject: String, from: String, snippet: String) -> (category: MailCategory, amount: String, deadline: String) {
        let haystack = (subject + "\n" + from + "\n" + snippet).lowercased()
        let amount = extractAmount(haystack)
        let deadline = extractDeadline(haystack)
        let sender = from.lowercased()

        if containsAny(haystack, [
            "invitation", "invite", "calendar invite", "meeting", "zoom.us", "teams.microsoft",
            "会议", "邀请", "日程", "约会"
        ]) {
            return (.invitation, amount, deadline)
        }
        if !amount.isEmpty || containsAny(haystack, [
            "invoice", "receipt", "bill", "payment due", "amount due", "order #", "refund",
            "发票", "账单", "应付", "订单", "付款", "扣款", "续费"
        ]) {
            return (.bill, amount, deadline)
        }
        let looksAutomated = containsAny(sender, ["no-reply", "noreply", "notification", "mailer-daemon", "donotreply"])
            || containsAny(haystack, ["验证码", "verification code", "security alert", "newsletter", "unsubscribe", "自动通知"])
        if looksAutomated {
            return (.notification, amount, deadline)
        }
        if containsAny(haystack, ["请回复", "please reply", "please confirm", "confirm your", "需要确认", "waiting for your", "请确认", "?"]) {
            return (.needsReply, amount, deadline)
        }
        return (.notification, amount, deadline)
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func snippet(_ body: String) -> String {
        var text = body
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        // Quoted replies are not part of the new message; stop at the first quote marker.
        if let range = text.range(of: "\nOn ", options: [.backwards]) {
            text = String(text[..<range.lowerBound])
        }
        text = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if let regex = try? NSRegularExpression(pattern: "\\s{2,}") {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumSnippetCharacters))
    }

    private func displaySender(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(unknown sender)" : trimmed
    }

    private func senderMailbox(_ raw: String) -> String? {
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            return MailAssistantConfig.mailbox(String(raw[raw.index(after: open)..<close]))
        }
        if let candidate = raw.split(separator: " ").last(where: { $0.contains("@") }) {
            return MailAssistantConfig.mailbox(String(candidate))
        }
        return MailAssistantConfig.mailbox(raw)
    }

    private func extractAmount(_ text: String) -> String {
        let patterns = [
            "(?:USD|CNY|RMB|EUR|GBP)\\s?[0-9][0-9,]*(?:\\.[0-9]{1,2})?",
            "[¥￥$€£]\\s?[0-9][0-9,]*(?:\\.[0-9]{1,2})?",
            "(?:金额|应付|合计|总计|amount|total|due)[:：\\s]{0,3}(?:USD|CNY|RMB|EUR|GBP|[¥￥$€£])?\\s?[0-9][0-9,]*(?:\\.[0-9]{1,2})?"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let found = Range(match.range, in: text) else { continue }
            let value = text[found].trimmingCharacters(in: .whitespaces)
            if value.contains(where: \.isNumber) { return value }
        }
        return ""
    }

    private func extractDeadline(_ text: String) -> String {
        let patterns = [
            "\\b20[0-9]{2}[-/][0-9]{1,2}[-/][0-9]{1,2}\\b",
            "\\b[0-9]{1,2}月[0-9]{1,2}日\\b",
            "(?:截止|到期|due|deadline|before)[^\\n]{0,24}?\\b[0-9]{1,2}[-/][0-9]{1,2}\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let found = Range(match.range, in: text) else { continue }
            return String(text[found].prefix(40))
        }
        return ""
    }
}
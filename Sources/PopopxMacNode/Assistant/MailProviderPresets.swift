//
//  MailProviderPresets.swift
//  POPOPX Mac Node
//
//  One-click server templates for the six mailboxes the brief names. A preset is
//  data, not a code path: applying it writes the same four fields the owner would
//  type by hand, through `MailAssistantConfig.normalised`, so a preset cannot
//  widen what the transport accepts.
//
//  The node dials implicit TLS only (993 / 465). Where a provider's officially
//  documented submission port is 587 or 1025, the preset says so in its note
//  instead of pretending the handshake will succeed — a template that hides a
//  provider limit is a silent failure.
//

import Foundation

public struct MailProviderPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var imapHost: String
    public var smtpHost: String
    /// The node only implements implicit TLS, so these are constants of the
    /// transport rather than per-provider choices.
    public var imapPort: Int
    public var smtpPort: Int
    public var usernameHintZh: String
    public var usernameHintEn: String
    public var appPasswordZh: String
    public var appPasswordEn: String
    public var noteZh: String
    public var noteEn: String
    /// Proton Bridge listens on this Mac; every other preset names a remote host.
    public var loopbackOnly: Bool
    /// The provider's documented submission port when it is not 465, so the UI can
    /// tell the owner why a handshake may be refused.
    public var officialSMTPPort: Int?

    public init(
        id: String,
        displayName: String,
        imapHost: String,
        smtpHost: String,
        imapPort: Int = 993,
        smtpPort: Int = 465,
        usernameHintZh: String,
        usernameHintEn: String,
        appPasswordZh: String,
        appPasswordEn: String,
        noteZh: String,
        noteEn: String,
        loopbackOnly: Bool = false,
        officialSMTPPort: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.imapHost = imapHost
        self.smtpHost = smtpHost
        self.imapPort = imapPort
        self.smtpPort = smtpPort
        self.usernameHintZh = usernameHintZh
        self.usernameHintEn = usernameHintEn
        self.appPasswordZh = appPasswordZh
        self.appPasswordEn = appPasswordEn
        self.noteZh = noteZh
        self.noteEn = noteEn
        self.loopbackOnly = loopbackOnly
        self.officialSMTPPort = officialSMTPPort
    }
}

public enum MailProviderPresets {
    public static let iCloud = MailProviderPreset(
        id: "icloud",
        displayName: "iCloud Mail",
        imapHost: "imap.mail.me.com",
        smtpHost: "smtp.mail.me.com",
        usernameHintZh: "完整 iCloud 邮箱地址（name@icloud.com）",
        usernameHintEn: "The full iCloud address (name@icloud.com)",
        appPasswordZh: "在 appleid.apple.com「登录与安全」生成 App 专用密码（16 位），不要使用 Apple ID 主密码。",
        appPasswordEn: "Create an app-specific password (16 characters) at appleid.apple.com → Sign-In and Security; never use the Apple ID password.",
        noteZh: "Apple 官方 SMTP 推荐 587 + STARTTLS；本节点只拨 465 隐式 TLS，若 465 被拒绝则该邮箱当前无法通过本节点收发。",
        noteEn: "Apple documents SMTP on 587 with STARTTLS; this node dials implicit TLS 465 only, so this mailbox cannot be used here if 465 is refused.",
        officialSMTPPort: 587
    )

    public static let gmail = MailProviderPreset(
        id: "gmail",
        displayName: "Gmail",
        imapHost: "imap.gmail.com",
        smtpHost: "smtp.gmail.com",
        usernameHintZh: "完整 Gmail 地址（name@gmail.com）",
        usernameHintEn: "The full Gmail address (name@gmail.com)",
        appPasswordZh: "先开启两步验证，再在 myaccount.google.com/apppasswords 生成 16 位应用专用密码。",
        appPasswordEn: "Enable 2-Step Verification, then create a 16-character app password at myaccount.google.com/apppasswords.",
        noteZh: "Gmail 同时支持 465 隐式 TLS 与 587 STARTTLS；本节点使用 465。",
        noteEn: "Gmail supports both implicit TLS 465 and STARTTLS 587; this node uses 465."
    )

    public static let outlook = MailProviderPreset(
        id: "outlook",
        displayName: "Outlook / Microsoft 365",
        imapHost: "outlook.office365.com",
        smtpHost: "smtp.office365.com",
        usernameHintZh: "完整 Microsoft 账户地址",
        usernameHintEn: "The full Microsoft account address",
        appPasswordZh: "Microsoft 通常要求 OAuth，本节点不支持 OAuth；仅当组织启用了应用密码时才可用。",
        appPasswordEn: "Microsoft normally requires OAuth, which this node does not implement; only an organization-issued app password can work.",
        noteZh: "Microsoft 官方 SMTP 为 587 + STARTTLS；本节点只拨 465，可能被服务端拒绝——这是服务商限制，不是配置错误。",
        noteEn: "Microsoft documents SMTP on 587 with STARTTLS; this node dials 465 only and may be refused — a provider limit, not a bad password.",
        officialSMTPPort: 587
    )

    public static let qq = MailProviderPreset(
        id: "qq",
        displayName: "QQ 邮箱",
        imapHost: "imap.qq.com",
        smtpHost: "smtp.qq.com",
        usernameHintZh: "完整 QQ 邮箱地址（number@qq.com）",
        usernameHintEn: "The full QQ Mail address (number@qq.com)",
        appPasswordZh: "QQ 邮箱网页版 → 设置 → 账户 → 开启 IMAP/SMTP 服务，生成 16 位授权码作为密码。",
        appPasswordEn: "In QQ Mail on the web: Settings → Account → enable IMAP/SMTP, then generate a 16-character authorization code and use it as the password.",
        noteZh: "QQ 邮箱官方支持 465 隐式 TLS。",
        noteEn: "QQ Mail documents implicit TLS 465."
    )

    public static let netEase163 = MailProviderPreset(
        id: "163",
        displayName: "网易 163 邮箱",
        imapHost: "imap.163.com",
        smtpHost: "smtp.163.com",
        usernameHintZh: "完整 163 邮箱地址（name@163.com）",
        usernameHintEn: "The full 163 address (name@163.com)",
        appPasswordZh: "163 邮箱网页版 → 设置 → POP3/SMTP/IMAP → 开启 IMAP/SMTP 服务并设置客户端授权密码。",
        appPasswordEn: "In 163 Mail on the web: Settings → POP3/SMTP/IMAP → enable IMAP/SMTP and set a client authorization password.",
        noteZh: "网易 163 官方支持 465 隐式 TLS。",
        noteEn: "NetEase 163 documents implicit TLS 465."
    )

    public static let protonBridge = MailProviderPreset(
        id: "proton-bridge",
        displayName: "Proton Mail Bridge",
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1",
        usernameHintZh: "Bridge 界面显示的完整 Proton 邮箱地址",
        usernameHintEn: "The full Proton address shown by Proton Mail Bridge",
        appPasswordZh: "密码是 Bridge 生成的专用密码（不是 Proton 登录密码）；Bridge 必须在本机保持运行。",
        appPasswordEn: "Use the Bridge-generated password (not the Proton login password); Bridge must be running on this Mac.",
        noteZh: "Bridge 默认 IMAP 1143 / SMTP 1025（STARTTLS）；本节点只接受 993/465 隐式 TLS。若你的 Bridge 版本不能在 993/465 上提供隐式 TLS，请改用手机客户端收发 Proton 邮件。",
        noteEn: "Bridge defaults to IMAP 1143 / SMTP 1025 with STARTTLS; this node accepts implicit TLS on 993/465 only. If your Bridge build cannot serve implicit TLS there, use the phone client for Proton mail.",
        loopbackOnly: true,
        officialSMTPPort: 1025
    )

    /// The order the console and the wizard list them in.
    public static let all: [MailProviderPreset] = [
        iCloud, gmail, outlook, qq, netEase163, protonBridge
    ]

    public static func preset(id: String) -> MailProviderPreset? {
        all.first { $0.id == id }
    }

    /// Writes only the server fields a preset owns. The Keychain references, the
    /// switch, the lookback window and the From address stay exactly as they were.
    public static func apply(
        _ preset: MailProviderPreset,
        to config: MailAssistantConfig
    ) -> MailAssistantConfig {
        var copy = config
        copy.imapHost = preset.imapHost
        copy.imapPort = preset.imapPort
        copy.smtpHost = preset.smtpHost
        copy.smtpPort = preset.smtpPort
        return copy
    }

    /// A preset that cannot survive `normalised` is a template that would silently
    /// write empty hosts. Both halves must pass the same validator the transport
    /// uses before the UI offers the button.
    public static func isApplicable(_ preset: MailProviderPreset) -> Bool {
        guard preset.imapPort == 993, preset.smtpPort == 465 else { return false }
        guard !MailAssistantConfig.host(preset.imapHost).isEmpty,
              !MailAssistantConfig.host(preset.smtpHost).isEmpty else { return false }
        return preset.loopbackOnly == (preset.imapHost == "127.0.0.1" && preset.smtpHost == "127.0.0.1")
    }
}
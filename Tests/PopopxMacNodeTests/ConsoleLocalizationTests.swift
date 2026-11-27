import XCTest
@testable import PopopxMacNode

/// The three console catalogs added on 2026-11-27 (pt-BR, ko, ar) are typed
/// out beside the `{ zh, en }` rows rather than derived from them. Nothing
/// regenerates them, so these tests are the only thing standing between
/// "translated" and a table that quietly lost a row and paints the English
/// fallback.
final class ConsoleLocalizationTests: XCTestCase {
    private typealias Catalog = (name: String, language: ConsoleLanguage, rows: [ConsoleTranslations.Row])

    private let page = WEBConsoleHTML.document

    private var catalogs: [Catalog] {
        [
            ("pt-BR", .portugueseBrazil, ConsoleTranslations.portugueseRows),
            ("ko", .korean, ConsoleTranslations.koreanRows),
            ("ar", .arabic, ConsoleTranslations.arabicRows),
        ]
    }

    /// Keys whose English text is a bare token (`MCP`, a path, `0–59`): leaving
    /// them byte-identical is the correct translation, not a missed row. The
    /// list is typed here on purpose — a future omission must fail a test
    /// instead of silently joining an inferred allowlist.
    private static let untranslatedTokens: [ConsoleLanguage: Set<String>] = [
        .portugueseBrazil: [
            "arkTitle", "asBriefMinuteNote", "asInklingRuntime", "asInklingTitle", "asKindCalDav",
            "asKindGodsEye", "asKindMcp", "chip", "dcKindMCP", "dcKindRSS", "dcStateOk", "dcUrl",
            "gePathPlaceholder", "geStatNode", "hvBridgeHome", "hvKindWorkspace", "opDoctorOk",
            "pvDomainMCP", "pvDomainWs", "receiptWebhook", "secondsUnit", "upBuild",
        ],
        .korean: [
            "arkTitle", "asBriefMinuteNote", "asKindCalDav", "asKindGodsEye", "asKindMcp",
            "dcKindMCP", "dcKindRSS", "dcUrl", "gePathPlaceholder", "geStatNode",
            "hvBridgeHome", "hvHaUrl", "pvDomainMCP",
        ],
        .arabic: [
            "arkTitle", "asBriefMinuteNote", "asKindCalDav", "asKindGodsEye", "asKindMcp",
            "dcKindMCP", "dcKindRSS", "dcUrl", "gePathPlaceholder", "geStatNode",
            "hvBridgeHome", "pvDomainMCP", "receiptWebhook",
        ],
    ]

    /// Rows that carry no prose in any language: a domain kind ("LAN") is a
    /// label, so it is exempt from the script check below without pretending
    /// its English spelling is the translation.
    private static let latinOnlyKeys: Set<String> = ["hvKindLan"]

    /// Literals a translator must never rewrite. They are the difference
    /// between a localized console and a console that localizes an IP address
    /// or a shell command.
    private static let technicalTokens = [
        "127.0.0.1", "localhost", "[::1]", "~/.local/bin", "SHA-256", "AES-GCM", "HMAC",
        "Ed25519", "FTS5", "GGUF", "MLX", "Ollama", "Keychain", "LaunchAgent", "MCP",
        "CalDAV", "MQTT", "Home Assistant", "God's Eye View", "Chrono Ark",
        "Inkling 2 Mini", "LTX-2.5", "popopx-chat", "::popopx_sys::NODE_CMD::",
        "Node.js", "WebSocket", "SQLite", "SMP", "popopx.im",
    ]

    func testEachNewCatalogCoversEveryBaseKey() {
        let base = Self.englishRows(in: page)
        XCTAssertGreaterThan(base.count, 700, "the base scan found \(base.count) rows; the table shape changed")
        for catalog in catalogs {
            let rows = catalog.rows
            let values = Dictionary(rows.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(rows.count, values.count, "\(catalog.name): a duplicated key would overwrite itself")
            XCTAssertEqual(rows.count, base.count,
                           "\(catalog.name): \(rows.count) rows against \(base.count) base keys")
            XCTAssertEqual(Set(values.keys), Set(base.keys),
                           "\(catalog.name) missing: \(Set(base.keys).subtracting(values.keys).sorted()); "
                           + "extra: \(Set(values.keys).subtracting(base.keys).sorted())")
            XCTAssertFalse(values.values.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                           "\(catalog.name): an empty value paints nothing")
        }
    }

    func testNoRowIsLeftInEnglishUnlessItIsABareToken() {
        let base = Self.englishRows(in: page)
        for catalog in catalogs {
            let values = Dictionary(catalog.rows.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
            let allowed = Self.untranslatedTokens[catalog.language] ?? []
            for (key, text) in values where text == base[key] {
                XCTAssertTrue(allowed.contains(key),
                              "\(catalog.name).\(key) is still the English text: \(text)")
            }
            // The allowlist must stay honest in the other direction too: a key
            // that was translated later has to leave this list.
            for key in allowed {
                XCTAssertEqual(values[key], base[key],
                               "\(catalog.name).\(key) is listed as a bare token but now differs from English; remove it from the allowlist")
            }
            if catalog.language == .korean || catalog.language == .arabic {
                let range: ClosedRange<UInt32> = catalog.language == .korean
                    ? 0xAC00...0xD7AF
                    : 0x0600...0x06FF
                for (key, text) in values
                where !allowed.contains(key) && !Self.latinOnlyKeys.contains(key) {
                    XCTAssertTrue(text.unicodeScalars.contains { range.contains($0.value) },
                                  "\(catalog.name).\(key) carries no \(catalog.name) script: \(text)")
                }
            }
        }
    }

    func testPlaceholdersAndTechnicalLiteralsSurvive() {
        let base = Self.englishRows(in: page)
        for catalog in catalogs {
            let values = Dictionary(catalog.rows.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
            for (key, text) in values {
                guard let english = base[key] else { continue }
                XCTAssertEqual(Self.placeholders(in: text), Self.placeholders(in: english),
                               "\(catalog.name).\(key): placeholder moved or lost")
                for token in Self.technicalTokens where english.contains(token) {
                    XCTAssertTrue(text.contains(token), "\(catalog.name).\(key): lost `\(token)`")
                }
                XCTAssertFalse(text.contains("\n") || text.contains("\t") || text.contains("\""),
                               "\(catalog.name).\(key): raw control or quote characters would break the inline script")
            }
            let uri = values["uri"] ?? ""
            XCTAssertTrue(uri.contains("/*PPX_SCHEME*/"),
                          "\(catalog.name).uri must keep the marker the page substitutes")
            let pull = values["asInklingPull"] ?? ""
            XCTAssertTrue(pull.hasSuffix(": "),
                          "\(catalog.name).asInklingPull is concatenated with a model name; the colon and space are the join")
            let claim = values["brandClaim"] ?? ""
            XCTAssertTrue(claim.hasPrefix("Connect Everything."),
                          "\(catalog.name).brandClaim must keep the untranslated brand mark")
            let install = values["daemonInstall"] ?? ""
            XCTAssertTrue(install.contains("https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh"),
                          "\(catalog.name).daemonInstall must keep the reviewed install URL")
            XCTAssertTrue(install.contains("shasum -a 256 popopx-install.sh"),
                          "\(catalog.name).daemonInstall must keep the digest check")
            XCTAssertTrue(install.contains("~/.local/bin/popopx-chat"),
                          "\(catalog.name).daemonInstall must name the installed path")
        }
    }

    func testTheThreeCatalogsAreServedAndTheMarkersAreGone() {
        XCTAssertFalse(page.contains("/*PPX_PTBR*/"), "the Portuguese catalog was never substituted")
        XCTAssertFalse(page.contains("/*PPX_KO*/"), "the Korean catalog was never substituted")
        XCTAssertFalse(page.contains("/*PPX_AR*/"), "the Arabic catalog was never substituted")
        XCTAssertTrue(page.contains("var PTBR = {brandSub:\"Hub de computação local"),
                      "the served page must carry the Portuguese catalog, not an empty fallback")
        XCTAssertTrue(page.contains("var KO = {brandSub:\"로컬 연산"),
                      "the served page must carry the Korean catalog, not an empty fallback")
        XCTAssertTrue(page.contains("var AR = {brandSub:\"مركز الحوسبة"),
                      "the served page must carry the Arabic catalog, not an empty fallback")
        XCTAssertTrue(page.contains("if (catalog === \"ptBR\") { return PTBR[key] || row.en || null; }"))
        XCTAssertTrue(page.contains("if (catalog === \"ko\") { return KO[key] || row.en || null; }"))
        XCTAssertTrue(page.contains("if (catalog === \"ar\") { return AR[key] || row.en || null; }"))
        // Dynamic rows have three columns only; a Latin-script catalog must read
        // English there instead of being lumped in with Chinese.
        XCTAssertTrue(page.contains("var suffix = { zh: \"Zh\", zhHant: \"Hant\" }[catalogFor(S.lang)] || \"En\";"))
        XCTAssertTrue(page.contains("if (catalog === \"zh\" || catalog === \"zhHant\") { return String(object[base + \"Zh\"]"))
    }

    func testArabicFlipsTheRootAndKeepsTechnicalRunsIsolated() {
        XCTAssertTrue(page.contains("html.setAttribute(\"dir\", catalog === \"ar\" ? \"rtl\" : \"ltr\");"),
                      "only the Arabic catalog may flip the document direction")
        XCTAssertTrue(page.contains("zh: \"zh-Hans-CN\", zhHant: \"zh-Hant-TW\", ptBR: \"pt-BR\", ko: \"ko\", ar: \"ar\""),
                      "the root `lang` must use the BCP-47 tag of the selected catalog")
        XCTAssertTrue(page.contains("code,kbd,samp,.mono,.code,pre.raw,.term__body,.engine__ref,#cmd,#cmdout,[dir=\"ltr\"]{"),
                      "the bidi block must name every technical surface")
        XCTAssertTrue(page.contains("direction:ltr;unicode-bidi:isolate;text-align:left;"),
                      "technical runs must pin direction and isolate their neighbours")
        XCTAssertTrue(page.contains(".stat__v,.stat__n{unicode-bidi:isolate}"))
        // Mirrored chrome: nothing here hard-codes a left/right side.
        XCTAssertTrue(page.contains(".lang__caret{position:absolute;inset-inline-end:9px"),
                      "the language caret must follow the inline edge")
        XCTAssertTrue(page.contains("[dir=\"rtl\"] .switch[aria-checked=\"true\"] .switch__knob{transform:translateX(-20px)}"))
        XCTAssertTrue(page.contains("[dir=\"rtl\"] .drawer__head svg{transform:scaleX(-1)}"))
        XCTAssertTrue(page.contains("[dir=\"rtl\"] .drawer.is-open .drawer__head svg{transform:scaleX(-1) rotate(90deg)}"))
        XCTAssertTrue(page.contains("[dir=\"rtl\"] .table tbody tr.is-active td:first-child{box-shadow:inset -2px 0 0 var(--accent-lift)}"))
        XCTAssertTrue(page.contains(".pv-card.is-spent{border-inline-start-color:var(--hair-strong);opacity:.72}"))
        XCTAssertTrue(page.contains("#toasts{position:fixed;inset-inline-end:var(--s4);"))
        XCTAssertFalse(page.contains(".lang__caret{position:absolute;left:9px"),
                       "a physical left offset would keep the caret on the wrong side in Arabic")
        // Technical inputs and stat values pin LTR; free text is left to the
        // first-strong-character rule.
        XCTAssertTrue(page.contains("dir: ltr ? \"ltr\" : null"),
                      "uptime and port stat values must not be reordered by the Arabic base direction")
        XCTAssertTrue(page.contains("h(\"input\", { type: \"number\", dir: \"ltr\""))
        XCTAssertTrue(page.contains("h(\"input\", { type: \"text\", dir: \"ltr\", spellcheck: \"false\", value: String(read() || \"\"), inputmode: \"url\" })"))
        XCTAssertTrue(page.contains("h(\"input\", { type: \"password\", dir: \"ltr\""))
        XCTAssertTrue(page.contains("h(\"input\", { type: \"text\", dir: \"auto\""))
        // Both progress indicators are block boxes filled by width, so the RTL
        // inline edge mirrors them without a direction-specific rule.
        XCTAssertTrue(page.contains(".checklist__bar i{display:block;height:100%"))
        XCTAssertTrue(page.contains("<div class=\"pullbar\" id=\"model-barwrap\" hidden><i id=\"model-bar\"></i></div>"))
        XCTAssertTrue(page.contains("ptBR: [\"Dom\", \"Seg\", \"Ter\", \"Qua\", \"Qui\", \"Sex\", \"Sáb\"]"))
        XCTAssertTrue(page.contains("ko: [\"일\", \"월\", \"화\", \"수\", \"목\", \"금\", \"토\"]"))
        XCTAssertTrue(page.contains("ar: [\"الأحد\", \"الاثنين\", \"الثلاثاء\", \"الأربعاء\", \"الخميس\", \"الجمعة\", \"السبت\"]"))
        // The catalog check that used to treat every non-English catalog as
        // Chinese is the one silent failure a Latin-script translation creates.
        XCTAssertTrue(page.contains("function uiIsChinese() { var catalog = catalogFor(S.lang); return catalog === \"zh\" || catalog === \"zhHant\"; }"))
    }

    // MARK: Parsing helpers

    private static func englishRows(in page: String) -> [String: String] {
        let expression = try! NSRegularExpression(
            pattern: "[ \\t]*([A-Za-z][A-Za-z0-9_]*): \\{ zh: \"([^\"]*)\", en: \"([^\"]*)\" \\}")
        let full = NSRange(page.startIndex..., in: page)
        var rows: [String: String] = [:]
        expression.enumerateMatches(in: page, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges == 4,
                  let key = Range(match.range(at: 1), in: page),
                  let value = Range(match.range(at: 3), in: page) else { return }
            rows[String(page[key])] = String(page[value])
        }
        return rows
    }

    private static func placeholders(in text: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: "\\{[A-Za-z][A-Za-z0-9]*\\}")
        let full = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, options: [], range: full).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        })
    }
}
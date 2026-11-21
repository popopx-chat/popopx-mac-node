//
//  MacNodeContractTests.swift
//  Tests for the frozen wire/type contract in Sources/PopopxMacNode/Models.
//
//  These assertions are what the iOS client and the web console both depend on,
//  so they are written against literals rather than recomputed from our own
//  helpers: a test that derives its expected value from the same expression as
//  the code under test proves nothing.
//
//  Nothing here opens a socket, pairs with a daemon, or deletes anything the
//  owner created. The cases that touch the real machine assert physical bounds
//  rather than exact values, and every sandbox they create is removed again.
//

import CryptoKit
import Foundation
import XCTest
@testable import PopopxMacNode

final class MacNodeContractTests: XCTestCase {
    /// A fixed zone so the window tests never depend on the machine's clock
    /// setting. Only used where the API takes an explicit calendar.
    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// Deterministic hardware samples so the ladder tests do not depend on the
    /// build machine. Only the memory band matters; the rest is plausible filler.
    private var sampleProfiles: [MacHardwareProfile] {
        [
            MacHardwareProfile(
                chipName: "Apple M5 Max", modelIdentifier: "Mac17,1", cpuArchitecture: "arm64",
                logicalCPUCount: 16, physicalCPUCount: 16, performanceCoreCount: 12, efficiencyCoreCount: 4,
                memoryTotal: ByteCount(bytes: 128 * 1_073_741_824),
                freeDisk: ByteCount(bytes: 900 * 1_073_741_824), totalDisk: ByteCount(bytes: 2_000 * 1_073_741_824),
                systemVolumeName: "Macintosh HD", operatingSystem: "26.1", kernelVersion: "27.0.0",
                serialMasked: "C3D4E5F6"
            ),
            MacHardwareProfile(
                chipName: "Apple M4 Max", modelIdentifier: "Mac15,9", cpuArchitecture: "arm64",
                logicalCPUCount: 16, physicalCPUCount: 16, performanceCoreCount: 12, efficiencyCoreCount: 4,
                memoryTotal: ByteCount(bytes: 48 * 1_073_741_824),
                freeDisk: ByteCount(bytes: 400 * 1_073_741_824), totalDisk: ByteCount(bytes: 1_000 * 1_073_741_824),
                systemVolumeName: "Macintosh HD", operatingSystem: "15.5", kernelVersion: "24.5.0",
                serialMasked: "A1B2C3D4"
            ),
            MacHardwareProfile(
                chipName: "Apple M3", modelIdentifier: "Mac14,15", cpuArchitecture: "arm64",
                logicalCPUCount: 8, physicalCPUCount: 8, performanceCoreCount: 4, efficiencyCoreCount: 4,
                memoryTotal: ByteCount(bytes: 16 * 1_073_741_824),
                freeDisk: ByteCount(bytes: 100 * 1_073_741_824), totalDisk: ByteCount(bytes: 500 * 1_073_741_824),
                systemVolumeName: "Macintosh HD", operatingSystem: "14.7", kernelVersion: "23.6.0",
                serialMasked: "E5F6A1B2"
            )
        ]
    }

    // MARK: Command wire

    func testCommandWireRoundTrip() throws {
        let command = NodeCommand(
            serviceId: "shadow_cos",
            action: "briefing",
            payload: "{\"day\":\"2026-11-21\"}",
            senderPublicKey: "paired-key-1"
        )
        XCTAssertEqual(
            command.wireString,
            "::popopx_sys::NODE_CMD::shadow_cos::briefing::{\"day\":\"2026-11-21\"}"
        )
        let reparsed = try XCTUnwrap(NodeWire.parseCommand(command.wireString))
        XCTAssertEqual(reparsed.serviceId, command.serviceId)
        XCTAssertEqual(reparsed.action, command.action)
        XCTAssertEqual(reparsed.payload, command.payload)
        XCTAssertEqual(command.jsonPayload["day"]?.stringValue, "2026-11-21")
    }

    /// `::` inside the payload must survive: JSON strings, URLs and the warroom
    /// trace format all contain them, and the node has to rejoin the tail rather
    /// than treat a fourth segment as junk.
    func testParserKeepsSeparatorsInsidePayload() throws {
        let wire = "::popopx_sys::NODE_CMD::zero_trust_warroom::trace::{\"leak\":\"a::b::c\"}"
        let command = try XCTUnwrap(NodeWire.parseCommand(wire))
        XCTAssertEqual(command.serviceId, "zero_trust_warroom")
        XCTAssertEqual(command.action, "trace")
        XCTAssertEqual(command.payload, "{\"leak\":\"a::b::c\"}")
        XCTAssertEqual(command.jsonPayload["leak"]?.stringValue, "a::b::c")
        XCTAssertEqual(command.wireString, wire)
    }

    /// Anything that is not exactly our contract fails closed — including the
    /// `popopx:/invitation#…` link shape and the commerce kinds the iOS client
    /// already owns, neither of which may be mistaken for a node command.
    func testParserRejectsForeignAndTruncatedMarkers() {
        let rejected = [
            "popopx:/invitation#/?v=6-8&smp=smp%3A%2F%2Ffp%40host",
            "::popopx_sys::EXT_REDEEM_REQ::abc",
            "::popopx_sys::NODE_CMD::",
            "::popopx_sys::NODE_CMD::shadow_cos",
            "::popopx_sys::NODE_CMD::shadow_cos::briefing",
            "::popopx_sys::NODE_CMD::shadow_cos::briefing::",
            "::popopx_sys::NODE_CMD::not_an_engine::briefing::{}",
            "::popopx_sys::NODE_CMD:::::",
            "NODE_CMD::shadow_cos::briefing::{}",
            ""
        ]
        for wire in rejected {
            XCTAssertNil(NodeWire.parseCommand(wire), "must reject \(wire)")
        }
    }

    /// The iOS side refuses a signal whose tail exceeds 1024 characters, and
    /// charges the service id and action to that budget. Mirroring the arithmetic
    /// here means an over-long card is dropped loudly instead of arriving in the
    /// owner's chat as visible markup.
    func testParserEnforcesThePayloadBudget() {
        let base = "::popopx_sys::NODE_CMD::shadow_cos::briefing::"
        let allowance = NodeWire.maxSignalPayloadCharacters - "shadow_cos".count - "briefing".count - 2
        XCTAssertEqual(allowance, 1_004)
        let filler = String(repeating: "x", count: allowance)
        XCTAssertNotNil(NodeWire.parseCommand(base + filler))
        XCTAssertNil(NodeWire.parseCommand(base + filler + "x"))
    }

    func testParserMarksLocalCommandsUnauthenticated() throws {
        let wire = "::popopx_sys::NODE_CMD::morning_tv::render::{}"
        let local = try XCTUnwrap(NodeWire.parseCommand(wire))
        XCTAssertFalse(local.authenticated, "a console-injected command has no paired key")
        XCTAssertEqual(local.senderPublicKey, "local-console")

        let paired = try XCTUnwrap(NodeWire.parseCommand(
            wire, senderPublicKey: "ios-key-9", authenticated: true
        ))
        XCTAssertTrue(paired.authenticated)
        XCTAssertEqual(paired.senderPublicKey, "ios-key-9")
    }

    /// The lockdown path must never depend on anything a model has to interpret.
    func testLockTriggersAreRecognisedInBothSlots() {
        XCTAssertEqual(NodeWire.lockTriggers, ["🔒", "LOCK_ALL", "lock_all"])
        for trigger in NodeWire.lockTriggers {
            XCTAssertTrue(
                NodeCommand(serviceId: "phantom_sentinel", action: trigger, payload: "{}", senderPublicKey: "k")
                    .isDeterministicLock,
                trigger
            )
            XCTAssertTrue(
                NodeCommand(serviceId: "phantom_sentinel", action: "lock", payload: trigger, senderPublicKey: "k")
                    .isDeterministicLock,
                trigger
            )
        }
        XCTAssertFalse(
            NodeCommand(serviceId: "phantom_sentinel", action: "status", payload: "{}", senderPublicKey: "k")
                .isDeterministicLock
        )
    }

    // MARK: Engine identity

    /// These strings travel to the iOS client and into settings.json on disk.
    /// Renaming one without a migration silently disables an engine.
    func testEngineRawValuesAreTheStableContract() {
        XCTAssertEqual(
            Set(EngineKind.allCases.map { $0.rawValue }),
            [
                "chrono_ark", "creator_paywall_hub", "edge_compute_mesh", "health_sentinel",
                "morning_tv", "phantom_sentinel", "shadow_cos", "solo_autopilot",
                "zerotrace_studio", "zero_trust_warroom"
            ]
        )
        XCTAssertEqual(EngineKind.displayOrder.count, EngineKind.allCases.count)
        XCTAssertEqual(Set(EngineKind.displayOrder), Set(EngineKind.allCases))
        XCTAssertEqual(EngineKind.allCases.filter { $0.isDeterministic }, [.phantomSentinel])
    }

    func testEveryEngineHasBilingualCopy() {
        for kind in EngineKind.allCases {
            XCTAssertFalse(kind.displayNameZh.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.displayNameEn.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.taglineZh.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.taglineEn.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.symbolName.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.substrate.isEmpty, kind.rawValue)
            XCTAssertNotEqual(kind.displayNameZh, kind.displayNameEn, kind.rawValue)
        }
        // Two engines sharing a display name would make the wizard ambiguous.
        XCTAssertEqual(Set(EngineKind.allCases.map { $0.displayNameZh }).count, EngineKind.allCases.count)
        XCTAssertEqual(Set(EngineKind.allCases.map { $0.displayNameEn }).count, EngineKind.allCases.count)
    }

    func testPortsAndHostsMatchTheDocumentedValues() {
        XCTAssertEqual(NodeWire.consolePort, 18920)
        XCTAssertEqual(NodeWire.popopxControlPort, 5225)
        XCTAssertEqual(NodeWire.ollamaPort, 11434)
        XCTAssertEqual(NodeWire.consoleHost, "127.0.0.1")
        XCTAssertEqual(NodeWire.consoleTokenHeader, "X-PPX-Token")
        XCTAssertEqual(NodeWire.consoleTokenQuery, "t")
        XCTAssertEqual(NodeWire.chatDaemonCandidates, ["popopx-chat"])
        XCTAssertEqual(SBChatWire.binaryNames, ["popopx-chat"], "the bridge must launch the same daemon it probes for")
        XCTAssertEqual(NodeWire.chatServerPortFlag, "--chat-server-port")
        XCTAssertEqual(NodeWire.invitationScheme, "popopx:/")
        XCTAssertEqual(NodeWire.invitationShareHost, "https://popopx.chat/")
        XCTAssertEqual(NodeWire.pairingCodePrefix, "PPXNODE1")
        XCTAssertEqual(NodeWire.signalMarker, "::popopx_sys::")
        XCTAssertEqual(NodeWire.commandPrefix, "::popopx_sys::NODE_CMD::")
        XCTAssertEqual(NodeWire.commandSegmentCount, 3)
        XCTAssertEqual(NodeWire.maxSignalPayloadCharacters, 1_024)
        XCTAssertEqual(NodeWire.maxInvitationLinkCharacters, 2_048)
        XCTAssertEqual(NodeWire.pairingOfferLifetime, 900)
        XCTAssertEqual(NodeWire.heartbeatInterval, 20)
    }

    func testConsoleRoutesAreUniqueAndWellFormed() {
        let routes = ConsoleRoute.all
        XCTAssertEqual(Set(routes).count, routes.count, "a duplicate route would shadow a handler")
        XCTAssertEqual(routes.count, 13)
        for route in routes {
            XCTAssertTrue(route.hasPrefix("/"), route)
            XCTAssertFalse(route.contains(".."), route)
            XCTAssertFalse(route.contains(" "), route)
        }
        for required in [ConsoleRoute.index, ConsoleRoute.health, ConsoleRoute.pairingQR, ConsoleRoute.commandInject] {
            XCTAssertTrue(routes.contains(required), "\(required) missing from `all`")
        }
    }

    // MARK: Localization parity with the iOS app

    /// The phone decides the language list; the node may not invent one. These
    /// are the `knownRegions` of the POPOPX iOS app target copied as literals,
    /// deliberately not read from `ConsoleLanguage` — a test that derives its
    /// expectation from the enum it is checking cannot notice the enum drifting.
    func testConsoleLocaleListMatchesTheiOSApp() {
        let iosRegions = ["en", "ru", "de", "fr", "it", "nl", "cs", "zh-Hans", "es", "pl",
                          "ja", "th", "fi", "uk", "bg", "tr", "hu"]
        // The node adds exactly one language the phone does not have. Naming it
        // here is the point: a second unannounced addition would fail this test
        // rather than quietly widen the two apps' lists.
        let nodeOnlyRegions: Set<String> = ["zh-Hant"]
        XCTAssertEqual(ConsoleLanguage.displayOrder.first, .system,
                       "the console must start on the phone's behaviour: follow the system locale")
        XCTAssertEqual(ConsoleLanguage.displayOrder.count, iosRegions.count + nodeOnlyRegions.count + 1)
        XCTAssertEqual(Set(ConsoleLanguage.displayOrder.dropFirst().map(\.rawValue)).subtracting(nodeOnlyRegions), Set(iosRegions),
                       "the node and the phone must offer the same languages, plus the one declared addition")
        XCTAssertEqual(ConsoleLanguage.chineseSimplified.rawValue, "zh-Hans",
                       "bare `zh` is not a region the phone can produce")

        let page = WEBConsoleHTML.document
        XCTAssertFalse(page.contains("/*PPX_LANGS*/"),
                       "an unsubstituted marker leaves LOCALES empty and the picker blank")
        XCTAssertFalse(page.contains("var LOCALES = [];"), "the served page must carry the registry")
        for region in iosRegions {
            XCTAssertTrue(page.contains("code:\"\(region)\","), "\(region) is missing from the served console")
        }
        XCTAssertTrue(page.contains("code:\"zh-Hans\",name:\"简体中文\",catalog:\"zh\""),
                      "the Simplified picker entry must name the catalog it reads")
        XCTAssertTrue(page.contains("code:\"zh-Hant\",name:\"繁體中文\",catalog:\"zhHant\""),
                      "Traditional must arrive with its own catalog, not the English fallback")
        // Every entry names one of three catalogs, and the counts must add up —
        // `system` is resolved by Swift, so its own label follows the machine and
        // is deliberately not pinned here.
        let english = page.components(separatedBy: "catalog:\"en\"").count - 1
        let simplified = page.components(separatedBy: "catalog:\"zh\"").count - 1
        let traditional = page.components(separatedBy: "catalog:\"zhHant\"").count - 1
        XCTAssertEqual(english + simplified + traditional, ConsoleLanguage.displayOrder.count,
                       "a registry entry without a catalog would paint an empty label")
        XCTAssertEqual(traditional, ConsoleLanguage.derived.count,
                       "only a language the node actually derives may claim the derived catalog")
        XCTAssertGreaterThanOrEqual(simplified, 1, "Simplified Chinese must always name its own catalog")
        XCTAssertFalse(page.contains("/*PPX_SCHEME*/"),
                       "the invitation label would print the substitution marker instead of the scheme")
        XCTAssertTrue(page.contains("popopx:/ invitation URI"),
                      "the console must name the scheme the node actually issues")
        XCTAssertFalse(page.contains("simplex://"),
                       "the console must not advertise a scheme neither fork parses")
        XCTAssertFalse(page.contains("/Users/"), "the console must not leak a development-machine path")
    }

    /// Every string the page asks for must exist in the page's own catalog: a
    /// missing key silently paints nothing, which is how a "localized" console
    /// ends up shipping half a language.
    func testConsoleCatalogCoversEveryReferencedKey() {
        let page = WEBConsoleHTML.document
        let declared = jsIdentifierGroups(in: page, pattern: "^[ \t]{2}([A-Za-z][A-Za-z0-9]*)[ \t]*:[ \t]*\\{[ \t]*zh:")
        XCTAssertGreaterThan(declared.count, 200, "the catalog scan found \(declared.count) rows; the table shape changed")

        var referenced = Set<String>()
        referenced.formUnion(jsIdentifierGroups(in: page, pattern: "\\bt\\(\"([A-Za-z][A-Za-z0-9]*)\"\\)"))
        referenced.formUnion(jsIdentifierGroups(in: page, pattern: "\\bfail\\(\"([A-Za-z][A-Za-z0-9]*)\""))
        referenced.formUnion(jsIdentifierGroups(in: page, pattern: "data-i18n(?:-ph|-aria)?=\"([A-Za-z][A-Za-z0-9]*)\""))
        XCTAssertGreaterThan(referenced.count, 100, "the reference scan found \(referenced.count) keys; the call shape changed")

        let missing = referenced.subtracting(declared)
        XCTAssertTrue(missing.isEmpty, "i18n keys used but not defined: \(missing.sorted().joined(separator: ", "))")
    }

    /// One fallback rule, shared by the page, the menu bar and the report copy:
    /// the two Chinese scripts paint Chinese, everything else reads English.
    func testLanguageFallbackIsOneRuleForEverySurface() {
        XCTAssertEqual(ConsoleLanguage.chineseSimplified.text(zh: "语言", en: "EN"), "语言")
        XCTAssertEqual(ConsoleLanguage.chineseTraditional.text(zh: "语言", en: "EN"), "語言",
                       "Traditional reads the same copy, converted rather than translated")
        for language in ConsoleLanguage.displayOrder
        where language != .system && language.resolved != .chineseSimplified && language.resolved != .chineseTraditional {
            XCTAssertEqual(language.text(zh: "中", en: "EN"), "EN", "\(language.rawValue) must fall back to English")
        }
        XCTAssertTrue(ConsoleLanguage.chineseTraditional.isChinese,
                      "the report copy and the local-model prompts key off this")
        XCTAssertEqual(ConsoleLanguage.chineseTraditional.catalogKey, "zhHant")
        XCTAssertTrue(ConsoleLanguage.chineseTraditional.hasCatalog)
        XCTAssertFalse(ConsoleLanguage.chineseTraditional.isCurated,
                       "a machine-derived catalog must never claim to be proof-read")
        let resolved = ConsoleLanguage.system.resolved
        XCTAssertNotEqual(resolved, .system, "`system` must resolve to a real language, never to itself")
        XCTAssertEqual(resolved, ConsoleLanguage.matchingCurrentSystemLocale())

        for kind in EngineKind.allCases {
            XCTAssertFalse(kind.displayNameZh.isEmpty)
            XCTAssertFalse(kind.displayNameEn.isEmpty)
            XCTAssertEqual(kind.displayName(for: .russian), kind.displayNameEn,
                           "\(kind.rawValue) should not be guessed into Russian")
            XCTAssertEqual(kind.displayName(for: .chineseSimplified), kind.displayNameZh)
            XCTAssertEqual(kind.displayName(for: .chineseTraditional), TraditionalChinese.render(kind.displayNameZh),
                           "\(kind.rawValue) must reach a Traditional menu the same way the console does")
        }
        XCTAssertEqual(Set(EngineKind.allCases.map { $0.displayNameEn }).count, EngineKind.allCases.count,
                       "two engines sharing a display name would make the menu ambiguous")
    }

    /// A language code that leaves one app must be understood by the other.
    /// This is the half of "一致" that a shared list alone cannot guarantee.
    func testLanguageCodesResolveIdenticallyOnBothEnds() {
        XCTAssertEqual(ConsoleLanguage.matching("zh-Hans"), .chineseSimplified)
        XCTAssertEqual(ConsoleLanguage.matching("zh-CN"), .chineseSimplified)
        XCTAssertEqual(ConsoleLanguage.matching("zh_Hant_TW"), .chineseTraditional,
                       "the script tag must decide, or a Traditional owner is folded into Simplified")
        XCTAssertEqual(ConsoleLanguage.matching("zh-TW"), .chineseTraditional)
        XCTAssertEqual(ConsoleLanguage.matching("zh-Hant-HK"), .chineseTraditional,
                       "Hong Kong is a region of the script, not a third catalog")
        XCTAssertEqual(ConsoleLanguage.matching("zh"), .chineseSimplified,
                       "a bare `zh` follows the phone, whose only Chinese catalog is zh-Hans")
        XCTAssertEqual(ConsoleLanguage.matching("ZH-hans-CN"), .chineseSimplified)
        XCTAssertEqual(ConsoleLanguage.matching("en-US"), .english)
        XCTAssertEqual(ConsoleLanguage.matching("ru_RU"), .russian)
        XCTAssertEqual(ConsoleLanguage.matching("de-AT"), .german)
        XCTAssertNil(ConsoleLanguage.matching("sr-RS"),
                     "a region neither app ships must never be invented")
        XCTAssertNil(ConsoleLanguage.matching("pt-BR"))
        XCTAssertNil(ConsoleLanguage.matching("ko-KR"))
        XCTAssertNil(ConsoleLanguage.matching(""))
        XCTAssertNil(ConsoleLanguage.matching("Base"), "`Base` is an Xcode folder, not a language")
        for language in ConsoleLanguage.displayOrder {
            XCTAssertEqual(ConsoleLanguage.matching(language.rawValue), language, language.rawValue)
        }
        let tags = ConsoleLanguage.displayOrder.filter { $0 != .system }.map(\.localeIdentifier)
        XCTAssertEqual(Set(tags).count, tags.count, "two regions sharing a BCP-47 tag would mislabel the page")
    }

    /// The model is told which language to answer in, which is the only thing
    /// that makes a fifteenth-region choice mean anything for generated text.
    func testModelLanguageDirectiveNamesTheChosenLanguage() {
        XCTAssertEqual(ConsoleLanguage.english.modelLanguageDirective, "Write in English.")
        XCTAssertEqual(ConsoleLanguage.chineseSimplified.modelLanguageDirective, "Write in Simplified Chinese (简体中文).")
        XCTAssertEqual(ConsoleLanguage.chineseTraditional.modelLanguageDirective, "Write in Traditional Chinese (繁體中文).",
                       "a Traditional owner must not be told to answer in Simplified")
        for language in ConsoleLanguage.displayOrder where !language.isCurated && language != .system {
            let directive = language.modelLanguageDirective
            XCTAssertTrue(directive.hasPrefix("Write in "), directive)
            XCTAssertTrue(directive.contains(language.nativeName), "\(language.rawValue): \(directive)")
            XCTAssertFalse(directive.contains("Simple Chinese") || directive.contains("English"),
                           "\(language.rawValue) must not be described as English")
        }
    }

    /// All matches of every capture group, because a key can be referenced
    /// several times and a repeated declaration is worth finding too.
    private func jsIdentifierGroups(in text: String, pattern: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let full = NSRange(text.startIndex..., in: text)
        var found = Set<String>()
        expression.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match else { return }
            for group in 1..<match.numberOfRanges {
                let range = match.range(at: group)
                guard range.location != NSNotFound, let swift = Range(range, in: text) else { continue }
                found.insert(String(text[swift]))
            }
        }
        return found
    }

    // MARK: Traditional Chinese, derived rather than duplicated

    /// The `zh` column of the served page, read back the way the page reads it.
    private func simplifiedRows(in page: String) -> [String: String] {
        let expression = try! NSRegularExpression(
            pattern: "[ \\t]*([A-Za-z][A-Za-z0-9_]*): \\{ zh: \"([^\"]*)\", en: "
        )
        let full = NSRange(page.startIndex..., in: page)
        var rows: [String: String] = [:]
        expression.enumerateMatches(in: page, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let key = Range(match.range(at: 1), in: page),
                  let value = Range(match.range(at: 2), in: page) else { return }
            rows[String(page[key])] = String(page[value])
        }
        return rows
    }

    /// The Traditional console is generated from the Simplified one, so it can
    /// neither fall behind it nor lead it: the same keys, each one the converted
    /// value of its own row. A hand-written second table could not be checked
    /// this way, which is why the table is not hand-written.
    func testTraditionalCatalogIsDerivedFromTheSimplifiedRows() {
        let page = WEBConsoleHTML.document
        XCTAssertFalse(page.contains("/*PPX_HANT*/"),
                       "an unsubstituted marker leaves the Traditional picker reading English")
        XCTAssertTrue(page.contains("var HANT = {"), "the page must carry the derived catalog")

        let simplified = simplifiedRows(in: page).filter { _, value in
            value.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")) != nil
        }
        XCTAssertGreaterThan(simplified.count, 200, "the Simplified scan found \(simplified.count) rows; the table shape changed")

        let derived = Dictionary(WEBConsoleHTML.traditionalRows.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(derived.count, WEBConsoleHTML.traditionalRows.count, "a duplicated Traditional row would overwrite itself")
        XCTAssertEqual(Set(derived.keys), Set(simplified.keys),
                       "keys only in Traditional: \(Set(derived.keys).subtracting(simplified.keys).sorted()); "
                       + "keys only in Simplified: \(Set(simplified.keys).subtracting(derived.keys).sorted())")
        var changed = 0
        for (key, source) in simplified {
            /* `traditionalRows` is generated from the page source, where the
               invitation label still carries its build-time marker, and the
               marker is substituted afterwards — so the expectation here folds
               the served scheme back into it. `WEBConsoleHTML.document` proves
               the other direction below. */
            let expected = TraditionalChinese.render(source)
                .replacingOccurrences(of: NodeWire.invitationScheme, with: "/*PPX_SCHEME*/")
            XCTAssertEqual(derived[key], expected, "\(key) is not its own row converted")
            if derived[key] != source { changed += 1 }
        }
        if let invitation = simplified["uri"] {
            XCTAssertTrue(page.contains(TraditionalChinese.render(invitation)),
                          "the Traditional row must be generated before the scheme is substituted, or the picker shows the marker")
        }
        /* Most rows contain at least one character that differs between the
           scripts; a catalog that converted nothing at all would still satisfy
           the equality above, so the volume of change is the proof the
           transform ran. */
        XCTAssertGreaterThan(changed, simplified.count / 2,
                             "only \(changed) of \(simplified.count) Traditional rows differ from their Simplified source")
    }

    /// Auditing every shipped Chinese string (the console catalog, the engine
    /// names, the checklist titles, the menu labels) against the Traditional
    /// output is what turns `fixUps` from folklore into a checked property: the
    /// converter has one systematic habit this product cannot ship with.
    func testTraditionalConversionLeavesNoVariantOrWrongWordInShippedCopy() {
        var shipped: [(where: String, text: String)] = WEBConsoleHTML.traditionalRows.map { ("console.\($0.key)", $0.text) }
        for kind in EngineKind.displayOrder {
            let descriptor = EngineDescriptor(kind: kind, order: 0)
            shipped.append(("\(kind.rawValue).title", descriptor.titleHant))
            shipped.append(("\(kind.rawValue).tagline", descriptor.taglineHant))
            XCTAssertEqual(descriptor.titleHant, TraditionalChinese.render(kind.displayNameZh), kind.rawValue)
            XCTAssertEqual(descriptor.taglineHant, TraditionalChinese.render(kind.taglineZh), kind.rawValue)
        }
        let step = InstallStep(id: "brew", titleZh: "Homebrew 包管理器", titleEn: "Homebrew package manager")
        XCTAssertEqual(step.titleHant, "Homebrew 包管理器", "this step title has no character that changes script")
        shipped.append(("step.brew", step.titleHant))

        XCTAssertGreaterThan(shipped.count, 250, "the audit covered only \(shipped.count) strings")
        for entry in shipped {
            XCTAssertFalse(entry.text.contains("啓"),
                           "\(entry.where): the converter answers 启 with the variant 啓, Traditional Chinese uses 啟 — add it to `TraditionalChinese.fixUps`")
            // Word-dependent mappings the character-wise converter cannot know.
            // None of these words occurs in this copy today; if one appears, the
            // fix-up table has to earn it.
            for wrong in ["皇後", "天後", "幹淨", "頭髮", "一瞭", "係統", "檯風"] {
                XCTAssertFalse(entry.text.contains(wrong), "\(entry.where) converted to \(wrong)")
            }
        }
        // The words the audit did find, proved in the direction a reader expects.
        XCTAssertEqual(TraditionalChinese.render("复制配对码"), "複製配對碼")
        XCTAssertEqual(TraditionalChinese.render("启动守护进程"), "啟動守護進程")
        XCTAssertEqual(TraditionalChinese.render("空闲算力"), "空閒算力")
        XCTAssertEqual(TraditionalChinese.render("剩余"), "剩餘")
        XCTAssertEqual(TraditionalChinese.render("平台"), "平台", "a platform is not a table (檯)")
        XCTAssertEqual(TraditionalChinese.render("界面"), "界面", "an interface is not noodles (麵)")
        XCTAssertEqual(TraditionalChinese.render("皇后"), "皇后", "an empress keeps 后; the converter cannot know")
    }

    /// The console reads the Traditional names off the snapshot, so they have to
    /// survive the wire: one broadcast snapshot, every browser's own language.
    func testTraditionalNamesTravelOnTheWire() throws {
        let descriptor = EngineDescriptor(kind: EngineKind.displayOrder[0], order: 0)
        let data = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["titleZh", "titleHant", "titleEn", "taglineZh", "taglineHant", "taglineEn"] {
            XCTAssertNotNil(json[key], "\(key) never reaches the browser")
        }
        XCTAssertEqual(json["titleHant"] as? String, TraditionalChinese.render(descriptor.titleZh))

        let stepData = try JSONEncoder().encode(InstallStep(id: "ffmpeg", titleZh: "校验权重", titleEn: "Verify weights"))
        let stepJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: stepData) as? [String: Any])
        XCTAssertEqual(stepJSON["titleHant"] as? String, "校驗權重")
    }

    // MARK: Compute ladder

    /// The ladder in README.md is a promise to the buyer; the band edges are
    /// exactly where it stops being true.
    func testMemoryTierBoundaries() {
        XCTAssertEqual(ComputeTier(memoryGB: 128), .flagship)
        XCTAssertEqual(ComputeTier(memoryGB: 96), .flagship)
        XCTAssertEqual(ComputeTier(memoryGB: 95), .high)
        XCTAssertEqual(ComputeTier(memoryGB: 64), .high)
        XCTAssertEqual(ComputeTier(memoryGB: 48), .high)
        XCTAssertEqual(ComputeTier(memoryGB: 47), .light)
        XCTAssertEqual(ComputeTier(memoryGB: 8), .light)
        XCTAssertEqual(ComputeTier.flagship.memoryBand, ">= 96 GB")
        XCTAssertEqual(ComputeTier.high.memoryBand, "48 - 95 GB")
        XCTAssertEqual(ComputeTier.light.memoryBand, "< 48 GB")
        for tier in ComputeTier.allCases {
            XCTAssertFalse(tier.titleZh.isEmpty)
            XCTAssertFalse(tier.titleEn.isEmpty)
        }
    }

    func testLadderMatchesThePublishedMatrix() {
        let flagship = ModelPlan.recommend(memoryGB: 128)
        XCTAssertEqual(flagship.llmQuantization, "Q8_0")
        XCTAssertEqual(flagship.videoPrecision, "BF16 full weights")
        XCTAssertTrue(flagship.heavyVideoLocally)
        XCTAssertFalse(flagship.routeHeavyVideoToMesh)
        XCTAssertEqual(flagship.audioSampleRateHz, 48_000, "the brief promises a native 48 kHz track")

        let high = ModelPlan.recommend(memoryGB: 64)
        XCTAssertEqual(high.llmQuantization, "Q4_K_M")
        XCTAssertEqual(high.videoRef, "ltx-2.5-mlx-8bit")
        XCTAssertTrue(high.heavyVideoLocally)
        XCTAssertFalse(high.routeHeavyVideoToMesh)

        let light = ModelPlan.recommend(memoryGB: 36)
        XCTAssertEqual(light.llmParameterBillions, 9)
        XCTAssertEqual(light.videoRef, "ltx-2.5-mlx-4bit")
        XCTAssertFalse(light.heavyVideoLocally)
        XCTAssertTrue(light.routeHeavyVideoToMesh, "sub-48 GB machines must delegate heavy video")

        for memory in [16, 48, 96] {
            XCTAssertEqual(ModelPlan.recommend(memoryGB: memory).audioSampleRateHz, 48_000)
            XCTAssertEqual(ModelPlan.recommend(memoryGB: memory).videoBackend, "MLX")
        }
    }

    /// The command we show the owner must name exactly the model we resolved, or
    /// a manual `ollama pull` installs something the plan will never find.
    func testPullCommandsNameTheResolvedModels() {
        for memory in [16, 36, 48, 64, 96, 128] {
            let plan = ModelPlan.recommend(memoryGB: memory)
            XCTAssertEqual(plan.ollamaModelPull, "ollama pull \(plan.llmRef)", "\(memory)GB")
            XCTAssertTrue(plan.llmRef.hasPrefix("qwen3.8:"), plan.llmRef)
            XCTAssertFalse(plan.rationale.isEmpty)
            XCTAssertFalse(plan.ltxWeightsHint.isEmpty)
        }
    }

    /// No band may promise more resident memory than the machine has, or the
    /// installer would pull weights that OOM the desktop session.
    func testExpectedResidentMemoryFitsTheMachine() {
        for memory in [16, 24, 36, 48, 64, 96, 128, 192] {
            let plan = ModelPlan.recommend(memoryGB: memory)
            XCTAssertGreaterThan(plan.expectedResidentGB, 0, "\(memory)GB")
            XCTAssertLessThan(plan.expectedResidentGB, memory, "\(memory)GB")
        }
    }

    func testPlanFromProfileUsesTheSameLadder() {
        let samples = sampleProfiles
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(
            ModelPlan.recommend(for: samples[0]),
            ModelPlan.recommend(memoryGB: 128)
        )
        XCTAssertEqual(ModelPlan.recommend(for: samples[1]), ModelPlan.recommend(memoryGB: 48))
        XCTAssertEqual(ModelPlan.recommend(for: samples[2]), ModelPlan.recommend(memoryGB: 16))
        for sample in samples {
            XCTAssertEqual(sample.tier, ComputeTier(memoryGB: sample.memoryGB))
            XCTAssertEqual(sample.memoryGB, Int(sample.memoryTotal.gibibytes.rounded()))
        }
    }

    func testProfileDerivedFieldsMatchThePublishedFormulas() {
        let flagship = sampleProfiles[0]
        XCTAssertEqual(flagship.shortLabel, "Apple M5 Max · 128 GB")
        XCTAssertEqual(flagship.renderWorkerBudget, 12, "min(12, 16 - 2)")
        XCTAssertEqual(flagship.meshMemoryCeilingGB, 70, "Int(128 * 0.55)")
        XCTAssertTrue(flagship.isAppleSilicon)

        let small = sampleProfiles[2]
        XCTAssertEqual(small.shortLabel, "Apple M3 · 16 GB")
        XCTAssertEqual(small.renderWorkerBudget, 6, "min(12, 8 - 2)")
        XCTAssertEqual(small.meshMemoryCeilingGB, 8, "floor of 8 GB for the mesh ceiling")

        // An Intel Xeon Mac is not Apple Silicon even though it is 64-bit x86.
        let intel = MacHardwareProfile(
            chipName: "Intel Core i9-9980HK", modelIdentifier: "MacBookPro15,1", cpuArchitecture: "x86_64",
            logicalCPUCount: 12, physicalCPUCount: 8, performanceCoreCount: 8, efficiencyCoreCount: 0,
            memoryTotal: ByteCount(bytes: 32 * 1_073_741_824),
            freeDisk: ByteCount(bytes: 200 * 1_073_741_824), totalDisk: ByteCount(bytes: 1_000 * 1_073_741_824),
            systemVolumeName: "Macintosh HD", operatingSystem: "15.7", kernelVersion: "24.6.0",
            serialMasked: "00000000"
        )
        XCTAssertFalse(intel.isAppleSilicon)
        XCTAssertEqual(intel.tier, .light)
    }

    // MARK: Numbers and text

    func testByteCountHumanizing() {
        XCTAssertEqual(ByteCount(bytes: 0).humanized, "0 B")
        XCTAssertEqual(ByteCount(bytes: 999).humanized, "999 B")
        XCTAssertEqual(ByteCount(bytes: 1_024).humanized, "1.0 KB")
        XCTAssertEqual(ByteCount(bytes: 1_048_576).humanized, "1.0 MB")
        XCTAssertEqual(ByteCount(bytes: 128 * 1_073_741_824).roundedGibibytes, 128)
        XCTAssertEqual(ByteCount(bytes: 47 * 1_073_741_824).roundedGibibytes, 47)
        XCTAssertEqual(ByteCount(bytes: 512 * 1_048_576).gibibytes, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ByteCount(bytes: 1_073_741_824).mebibytes, 1_024, accuracy: 0.001)
        XCTAssertTrue(ByteCount(bytes: 1_048_576) < ByteCount(bytes: 2_097_152))
        XCTAssertEqual(ByteCount(bytes: -5).humanized, "-5 B", "a negative count is never scaled")
    }

    /// Golden digests, not self-consistency: a test that compares two calls of the
    /// same hash function would happily pass a swap to MD5.
    func testSHA256MatchesPublishedVectors() {
        XCTAssertEqual(
            Digest.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            Digest.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            Digest.sha256Hex(Data([0x61, 0x62, 0x63])),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(Digest.sha256Bytes(Data()).count, 32)
        XCTAssertEqual(Digest.short(Data([0xde, 0xad, 0xbe, 0xef]), length: 4).count, 4)
    }

    func testConstantTimeMatcherOnlyAcceptsEqualDigests() {
        let honest = Digest.sha256Hex("node")
        XCTAssertTrue(Digest.matches(honest, Digest.sha256Hex("node")))
        XCTAssertFalse(Digest.matches(honest, Digest.sha256Hex("nodes")))
        XCTAssertFalse(Digest.matches(honest, String(honest.dropLast())))
        XCTAssertFalse(Digest.matches(honest, honest.uppercased()))
        XCTAssertTrue(Digest.matches("", ""))
    }

    func testBase64URLHasNoPaddingOrAlphabetAmbiguity() {
        let data = Data((0..<48).map { UInt8($0) })
        let encoded = TextKit.base64URL(data)
        for forbidden in ["=", "+", "/"] {
            XCTAssertFalse(encoded.contains(forbidden), "\(encoded) contains \(forbidden)")
        }
        XCTAssertEqual(TextKit.base64URLDecode(encoded), data)
        XCTAssertEqual(TextKit.base64URL(Data()).count, 0)
    }

    /// Artifact names arrive off the wire, so the filter has to stop path
    /// traversal and shell metacharacters, not merely pretty-print them.
    func testSafeFileNameCannotEscapeADirectory() {
        let hostile = [
            "../../etc/passwd", "..", ".", "/", "\\..\\x", ".env", "~/.ssh/id_ed25519",
            "$(`whoami`)", "a\nb", "a|b;c", "*", "?", "; rm -rf /", String(repeating: ".", count: 200)
        ]
        for raw in hostile {
            let name = TextKit.safeFileName(raw)
            XCTAssertFalse(name.contains("/"), "\(raw) → \(name)")
            XCTAssertFalse(name.contains("\\"), "\(raw) → \(name)")
            XCTAssertFalse(name.contains(" "), "\(raw) → \(name)")
            XCTAssertFalse(name.contains(".."), "\(raw) → \(name)")
            XCTAssertFalse(name.hasPrefix("."), "\(raw) → \(name)")
            for forbidden in ["|", ";", "$", "`", "?", "*"] {
                XCTAssertFalse(name.contains(forbidden), "\(raw) → \(name)")
            }
            XCTAssertFalse(name.isEmpty, raw)
        }
        XCTAssertEqual(TextKit.safeFileName(""), "artifact")
        XCTAssertEqual(TextKit.safeFileName("///"), "artifact")
        XCTAssertEqual(TextKit.safeFileName(".."), "artifact")
        XCTAssertEqual(TextKit.safeFileName("."), "artifact")
        XCTAssertEqual(TextKit.safeFileName("*"), "artifact")
    }

    func testSafeFileNameKeepsLegitimateNames() {
        XCTAssertEqual(TextKit.safeFileName("briefing-2026-11-21.mp4"), "briefing-2026-11-21.mp4")
        XCTAssertEqual(TextKit.safeFileName("LTX Render.MP4"), "ltx-render.mp4")
        XCTAssertEqual(TextKit.safeFileName("简报 4K.mp4"), "简报-4k.mp4")
        XCTAssertEqual(TextKit.safeFileName("clip_01.draft.mov"), "clip_01.draft.mov")
        XCTAssertEqual(TextKit.safeFileName("render"), "render")
        XCTAssertEqual(TextKit.safeFileName(".env"), "env")
        XCTAssertEqual(TextKit.safeFileName("; rm -rf /"), "rm-rf")
        XCTAssertEqual(TextKit.safeFileName(String(repeating: "a", count: 400)).count, 72)
    }

    /// The open-source red line: no log line, error string or snapshot field may
    /// carry the owner's home directory — as a prefix or buried mid-sentence.
    func testAnonymiseNeverLeaksHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(home.isEmpty)
        XCTAssertTrue(home.hasPrefix("/"))
        let cases = [
            "\(home)/Library/Application Support/PopopxMacNode/logs/install.log",
            "The operation couldn't be completed. Cannot write to \(home)/tmp: permission denied",
            "Traceback: File \"\(home)/engines/ltx2/main.py\", line 12",
            "\(home)\(home)/doubled",
            home
        ]
        for text in cases {
            let masked = AppPaths.anonymise(text)
            XCTAssertFalse(masked.contains(home), "\(masked) still contains the home path")
            XCTAssertTrue(masked.contains("~"), masked)
        }
        XCTAssertEqual(AppPaths.anonymise(home), "~")
        XCTAssertEqual(AppPaths.anonymise("/usr/bin/ffmpeg"), "/usr/bin/ffmpeg")
        XCTAssertEqual(AppPaths.anonymise(url: AppPaths.root), "~/Library/Application Support/PopopxMacNode")
    }

    func testRandomTokensAreDistinctAndLongEnough() {
        let a = TextKit.randomToken(bytes: 32)
        let b = TextKit.randomToken(bytes: 32)
        XCTAssertEqual(a.count, 43, "32 bytes of unpadded base64url")
        XCTAssertNotEqual(a, b)
        for forbidden in ["+", "/", "=", " "] {
            XCTAssertFalse(a.contains(forbidden), a)
        }
        XCTAssertEqual(TextKit.randomToken(bytes: 8).count, 11)
    }

    func testFingerprintIsStableShortAndCollisionResistant() {
        XCTAssertEqual(TextKit.fingerprint("PPXNODE1-abc"), TextKit.fingerprint("PPXNODE1-abc"))
        XCTAssertEqual(TextKit.fingerprint("PPXNODE1-abc").count, 8)
        XCTAssertNotEqual(TextKit.fingerprint("PPXNODE1-abc"), TextKit.fingerprint("PPXNODE1-abd"))
        XCTAssertNotEqual(TextKit.fingerprint(""), TextKit.fingerprint("x"))
    }

    func testTruncateKeepsReadabilityWithoutLying() {
        XCTAssertEqual(TextKit.truncate("short", to: 20), "short")
        let long = String(repeating: "k", count: 200)
        XCTAssertTrue(TextKit.truncate(long, to: 24).hasSuffix("…"))
        XCTAssertLessThanOrEqual(TextKit.truncate(long, to: 24).count, 25)
    }

    // MARK: JSON value

    func testJSONValueLiteralProtocolsAndAccessors() {
        let value: JSONValue = ["engine": .string("shadow_cos"), "ok": .bool(true), "count": .int(3)]
        XCTAssertEqual(value["engine"]?.stringValue, "shadow_cos")
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertEqual(value["count"]?.intValue, 3)
        XCTAssertNil(value["missing"])

        let array: JSONValue = [1, 2, 3]
        XCTAssertEqual(array.arrayValue?.count, 3)
        XCTAssertEqual(array[1]?.intValue, 2)
        XCTAssertNil(array[3])

        XCTAssertTrue(JSONValue.null.isEmptyValue)
        XCTAssertTrue(JSONValue.string("").isEmptyValue)
        XCTAssertTrue(JSONValue.array([]).isEmptyValue)
        XCTAssertTrue(JSONValue.object([:]).isEmptyValue)
        XCTAssertFalse(JSONValue.bool(false).isEmptyValue)
        XCTAssertFalse(JSONValue.int(0).isEmptyValue)
        XCTAssertFalse(JSONValue.object(["a": .int(1)]).debugSummary.isEmpty)
    }

    /// Bare scalars on the wire are legal: the iOS side sometimes sends a plain
    /// token where a JSON object was expected.
    func testJSONValueParsesScalarsAndKeepsGarbageAsText() {
        XCTAssertEqual(JSONValue.parse("42").intValue, 42)
        XCTAssertEqual(JSONValue.parse("4.5").doubleValue ?? -1, 4.5, accuracy: 0.0001)
        XCTAssertEqual(JSONValue.parse("true").boolValue, true)
        XCTAssertEqual(JSONValue.parse("\"hello\"").stringValue, "hello")
        XCTAssertEqual(JSONValue.parse("not json").stringValue, "not json")
        XCTAssertEqual(JSONValue.parse("").stringValue, "")
        XCTAssertEqual(JSONValue.parse("{\"a\":[1,2]}")["a"]?.arrayValue?.count, 2)
    }

    func testJSONValueRoundTripThroughTheSharedCoder() throws {
        let value: JSONValue = [
            "nested": ["list": [1, "two", .null]],
            "float": 1.5,
            "empty": .object([:])
        ]
        let data = try XCTUnwrap(NodeJSON.encodeLine(value))
        let decoded = try XCTUnwrap(NodeJSON.decode(JSONValue.self, from: data))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["nested"]?["list"]?.arrayValue?.count, 3)
        XCTAssertNil(NodeJSON.decode(JSONValue.self, from: Data("garbage".utf8)))
        XCTAssertTrue(value.serialized().contains("\"nested\""))
    }

    /// One coder for files, REST and the SMP wire, or the three formats drift.
    func testNodeJSONUsesSecondPrecisionISO8601AndSortedKeys() throws {
        struct Probe: Codable { let z: Date; let a: Int }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let line = String(
            decoding: try XCTUnwrap(NodeJSON.encodeLine(Probe(z: date, a: 1))),
            as: UTF8.self
        )
        XCTAssertEqual(line, "{\"a\":1,\"z\":\"2027-01-15T08:00:00Z\"}")

        XCTAssertTrue(date.ppxISO8601.hasSuffix("Z"), date.ppxISO8601)
        XCTAssertEqual(date.ppxISO8601, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(try XCTUnwrap(Date.ppxFromISO8601(date.ppxISO8601)), date)
        XCTAssertEqual(try XCTUnwrap(Date.ppxFromISO8601("2027-01-15T08:00:00Z")), date)
        XCTAssertNil(Date.ppxFromISO8601("yesterday"))
        // ppxClock renders in the machine's own timezone, so the expectation is
        // built from the local calendar instead of a fixed UTC hour.
        let local = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 13, minute: 45, second: 30))
        )
        XCTAssertEqual(local.ppxClock, "13:45:30")
    }

    // MARK: Settings document

    func testEngineSwitchDefaultsKeepMeshSharingOff() {
        let defaults = NodeSettings.defaultEngineSwitches()
        XCTAssertEqual(Set(defaults.keys), Set(EngineKind.allCases.map { $0.rawValue }))
        XCTAssertEqual(defaults[EngineKind.edgeComputeMesh.rawValue], false, "lending compute is opt-in")
        for kind in EngineKind.allCases where kind != .edgeComputeMesh {
            XCTAssertEqual(defaults[kind.rawValue], true, kind.rawValue)
        }
    }

    func testFlippingOneSwitchCannotTouchAnother() {
        var settings = NodeSettings()
        for kind in EngineKind.allCases {
            let before = settings.isEnabled(kind)
            let next = settings.withEnabled(kind, !before)
            XCTAssertEqual(next.isEnabled(kind), !before, kind.rawValue)
            XCTAssertEqual(next.enginesEnabled[kind.rawValue], !before, kind.rawValue)
            for other in EngineKind.allCases where other != kind {
                XCTAssertEqual(next.isEnabled(other), settings.isEnabled(other), other.rawValue)
            }
            settings = next
        }
        XCTAssertEqual(settings.enginesEnabled.count, EngineKind.allCases.count)
    }

    func testMissingSwitchKeyFallsBackToTheShippedDefault() {
        var settings = NodeSettings()
        settings.enginesEnabled = [:]
        XCTAssertEqual(settings.isEnabled(.shadowCos), true, "everything but mesh is on by default")
        XCTAssertEqual(settings.isEnabled(.edgeComputeMesh), false)
        XCTAssertEqual(
            settings.enabledEngineList,
            EngineKind.displayOrder.filter { $0 != .edgeComputeMesh }
        )

        settings.enginesEnabled = [EngineKind.morningTv.rawValue: false]
        XCTAssertFalse(settings.isEnabled(.morningTv))
        XCTAssertFalse(settings.enabledEngineList.contains(.morningTv))
        XCTAssertTrue(settings.enabledEngineList.contains(.healthSentinel))
    }

    func testSettingsDocumentRoundTripPreservesEverySection() throws {
        var settings = NodeSettings()
        settings.nodeName = "Studio M5 Max"
        settings.language = .english
        settings.launchAtLogin = true
        settings.llmModelOverride = "qwen3.8:27b-q8_0"
        settings.shadowWorkspaces = ["~/Documents/Briefings"]
        settings.mesh.sharingEnabled = true
        settings.mesh.maxMemoryGB = 24
        settings.ark.heartbeatIntervalHours = 48
        settings.sentinel.unmountPaths = ["/Volumes/Vault"]
        settings.sentinel.webhookURL = "http://192.168.1.9:8383/api/away"
        // Second precision: the shared coder writes ISO8601 without fractions, so
        // a sub-second `Date()` would legitimately not survive the round trip.
        settings.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let data = try XCTUnwrap(NodeJSON.encodePretty(settings))
        let decoded = try XCTUnwrap(NodeJSON.decode(NodeSettings.self, from: data))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.mesh.maxMemoryGB, 24)
        XCTAssertEqual(decoded.ark.heartbeatIntervalHours, 48)
        XCTAssertEqual(decoded.sentinel.unmountPaths, ["/Volumes/Vault"])
        XCTAssertEqual(decoded.language.shortLabel, "EN")
        XCTAssertEqual(decoded.updatedAt, settings.updatedAt)
    }

    /// The safety floors are the reason a compromised chat message cannot make the
    /// node thrash itself or open the vault instantly.
    func testSafetyFloorsCannotBeConfiguredAway() {
        XCTAssertEqual(MeshConfig(maxMemoryGB: 1).maxMemoryGB, 4, "a 1 GB ceiling would thrash the machine")
        XCTAssertEqual(MeshConfig(minFreeDiskGB: 0).minFreeDiskGB, 10)
        XCTAssertEqual(MeshConfig(maxConcurrentJobs: 0).maxConcurrentJobs, 1)
        XCTAssertEqual(MeshConfig().sharingEnabled, false)
        XCTAssertEqual(SentinelConfig(triggerPhrases: []).triggerPhrases, NodeWire.lockTriggers)
        XCTAssertEqual(ArkConfig(heartbeatIntervalHours: 0).heartbeatIntervalHours, 1)
        XCTAssertEqual(ArkConfig(missedHeartbeatsBeforeRelease: 0).missedHeartbeatsBeforeRelease, 1)
        XCTAssertEqual(ArkConfig(timelockSeconds: 1).timelockSeconds, 60, "a 1 second vault is not a vault")
        XCTAssertEqual(WarroomConfig(payloadBits: 1).payloadBits, 8)
        XCTAssertEqual(WarroomConfig(payloadBits: 9_000).payloadBits, 32)
        XCTAssertEqual(WarroomConfig(segmentsPerVideo: 0).segmentsPerVideo, 8)
    }

    // MARK: Scheduling primitives

    func testTimeWindowHonoursWeekdays() throws {
        let calendar = shanghai
        // 2026-11-23 is a Monday (weekday 2), 2026-11-28 is a Saturday (weekday 7).
        let monday = try XCTUnwrap(Self.at("02:30", year: 2026, month: 11, day: 23, calendar: calendar))
        let saturday = try XCTUnwrap(Self.at("02:30", year: 2026, month: 11, day: 28, calendar: calendar))
        let midday = try XCTUnwrap(Self.at("12:00", year: 2026, month: 11, day: 23, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)
        XCTAssertEqual(calendar.component(.weekday, from: saturday), 7)

        let overnight = TimeWindow(startHour: 23, endHour: 6, weekdays: [2, 3, 4, 5, 6])
        XCTAssertTrue(overnight.contains(monday, calendar: calendar), "02:30 Monday is inside 23→06")
        XCTAssertFalse(overnight.contains(midday, calendar: calendar))
        XCTAssertFalse(overnight.contains(saturday, calendar: calendar), "the weekday filter outranks the hour")

        let daytime = TimeWindow(startHour: 9, endHour: 17, weekdays: Array(1...7))
        let nine = try XCTUnwrap(Self.at("09:00", year: 2026, month: 11, day: 23, calendar: calendar))
        let seventeen = try XCTUnwrap(Self.at("17:00", year: 2026, month: 11, day: 23, calendar: calendar))
        XCTAssertTrue(daytime.contains(nine, calendar: calendar))
        XCTAssertFalse(daytime.contains(seventeen, calendar: calendar), "endHour is exclusive")
        XCTAssertEqual(daytime.label, "09:00-17:00")
    }

    func testTimeWindowClampsNonsenseAndTreatsEmptyAsNever() throws {
        let calendar = shanghai
        let absurd = TimeWindow(startHour: -5, endHour: 40, weekdays: Array(1...7))
        XCTAssertEqual(absurd.startHour, 0)
        XCTAssertEqual(absurd.endHour, 23)
        XCTAssertEqual(absurd.label, "00:00-23:00")

        let noon = try XCTUnwrap(Self.at("12:00", year: 2026, month: 11, day: 23, calendar: calendar))
        XCTAssertTrue(absurd.contains(noon, calendar: calendar))

        let zeroLength = TimeWindow(startHour: 5, endHour: 5, weekdays: Array(1...7))
        let five = try XCTUnwrap(Self.at("05:00", year: 2026, month: 11, day: 23, calendar: calendar))
        XCTAssertFalse(zeroLength.contains(five, calendar: calendar),
                       "start == end is an empty half-open range, not \"all day\"")
        XCTAssertEqual(TimeWindow(startHour: 1, endHour: 2).weekdays, Array(2...6),
                       "an omitted weekday list means weekdays, not never")
        XCTAssertEqual(TimeWindow(startHour: 1, endHour: 2, weekdays: []).weekdays, Array(2...6))
    }

    /// `acceptingWork` resolves the window in the machine's own calendar, so these
    /// dates are built with `Calendar.current` rather than a fixed zone.
    func testMeshSharingRequiresBothSwitchAndWindow() throws {
        let calendar = Calendar.current
        let today = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let weekday = calendar.component(.weekday, from: today)
        let window = TimeWindow(startHour: 1, endHour: 5, weekdays: [weekday])
        let inside = try XCTUnwrap(calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today))
        let outside = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today))
        XCTAssertTrue(window.contains(inside, calendar: calendar))
        XCTAssertFalse(window.contains(outside, calendar: calendar))

        var config = MeshConfig()
        config.sharingEnabled = false
        config.idleWindows = [window]
        XCTAssertFalse(config.acceptingWork(at: inside), "the switch is the owner's veto, not a suggestion")

        config.sharingEnabled = true
        XCTAssertTrue(config.acceptingWork(at: inside))
        XCTAssertFalse(config.acceptingWork(at: outside))

        config.idleWindows = []
        XCTAssertFalse(config.acceptingWork(at: inside), "no configured window must not mean \"always\"")
    }

    func testArkDeadlinesDeriveFromHeartbeatAndTimelock() throws {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        var config = ArkConfig()
        config.lastHeartbeatAt = anchor
        config.heartbeatIntervalHours = 24
        config.missedHeartbeatsBeforeRelease = 3
        config.timelockSeconds = 3_600

        let release = try XCTUnwrap(config.releaseDeadline)
        let expiry = try XCTUnwrap(config.timelockExpiry)
        XCTAssertEqual(release, anchor.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(expiry, anchor.addingTimeInterval(3_600))
        XCTAssertGreaterThan(release, expiry, "the vault opens long before the owner is declared gone")

        var untouched = ArkConfig()
        XCTAssertNil(untouched.releaseDeadline, "no heartbeat and no release means nothing to time out")
        XCTAssertNil(untouched.timelockExpiry)

        // A sealed archive with no heartbeat yet still has an absolute expiry,
        // anchored to the wall clock instead of a missing date.
        untouched.sealedArchives = ["vault.zip"]
        XCTAssertNotNil(untouched.timelockExpiry)
        XCTAssertNil(untouched.releaseDeadline)

        // Only `releasedAt` set: the release deadline exists, the time lock does not.
        var released = ArkConfig()
        released.releasedAt = anchor
        XCTAssertEqual(released.releaseDeadline, anchor.addingTimeInterval(72 * 4 * 3_600))
        XCTAssertNil(released.timelockExpiry)
    }

    func testPairingOfferExpiryAndOneTimeUse() {
        let now = Date()
        var fresh = PairingOffer(
            code: "PPXNODE1-abc.sig",
            invitationURI: "popopx:/i#linkid/linkkey",
            nodePublicKey: "pub",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(fresh.id, fresh.code)
        XCTAssertTrue(fresh.isValid, "a 60 second offer is valid right now")
        XCTAssertEqual(fresh.secondsRemaining(at: now.addingTimeInterval(20)), 40)
        XCTAssertEqual(fresh.secondsRemaining(at: now.addingTimeInterval(120)), 0, "never negative")

        fresh.used = true
        XCTAssertFalse(fresh.isValid, "a scanned offer must not be reusable")

        let nonOneTime = PairingOffer(
            code: "PPXNODE1-reusable.sig",
            invitationURI: "popopx:/i#linkid/linkkey",
            nodePublicKey: "pub",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60),
            oneTime: false,
            used: true
        )
        /* `oneTime` is a label for the QR card; retirement is unconditional.
           `MacNodePopopxBridge` sets `used` the moment the daemon reports the
           connection was consumed, so an offer that carries `used` is spent
           whatever its `oneTime` flag says. */
        XCTAssertFalse(nonOneTime.isValid, "a retired offer is spent even when it was issued as reusable")

        let stale = PairingOffer(
            code: "PPXNODE1-old.sig",
            invitationURI: "popopx:/invitation#/?v=6-8",
            nodePublicKey: "pub",
            issuedAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertFalse(stale.isValid)
    }

    func testInvitationLinksStayWithinWhatTheDaemonAccepts() {
        let overflow = "popopx:/invitation#/?v=6-8&smp=" + String(repeating: "a", count: NodeWire.maxInvitationLinkCharacters)
        XCTAssertGreaterThan(overflow.count, NodeWire.maxInvitationLinkCharacters, "fixture must overflow")
        for link in ["popopx:/i#linkid/linkkey", "https://popopx.chat/contact#abc"] {
            XCTAssertLessThanOrEqual(link.count, NodeWire.maxInvitationLinkCharacters)
            XCTAssertTrue(
                link.hasPrefix(NodeWire.invitationScheme) || link.hasPrefix(NodeWire.invitationShareHost), link
            )
            for forbidden in NodeWire.forbiddenLinkCharacters {
                XCTAssertFalse(link.contains(forbidden), "\(link) contains \(forbidden)")
            }
        }
    }

    // MARK: Paths

    func testAppPathsLayoutStaysUnderTheNodeRoot() {
        let root = AppPaths.root.path
        XCTAssertTrue(root.hasSuffix("/Library/Application Support/PopopxMacNode"), root)
        let directories = [
            AppPaths.engines, AppPaths.ltxWorkspace, AppPaths.weights, AppPaths.logs, AppPaths.config,
            AppPaths.vault, AppPaths.sealed, AppPaths.pairing, AppPaths.popopx, AppPaths.outbox,
            AppPaths.sandboxes, AppPaths.ledger, AppPaths.output, AppPaths.quarantine
        ]
        for url in directories {
            XCTAssertTrue(AppPaths.isContained(url), "\(url.path) escapes \(root)")
            XCTAssertNotEqual(url.path, root, "\(url.lastPathComponent) must not collide with the root")
        }
        XCTAssertEqual(AppPaths.ltxWorkspace.path, AppPaths.engines.appendingPathComponent("ltx2").path)
        XCTAssertEqual(AppPaths.weights.path, AppPaths.engines.appendingPathComponent("weights").path)
        XCTAssertEqual(AppPaths.sealed.path, AppPaths.vault.appendingPathComponent("sealed").path)
        XCTAssertEqual(AppPaths.ltxVenv.path, AppPaths.ltxWorkspace.appendingPathComponent(".venv").path)
    }

    func testFileNamesAreWhereTheDocumentSaysTheyAre() {
        XCTAssertTrue(AppPaths.settingsFile.path.hasSuffix("config/settings.json"))
        XCTAssertTrue(AppPaths.pairedDevicesFile.path.hasSuffix("pairing/devices.json"))
        XCTAssertTrue(AppPaths.nodeKeyFile.path.hasSuffix("pairing/node.key"))
        XCTAssertTrue(AppPaths.offerFile.path.hasSuffix("pairing/offer.json"))
        XCTAssertTrue(AppPaths.installLogFile.path.hasSuffix("logs/install.log"))
        XCTAssertTrue(AppPaths.auditLogFile.path.hasSuffix("logs/node.log"))
        XCTAssertTrue(AppPaths.lockdownLedgerFile.path.hasSuffix("ledger/lockdown.json"))
        XCTAssertTrue(AppPaths.meshLedgerFile.path.hasSuffix("ledger/mesh.json"))
        XCTAssertEqual(AppPaths.appName, "POPOPX Mac Node")
        XCTAssertEqual(AppPaths.bundleName, "PopopxMacNode")
    }

    /// `README.md` and `README.zh-CN.md` are one document in two languages, so the
    /// split is only safe while they stay in lockstep. Structure, links, the
    /// architecture diagram and the engine matrix are compared against each other
    /// rather than against literals, and each file is checked to stay in its own
    /// script. Adding an engine to `EngineKind` without documenting it in both
    /// languages fails here, as does translating one section and forgetting the other.
    func testTheTwoReadmeLanguagesStayInLockstep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Tests/PopopxMacNodeTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // repository root
        let english = try ReadmeProbe(url: root.appendingPathComponent("README.md"))
        let chinese = try ReadmeProbe(url: root.appendingPathComponent("README.zh-CN.md"))

        XCTAssertEqual(english.levelTwoCount, 11, "the document has eleven top-level sections")
        XCTAssertEqual(english.levelTwoCount, chinese.levelTwoCount, "one README gained or lost a section")
        XCTAssertEqual(english.levelThreeCount, 10, "one build guide, the daemon install guide, plus eight self-audit checks")
        XCTAssertEqual(english.levelThreeCount, chinese.levelThreeCount, "the audit guide no longer mirrors")
        XCTAssertEqual(english.fenceCount, chinese.fenceCount, "the two documents no longer show the same commands")
        XCTAssertEqual(english.tableRowCount, chinese.tableRowCount, "the tables must keep the same rows")
        XCTAssertEqual(english.dividerCount, chinese.dividerCount)
        XCTAssertEqual(english.badgeCount, chinese.badgeCount, "the badge row must be the same in both languages")
        XCTAssertEqual(english.linkTargets, chinese.linkTargets, "one language links where the other does not")
        XCTAssertGreaterThan(english.diagram.count, 1_500, "the architecture diagram is missing from README.md")
        XCTAssertEqual(english.diagram, chinese.diagram, "the architecture diagram must stay byte-identical")
        XCTAssertEqual(english.throughputRows, 5, "the memory ladder has exactly five bands")
        XCTAssertEqual(english.throughputRows, chinese.throughputRows, "the ladder was edited in one language only")

        for kind in EngineKind.displayOrder {
            XCTAssertTrue(english.text.contains("`\(kind.rawValue)`"), "README.md does not document \(kind.rawValue)")
            XCTAssertTrue(chinese.text.contains("`\(kind.rawValue)`"), "README.zh-CN.md does not document \(kind.rawValue)")
            XCTAssertTrue(english.text.contains(kind.displayNameEn), "README.md is missing the name of \(kind.rawValue)")
            XCTAssertTrue(chinese.text.contains(kind.displayNameZh), "README.zh-CN.md is missing the name of \(kind.rawValue)")
        }

        // Each document stays in its own language. The only Han in the English file is
        // the name of the other language, because a switcher has to spell it out.
        XCTAssertTrue(
            english.hanziLines.allSatisfy { $0.contains("./README.zh-CN.md") },
            "README.md carries prose the Chinese document owns: \(english.hanziLines)"
        )
        XCTAssertGreaterThan(chinese.hanziCount, 1_000, "README.zh-CN.md is not Chinese")
        XCTAssertTrue(english.text.contains("[简体中文](./README.zh-CN.md)"), "no way from English to Chinese")
        XCTAssertTrue(chinese.text.contains("[English](./README.md)"), "no way from Chinese to English")
    }

    /// Wizard step 2 and the SMP bridge need the daemon, so how a reader obtains it is part of the
    /// contract, not a footnote. Two READMEs and the console must name the *same* endpoint, must
    /// name it in checksum-first order (download, verify, then run), and must never tell the reader
    /// to pipe a download into a shell. The bare apex host is rejected too: drop `raw.` from the
    /// endpoint and that is what you get, it resolves to nothing, and piping a download from it
    /// straight into bash feeds an empty body to a shell and reports success. The digest is a dated
    /// measurement that the READMEs present as such — a test cannot fetch it, and a test that
    /// asserted a fetched value would be a network call.
    func testTheChatDaemonInstallGuideIsChecksumFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Both needles are derived, not hand-typed: an absence assertion with a misspelled needle
        // passes forever without noticing, and this file has already been bitten by `popupx`.
        let endpoint = "https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh"
        let deadApex = endpoint.replacingOccurrences(of: "raw.", with: "")
        let digest = "5a8d7c4572efed20fc545ea4ce256fd61cd5becee7cb82d0e86be9973d7d07f1"
        XCTAssertTrue(endpoint.contains("raw.githubusercontent.com"), endpoint)
        XCTAssertFalse(deadApex.contains("raw."), deadApex)
        XCTAssertTrue(endpoint.hasSuffix("/popopx-chat/popopx-chat/master/install.sh"), endpoint)

        var texts: [String: String] = [:]
        for name in ["README.md", "README.zh-CN.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            texts[name] = text
            XCTAssertTrue(text.contains(endpoint), "\(name) does not name the install endpoint")
            XCTAssertEqual(text.components(separatedBy: digest).count - 1, 1, "\(name) states the digest other than once")
            XCTAssertNil(text.range(of: deadApex), "\(name) tells the reader to download from a host that does not resolve")
            XCTAssertEqual(text.components(separatedBy: "curl -o-").count - 1, 1, "\(name) has more than one download command")
            for pipeToShell in ["| bash", "| sh ", "|sh", "| zsh"] {
                XCTAssertNil(text.range(of: pipeToShell), "\(name) pipes a download straight into a shell")
            }
            guard let verify = text.range(of: "shasum -a 256 -c"), let run = text.range(of: "bash popopx-install.sh") else {
                return XCTFail("\(name) is missing either the verification step or the run step")
            }
            XCTAssertLessThan(verify.lowerBound, run.lowerBound, "\(name) runs the script before it checks it")
        }
        // Inside the install section there is exactly one 64-hex string per document, it is the same
        // one in both languages, and it is the value the prose attributes to `master/install.sh`.
        // Elsewhere the READMEs publish other digests (the DMG, the sibling licences) and that is fine.
        var installHexes: [String: Set<String>] = [:]
        for (name, text) in texts {
            let heading = name == "README.md" ? "### The chat daemon" : "### 聊天守护进程"
            guard let from = text.range(of: heading) else { return XCTFail("\(name) has no \(heading) section") }
            let tail = text[from.upperBound...]
            let end = tail.range(of: "\n### ")?.lowerBound ?? tail.endIndex
            let section = String(tail[..<end])
            XCTAssertTrue(section.contains(endpoint), "\(name): the install section lost the endpoint")
            installHexes[name] = jsIdentifierGroups(in: section, pattern: "([0-9a-f]{64})")
        }
        for (name, hexes) in installHexes {
            XCTAssertEqual(hexes, [digest], "\(name) publishes a digest that is not the measured one: \(hexes)")
        }

        // The console copy is the third place the same command has to appear, once per language.
        let console = try String(
            contentsOf: root.appendingPathComponent("Sources/PopopxMacNode/WebConsole/LocalWebConsoleServer.swift"),
            encoding: .utf8
        )
        let lines = console.split(separator: "\n", omittingEmptySubsequences: false)
        let install = lines.filter { $0.hasPrefix("  daemonInstall: { zh:") }
        XCTAssertEqual(install.count, 1, "the daemon-missing copy must exist exactly once")
        guard let copy = install.first else { return }
        XCTAssertTrue(copy.contains(endpoint), "the console names a different endpoint than the READMEs")
        XCTAssertTrue(copy.contains("shasum"), "the console tells the reader to run the script without checking it")
        for pipeToShell in ["| bash", "| sh ", "|sh"] {
            XCTAssertNil(copy.range(of: pipeToShell), "the console copy pipes into a shell")
        }
        let halves = copy.components(separatedBy: "en: ")
        XCTAssertEqual(halves.count, 2, "the copy is one zh string and one en string")
        for half in halves {
            XCTAssertTrue(half.contains(endpoint), "one language of the console copy lost the endpoint")
            XCTAssertTrue(half.contains("popopx-chat"), "one language of the console copy does not name the daemon")
        }
        XCTAssertTrue(
            console.contains("setText(\"bridge-install\", bridge.binaryPath ? \"\" : t(\"daemonInstall\"));"),
            "the console computes the install copy but never shows it"
        )
    }

    /// `config/engines.json` outlives a rename: a node that was configured before
    /// `simplexChatBinaryPath` became `popopxChatBinaryPath` must still find its daemon, and the
    /// file it writes back must contain only the new key, so the old spelling stops spreading.
    /// Both directions are asserted against the production coders, not a hand-rolled decoder.
    func testEnginesJSONReadsTheLegacyKeyAndWritesOnlyTheNewOne() throws {
        func config(_ json: String) throws -> HWEngineConfig {
            guard let decoded = NodeJSON.decode(HWEngineConfig.self, from: Data(json.utf8)) else {
                XCTFail("the production decoder rejected \(json)")
                return .empty
            }
            return decoded
        }

        let legacy = try config(
            #"{"weightSources":[],"simplexChatBinaryPath":"/legacy/bin/popopx-chat","allowHomebrewBootstrap":true}"#
        )
        XCTAssertEqual(legacy.popopxChatBinaryPath, "/legacy/bin/popopx-chat", "an old engines.json lost its daemon path")
        XCTAssertEqual(legacy.allowHomebrewBootstrap, true)

        let current = try config(
            #"{"weightSources":[],"popopxChatBinaryPath":"/new/bin/popopx-chat","allowHomebrewBootstrap":false}"#
        )
        XCTAssertEqual(current.popopxChatBinaryPath, "/new/bin/popopx-chat")

        let both = try config(
            #"{"weightSources":[],"popopxChatBinaryPath":"/new/bin/popopx-chat","simplexChatBinaryPath":"/legacy/bin/popopx-chat","allowHomebrewBootstrap":false}"#
        )
        XCTAssertEqual(both.popopxChatBinaryPath, "/new/bin/popopx-chat", "the deprecated key outranked the current one")

        let absent = try config(#"{"weightSources":[],"allowHomebrewBootstrap":false}"#)
        XCTAssertNil(absent.popopxChatBinaryPath)

        // Round-tripping the value read from the legacy spelling must not write the legacy spelling.
        guard let data = NodeJSON.encodePretty(legacy), let written = String(data: data, encoding: .utf8) else {
            return XCTFail("the config could not be encoded")
        }
        XCTAssertTrue(written.contains("popopxChatBinaryPath"), written)
        XCTAssertFalse(written.contains("simplexChatBinaryPath"), "the encoder revived the deprecated key")

        // The strict fields keep their synthesized semantics: a missing or malformed one is an
        // error, and a decode error is what makes `load()` fall back to `.empty`.
        XCTAssertNil(NodeJSON.decode(HWEngineConfig.self, from: Data(#"{"weightSources":[]}"#.utf8)))
        XCTAssertNil(NodeJSON.decode(HWEngineConfig.self, from: Data(#"{"weightSources":[],"allowHomebrewBootstrap":"yes"}"#.utf8)))
        XCTAssertEqual(HWEngineConfig.load(), HWEngineConfig.load(), "loading the config twice must be deterministic")
    }

    /// The licence boundary is a claim about three repositories, and two of them are not in this
    /// checkout — so what can be proven here is the shape of the claim: no document may sell the
    /// relay servers, the blind signature or the watermark as closed code outside the section that
    /// records that wording as retracted, both sibling repositories must be named by URL, and the
    /// digest printed on the page must be the digest of the `LICENSE` file it describes.
    func testTheLicenseBoundarySellsServicesNotCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = ["LICENSE-COMMERCIAL.md", "README.md", "README.zh-CN.md"]
        var texts: [String: String] = [:]
        for name in names {
            texts[name] = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }

        let closedWords = ["闭源", "closed-source", "closed source"]
        let codeNouns = ["中继", "relay", "盲签", "blind", "指纹", "fingerprint", "水印", "watermark", "结算", "settlement"]
        // The commercial terms quote the retracted wording on purpose, inside its own section.
        let retractionHeadings = ["本文件修正了什么", "What this document corrected"]
        let retractionTells = [
            "纠正", "误称", "旧表述", "为什么是错的", "correction", "corrected", "Former wording", "Why it was wrong"
        ]
        for name in names {
            let text = try XCTUnwrap(texts[name])
            var insideRetraction = false
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                if line.hasPrefix("## ") {
                    insideRetraction = retractionHeadings.contains { line.contains($0) }
                }
                let lowered = line.lowercased()
                guard closedWords.contains(where: { lowered.contains($0) }) else { continue }
                guard codeNouns.contains(where: { lowered.contains($0) }) else { continue }
                XCTAssert(
                    insideRetraction || retractionTells.contains { line.contains($0) },
                    "\(name):\(offset + 1) offers source as a closed product: \(line)"
                )
            }
            XCTAssertTrue(text.contains("popopxmq"), "\(name) never names the relay repository")
            XCTAssertTrue(
                text.contains("https://github.com/popopx-chat/popopx-chat"),
                "\(name) never links the client repository"
            )
            XCTAssertTrue(text.contains("TRADEMARK-POPOPX.md"), "\(name) never points at the trademark policy")
            XCTAssertFalse(text.contains("Brand & relay:"), "\(name) files the relay source under the brand column")
            XCTAssertFalse(text.contains("品牌与中继"), "\(name) files the relay source under the brand column")
        }

        let commercial = try XCTUnwrap(texts["LICENSE-COMMERCIAL.md"])
        XCTAssertTrue(
            commercial.contains("not registered") && commercial.contains("尚未注册"),
            "the policy states the marks are unregistered; both language halves must say so, not claim a registration"
        )
        XCTAssertTrue(
            commercial.contains("第 13 条") && commercial.contains("section 13"),
            "the AGPL §13 explainer has to survive every rewrite of this file"
        )

        let license = try Data(contentsOf: root.appendingPathComponent("LICENSE"))
        let digest = SHA256.hash(data: license).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest, "8486a10c4393cee1c25392769ddd3b2d6c242d6ec7928e1414efff7dfb2f07ef",
            "LICENSE is no longer the AGPL-3.0 text these documents describe"
        )
        XCTAssertEqual(license.filter { $0 == 0x0A }.count, 661, "the documents quote a 661-line licence")
        for name in names {
            XCTAssertTrue(
                try XCTUnwrap(texts[name]).contains(digest),
                "\(name) prints a licence digest that is not this file's"
            )
        }
    }

    /// Release notes are generated by `.github/workflows/release.yml`, so a corrected document and a
    /// stale generator can disagree silently: until 2026-11-21 the workflow body filed the relay
    /// servers, the blind-signature settlement and the watermarking code as things that need a
    /// commercial licence, and every tag re-published that sentence. The three reserved items are
    /// required inside the `body:` block rather than anywhere in the file, because a YAML comment
    /// would satisfy a whole-file search while shipping nothing, and every `AGPL-3.0` mention has to
    /// carry `-only` — `-or-later` is a different licence from the `LICENSE` file it advertises.
    func testTheReleaseNotesTemplateSellsServicesNotCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8
        )
        let lines = workflow.components(separatedBy: "\n")

        XCTAssertEqual(
            lines.first { $0.contains("SPDX-License-Identifier") },
            "# SPDX-License-Identifier: AGPL-3.0-only",
            "the workflow header no longer declares the licence this repository is under"
        )

        var withoutOnlySuffix = 0
        var cursor = workflow.startIndex
        while let hit = workflow.range(of: "AGPL-3.0", range: cursor..<workflow.endIndex) {
            if !workflow[hit.upperBound...].hasPrefix("-only") { withoutOnlySuffix += 1 }
            cursor = hit.upperBound
        }
        XCTAssertEqual(
            withoutOnlySuffix, 0,
            "an `AGPL-3.0` that is not `AGPL-3.0-only` promises a different licence than LICENSE"
        )

        guard let marker = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "body: |" })
        else {
            return XCTFail("release.yml stopped writing a release body, so these notes come from nowhere")
        }
        var bodyLines: [String] = []
        for line in lines[(marker + 1)...] {
            guard line.isEmpty || line.hasPrefix("            ") else { break }
            bodyLines.append(line)
        }
        XCTAssertGreaterThan(bodyLines.count, 20, "the release body collapsed to \(bodyLines.count) lines")
        let body = bodyLines.joined(separator: "\n")

        XCTAssertTrue(body.contains("GNU AGPL-3.0-only"), "the published notes never name the licence")
        XCTAssertTrue(body.contains("只保留三项"), "the notes no longer say the commercial track is bounded")
        for item in ["官方托管中继网络与带宽", "品牌与商标资产", "官方发行通道与企业 SLA 支持"] {
            XCTAssertTrue(body.contains(item), "the notes no longer reserve \(item), or no longer limit it")
        }
        XCTAssertTrue(
            body.contains("https://github.com/popopx-chat/popopx-mac-node/blob/main/LICENSE-COMMERCIAL.md"),
            "a Release page has no repository-relative base, so the link to the terms has to be absolute"
        )

        for retracted in [
            "中继集群", "SDK 与 POPOPX 商标需商业授权", "**AGPL-3.0**", "./LICENSE-COMMERCIAL.md", "闭源", "closed-source"
        ] {
            XCTAssertFalse(workflow.contains(retracted), "release.yml reintroduces retracted wording: \(retracted)")
        }
    }

    func testContainmentRejectsTraversalAndSiblings() {
        let root = AppPaths.root
        XCTAssertTrue(AppPaths.isContained(root))
        XCTAssertTrue(AppPaths.isContained(root.appendingPathComponent("outbox/a.mp4")))
        XCTAssertFalse(AppPaths.isContained(root.appendingPathComponent("..")))
        XCTAssertFalse(AppPaths.isContained(root.deletingLastPathComponent()))
        XCTAssertFalse(AppPaths.isContained(URL(fileURLWithPath: "/etc/passwd")))
        // A directory whose name merely starts with ours is not ours.
        XCTAssertFalse(AppPaths.isContained(URL(fileURLWithPath: root.path + "Evil/logs")))
    }

    func testContainedResolutionRefusesWhatResolveAccepts() throws {
        XCTAssertNotNil(AppPaths.resolve(userPath: "/tmp/x"))
        XCTAssertNil(AppPaths.resolve(userPath: ""), "blank must not mean the current directory")
        XCTAssertNil(AppPaths.resolve(userPath: "   "))

        let tilde = try XCTUnwrap(AppPaths.resolve(userPath: "~/Documents"))
        XCTAssertFalse(tilde.path.contains("~"), tilde.path)
        XCTAssertFalse(tilde.path.hasPrefix("~"))
        XCTAssertNil(AppPaths.resolveContained(userPath: "~/Documents"), "outside the node root")
        XCTAssertNil(AppPaths.resolveContained(userPath: "outbox/../../../etc"), "traversal")
        XCTAssertNil(AppPaths.resolveContained(userPath: "/etc/passwd"))
        XCTAssertEqual(
            AppPaths.resolveContained(userPath: "outbox/render.mp4")?.path,
            AppPaths.outbox.appendingPathComponent("render.mp4").path
        )
        XCTAssertEqual(
            AppPaths.resolveContained(userPath: AppPaths.outbox.path)?.path,
            AppPaths.outbox.path
        )
    }

    func testSandboxNamesAreDerivedNotGuessed() throws {
        let url = try AppPaths.makeSandbox(jobID: "../../evil job#1")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(AppPaths.isContained(url))
        XCTAssertTrue(url.path.hasPrefix(AppPaths.sandboxes.path + "/"))
        for forbidden in ["/", "\\", " ", ".."] {
            XCTAssertFalse(url.lastPathComponent.contains(forbidden), url.lastPathComponent)
        }
        XCTAssertFalse(url.lastPathComponent.isEmpty)
        XCTAssertEqual(url.deletingLastPathComponent().path, AppPaths.sandboxes.path)
    }

    /// Guard only — a real erase would delete the owner's data during a test run.
    func testEraseRequiresTheLiteralToken() {
        for wrong in ["yes", "", "erase", "confirm", "ERASE-POPOPX-NODE-DATA ", "erase-popopx-node-data"] {
            XCTAssertThrowsError(try AppPaths.eraseNodeData(confirmationToken: wrong), wrong)
        }
    }

    // MARK: Real machine

    func testHardwareProbeReturnsPlausibleRealValues() async {
        let profile = await HardwareProfiler.shared.profile()
        XCTAssertGreaterThan(profile.physicalCPUCount, 0)
        XCTAssertLessThanOrEqual(profile.physicalCPUCount, profile.logicalCPUCount)
        XCTAssertGreaterThan(profile.memoryTotal.gibibytes, 0)
        XCTAssertEqual(profile.memoryGB, profile.memoryTotal.roundedGibibytes)
        XCTAssertFalse(profile.chipName.isEmpty)
        XCTAssertFalse(profile.modelIdentifier.isEmpty)
        XCTAssertFalse(profile.kernelVersion.isEmpty)
        XCTAssertFalse(profile.operatingSystem.isEmpty)
        XCTAssertGreaterThan(profile.totalDisk.gibibytes, profile.freeDisk.gibibytes)
        XCTAssertEqual(profile.tier, ComputeTier(memoryGB: profile.memoryGB))
        XCTAssertTrue(profile.isAppleSilicon, profile.cpuArchitecture)
        XCTAssertEqual(profile.serialMasked.count, 8, "the IOPlatform serial is shown as its last 8 chars")
        XCTAssertEqual(
            profile.performanceCoreCount + profile.efficiencyCoreCount, profile.physicalCPUCount,
            "perf + effi cores should equal the physical core count on Apple Silicon"
        )
    }

    func testSysctlAgreesWithFoundation() {
        XCTAssertEqual(Sysctl.logicalCPUCount, ProcessInfo.processInfo.processorCount)
        XCTAssertEqual(Int(Sysctl.memorySize), Int(ProcessInfo.processInfo.physicalMemory))
        XCTAssertEqual(Sysctl.uint64("hw.memsize"), Sysctl.memorySize)
        XCTAssertEqual(Sysctl.int("hw.ncpu"), ProcessInfo.processInfo.processorCount)
        XCTAssertLessThanOrEqual(Sysctl.physicalCPUCount, ProcessInfo.processInfo.processorCount)
        XCTAssertGreaterThan(Sysctl.performanceCores, 0)
        XCTAssertGreaterThanOrEqual(Sysctl.efficiencyCores, 0)
        XCTAssertEqual(
            Sysctl.performanceCores + Sysctl.efficiencyCores, Sysctl.physicalCPUCount,
            "hw.perflevel0 + hw.perflevel1 should equal hw.physicalcpu"
        )
        XCTAssertFalse(Sysctl.chipName?.isEmpty ?? true)
        XCTAssertFalse(Sysctl.modelIdentifier?.isEmpty ?? true)
        XCTAssertFalse(Sysctl.kernelVersion?.isEmpty ?? true)
        XCTAssertFalse(Sysctl.operatingSystemVersion.isEmpty)
        XCTAssertNil(Sysctl.string("ppxNoSuchKeyAtAll"))
        XCTAssertNil(Sysctl.uint64("ppxNoSuchKeyAtAll"))
        XCTAssertNil(Sysctl.int("ppxNoSuchKeyAtAll"))
    }

    func testLoadSampleIsWithinPhysicalBounds() async {
        let load = await HardwareProfiler.shared.loadSample()
        XCTAssertTrue(load.cpuLoadPercent >= 0 && load.cpuLoadPercent <= 100, "\(load.cpuLoadPercent)")
        XCTAssertGreaterThan(load.memoryUsed.bytes, 0)
        XCTAssertLessThanOrEqual(load.memoryUsed.bytes, Int64(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(load.activeProcessCount, 0)
        XCTAssertTrue(load.memoryPressure.isSafeToStartHeavyJob || load.memoryPressure == .critical)
        XCTAssertFalse(load.sampledAt.timeIntervalSinceNow < -120, "the sample must be fresh")
    }

    func testWorkerBudgetNeverExceedsCoresAndNeverZero() async {
        let profile = await HardwareProfiler.shared.profile()
        XCTAssertGreaterThanOrEqual(profile.renderWorkerBudget, 2)
        XCTAssertLessThanOrEqual(profile.renderWorkerBudget, max(2, profile.physicalCPUCount))
        XCTAssertGreaterThanOrEqual(profile.meshMemoryCeilingGB, 8)
        XCTAssertLessThan(profile.meshMemoryCeilingGB, max(9, profile.memoryGB))
    }

    func testShellResolutionIsHonest() {
        // A binary that certainly exists must resolve, an absolute path we ask for
        // must be taken verbatim, and a missing one must be reported as missing —
        // the whole installer's honesty rests on this.
        XCTAssertEqual(Shell.which("/bin/sh"), "/bin/sh")
        XCTAssertNotNil(Shell.which("sh"))
        XCTAssertNil(Shell.which("popopx-definitely-not-installed"))
        XCTAssertNil(Shell.which("/definitely/not/here"))
        XCTAssertTrue(Shell.isPresent("/bin/sh"))
        XCTAssertFalse(Shell.isPresent("/definitely/not/here"))
        XCTAssertTrue(Shell.searchPaths.allSatisfy { $0.hasPrefix("/") }, "\(Shell.searchPaths)")
        XCTAssertTrue(Shell.searchPaths.allSatisfy { !$0.contains("~") }, "PATH must not hold a tilde")
        XCTAssertTrue(Shell.searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(Shell.searchPaths.contains("/usr/local/bin"))
        XCTAssertTrue(Shell.augmentedEnvironment["PATH"]!.contains("/usr/bin"))
    }

    func testSubprocessRunsAndTimesOutWithoutBlockingTheCaller() async {
        let echo = await Shell.run("/bin/echo", ["popopx"])
        XCTAssertTrue(echo.succeeded)
        XCTAssertEqual(echo.firstLine, "popopx")
        XCTAssertEqual(echo.exitCode, 0)
        XCTAssertFalse(echo.timedOut)

        let sleepy = await Shell.run("/bin/sleep", ["5"], timeout: 0.2)
        XCTAssertTrue(sleepy.timedOut, "the watchdog must fire")
        XCTAssertFalse(sleepy.succeeded)

        let failing = await Shell.run("/usr/bin/false")
        XCTAssertFalse(failing.succeeded)
        XCTAssertNotEqual(failing.exitCode, 0)

        let absent = await Shell.run("popopx-definitely-not-installed")
        XCTAssertEqual(absent.exitCode, 127, "a missing binary is 127, never a silent success")
        XCTAssertFalse(absent.succeeded)
        XCTAssertTrue(absent.combinedOutput.contains("not found"), absent.combinedOutput)
    }

    func testSubprocessCannotReadWhatItIsNotGiven() async {
        // No shell is spawned, so metacharacters in an argument stay data. This is
        // the injection barrier for every path that arrives from the browser or
        // from a paired phone.
        let marker = "/tmp/ppx-injection-probe"
        try? FileManager.default.removeItem(atPath: marker)
        let echo = await Shell.run("/bin/echo", ["hi; touch \(marker)"])
        XCTAssertEqual(echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi; touch \(marker)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "a shell was spawned after all")

        let absolute = await Shell.runAbsolute(launchPath: "/bin/echo", ["via-absolute"])
        XCTAssertEqual(absolute.firstLine, "via-absolute")

        let piped = await Shell.run("/bin/cat", stdin: Data("piped".utf8))
        XCTAssertEqual(piped.stdout, "piped")

        let blocked = await Shell.runAbsolute(launchPath: "/definitely/not/here", [])
        XCTAssertEqual(blocked.exitCode, 127)
    }

    func testChildEnvironmentIsAugmentedNotWhitelistedAway() async {
        // The installer needs `PATH` entries a GUI process lacks; overrides must
        // still win. Asserting the real contract here, because `Process` inherits
        // nothing at all once `environment` is set.
        let probe = await Shell.run("/usr/bin/env", environment: ["PPX_PROBE": "1"])
        XCTAssertTrue(probe.stdout.contains("PPX_PROBE=1"), probe.stdout)
        guard let pathLine = probe.stdout.split(separator: "\n").first(where: { $0.hasPrefix("PATH=") }) else {
            return XCTFail("the child saw no PATH: \(probe.combinedOutput)")
        }
        XCTAssertTrue(pathLine.contains("/opt/homebrew/bin"), String(pathLine))
        XCTAssertTrue(pathLine.contains("/usr/local/bin"), String(pathLine))
    }

    // MARK: Helpers

    /// A date at `HH:mm` on a fixed calendar day, so window tests never depend on
    /// when the suite runs or what weekday today happens to be.
    private static func at(
        _ text: String, year: Int, month: Int, day: Int, calendar: Calendar
    ) -> Date? {
        let parts = text.split(separator: ":").map { Int($0) ?? 0 }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: parts[0], minute: parts[1], second: 0
        ))
    }
}

/// A structural read of one Markdown document: the counts a translated twin has to
/// match, plus the script census that proves each file stayed in its own language.
private struct ReadmeProbe {
    let text: String
    let lines: [String]

    init(url: URL) throws {
        text = try String(contentsOf: url, encoding: .utf8)
        lines = text.components(separatedBy: "\n")
    }

    var levelTwoCount: Int { lines.filter { $0.hasPrefix("## ") }.count }
    var levelThreeCount: Int { lines.filter { $0.hasPrefix("### ") }.count }
    var fenceCount: Int { stripped.filter { $0.hasPrefix("```") }.count / 2 }
    var tableRowCount: Int { stripped.filter { $0.hasPrefix("|") }.count }
    var dividerCount: Int { stripped.filter { $0 == "---" }.count }
    var badgeCount: Int { text.components(separatedBy: "img.shields.io").count - 1 }
    var throughputRows: Int { lines.filter { $0.contains("tok/s") }.count }
    var hanziLines: [String] { lines.filter { $0.unicodeScalars.contains(where: Self.isHanzi) } }
    var hanziCount: Int { text.unicodeScalars.filter(Self.isHanzi).count }

    /// The fenced `text` block holding the architecture diagram, verbatim.
    var diagram: String {
        guard let opened = text.range(of: "```text\n"),
              let closed = text.range(of: "\n```", range: opened.upperBound..<text.endIndex)
        else { return "" }
        return String(text[opened.upperBound..<closed.lowerBound])
    }

    var linkTargets: Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "\\]\\(([^)\\s]+)") else { return [] }
        let scan = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: Set<String> = []
        for match in regex.matches(in: text, range: scan) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            found.insert(String(text[range]))
        }
        return found
    }

    private var stripped: [String] { lines.map { $0.trimmingCharacters(in: .whitespaces) } }

    /// The CJK Unified Ideographs block only: box-drawing characters, arrows and the
    /// full-width punctuation of a Chinese document must not count as Han.
    private static func isHanzi(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
    }
}

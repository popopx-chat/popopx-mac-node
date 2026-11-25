//
//  ICalendarDocument.swift
//  PopopxMacNode — RFC 5545 payload builder for calendar proposals.
//
//  The `.ics` body is the only artifact this node hands to somebody outside the
//  Mac, so it is built here rather than by stringly-edited templates in a route:
//  the folding, the escaping and the timezone rules all have to be right in one
//  place, and each one is pinned by `PrivacyBridgeTests`.
//
//  Three rules drive the whole file:
//
//  * Every content line ends CRLF and is folded at 75 *octets*, not 75
//    characters — a Chinese summary is three bytes a glyph, and a client that
//    counted characters would cut a scalar in half.
//  * A `TZID` parameter is only legal when the same document defines that zone,
//    so `VTIMEZONE` is derived from the transitions the real `TimeZone` reports.
//    A zone whose switches are not yearly-regular gets the UTC form instead of
//    an invented rule.
//  * Nothing here is ever copied out of somebody else's calendar: every field is
//    text the owner (or the node on the owner's behalf) authored, which is what
//    keeps the redaction rule intact for an outbound file.
//

import Foundation

// MARK: - Value types

/// `METHOD:` — the transport meaning of the whole document.
public enum ICSMethod: String, Sendable {
    case publish = "PUBLISH"
    case request = "REQUEST"
    /// RFC 5545 §3.2.1 allows only PUBLISH | REQUEST | REPLY | ADD | CANCEL |
    /// REFRESH here. A cancelled booking therefore carries `METHOD:CANCEL` on the
    /// line and `STATUS:CANCELLED` inside the VEVENT; the two spellings differ and
    /// the pair is what a receiver such as Calendar.app expects to see.
    case cancel = "CANCEL"
    case refresh = "REFRESH"
}

/// `STATUS:` of one `VEVENT`.
public enum ICSEventStatus: String, Sendable {
    case confirmed = "CONFIRMED"
    case tentative = "TENTATIVE"
    case cancelled = "CANCELLED"
}

/// How date-times are written into the document.
public enum ICSDateTimeStyle: String, Codable, Sendable, CaseIterable {
    /// `DTSTART:20260115T010000Z` — always legal, needs no `VTIMEZONE`.
    case utc
    /// `DTSTART;TZID=Asia/Shanghai:20260115T090000` plus a `VTIMEZONE` block.
    case timeZoneId
}

/// One `VEVENT`.
public struct ICSEvent: Sendable, Equatable {
    public var uid: String
    public var sequence: Int
    public var status: ICSEventStatus
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var summary: String
    public var location: String?
    public var note: String?
    public var url: String?
    /// The node's own booking reference, carried as an `X-` property so a
    /// reschedule can be correlated after the event leaves the Mac.
    public var bookingReference: String?
    public var created: Date?
    public var lastModified: Date?

    public init(
        uid: String,
        sequence: Int = 0,
        status: ICSEventStatus = .confirmed,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        summary: String,
        location: String? = nil,
        note: String? = nil,
        url: String? = nil,
        bookingReference: String? = nil,
        created: Date? = nil,
        lastModified: Date? = nil
    ) {
        self.uid = uid
        self.sequence = sequence
        self.status = status
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.summary = summary
        self.location = location
        self.note = note
        self.url = url
        self.bookingReference = bookingReference
        self.created = created
        self.lastModified = lastModified
    }
}

// MARK: - Builder

public enum ICalendar {
    public static let crlf = "\r\n"
    public static let defaultProductIdentifier = "-//POPOPX Chat//Mac Node//EN"
    /// RFC 5545 §3.1: a content line is 75 octets, excluding the line break.
    public static let maximumLineOctets = 75

    /// `UTC` is not resolvable by identifier on every OS build, and a nil
    /// timezone would silently rewrite every stamp.
    public static let utcZone = TimeZone(secondsFromGMT: 0) ?? .autoupdatingCurrent

    // MARK: Text

    /// `TEXT` escaping (RFC 5545 §3.3.11). Backslash first, or an embedded
    /// newline would be re-escaped by the second pass.
    public static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": output += "\\\\"
            case ";": output += "\\;"
            case ",": output += "\\,"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Splits a property into a first line of at most 75 octets plus continuation
    /// lines led by one space, closing only between grapheme clusters.
    ///
    /// The leading space is part of the line, so a continuation carries 74
    /// octets of content and not 75.
    public static func fold(_ line: String) -> String {
        guard line.utf8.count > maximumLineOctets else { return line }
        var chunks: [String] = []
        var current = ""
        var octets = 0
        var budget = maximumLineOctets
        for character in line {
            let cost = String(character).utf8.count
            if octets + cost > budget {
                chunks.append(current)
                current = ""
                octets = 0
                budget = maximumLineOctets - 1
            }
            current.append(character)
            octets += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.enumerated()
            .map { $0.offset == 0 ? $0.element : " \($0.element)" }
            .joined(separator: crlf)
    }

    static func property(_ name: String, parameters: [String] = [], value: String) -> String {
        let head = name + parameters.map { ";\($0)" }.joined()
        return fold("\(head):\(value)")
    }

    // MARK: Stamps

    /// Basic format in UTC: `20260115T010000Z`.
    public static func utcStamp(_ date: Date) -> String {
        basic(DateComponentsIn(date, zone: utcZone)) + "Z"
    }

    /// Local wall time, no suffix: `20260115T090000`.
    public static func localStamp(_ date: Date, timeZone: TimeZone) -> String {
        basic(DateComponentsIn(date, zone: timeZone))
    }

    static func basic(_ parts: DateComponents) -> String {
        String(
            format: "%04d%02d%02dT%02d%02d%02d",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func DateComponentsIn(_ date: Date, zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// `TZOFFSETFROM`/`TZOFFSETTO` form: `+0800`, `-0500`, `+0530`.
    public static func offsetStamp(_ offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        let sign = total < 0 ? "-" : "+"
        let magnitude = abs(total)
        return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    // MARK: VTIMEZONE

    /// One `STANDARD` or `DAYLIGHT` block.
    public struct ObserverRule: Sendable, Equatable {
        public let kind: String                // "DAYLIGHT" | "STANDARD"
        public let offsetFrom: TimeInterval
        public let offsetTo: TimeInterval
        public let name: String
        public let anchor: DateComponents      // a real observed switch, in local wall time
        public let recurrence: String?         // "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"
    }

    /// Derives the recurring switch rules for `zone` by watching the transitions
    /// it reports around `date`.
    ///
    /// The rule is only emitted when every observed switch of that kind inside a
    /// two-year window lands on the same month, weekday ordinal and wall-clock
    /// time. That check is the whole point: an irregular zone returns nil and the
    /// caller writes the event in UTC rather than shipping a rule the zone does
    /// not obey. A zone with no transitions at all (Asia/Shanghai since 1991) gets
    /// one `STANDARD` block with no `RRULE`.
    public static func observerRules(for zone: TimeZone, around date: Date) -> [ObserverRule]? {
        let span = 400 * 86_400
        let observed = transitions(for: zone, from: date.addingTimeInterval(-Double(span)),
                                  to: date.addingTimeInterval(Double(span)))

        guard !observed.isEmpty else { return fixedOffsetRules(for: zone, around: date) }

        var grouped: [String: [(date: Date, from: Int, to: Int)]] = [:]
        for transition in observed {
            grouped[transition.to > transition.from ? "DAYLIGHT" : "STANDARD", default: []].append(transition)
        }
        // A zone that switches must show both directions inside the window; one
        // direction only means the window missed the pattern, so nothing is
        // asserted and the caller falls back to UTC.
        guard grouped.count == 2 else { return nil }

        var rules: [ObserverRule] = []
        for (kind, transitions) in grouped {
            guard let rule = regularRule(for: kind, transitions: transitions, zone: zone, nearest: date)
            else { return nil }
            rules.append(rule)
        }
        return rules.sorted { $0.anchor.month ?? 0 < $1.anchor.month ?? 0 }
    }

    /// Offset changes inside `[from, to]`, found by a coarse walk plus a binary
    /// search of the bracket that moved.
    ///
    /// `TimeZone` exposes no transition enumerator on this OS — only
    /// `nextDaylightSavingTimeTransition`, which is pinned to *now* and so cannot
    /// be asked about a past or future year. `secondsFromGMT(for:)` is the one
    /// query that works for any instant, so the search is built on it. The whole
    /// window costs a few thousand calls and one binary search per switch.
    public static func transitions(for zone: TimeZone,
                                   from: Date,
                                   to: Date,
                                   stride: TimeInterval = 4 * 3600) -> [(date: Date, from: Int, to: Int)] {
        guard to > from else { return [] }
        var found: [(date: Date, from: Int, to: Int)] = []
        var cursor = from
        var previous = zone.secondsFromGMT(for: cursor)
        while cursor < to {
            let next = min(cursor.addingTimeInterval(stride), to)
            let current = zone.secondsFromGMT(for: next)
            if current != previous {
                found.append((date: boundary(in: zone, low: cursor, high: next, from: previous),
                              from: previous,
                              to: current))
            }
            previous = current
            cursor = next
        }
        return found
    }

    /// The instant at which `zone` stops answering `offset`, to within a second.
    static func boundary(in zone: TimeZone, low: Date, high: Date, from offset: Int) -> Date {
        var lower = low
        var upper = high
        while upper.timeIntervalSince(lower) > 1 {
            let middle = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
            if zone.secondsFromGMT(for: middle) == offset {
                lower = middle
            } else {
                upper = middle
            }
        }
        return upper
    }

    /// The yearly appointment of a switch: month, which weekday of that month,
    /// and the wall-clock time. Hashable because a `Set` of them is what proves
    /// the rule repeats.
    struct WallSignature: Hashable {
        let month: Int
        let ordinal: Int
        let mark: String
        let time: String
        var recurrence: String { "FREQ=YEARLY;BYMONTH=\(month);BYDAY=\(ordinal)\(mark)" }
    }

    /// `nil` when the switches of one kind are not the same yearly appointment.
    static func regularRule(for kind: String,
                            transitions: [(date: Date, from: Int, to: Int)],
                            zone: TimeZone,
                            nearest date: Date) -> ObserverRule? {
        let fingerprints = Set(transitions.map { wallFingerprint($0.date, offset: TimeInterval($0.from)) })
        guard fingerprints.count == 1, let first = fingerprints.first else { return nil }
        guard let chosen = transitions.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else { return nil }
        let anchor = chosen.date
        // The block describes the period that *begins* at its DTSTART, so the
        // abbreviation is read just after the switch: `STANDARD` gets EST, not the
        // EDT that was in force before it.
        return ObserverRule(
            kind: kind,
            offsetFrom: TimeInterval(chosen.from),
            offsetTo: TimeInterval(chosen.to),
            name: name(for: zone, daylight: kind == "DAYLIGHT"),
            anchor: wallComponents(anchor, from: TimeInterval(chosen.from)),
            recurrence: first.recurrence
        )
    }

    /// `TZNAME` is a display label, and `abbreviation(for:)` answers `GMT-5` on
    /// this OS for zones whose short name is not in the legacy abbreviation
    /// table — so the CLDR short forms come first, and only a zone with no short
    /// name at all falls back.
    static func name(for zone: TimeZone, daylight: Bool) -> String {
        let locale = Locale(identifier: "en_US")
        let short = zone.localizedName(for: daylight ? .shortDaylightSaving : .shortStandard, locale: locale)
        if let short, !short.isEmpty { return short }
        let long = zone.localizedName(for: daylight ? .daylightSaving : .standard, locale: locale)
        if let long, !long.isEmpty { return long }
        return daylight ? "DAYLIGHT" : "STANDARD"
    }

    /// The switch's yearly appointment, in the offset that was in force *before*
    /// it — which is why a 02:00→03:00 jump is written as 02:00 in the examples of
    /// RFC 5545.
    static func wallFingerprint(_ transition: Date, offset: TimeInterval) -> WallSignature {
        let parts = wallComponents(transition, from: offset)
        let day = parts.day ?? 1
        var weekdayCalendar = Calendar(identifier: .gregorian)
        weekdayCalendar.timeZone = utcZone
        let weekday = weekdayCalendar.component(.weekday, from: Date.wallDate(parts))
        return WallSignature(
            month: parts.month ?? 1,
            ordinal: (day - 1) / 7 + 1,
            mark: weekdayMark(weekday),
            time: String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        )
    }

    static func wallComponents(_ transition: Date, from offset: TimeInterval) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: Int(offset)) ?? utcZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: transition)
    }

    static let weekdayMarks = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static func weekdayMark(_ weekday: Int) -> String {
        weekdayMarks[min(max(weekday - 1, 0), weekdayMarks.count - 1)]
    }

    static func fixedOffsetRules(for zone: TimeZone, around date: Date) -> [ObserverRule]? {
        let offset = TimeInterval(zone.secondsFromGMT(for: date))
        let parts = wallComponents(date, from: offset)
        return [ObserverRule(
            kind: "STANDARD",
            offsetFrom: offset,
            offsetTo: offset,
            name: name(for: zone, daylight: false),
            anchor: parts,
            recurrence: nil
        )]
    }

    static func timezoneLines(identifier: String, rules: [ObserverRule]) -> [String] {
        var lines = [property("BEGIN", value: "VTIMEZONE"), property("TZID", value: identifier)]
        for rule in rules {
            lines.append(property("BEGIN", value: rule.kind))
            lines.append(property("TZOFFSETFROM", value: offsetStamp(rule.offsetFrom)))
            lines.append(property("TZOFFSETTO", value: offsetStamp(rule.offsetTo)))
            lines.append(property("TZNAME", value: escape(rule.name)))
            lines.append(property("DTSTART", value: basic(rule.anchor)))
            if let recurrence = rule.recurrence {
                lines.append(property("RRULE", value: recurrence))
            }
            lines.append(property("END", value: rule.kind))
        }
        lines.append(property("END", value: "VTIMEZONE"))
        return lines
    }

    // MARK: Document

    /// Builds the whole `VCALENDAR`: folded lines, CRLF between them, CRLF last.
    public static func document(events: [ICSEvent],
                                method: ICSMethod = .publish,
                                productIdentifier: String = defaultProductIdentifier,
                                calendarName: String? = nil,
                                style: ICSDateTimeStyle = .timeZoneId,
                                now: Date = Date()) -> String {
        var lines: [String] = [
            property("BEGIN", value: "VCALENDAR"),
            property("VERSION", value: "2.0"),
            property("PRODID", value: escape(productIdentifier)),
            property("CALSCALE", value: "GREGORIAN"),
            property("METHOD", value: method.rawValue)
        ]
        if let calendarName, !calendarName.isEmpty {
            lines.append(property("X-WR-CALNAME", value: escape(calendarName)))
        }

        var definedZones = Set<String>()
        for event in events {
            // An identifier this OS cannot resolve is not a zone to define: the
            // event is written in UTC rather than under a `TZID` nobody knows.
            guard let zone = TimeZone(identifier: event.timeZoneIdentifier) else {
                lines.append(contentsOf: eventLines(event, zone: nil, now: now))
                continue
            }
            let rules = style == .timeZoneId ? observerRules(for: zone, around: event.start) : nil
            if let rules, !definedZones.contains(zone.identifier) {
                lines.append(contentsOf: timezoneLines(identifier: zone.identifier, rules: rules))
                definedZones.insert(zone.identifier)
            }
            lines.append(contentsOf: eventLines(event, zone: rules == nil ? nil : zone, now: now))
        }
        lines.append(property("END", value: "VCALENDAR"))
        return lines.joined(separator: crlf) + crlf
    }

    /// One `VEVENT`. `zone` is nil exactly when the date-times go out in UTC.
    static func eventLines(_ event: ICSEvent, zone: TimeZone?, now: Date) -> [String] {
        var lines = [property("BEGIN", value: "VEVENT"), property("UID", value: escape(event.uid))]
        lines.append(property("DTSTAMP", value: utcStamp(now)))
        if event.sequence > 0 {
            lines.append(property("SEQUENCE", value: String(event.sequence)))
        }
        if let created = event.created { lines.append(property("CREATED", value: utcStamp(created))) }
        if let modified = event.lastModified { lines.append(property("LAST-MODIFIED", value: utcStamp(modified))) }
        if let reference = event.bookingReference, !reference.isEmpty {
            lines.append(property("X-POPOPX-BOOKING-REF", value: escape(reference)))
        }

        if let zone {
            let id = zone.identifier
            lines.append(property("DTSTART", parameters: ["TZID=\(id)"], value: localStamp(event.start, timeZone: zone)))
            lines.append(property("DTEND", parameters: ["TZID=\(id)"], value: localStamp(event.end, timeZone: zone)))
        } else {
            lines.append(property("DTSTART", value: utcStamp(event.start)))
            lines.append(property("DTEND", value: utcStamp(event.end)))
        }

        lines.append(property("SUMMARY", value: escape(event.summary)))
        lines.append(property("STATUS", value: event.status.rawValue))
        lines.append(property("TRANSP", value: "OPAQUE"))
        if let location = event.location, !location.isEmpty {
            lines.append(property("LOCATION", value: escape(location)))
        }
        if let note = event.note, !note.isEmpty {
            lines.append(property("DESCRIPTION", value: escape(note)))
        }
        if let url = event.url, !url.isEmpty {
            lines.append(property("URL", value: escape(url)))
        }
        lines.append(property("END", value: "VEVENT"))
        return lines
    }
}

private extension Date {
    /// Rebuilds a plain calendar date from wall-clock components so that
    /// `Calendar.component(.weekday:)` reports the weekday of *that* date: the
    /// components already carry the offset of the moment they were read in, so
    /// reading them back in UTC keeps month, day and weekday aligned.
    static func wallDate(_ parts: DateComponents) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ICalendar.utcZone
        return calendar.date(from: parts) ?? Date()
    }
}

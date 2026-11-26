//
//  ICalendarFreeBusy.swift
//  PopopxMacNode — reading somebody else's calendar and keeping only the gaps.
//
//  The CalDAV bridge is the first place this node ingests a document it did not
//  write, so this file exists to hold one line: **`busy(in:)` is the only public read,
//  and what it returns has two `Date` fields per interval.**
//
//  That is the same argument the EventKit bridge makes about `fetchBusy` — see
//  `RedactedBusyInterval` — and here it matters more, because a CalDAV payload is full
//  of other people's text: `SUMMARY`, `ORGANIZER`, every `ATTENDEE` address,
//  `DESCRIPTION`, `LOCATION`. There is no redaction step to get wrong because there is
//  no redaction step: occurrences are parsed into a `private` struct that nothing
//  outside this file can name, and dropped at the end of one function. The tests prove
//  it by planting canary strings in every sensitive property.
//
//  Secondary rules, both of which cost real work:
//
//  * Stamps are interpreted in the zone the *document* declares. An unknown `TZID` is
//    floating wall time (RFC 5545 §3.3.5), so it is read in the probe's zone rather
//    than shifted into UTC — reading 09:00 as 09:00Z would move every block by eight
//    hours and the node would happily book on top of it.
//  * A recurrence this parser cannot evaluate is reported, not guessed. Under-reporting
//    busy time is the dangerous direction, so `approximated` tells the scheduler this
//    source is a floor rather than the truth.
//

import Foundation

// MARK: - Result

/// What the CalDAV bridge keeps from a `.ics` document. Every field is a count or a
/// pair of instants, so this type cannot be the reason a title leaked.
public struct ICalendarFreeBusy: Sendable, Equatable, Codable {
    public var busy: [RedactedBusyInterval]
    /// Occurrences that contributed a busy interval.
    public var eventCount: Int
    /// Events dropped as cancelled, transparent, or wholly outside the window.
    public var discardedCount: Int
    /// True when at least one recurrence was too unusual to expand.
    public var approximated: Bool
    /// True when a `DTSTART;TZID=` named a zone the document never defined — legal to
    /// receive, illegal to send, and always worth telling the owner about.
    public var unknownTimeZone: Bool

    public init(
        busy: [RedactedBusyInterval] = [],
        eventCount: Int = 0,
        discardedCount: Int = 0,
        approximated: Bool = false,
        unknownTimeZone: Bool = false
    ) {
        self.busy = busy
        self.eventCount = eventCount
        self.discardedCount = discardedCount
        self.approximated = approximated
        self.unknownTimeZone = unknownTimeZone
    }

    public static let empty = ICalendarFreeBusy()
}

// MARK: - Parser

public enum ICalendarParse {
    /// Occurrences expanded for one recurring event, per probe. A daily stand-up inside
    /// the legal 92-day window is at most 92, so the cap only ever bites on a rule that
    /// would otherwise spin the node on every console poll.
    public static let maximumOccurrences = 400

    public static let utcZone = TimeZone(secondsFromGMT: 0) ?? .autoupdatingCurrent

    // MARK: Lines

    /// Unfolds a document into content lines (§3.1): a line beginning with a space or a
    /// horizontal tab is the tail of the line before it, and the break is not there.
    ///
    /// Skipping this is how a long `DESCRIPTION` becomes two lines and a `DTEND` folded
    /// across the break becomes no end at all — the exact shape a real Nextcloud export
    /// produces.
    public static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.components(separatedBy: "\n") {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += String(raw.dropFirst())
                continue
            }
            if !raw.isEmpty { lines.append(raw) }
        }
        return lines
    }

    /// One `NAME;PARAM=value:VALUE` line. Parameter values may be quoted and may contain
    /// `:`, so the split point is the first colon outside a quoted string — an
    /// `ATTENDEE;CN="Ada: Team Lead"` would otherwise be cut in half.
    static func contentLine(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var head = ""
        var colon: String.Index?
        var quoted = false
        var cursor = line.startIndex
        while cursor < line.endIndex {
            let character = line[cursor]
            if character == "\"" { quoted.toggle() }
            if character == ":", !quoted { colon = cursor; break }
            head.append(character)
            cursor = line.index(after: cursor)
        }
        guard let split = colon, !head.isEmpty else { return nil }
        let value = String(line[line.index(after: split)...])
        let pieces = head.split(separator: ";", omittingEmptySubsequences: false)
        guard let property = pieces.first, !property.isEmpty else { return nil }
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<equals]).uppercased()
            var raw = String(piece[piece.index(after: equals)...])
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            params[key] = raw
        }
        return (String(property).uppercased(), params, value)
    }

    // MARK: Stamps

    /// `20260115T090000Z`, `20260115T090000`, `20260115`.
    ///
    /// Hand-parsed instead of `DateFormatter` because a formatter reads the user's
    /// locale defaults, and `ICalendar.basic` on the builder side writes these digits
    /// literally — the inverse has to be equally literal.
    ///
    /// Returns the instant and whether the stamp was *floating*. A floating stamp is
    /// stored as wall time in `zone` by design: that is what "the 9 o'clock stand-up"
    /// means once the scheduler subtracts it in the same zone.
    public static func dateTime(_ value: String, zone: TimeZone) -> (date: Date, floating: Bool)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let utc = text.hasSuffix("Z")
        let body = utc ? String(text.dropLast()) : text
        let dateOnly = body.count == 8
        guard dateOnly || body.count == 15 else { return nil }
        guard let year = Int(body.prefix(4)),
              let month = Int(body.dropFirst(4).prefix(2)),
              let day = Int(body.dropFirst(6).prefix(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0
        if !dateOnly {
            guard body.dropFirst(8).first == "T",
                  let candidate = Int(body.dropFirst(9).prefix(2)),
                  let candidateMinute = Int(body.dropFirst(11).prefix(2)),
                  let candidateSecond = Int(body.dropFirst(13).prefix(2)),
                  (0...23).contains(candidate), (0...59).contains(candidateMinute),
                  (0...60).contains(candidateSecond) else { return nil }
            hour = candidate
            minute = candidateMinute
            second = candidateSecond
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc ? utcZone : zone
        guard let date = calendar.date(from: components) else { return nil }
        return (date, !utc)
    }

    /// `P1D`, `PT1H30M`, `-PT15M`, `P1W` (§3.3.6).
    public static func duration(_ value: String) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard text.hasPrefix("P") || text.hasPrefix("-P") else { return nil }
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst(2)) : String(text.dropFirst(1))
        guard !body.isEmpty else { return nil }
        var total: TimeInterval = 0
        var dateSide = body
        var timeSide = ""
        if let split = body.firstIndex(of: "T") {
            dateSide = String(body[..<split])
            timeSide = String(body[body.index(after: split)...])
        }
        guard let date = units(dateSide, stops: ["Y": 31_557_600, "M": 2_592_000, "W": 604_800, "D": 86_400]),
              let time = units(timeSide, stops: ["H": 3600, "M": 60, "S": 1]) else { return nil }
        total = date + time
        return negative ? -total : total
    }

    /// Digit runs terminated by a unit letter. An empty side is a legal zero, so
    /// `PT1H` and `P1DT1H` both read.
    static func units(_ text: String, stops: [String: TimeInterval]) -> TimeInterval? {
        guard !text.isEmpty else { return 0 }
        var total: TimeInterval = 0
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard !digits.isEmpty, let value = Double(digits), let cost = stops[String(character)] else {
                return nil
            }
            total += value * cost
            digits = ""
        }
        guard digits.isEmpty else { return nil }
        return total
    }

    // MARK: Free/busy

    /// The only public read of a document: busy intervals inside `window`.
    ///
    /// `summary`, `description`, `location`, `organizer` and `attendee` are read into
    /// `ParsedEvent` — a type private to this file — and are gone when `append` returns.
    public static func busy(
        in text: String,
        window: DateInterval,
        defaultZone: TimeZone = .autoupdatingCurrent
    ) -> ICalendarFreeBusy {
        let lines = unfold(text).compactMap { contentLine($0) }
        var definedZones = Set<String>()
        for line in lines where line.name == "TZID" { definedZones.insert(line.value) }

        var result = ICalendarFreeBusy(unknownTimeZone: lines.contains {
            $0.name == "DTSTART" && $0.params["TZID"].map { !definedZones.contains($0) } == true
        })

        var event: ParsedEvent?
        var depth = 0
        for line in lines {
            switch line.name {
            case "BEGIN":
                let kind = line.value.uppercased()
                if kind == "VEVENT" || kind == "VFREEBUSY" {
                    event = ParsedEvent()
                    depth = 1
                } else if depth > 0 {
                    depth += 1   // a nested component inside one we are reading
                }
            case "END":
                let kind = line.value.uppercased()
                guard depth > 0 else { continue }
                depth -= 1
                guard depth == 0, var parsed = event,
                      kind == "VEVENT" || kind == "VFREEBUSY" else { continue }
                parsed.finish(defaultZone: defaultZone)
                append(parsed, into: &result, window: window, defaultZone: defaultZone)
                event = nil
            default:
                if depth == 1 { event?.absorb(line) }
            }
        }
        result.busy = merge(result.busy)
        return result
    }

    /// Folds one parsed event into the answer. Everything that could name a person or a
    /// meeting dies here, one call before the function's return value.
    fileprivate static func append(
        _ event: ParsedEvent,
        into result: inout ICalendarFreeBusy,
        window: DateInterval,
        defaultZone: TimeZone
    ) {
        guard event.status.uppercased() != "CANCELLED",
              event.transparency.uppercased() != "TRANSPARENT" else {
            result.discardedCount += 1
            return
        }

        // A `VFREEBUSY` carries its own intervals, which already are the answer.
        if !event.freeBusyRanges.isEmpty {
            let clipped = event.freeBusyRanges.filter { $0.end > window.start && $0.start < window.end }
            result.busy += clipped.map {
                RedactedBusyInterval(start: max($0.start, window.start), end: min($0.end, window.end))
            }
            result.eventCount += clipped.count
            result.discardedCount += event.freeBusyRanges.count - clipped.count
            return
        }

        guard let anchor = event.start else {
            // An event with no start cannot be placed, and dropping it quietly would
            // make the window look freer than it is.
            result.approximated = true
            result.discardedCount += 1
            return
        }
        guard let length = event.resolvedDuration, length >= 0 else {
            result.approximated = true
            result.discardedCount += 1
            return
        }

        let zone = event.zone ?? defaultZone
        let occurrences = event.expansions(start: anchor, length: length, zone: zone, window: window)
        if occurrences.approximated { result.approximated = true }
        guard !occurrences.dates.isEmpty else {
            result.discardedCount += 1
            return
        }
        for from in occurrences.dates {
            let to = from.addingTimeInterval(length)
            result.busy.append(RedactedBusyInterval(
                start: max(from, window.start),
                end: min(max(to, from), window.end)
            ))
            result.eventCount += 1
        }
    }

    /// Sorted, overlapping intervals merged. The scheduler subtracts this set from the
    /// working day, so overlapping pairs are not something it can survive twice.
    public static func merge(_ intervals: [RedactedBusyInterval]) -> [RedactedBusyInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [RedactedBusyInterval] = []
        var current = sorted[0]
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                current = RedactedBusyInterval(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}

// MARK: - The type that holds the sensitive text

/// One `VEVENT` as parsed, including the properties that must never be returned.
///
/// `private` to this file is the whole redaction guarantee: nothing outside it can name
/// a `summary`, so nothing outside it can put one in a response, an audit row or a log
/// line. The fields are still assigned, because a canary that is never read would make
/// the zero-leak test prove nothing.
private struct ParsedEvent {
    var summary = ""
    var location = ""
    var details = ""
    var organizer = ""
    var attendees: [String] = []
    var status = ""
    var transparency = ""
    var uid = ""

    var rawStart = ""
    var rawEnd = ""
    var rawDuration = ""
    var rawRecurrence = ""
    var exceptionDates: [String] = []
    var rawFreeBusy: [(text: String, type: String)] = []
    var timeZoneIdentifier = ""
    var isAllDay = false

    var start: Date?
    var end: Date?
    var zone: TimeZone?
    var freeBusyRanges: [DateInterval] = []

    mutating func absorb(_ line: (name: String, params: [String: String], value: String)) {
        switch line.name {
        case "SUMMARY": summary = line.value
        case "LOCATION": location = line.value
        case "DESCRIPTION": details = line.value
        case "ORGANIZER": organizer = line.value
        case "ATTENDEE": attendees.append(line.value)
        case "UID": uid = line.value
        case "STATUS": status = line.value
        case "TRANSP": transparency = line.value
        case "DTSTART":
            rawStart = line.value
            if line.params["VALUE"]?.uppercased() == "DATE" { isAllDay = true }
            if let tzid = line.params["TZID"] { timeZoneIdentifier = tzid }
        case "DTEND":
            rawEnd = line.value
            if line.params["VALUE"]?.uppercased() == "DATE" { isAllDay = true }
            if timeZoneIdentifier.isEmpty, let tzid = line.params["TZID"] { timeZoneIdentifier = tzid }
        case "DURATION": rawDuration = line.value
        case "RRULE": rawRecurrence = line.value
        case "EXDATE": exceptionDates.append(contentsOf: line.value.split(separator: ",").map(String.init))
        case "FREEBUSY": rawFreeBusy.append((line.value, line.params["FBTYPE"]?.uppercased() ?? "BUSY"))
        default: break
        }
    }

    mutating func finish(defaultZone: TimeZone) {
        let candidate = timeZoneIdentifier.isEmpty ? nil : TimeZone(identifier: timeZoneIdentifier)
        zone = candidate
        // An absent `TZID` and a `TZID` this document never defines are the same thing:
        // floating, and the caller's zone is what the owner means by "09:00". Resolving
        // against `.autoupdatingCurrent` here would re-date every block by the Mac's
        // system zone — the one zone `freeBusy(zone:)` was explicitly not asked to use.
        let effective = candidate ?? defaultZone
        start = ICalendarParse.dateTime(rawStart, zone: effective)?.date
        end = ICalendarParse.dateTime(rawEnd, zone: effective)?.date
        resolveFreeBusy(effective: effective)
    }

    /// `FREEBUSY:20260115T090000Z/20260115T100000Z` and the duration form
    /// `…/PT30M`, both of which a real free-busy report uses. A bare instant is a
    /// zero-length claim and is read as such.
    mutating func resolveFreeBusy(effective: TimeZone) {
        for entry in rawFreeBusy {
            guard entry.type == "BUSY" || entry.type == "BUSY-TENTATIVE" || entry.type == "BUSY-UNAVAILABLE" else {
                continue
            }
            let halves = entry.text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let first = halves.first,
                  let from = ICalendarParse.dateTime(first, zone: effective)?.date else { continue }
            let tail = halves.count > 1 ? halves[1] : ""
            if let to = ICalendarParse.dateTime(tail, zone: effective)?.date {
                freeBusyRanges.append(DateInterval(start: from, end: max(from, to)))
            } else if let length = ICalendarParse.duration(tail) {
                freeBusyRanges.append(DateInterval(start: from, end: from.addingTimeInterval(max(0, length))))
            } else if isAllDay {
                freeBusyRanges.append(DateInterval(start: from, end: from.addingTimeInterval(86_400)))
            }
        }
    }

    /// `DTEND`, else `DURATION`, else one day for an all-day event with neither.
    ///
    /// The exclusive-end convention (§3.6.1) matters: `DTSTART=15`/`DTEND=16` for
    /// all-day events means *one* day, not two, so an all-day end is pulled back by a
    /// day before it is subtracted.
    var resolvedDuration: TimeInterval? {
        if isAllDay, let start, let end, end > start {
            // The exclusive-end convention: a single all-day event runs 15th → 16th, so
            // the busy span is one day and not two.
            return max(86_400, end.timeIntervalSince(start) - 86_400)
        }
        if let start, let end, end >= start { return end.timeIntervalSince(start) }
        if let length = ICalendarParse.duration(rawDuration) { return max(0, length) }
        if isAllDay { return 86_400 }
        // A timed event with neither property is zero-length (§3.8.2.2): it still
        // occupies its start instant, which is the conservative reading.
        return rawEnd.isEmpty && rawDuration.isEmpty ? 0 : nil
    }

    /// The instants this event occupies inside `window`, recurrence expanded.
    func expansions(
        start anchor: Date,
        length: TimeInterval,
        zone: TimeZone,
        window: DateInterval
    ) -> (dates: [Date], approximated: Bool) {
        guard let rule = RecurrenceRule(parse: rawRecurrence) else {
            return (Self.within(window, [anchor], exceptions: exceptions(in: zone)), false)
        }
        guard rule.supported else { return (Self.within(window, [anchor], exceptions: exceptions(in: zone)), true) }

        var dates: [Date] = []
        var cursor = anchor
        var seen = 0
        while cursor <= window.end, dates.count < ICalendarParse.maximumOccurrences {
            if let until = rule.until, cursor > until { break }
            if rule.landsOn(candidate: cursor, anchor: anchor, zone: zone),
               cursor >= window.start {
                dates.append(cursor)
                seen += 1
                if let count = rule.count, seen >= count {
                    return (Self.within(window, dates, exceptions: exceptions(in: zone)), false)
                }
            }
            guard let next = rule.advance(from: cursor, zone: zone) else {
                return (Self.within(window, dates, exceptions: exceptions(in: zone)), true)
            }
            cursor = next
        }
        // Stepping stopped because the cap was hit, not because the window ended.
        let truncated = cursor <= window.end
        return (Self.within(window, dates, exceptions: exceptions(in: zone)), truncated)
    }

    func exceptions(in zone: TimeZone) -> Set<Date> {
        Set(exceptionDates.compactMap { ICalendarParse.dateTime($0, zone: zone)?.date })
    }

    static func within(_ window: DateInterval, _ dates: [Date], exceptions: Set<Date>) -> [Date] {
        dates.filter { date in
            date >= window.start && date < window.end && !exceptions.contains(where: {
                abs($0.timeIntervalSince(date)) < 1
            })
        }
    }
}

private extension ParsedEvent {
    /// The subset of `RRULE` this node expands: `FREQ` of DAILY/WEEKLY/MONTHLY/YEARLY,
    /// `INTERVAL`, `COUNT`, `UNTIL`, and `BYDAY` for weekly rules.
    ///
    /// Anything else sets `supported = false`, and the caller reports an approximation
    /// rather than inventing dates. Sub-daily frequencies are refused for the same
    /// reason: an hourly rule stepped a day at a time would silently drop busy blocks.
    struct RecurrenceRule {
        var frequency = ""
        var interval = 1
        var count: Int?
        var until: Date?
        var weekdays: [Int] = []
        var supported = true

        init?(parse text: String) {
            let body = text.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            for piece in body.split(separator: ";") {
                let halves = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard halves.count == 2 else { continue }
                let value = halves[1]
                switch halves[0].uppercased() {
                case "FREQ": frequency = value.uppercased()
                case "INTERVAL": interval = max(1, Int(value) ?? 1)
                case "COUNT": count = max(1, Int(value) ?? 1)
                case "UNTIL": until = ICalendarParse.dateTime(value, zone: ICalendarParse.utcZone)?.date
                case "BYDAY": weekdays = Self.weekdayNumbers(value)
                case "BYMONTH", "BYMONTHDAY": break
                default: supported = false
                }
            }
            guard !frequency.isEmpty else { return nil }
            switch frequency {
            case "DAILY", "WEEKLY", "MONTHLY", "YEARLY": break
            default: supported = false
            }
            if !weekdays.isEmpty, frequency != "WEEKLY" { supported = false }
        }

        /// `Calendar.component(.weekday)` numbers, 1 = Sunday: `MO,TU,+3WE` → [2, 3, 4].
        /// An ordinal (`+3WE`) is not the third Wednesday rule this parser claims to
        /// honour, so `BYDAY` with an ordinal marks the rule unsupported instead.
        static func weekdayNumbers(_ text: String) -> [Int] {
            let marks = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
            var values: [Int] = []
            for mark in text.split(separator: ",") {
                let token = mark.trimmingCharacters(in: .whitespaces).uppercased()
                guard token.count == 2, let value = marks[token] else { return [] }
                values.append(value)
            }
            return values
        }

        func landsOn(candidate: Date, anchor: Date, zone: TimeZone) -> Bool {
            guard !weekdays.isEmpty else { return true }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return weekdays.contains(calendar.component(.weekday, from: candidate))
        }

        func advance(from date: Date, zone: TimeZone) -> Date? {
            guard supported else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let step: Calendar.Component
            switch frequency {
            case "DAILY": step = .day
            case "WEEKLY": step = .weekOfYear
            case "MONTHLY": step = .month
            case "YEARLY": step = .year
            default: return nil
            }
            return calendar.date(byAdding: step, value: interval, to: date)
        }
    }
}

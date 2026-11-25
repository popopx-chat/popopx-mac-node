import Foundation
import EventKit

// MARK: - Redacted calendar gateway
//
// The availability half of the privacy calendar bridge. The rule this file exists
// to enforce is that no original calendar text can leave it.

/// A busy period and nothing else.
///
/// The redaction guarantee is structural rather than a filter. There is no code
/// path that strips a `title` from a response, because the gateway converts every
/// `EKEvent` into a `RedactedBusyInterval` inside one function (`fetchBusy`), so
/// summary, location, notes and attendees die there and cannot reach a response
/// builder, an audit row, a log line or the snapshot. A test asserts the
/// serialised response carries no text-valued key at all.
public struct RedactedBusyInterval: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }
}

/// One bookable gap. Deliberately two fields, matching the response contract
/// `freeSlots: [{ start, end }]`.
public struct FreeSlot: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

/// Everything the availability calculator needs. Hours are wall-clock hours in
/// `timeZoneIdentifier`, which is what "lunch" and "working hours" mean to a human.
public struct CalendarProbe: Sendable, Equatable {
    /// The day loop below walks the window, so a typo'd two-year probe should cost
    /// a refusal rather than a spin.
    public static let maximumWindowDays = 92
    public static let maximumSlots = 64

    public var start: Date
    public var end: Date
    public var durationMinutes: Int
    public var timeZoneIdentifier: String
    public var workingStartHour: Int
    public var workingEndHour: Int
    /// ISO weekday numbers, 1 = Monday … 7 = Sunday.
    public var workdays: [Int]
    public var blockLunch: Bool
    public var lunchStartHour: Int
    public var lunchEndHour: Int
    public var bufferMinutes: Int

    public init(
        start: Date,
        end: Date,
        durationMinutes: Int = 30,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        workingStartHour: Int = 9,
        workingEndHour: Int = 18,
        workdays: [Int] = [1, 2, 3, 4, 5],
        blockLunch: Bool = false,
        lunchStartHour: Int = 12,
        lunchEndHour: Int = 13,
        bufferMinutes: Int = 0
    ) {
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.workingStartHour = workingStartHour
        self.workingEndHour = workingEndHour
        self.workdays = workdays
        self.blockLunch = blockLunch
        self.lunchStartHour = lunchStartHour
        self.lunchEndHour = lunchEndHour
        self.bufferMinutes = bufferMinutes
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    /// `nil` when the probe is usable, otherwise the reason it is not. Bad input is
    /// refused rather than clamped: an assistant that asked for a 3-hour meeting in
    /// a 1-hour window should find out instead of receiving an empty slot list.
    public func validated() -> String? {
        guard end > start else { return "endIso must be after startIso" }
        guard end.timeIntervalSince(start) <= Double(Self.maximumWindowDays) * 86_400 else {
            return "search window exceeds \(Self.maximumWindowDays) days"
        }
        guard (5...1_440).contains(durationMinutes) else { return "durationMinutes must be 5…1440" }
        guard (0...23).contains(workingStartHour) else { return "workingStartHour must be 0…23" }
        guard (1...24).contains(workingEndHour), workingEndHour > workingStartHour else {
            return "workingEndHour must be after workingStartHour"
        }
        guard !workdays.isEmpty else { return "workdays must name at least one day" }
        guard Set(workdays).isSubset(of: Set(1...7)) else { return "workdays must be ISO 1…7 (Mon…Sun)" }
        if blockLunch {
            guard (0...23).contains(lunchStartHour), (1...24).contains(lunchEndHour),
                  lunchEndHour > lunchStartHour else { return "lunch window is invalid" }
        }
        guard (0...240).contains(bufferMinutes) else { return "bufferMinutes must be 0…240" }
        return nil
    }
}

/// Why a probe was answered with nothing.
public enum AvailabilityRefusal: String, Sendable, Codable {
    case bridgeDisabled
    case notAuthorized
    case deniedBySystem
    case storeUnavailable
}

public struct AvailabilityOutcome: Sendable, Equatable {
    public var freeSlots: [FreeSlot]
    /// Counts only — the times behind them stay inside the gateway.
    public var busyCount: Int
    public var busyMinutes: Int
    public var refusal: AvailabilityRefusal?
    public var probeRefused: String?

    public init(
        freeSlots: [FreeSlot] = [],
        busyCount: Int = 0,
        busyMinutes: Int = 0,
        refusal: AvailabilityRefusal? = nil,
        probeRefused: String? = nil
    ) {
        self.freeSlots = freeSlots
        self.busyCount = busyCount
        self.busyMinutes = busyMinutes
        self.refusal = refusal
        self.probeRefused = probeRefused
    }

    public var ok: Bool { refusal == nil && probeRefused == nil }

    public static func refused(_ refusal: AvailabilityRefusal) -> AvailabilityOutcome {
        AvailabilityOutcome(refusal: refusal)
    }
}

/// The event text the node is about to write. Every string here was authored by
/// POPOPX — the assistant's proposal, or this node's own call link — which is what
/// makes it lawful to echo back to a phone. The bridge never quotes the owner's
/// existing events.
public struct CalendarEventDraft: Sendable, Equatable {
    public var summary: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var location: String
    public var notes: String
    public var url: String?

    public init(
        summary: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        location: String = "",
        notes: String = "",
        url: String? = nil
    ) {
        self.summary = summary
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.url = url
    }
}

public enum CalendarCommitOutcome: Sendable, Equatable {
    case committed(identifier: String)
    case refused(String)

    public var identifier: String? {
        if case .committed(let value) = self { return value }
        return nil
    }

    public var refusal: String? {
        if case .refused(let value) = self { return value }
        return nil
    }

    public var ok: Bool { identifier != nil }
}

/// The calendar capabilities the proposal engine needs.
///
/// A protocol rather than a class because the state-machine tests must be able to
/// assert the zero-write-before-approval rule: the fake records every call it
/// receives, and a test fails if a commit was recorded before an approval — a
/// promise that cannot be checked against a real `EKEventStore` in a test host,
/// because a test that needs a TCC dialog is a test that silently skips.
public protocol CalendarGateway: Sendable {
    /// `notDetermined` / `fullAccess` / `writeAccess` / `denied` / `restricted`.
    func authorizationState() async -> String
    /// Raises the TCC prompt. Returns the resulting state.
    func requestFullAccess() async -> String
    func availability(_ probe: CalendarProbe) async -> AvailabilityOutcome
    func commit(_ draft: CalendarEventDraft) async -> CalendarCommitOutcome
    func reschedule(identifier: String, start: Date, end: Date) async -> CalendarCommitOutcome
    func remove(identifier: String) async -> CalendarCommitOutcome
    /// Whether a ledgered booking is still present in the system calendar.
    func exists(identifier: String) async -> Bool
}

// MARK: - EventKit implementation

/// The only type in the package that touches EventKit.
///
/// `@unchecked Sendable` is honest here: `EKEventStore` is not `Sendable`, so every
/// call is funnelled through one serial queue. Two callers at once is the normal
/// case — the console polls availability while a phone proposal is committed — and
/// EventKit does not support sharing a store across threads concurrently.
public final class EventKitCalendarGateway: CalendarGateway, @unchecked Sendable {
    private let store: EKEventStore
    private let queue = DispatchQueue(label: "im.popopx.node.eventkit", qos: .utility)

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    private func lane<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    public func authorizationState() async -> String {
        await lane { Self.describe(EKEventStore.authorizationStatus(for: .event)) }
    }

    public func requestFullAccess() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            // EventKit answers on a queue of its own; the value read back is the
            // status *after* the answer, so a denial that arrived while the dialog
            // was open is still reported truthfully.
            store.requestFullAccessToEvents { _, _ in
                continuation.resume(returning: Self.describe(EKEventStore.authorizationStatus(for: .event)))
            }
        }
    }

    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return PrivacyAuthorization.fullAccess
        case .writeOnly: return PrivacyAuthorization.writeOnly
        case .denied: return PrivacyAuthorization.denied
        case .restricted: return PrivacyAuthorization.restricted
        case .notDetermined: return PrivacyAuthorization.notDetermined
        @unknown default: return PrivacyAuthorization.notDetermined
        }
    }

    public func availability(_ probe: CalendarProbe) async -> AvailabilityOutcome {
        if let reason = probe.validated() {
            return AvailabilityOutcome(probeRefused: reason)
        }
        let outcome: AvailabilityOutcome = await lane {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: break
            case .denied, .restricted: return AvailabilityOutcome(refusal: .deniedBySystem)
            default: return AvailabilityOutcome(refusal: .notAuthorized)
            }
            let busy = Self.fetchBusy(in: self.store, probe: probe)
            return AvailabilityOutcome(
                freeSlots: AvailabilityEngine.freeSlots(probe: probe, busy: busy),
                busyCount: busy.count,
                busyMinutes: busy.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
            )
        }
        return outcome
    }

    /// Reads events and returns intervals. This function is the redaction boundary;
    /// see `RedactedBusyInterval`.
    static func fetchBusy(in store: EKEventStore, probe: CalendarProbe) -> [RedactedBusyInterval] {
        let predicate = store.predicateForEvents(withStart: probe.start, end: probe.end, calendars: nil)
        var intervals: [RedactedBusyInterval] = []
        for event in store.events(matching: predicate) {
            // A cancelled row still occupies a row in some stores; it must not
            // block a slot.
            // Explicit type: `.canceled` alone is ambiguous with
            // `AsyncStream.Continuation.Termination` in this scope, and EventKit
            // spells its case with one "l" (RFC 5545 uses `CANCELLED`, which is a
            // different string in a different file).
            if event.status == EKEventStatus.canceled { continue }
            if event.isAllDay {
                // EventKit reports an all-day event in local day boundaries, which
                // is exactly the block the owner means, and still leaks no text.
                let start = max(event.startDate, probe.start)
                let end = min(event.endDate, probe.end)
                if end > start { intervals.append(RedactedBusyInterval(start: start, end: end)) }
                continue
            }
            guard event.endDate > event.startDate else { continue }
            intervals.append(RedactedBusyInterval(start: event.startDate, end: event.endDate))
        }
        return intervals
    }

    public func commit(_ draft: CalendarEventDraft) async -> CalendarCommitOutcome {
        await lane {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return .refused("日历访问未授权 / calendar access not granted")
            }
            guard let calendar = self.defaultCalendar() else {
                return .refused("本机没有可写入的日历 / no writable calendar on this Mac")
            }
            let event = EKEvent()
            event.calendar = calendar
            event.title = draft.summary
            event.startDate = draft.start
            event.endDate = max(draft.start, draft.end)
            event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .autoupdatingCurrent
            if !draft.location.isEmpty { event.location = draft.location }
            if !draft.notes.isEmpty { event.notes = draft.notes }
            if let text = draft.url, let url = URL(string: text) { event.url = url }
            do {
                try self.store.save(event, span: .thisEvent)
                return .committed(identifier: event.eventIdentifier)
            } catch {
                return .refused("写入系统日历失败 / EventKit save failed: \(AppPaths.anonymise(error.localizedDescription))")
            }
        }
    }

    public func reschedule(identifier: String, start: Date, end: Date) async -> CalendarCommitOutcome {
        await lane {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return .refused("日历访问未授权 / calendar access not granted")
            }
            guard let event = self.store.event(withIdentifier: identifier) else {
                return .refused("该预订已不在系统日历中 / booking is no longer in the calendar")
            }
            // `allowsContentModifications` is the macOS flag; subscribed and
            // read-only calendars refuse a save with a far less readable error.
            guard event.calendar?.allowsContentModifications ?? false else {
                return .refused("该日历不可写 / the booking's calendar is read-only")
            }
            event.startDate = start
            event.endDate = max(start, end)
            do {
                try self.store.save(event, span: .thisEvent)
                return .committed(identifier: event.eventIdentifier)
            } catch {
                return .refused("改期写入失败 / EventKit update failed: \(AppPaths.anonymise(error.localizedDescription))")
            }
        }
    }

    public func remove(identifier: String) async -> CalendarCommitOutcome {
        await lane {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return .refused("日历访问未授权 / calendar access not granted")
            }
            guard let event = self.store.event(withIdentifier: identifier) else {
                return .refused("该预订已不在系统日历中 / booking is no longer in the calendar")
            }
            guard event.calendar?.allowsContentModifications ?? false else {
                return .refused("该日历不可写 / the booking's calendar is read-only")
            }
            do {
                try self.store.remove(event, span: .thisEvent)
                return .committed(identifier: identifier)
            } catch {
                return .refused("删除失败 / EventKit remove failed: \(AppPaths.anonymise(error.localizedDescription))")
            }
        }
    }

    public func exists(identifier: String) async -> Bool {
        await lane { self.store.event(withIdentifier: identifier) != nil }
    }

    /// A calendar the node may write into: the system default when it accepts
    /// content, otherwise the first writable one the owner has.
    private func defaultCalendar() -> EKCalendar? {
        if let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications {
            return calendar
        }
        return store.calendars(for: .event).first { $0.allowsContentModifications }
    }
}

// MARK: - Availability calculator

/// Pure availability maths, so the interesting half of the feature is testable
/// without a calendar, a permission dialog, or a wall clock.
public enum AvailabilityEngine {
    public static func freeSlots(probe: CalendarProbe, busy: [RedactedBusyInterval]) -> [FreeSlot] {
        let calendar = dayCalendar(for: probe)
        let blocked = padded(busy: busy, bufferMinutes: probe.bufferMinutes)
        let minimum = TimeInterval(probe.durationMinutes * 60)
        var slots: [FreeSlot] = []

        var day = calendar.startOfDay(for: probe.start)
        var steps = 0
        while day <= probe.end, steps <= CalendarProbe.maximumWindowDays + 1 {
            steps += 1
            if probe.workdays.contains(isoWeekday(of: day, calendar: calendar)) {
                for window in openWindows(on: day, probe: probe, calendar: calendar) {
                    for run in subtract(from: window, blocked: blocked) {
                        guard run.end.timeIntervalSince(run.start) >= minimum else { continue }
                        slots.append(FreeSlot(start: run.start, end: run.end))
                        if slots.count >= CalendarProbe.maximumSlots { return slots }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return slots
    }

    static func dayCalendar(for probe: CalendarProbe) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = probe.timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    /// `weekday` follows `firstWeekday`; ISO never does, and the settings store
    /// holds ISO numbers, so the conversion is explicit rather than inherited.
    static func isoWeekday(of date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    static func padded(busy: [RedactedBusyInterval], bufferMinutes: Int) -> [RedactedBusyInterval] {
        guard bufferMinutes > 0 else { return merge(busy) }
        let buffer = TimeInterval(bufferMinutes * 60)
        return merge(busy.map { RedactedBusyInterval(start: $0.start - buffer, end: $0.end + buffer) })
    }

    /// The bookable stretches of one local day: working hours, minus lunch, clipped
    /// to the probe window.
    static func openWindows(on day: Date, probe: CalendarProbe, calendar: Calendar) -> [DateInterval] {
        guard let openStart = hour(for: day, hour: probe.workingStartHour, calendar: calendar),
              let openEnd = hour(for: day, hour: probe.workingEndHour, calendar: calendar),
              let window = clipped(DateInterval(start: openStart, end: openEnd), probe: probe)
        else { return [] }
        guard probe.blockLunch,
              let lunchStart = hour(for: day, hour: probe.lunchStartHour, calendar: calendar),
              let lunchEnd = hour(for: day, hour: probe.lunchEndHour, calendar: calendar)
        else { return [window] }
        return subtract(
            from: window,
            blocked: [RedactedBusyInterval(start: lunchStart, end: lunchEnd)]
        ).filter { $0.duration > 0 }
    }

    /// A wall-clock hour on `day`. `24` means midnight tomorrow, which is how a
    /// working end of 18:00 stays expressible as `workingEndHour = 18` and how a
    /// caller can say "until midnight".
    static func hour(for day: Date, hour: Int, calendar: Calendar) -> Date? {
        if hour >= 24 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            var components = calendar.dateComponents([.year, .month, .day], from: next)
            components.hour = 0
            return calendar.date(from: components)
        }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = min(max(hour, 0), 23)
        return calendar.date(from: components)
    }

    static func clipped(_ interval: DateInterval, probe: CalendarProbe) -> DateInterval? {
        let start = max(interval.start, probe.start)
        let end = min(interval.end, probe.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func merge(_ intervals: [RedactedBusyInterval]) -> [RedactedBusyInterval] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [RedactedBusyInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = RedactedBusyInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// `window` minus `blocked`, leaving runs in chronological order.
    static func subtract(from window: DateInterval, blocked: [RedactedBusyInterval]) -> [DateInterval] {
        var runs = [window]
        for block in blocked where block.end > block.start {
            var next: [DateInterval] = []
            for run in runs {
                guard block.start < run.end, block.end > run.start else {
                    next.append(run)
                    continue
                }
                if block.start > run.start {
                    next.append(DateInterval(start: run.start, end: min(block.start, run.end)))
                }
                if block.end < run.end {
                    next.append(DateInterval(start: max(block.end, run.start), end: run.end))
                }
            }
            runs = next
        }
        return runs.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
    }
}

//
//  CalDavBridge.swift
//  PopopxMacNode — remote calendars as busy windows, nothing else.
//
//  The guarantee this file exists to hold is the one the privacy design already states for
//  EventKit: the node may learn *when the owner is busy* and must not learn what the event is.
//  A `REPORT calendar-query` reply carries the whole `VEVENT` — `SUMMARY`, `DESCRIPTION`,
//  `LOCATION`, `ATTENDEE` — so those properties are read by `ICalendarParse` into a `private`
//  type and go out of scope inside that function. What crosses this boundary is
//  `ICalendarFreeBusy`: intervals and counts. There is no field anywhere in here that could
//  hold a title even if a later edit wanted one.
//
//  The second reason this is a separate bridge rather than another `CalendarGateway`: the
//  owner's Nextcloud or Radicale is somebody else's machine, so it goes through the same
//  address allow-list as the smart-home side (`CalDavServerConfig.acceptance`) and its token
//  lives in the Keychain, never in `settings.json`.
//

import Foundation

/// One configured server, as the console card shows it.
public struct CalDavServerCard: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    /// Host and port only. The path is a collection root and is not repeated onto a card.
    public var host: String
    public var enabled: Bool
    public var credentialStored: Bool
    /// Whether the last attempt reached the server at all, as opposed to being refused before
    /// a socket was opened.
    public var reachable: Bool
    public var calendarCount: Int
    public var eventCount: Int
    public var busyCount: Int
    /// At least one recurrence or block this parser could not fully evaluate. Reported because
    /// a free/busy answer that is a floor must not be presented as the truth.
    public var approximated: Bool
    public var reason: String
    public var lastProbed: String

    public init(
        id: String,
        label: String = "",
        host: String = "",
        enabled: Bool = false,
        credentialStored: Bool = false,
        reachable: Bool = false,
        calendarCount: Int = 0,
        eventCount: Int = 0,
        busyCount: Int = 0,
        approximated: Bool = false,
        reason: String = "",
        lastProbed: String = ""
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.enabled = enabled
        self.credentialStored = credentialStored
        self.reachable = reachable
        self.calendarCount = calendarCount
        self.eventCount = eventCount
        self.busyCount = busyCount
        self.approximated = approximated
        self.reason = reason
        self.lastProbed = lastProbed
    }
}

/// What one read across every admissible server produced.
public struct CalDavReading: Sendable, Equatable {
    public var freeBusy: ICalendarFreeBusy
    public var cards: [CalDavServerCard]
    public var serversAsked: Int

    public init(
        freeBusy: ICalendarFreeBusy = .empty,
        cards: [CalDavServerCard] = [],
        serversAsked: Int = 0
    ) {
        self.freeBusy = freeBusy
        self.cards = cards
        self.serversAsked = serversAsked
    }
}

public actor CalDavBridge {
    /// Collections asked per server. A owner with forty calendars gets the first few merged and
    /// a card that says so — silently merging all forty would take a minute per availability
    /// probe and read as a hang.
    public static let maximumCollectionsPerServer = 4
    public static let minimumSlotMinutes = 15

    private var config: HubConfig
    private let secrets: HubSecretStoring
    private var cards: [CalDavServerCard] = []

    public init(config: HubConfig = .disabled, secrets: HubSecretStoring = VolatileSecretStore()) {
        self.config = config.normalised
        self.secrets = secrets
    }

    public func update(config: HubConfig) {
        let next = config.normalised
        self.config = next
        // A server that was removed, disabled or no longer admissible stops having a row. The
        // card list is a view of the config, not a history.
        let known = Set(next.calDav.servers.map { $0.id })
        cards.removeAll { !known.contains($0.id) }
        if !next.allowCalDavBridge { cards.removeAll() }
    }

    public func serverCards() -> [CalDavServerCard] { cards }

    /// The Keychain reference for one server, so the settings document can hold a name instead
    /// of a password.
    public func credentialReference(for serverID: String) -> String {
        HubSecrets.reference("caldav", serverID)
    }

    /// Stores a password for one configured server and returns the reference to put in the
    /// document. Refuses a server this node would never contact, so a token cannot be filed
    /// against a host that turns out to be public.
    public func storePassword(_ password: String, for serverID: String) -> HubSecretOutcome {
        let wanted = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = config.calDav.servers.first(where: { $0.id == wanted }) else {
            return .refused(reason: "该服务器尚未在设置中登记 / that server is not in the settings document yet")
        }
        guard server.acceptance == nil else {
            return .refused(reason: "该服务器地址不可达或被边界规则拒绝 / that server's address is refused by the boundary rule")
        }
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else {
            return .refused(reason: "口令为空或过长 / the password is empty or too long")
        }
        let reference = credentialReference(for: serverID)
        return secrets.store(trimmed, for: reference)
            ? .stored(reference: reference)
            : .refused(reason: "钥匙串写入失败 / the credential store refused")
    }

    // MARK: - Reading

    /// Free/busy for one window, merged across every admissible server.
    ///
    /// A server that cannot be reached contributes nothing rather than an empty answer: an
    /// outage must not turn a busy afternoon into open space. The caller reads `approximated`
    /// for the softer version of the same rule, and the card carries the reason.
    public func read(window: DateInterval, zone: TimeZone) async -> CalDavReading {
        guard config.allowCalDavBridge else {
            cards = []
            return CalDavReading()
        }
        let servers = config.calDav.normalised.usableServers
        var merged: [RedactedBusyInterval] = []
        var totals = ICalendarFreeBusy()
        var rows: [CalDavServerCard] = []
        var asked = 0

        for server in servers {
            let reference = credentialReference(for: server.id)
            let password = secrets.secret(for: reference) ?? ""
            let host = server.endpoint.map { "\($0.host):\($0.port)" } ?? ""
            guard server.acceptance == nil else {
                rows.append(CalDavServerCard(id: server.id, label: server.displayName, host: host, enabled: false, reason: server.acceptance ?? ""))
                continue
            }
            guard !password.isEmpty else {
                rows.append(CalDavServerCard(
                    id: server.id, label: server.displayName, host: host, enabled: true,
                    reason: "钥匙串中没有该服务器的口令 / no credential stored for this server"
                ))
                continue
            }
            asked += 1
            do {
                let client = try CalDavClient(config: server, password: password)
                defer { client.close() }
                let paths: [String]
                let calendarCount: Int
                if !server.calendarPath.isEmpty {
                    paths = [server.calendarPath]
                    calendarCount = 1
                } else {
                    let found = try await client.discoverCalendars(window: window)
                    paths = found.prefix(Self.maximumCollectionsPerServer).map { $0.path }
                    calendarCount = found.count
                }
                var part = ICalendarFreeBusy()
                var intervals: [RedactedBusyInterval] = []
                for path in paths {
                    let piece = try await client.freeBusy(calendarPath: path, window: window, zone: zone)
                    intervals.append(contentsOf: piece.busy)
                    part.eventCount += piece.eventCount
                    part.discardedCount += piece.discardedCount
                    part.approximated = part.approximated || piece.approximated
                    part.unknownTimeZone = part.unknownTimeZone || piece.unknownTimeZone
                }
                part.busy = ICalendarParse.merge(intervals)
                merged.append(contentsOf: part.busy)
                totals.eventCount += part.eventCount
                totals.discardedCount += part.discardedCount
                totals.approximated = totals.approximated || part.approximated || calendarCount > paths.count
                totals.unknownTimeZone = totals.unknownTimeZone || part.unknownTimeZone
                rows.append(CalDavServerCard(
                    id: server.id,
                    label: server.displayName,
                    host: host,
                    enabled: true,
                    credentialStored: true,
                    reachable: true,
                    calendarCount: calendarCount,
                    eventCount: part.eventCount,
                    busyCount: part.busy.count,
                    approximated: part.approximated || calendarCount > paths.count,
                    reason: calendarCount > paths.count
                        ? "仅合并了前 \(paths.count) 个日历（共 \(calendarCount) 个）/ only the first \(paths.count) of \(calendarCount) collections were merged"
                        : ""
                ))
            } catch {
                rows.append(CalDavServerCard(
                    id: server.id, label: server.displayName, host: host, enabled: true,
                    credentialStored: true, reason: String(describing: error)
                ))
            }
        }

        totals.busy = ICalendarParse.merge(merged)
        let stamped = rows.map { row -> CalDavServerCard in
            var copy = row
            copy.lastProbed = PrivacyStamp.iso(Date())
            return copy
        }
        cards = stamped
        return CalDavReading(freeBusy: totals, cards: stamped, serversAsked: asked)
    }

    /// The intervals alone, for the availability merge.
    public func busyIntervals(window: DateInterval, zone: TimeZone) async -> [RedactedBusyInterval] {
        await read(window: window, zone: zone).freeBusy.busy
    }

    /// Cuts remote busy windows out of locally-free ones.
    ///
    /// The merge happens on the *free* side because the gateway's own busy intervals never
    /// leave the calendar layer — that is the EventKit guarantee, and a CalDAV addition must not
    /// become the reason it leaks. A slot shorter than `minimumSlotMinutes` after cutting is
    /// dropped rather than offered: a four-minute gap is not a meeting, and the node must not
    /// propose one the owner cannot keep.
    public static func subtract(
        busy: [RedactedBusyInterval],
        from slots: [FreeSlot],
        minimumMinutes: Int = CalDavBridge.minimumSlotMinutes
    ) -> [FreeSlot] {
        guard !busy.isEmpty, minimumMinutes >= 0 else { return slots }
        let cut = ICalendarParse.merge(busy)
        var result: [FreeSlot] = []
        for slot in slots {
            var cursor = slot.start
            var pieces: [FreeSlot] = []
            for block in cut {
                guard block.end > cursor, block.start < slot.end else { continue }
                if block.start > cursor { pieces.append(FreeSlot(start: cursor, end: block.start)) }
                cursor = max(cursor, block.end)
                if cursor >= slot.end { break }
            }
            if cursor < slot.end { pieces.append(FreeSlot(start: cursor, end: slot.end)) }
            result.append(contentsOf: pieces.filter { $0.minutes >= minimumMinutes })
        }
        return result
    }

    /// Minutes the remote calendars claim inside `window`, for the response's busy accounting.
    public static func busyMinutes(_ intervals: [RedactedBusyInterval]) -> Int {
        ICalendarParse.merge(intervals).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
    }
}

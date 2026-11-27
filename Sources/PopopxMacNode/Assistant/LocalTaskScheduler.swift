//
//  LocalTaskScheduler.swift
//  PopopxMacNode — the assistant's clock.
//
//  The scheduler owns exactly two recurring jobs, both off by default:
//
//  * a **daily briefing** at an owner-set local time (08:00 by default), and
//  * a **home health patrol** every N minutes.
//
//  It does not know what a briefing contains. The manager supplies two async
//  handlers; the scheduler only decides *when* and records *that it happened*.
//  Every due check, skipped tick, start and completion goes through the SQLite
//  audit store, and the "last ran" marker is persisted there too, so restarting
//  the app at 08:01 does not replay the 08:00 briefing.
//
//  A manual 「立即运行」 is a real run: it moves the marker, which is why pressing
//  it twice does not produce two briefings that day.
//

import Foundation

public actor LocalTaskScheduler {
    public typealias Handler = @Sendable (Date) async -> String

    public static let tickInterval: TimeInterval = 30

    private let clock: AssistantClock
    private let store: AssistantAuditStore
    private var config: AssistantConfig
    private var briefingHandler: Handler?
    private var patrolHandler: Handler?
    private var loop: Task<Void, Never>?
    private var briefingRunning = false
    private var patrolRunning = false
    private var lastRunDetail = ""
    private let calendar = Calendar.current

    public init(
        config: AssistantConfig = .disabled,
        clock: AssistantClock = SystemAssistantClock(),
        store: AssistantAuditStore
    ) {
        self.config = config.normalised
        self.clock = clock
        self.store = store
    }

    public func setHandlers(briefing: Handler?, patrol: Handler?) {
        briefingHandler = briefing
        patrolHandler = patrol
    }

    public func update(config next: AssistantConfig, now: Date? = nil) async {
        let before = config
        config = next.normalised
        if before.briefing.enabled != config.briefing.enabled {
            await store.record(
                channel: "scheduler",
                event: config.briefing.enabled ? "briefing.enabled" : "briefing.disabled",
                detail: "daily \(String(format: "%02d:%02d", config.briefing.hour, config.briefing.minute))",
                at: now ?? clock.now
            )
        }
        if before.patrol.enabled != config.patrol.enabled {
            await store.record(
                channel: "scheduler",
                event: config.patrol.enabled ? "patrol.enabled" : "patrol.disabled",
                detail: "every \(config.patrol.intervalMinutes) min",
                at: now ?? clock.now
            )
        }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public var isRunning: Bool { loop != nil }

    /// The unit the fake clock drives. Kept public so the console's one-shot
    /// routes and the tests share the exact production path.
    public func tick(now: Date? = nil) async {
        let moment = now ?? clock.now
        guard config.enabled else { return }
        if config.briefing.enabled, await briefingDue(now: moment) {
            _ = await runBriefing(now: moment, manual: false)
        }
        if config.patrol.enabled, await patrolDue(now: moment) {
            _ = await runPatrol(now: moment, manual: false)
        }
    }

    @discardableResult
    public func runBriefingNow(now: Date? = nil) async -> String {
        await runBriefing(now: now ?? clock.now, manual: true)
    }

    @discardableResult
    public func runPatrolNow(now: Date? = nil) async -> String {
        await runPatrol(now: now ?? clock.now, manual: true)
    }

    public func status(now: Date? = nil) async -> AssistantSchedulerCard {
        let moment = now ?? clock.now
        let lastBriefing = await store.stateDate(AssistantAuditStore.stateKeyBriefing)
        let lastPatrol = await store.stateDate(AssistantAuditStore.stateKeyPatrol)
        return AssistantSchedulerCard(
            enabled: config.enabled,
            briefingEnabled: config.briefing.enabled,
            briefingHour: config.briefing.hour,
            briefingMinute: config.briefing.minute,
            patrolEnabled: config.patrol.enabled,
            patrolIntervalMinutes: config.patrol.intervalMinutes,
            offlineMinutes: config.patrol.offlineMinutes,
            running: briefingRunning || patrolRunning || (loop != nil),
            lastBriefingAt: lastBriefing,
            lastPatrolAt: lastPatrol,
            nextBriefingAt: config.briefing.enabled ? nextBriefing(after: moment) : nil,
            lastRunDetail: lastRunDetail
        )
    }

    // MARK: - Running

    private func runBriefing(now: Date, manual: Bool) async -> String {
        guard config.enabled, config.briefing.enabled else {
            let detail = config.enabled ? "简报未开启 / the daily briefing is off" : "私人助手未开启 / the assistant is off"
            await store.record(channel: "scheduler", event: "briefing.refused", detail: detail, outcome: "refused", at: now)
            return detail
        }
        guard !briefingRunning else { return "简报正在运行 / a briefing is already running" }
        guard let briefingHandler else { return "未装配简报处理器 / no briefing handler" }
        briefingRunning = true
        await store.record(
            channel: "scheduler",
            event: manual ? "briefing.manual_start" : "briefing.start",
            detail: "daily \(String(format: "%02d:%02d", config.briefing.hour, config.briefing.minute))",
            at: now
        )
        let detail = await briefingHandler(now)
        briefingRunning = false
        lastRunDetail = detail
        await store.setStateDate(AssistantAuditStore.stateKeyBriefing, date: now)
        await store.record(
            channel: "scheduler",
            event: "briefing.done",
            detail: detail,
            outcome: "ok",
            at: now
        )
        return detail
    }

    private func runPatrol(now: Date, manual: Bool) async -> String {
        guard config.enabled, config.patrol.enabled else {
            let detail = config.enabled ? "巡检未开启 / the patrol is off" : "私人助手未开启 / the assistant is off"
            await store.record(channel: "scheduler", event: "patrol.refused", detail: detail, outcome: "refused", at: now)
            return detail
        }
        guard !patrolRunning else { return "巡检正在运行 / a patrol is already running" }
        guard let patrolHandler else { return "未装配巡检处理器 / no patrol handler" }
        patrolRunning = true
        await store.record(
            channel: "scheduler",
            event: manual ? "patrol.manual_start" : "patrol.start",
            detail: "every \(config.patrol.intervalMinutes) min · offline \(config.patrol.offlineMinutes) min",
            at: now
        )
        let detail = await patrolHandler(now)
        patrolRunning = false
        lastRunDetail = detail
        await store.setStateDate(AssistantAuditStore.stateKeyPatrol, date: now)
        await store.record(
            channel: "scheduler",
            event: "patrol.done",
            detail: detail,
            outcome: "ok",
            at: now
        )
        return detail
    }

    // MARK: - Due checks

    private func briefingDue(now: Date) async -> Bool {
        guard let scheduled = scheduledBriefing(on: now) else { return false }
        guard now >= scheduled else { return false }
        guard let last = await store.stateDate(AssistantAuditStore.stateKeyBriefing) else { return true }
        // A run earlier today satisfies today's briefing, even if it was manual.
        if calendar.isDate(last, inSameDayAs: now) { return false }
        return last < scheduled
    }

    private func patrolDue(now: Date) async -> Bool {
        guard let last = await store.stateDate(AssistantAuditStore.stateKeyPatrol) else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(config.patrol.intervalMinutes * 60)
    }

    private func scheduledBriefing(on day: Date) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = config.briefing.hour
        components.minute = config.briefing.minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func nextBriefing(after now: Date) -> Date? {
        var components = DateComponents()
        components.hour = config.briefing.hour
        components.minute = config.briefing.minute
        components.second = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        )
    }
}
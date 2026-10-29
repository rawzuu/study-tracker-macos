import Engine
import Focus
import Foundation
import Testing
@testable import FocusStore

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let minute = StudyClock.minute
private let monday = clock.parseDayKey("2026-10-26")!
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Int { clock.atMinutes(clock.addDays(monday, day), h * 60 + m) }

@Suite struct FocusStoreTests {
    @Test func usageAddsUpByHour() async throws {
        let store = try FocusStore.inMemory()
        let yt = UsageActivity(bundleId: "com.apple.Safari", appName: "Safari", host: "youtube.com")
        let notes = UsageActivity(bundleId: "com.apple.Notes", appName: "Poznámky")
        try await store.add([UsageSegment(activity: yt, start: at(0, 9, 50), end: at(0, 10, 20)),
                             UsageSegment(activity: notes, start: at(0, 10, 20), end: at(0, 10, 30))], clock: clock)
        try await store.add([UsageSegment(activity: yt, start: at(0, 10, 40), end: at(0, 10, 45))], clock: clock)
        try await store.add([UsageSegment(activity: notes, start: at(1, 8), end: at(1, 8, 1))], clock: clock)

        let monday = try await store.usage(fromDay: "2026-10-26", toDay: "2026-10-26")
        #expect(monday.map(\.hour) == [9, 10, 10])
        let ytAt10 = monday.first { $0.hour == 10 && $0.host == "youtube.com" }
        #expect(ytAt10?.ms == 25 * minute)
        #expect(monday.first { $0.hour == 9 }?.ms == 10 * minute)
        #expect(try await store.usage(fromDay: "2026-10-26", toDay: "2026-10-27").count == 4)
    }

    @Test func eventsAttemptsAndUnlocks() async throws {
        let store = try FocusStore.inMemory()
        let yt = FocusTarget.site("youtube.com")
        try await store.record(FocusEvent(at: at(0, 9), kind: .attempt, target: yt, name: "youtube.com", listIds: ["social"]))
        try await store.record(FocusEvent(at: at(0, 10), kind: .attempt, target: yt, name: "youtube.com", listIds: ["social"]))
        try await store.record(FocusEvent(at: at(0, 10), kind: .attempt, target: .app("com.hnc.Discord"), name: "Discord"))
        try await store.record(FocusEvent(at: at(0, 10, 1), kind: .unlock, target: yt, name: "youtube.com", listIds: ["social", "video"],
                                          until: at(0, 10, 6)))
        try await store.record(FocusEvent(at: at(0, 11), kind: .tamper, target: nil, name: "Safari", detail: "Rozšíření je vypnuté"))

        #expect(try await store.attemptCount(yt, since: at(0, 0)) == 2)
        #expect(try await store.attemptCount(yt, since: at(0, 9, 30)) == 1)
        #expect(try await store.activeExceptions(now: at(0, 10, 5)) == [FocusException(target: yt, until: at(0, 10, 6))])
        #expect(try await store.activeExceptions(now: at(0, 10, 6)).isEmpty)
        #expect(try await store.unlockLists(since: at(0, 0)) == [["social", "video"]])

        let events = try await store.events(from: at(0, 0), to: at(1, 0))
        #expect(events.map(\.kind) == [.attempt, .attempt, .attempt, .unlock, .tamper])
        #expect(events.last == FocusEvent(at: at(0, 11), kind: .tamper, target: nil, name: "Safari", detail: "Rozšíření je vypnuté"))
        #expect(events[3].listIds == ["social", "video"])
    }

    @Test func commitmentsAndPrune() async throws {
        let store = try FocusStore.inMemory()
        let list = FocusList(id: "social", name: "Sociální sítě", sites: ["youtube.com"], strictness: .strict)
        let c = Commitment(list: list, strictness: .strict, until: at(0, 12), source: Commitment.source)
        try await store.save([c, c])
        try await store.save([Commitment(list: list, strictness: .strict, until: at(0, 8), source: Commitment.source)])
        #expect(try await store.commitments(now: at(0, 9)) == [c])

        try await store.record(FocusEvent(at: at(-200, 9), kind: .attempt, target: .app("x"), name: "x"))
        try await store.record(FocusEvent(at: at(0, 9), kind: .attempt, target: .app("x"), name: "x"))
        try await store.add([UsageSegment(activity: UsageActivity(bundleId: "x", appName: "x"), start: at(-200, 9), end: at(-200, 10))], clock: clock)
        try await store.prune(keepDays: 180, now: at(0, 9), clock: clock)
        #expect(try await store.events(from: 0, to: at(1, 0)).count == 1)
        #expect(try await store.usage(fromDay: "2000-01-01", toDay: "2099-01-01").isEmpty)

        // Smazání historie závazek nezruší.
        try await store.deleteHistory()
        #expect(try await store.events(from: 0, to: at(1, 0)).isEmpty)
        #expect(try await store.commitments(now: at(0, 9)) == [c])
    }

    @Test func sharedFileFromTwoConnections() async throws {
        let url = URL.temporaryDirectory.appending(path: "focus-\(UUID().uuidString)/focus.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Strážce zapisuje, aplikace čte – dvě samostatná spojení na stejný soubor.
        let guardStore = try FocusStore(at: url)
        let appStore = try FocusStore(at: url)
        try await guardStore.record(FocusEvent(at: 5, kind: .attempt, target: .app("a"), name: "a"))
        #expect(try await appStore.events(from: 0, to: 10).count == 1)
    }
}

@Suite struct FocusStatsTests {
    @Test func aggregates() {
        let usage = [
            UsageRow(day: "2026-10-26", hour: 9, bundleId: "com.apple.Safari", appName: "Safari", host: "youtube.com", ms: 30 * minute),
            UsageRow(day: "2026-10-26", hour: 10, bundleId: "com.apple.Safari", appName: "Safari", host: "youtube.com", ms: 10 * minute),
            UsageRow(day: "2026-10-27", hour: 10, bundleId: "com.apple.Notes", appName: "Poznámky", host: "", ms: 20 * minute),
            UsageRow(day: "2026-10-01", hour: 10, bundleId: "x", appName: "Mimo období", host: "", ms: 99 * minute),
        ]
        let events = [
            FocusEvent(at: at(0, 9), kind: .attempt, target: .site("youtube.com"), name: "youtube.com"),
            FocusEvent(at: at(1, 9, 30), kind: .attempt, target: .site("youtube.com"), name: "youtube.com"),
            FocusEvent(at: at(1, 22), kind: .attempt, target: .app("d"), name: "Discord"),
            FocusEvent(at: at(1, 22, 1), kind: .unlock, target: .app("d"), name: "Discord", until: at(1, 22, 6)),
            FocusEvent(at: at(1, 23), kind: .tamper, target: nil, name: "Safari", detail: "Rozšíření vypnuté"),
        ]
        let s = FocusStats.make(usage: usage, events: events, days: 7, now: at(1, 23, 30), clock: clock)
        #expect(s.days.count == 7)
        #expect(s.days.last?.key == "2026-10-27")
        #expect(s.screenMs == 60 * minute)
        #expect(s.days.suffix(2).map(\.attempts) == [1, 2])
        #expect(s.top.map(\.name) == ["youtube.com", "Poznámky"])
        #expect(s.top.first?.isSite == true)
        #expect(s.topAttempts.map(\.name) == ["youtube.com", "Discord"])
        #expect(s.heatmap[1][22] == 1)
        #expect(s.heatmap[0][9] == 1)
        #expect(s.unlocks == 1)
        #expect(s.weeklyLine == "Soustředění: u obrazovky 1 h, 3 pokusy o rozptýlení (nejčastěji youtube.com).")
        #expect(FocusStats.make(usage: [], events: [], days: 7, now: at(1, 23), clock: clock).weeklyLine == nil)
        #expect(s.tamper.map(\.detail) == ["Rozšíření vypnuté"])
    }
}

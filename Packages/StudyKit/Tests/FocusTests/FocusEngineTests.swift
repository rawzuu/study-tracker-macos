import Engine
import Foundation
import Testing
import WidgetData
@testable import Focus

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let minute = StudyClock.minute
/// Pondělí 26. 10. 2026 0:00 (den po změně času).
private let monday = clock.parseDayKey("2026-10-26")!
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Int { clock.atMinutes(clock.addDays(monday, day), h * 60 + m) }

private let social = FocusList(id: "social", name: "Sociální sítě", apps: [FocusApp(bundleId: "com.hnc.Discord", name: "Discord")],
                               sites: ["youtube.com", "reddit.com", "x.com/home"])
private let schoolOnly = FocusList(id: "school", name: "Jen škola", mode: .allowOnly,
                                   apps: [FocusApp(bundleId: "com.apple.Safari", name: "Safari")], sites: ["is.muni.cz", "ankiweb.net"])

private func config(_ plans: [FocusPlan], lists: [FocusList] = [social, schoolOnly], locks: [FocusLock] = []) -> FocusConfig {
    FocusConfig(enabled: true, lists: lists, plans: plans, locks: locks)
}

private let duringBlock = FocusPlan(id: "p1", name: "Během učení", listIds: ["social"], trigger: .studyBlock(StudyBlockOptions()))

@Suite struct SiteRuleTests {
    @Test func parsesPastedAddresses() {
        let r = SiteRule("  https://www.YouTube.com/shorts/abc?x=1#t ")
        #expect(r?.host == "youtube.com")
        #expect(r?.path == "/shorts/abc")
        #expect(SiteRule("*.reddit.com")?.text == "reddit.com")
        #expect(SiteRule("example.com:8080/")?.text == "example.com")
        #expect(SiteRule("abc") == nil)
        #expect(SiteRule("") == nil)
        #expect(SiteRule("bad host.com") == nil)
    }

    @Test func matchesSubdomainsAndPaths() {
        let yt = SiteRule("youtube.com")!
        #expect(yt.matches(host: "m.youtube.com"))
        #expect(yt.matches(host: "WWW.YOUTUBE.COM."))
        #expect(!yt.matches(host: "notyoutube.com"))
        let shorts = SiteRule("youtube.com/shorts")!
        #expect(shorts.matches(host: "youtube.com", path: "/shorts"))
        #expect(shorts.matches(host: "youtube.com", path: "/shorts/xyz"))
        #expect(!shorts.matches(host: "youtube.com", path: "/shortsy"))
        #expect(!shorts.matches(host: "youtube.com", path: "/watch"))
    }

    @Test func targetOfURL() {
        let t = SiteRule.target(of: URL(string: "https://www.reddit.com:443/r/swift?sort=new")!)
        #expect(t?.host == "reddit.com")
        #expect(t?.path == "/r/swift")
        #expect(SiteRule.target(of: URL(string: "safari-web-extension://abc/blocked.html")!) == nil)
    }
}

@Suite struct StrictnessTests {
    @Test func mergeTakesStricterOfEach() {
        let a = Strictness(delayMinutes: 5, typingCharacters: 0, weeklyAllowance: 3, unlockMinutes: 10)
        let b = Strictness(delayMinutes: 1, typingCharacters: 120, weeklyAllowance: nil, unlockMinutes: 5)
        let m = a.merged(with: b)
        #expect(m == Strictness(locked: false, delayMinutes: 5, typingCharacters: 120, weeklyAllowance: 3, unlockMinutes: 5))
        #expect(m.merged(with: .strict).locked)
        #expect(!Strictness(weeklyAllowance: 0).canUnlock)
    }
}

@Suite struct TimeWindowTests {
    @Test func sameDay() {
        let w = TimeWindow(weekdays: [0, 1, 2, 3, 4], start: 8 * 60, end: 14 * 60)
        #expect(w.end(containing: at(0, 9), clock: clock) == at(0, 14))
        #expect(w.end(containing: at(0, 14), clock: clock) == nil)
        #expect(w.end(containing: at(0, 7, 59), clock: clock) == nil)
        #expect(w.end(containing: at(5, 9), clock: clock) == nil)
    }

    @Test func overnight() {
        let fri = TimeWindow(weekdays: [4], start: 22 * 60, end: 2 * 60)
        #expect(fri.end(containing: at(4, 23), clock: clock) == at(5, 2))
        #expect(fri.end(containing: at(5, 1), clock: clock) == at(5, 2))
        #expect(fri.end(containing: at(5, 3), clock: clock) == nil)
        #expect(fri.end(containing: at(3, 23), clock: clock) == nil)
    }

    @Test func wholeDay() {
        let w = TimeWindow(weekdays: [0], start: 0, end: 1440)
        #expect(w.end(containing: at(0, 23, 59), clock: clock) == at(1, 0))
    }
}

@Suite struct FocusEngineTests {
    @Test func studyBlockPlan() {
        let running = FocusContext(now: at(0, 10), study: .init(paused: false, isWork: true, phaseEnd: at(0, 10, 25)))
        let state = FocusEngine.evaluate(config([duringBlock]), context: running, clock: clock)
        #expect(state.rules.map(\.list.id) == ["social"])
        #expect(state.rules.first?.until == at(0, 10, 25))
        #expect(state.check(app: "com.hnc.Discord", name: "Discord")?.listNames == ["Sociální sítě"])
        #expect(state.check(app: "com.apple.Notes", name: "Poznámky") == nil)

        // Přestávka je ve výchozím stavu volná, pozastavený blok ne.
        let pause = FocusContext(now: at(0, 10), study: .init(paused: false, isWork: false, phaseEnd: at(0, 10, 5)))
        #expect(!FocusEngine.evaluate(config([duringBlock]), context: pause, clock: clock).isActive)
        let paused = FocusContext(now: at(0, 10), study: .init(paused: true, isWork: true, phaseEnd: nil))
        let pausedState = FocusEngine.evaluate(config([duringBlock]), context: paused, clock: clock)
        #expect(pausedState.isActive)
        #expect(pausedState.rules.first?.until == nil)
        // Bez bloku nic.
        #expect(!FocusEngine.evaluate(config([duringBlock]), context: FocusContext(now: at(0, 10)), clock: clock).isActive)
        // Vypnutý hlavní vypínač i vypnutý plán.
        var off = config([duringBlock])
        off.enabled = false
        #expect(!FocusEngine.evaluate(off, context: running, clock: clock).isActive)
        var disabledPlan = duringBlock
        disabledPlan.enabled = false
        #expect(!FocusEngine.evaluate(config([disabledPlan]), context: running, clock: clock).isActive)
    }

    @Test func sitesBlockAndAllowOnly() {
        let plan = FocusPlan(name: "Ráno", listIds: ["social", "school"], trigger: .schedule([TimeWindow(weekdays: [0], start: 480, end: 720)]))
        let state = FocusEngine.evaluate(config([plan]), context: FocusContext(now: at(0, 9)), clock: clock)
        let yt = state.check(host: "m.youtube.com", path: "/watch")
        #expect(yt?.target == .site("youtube.com"))
        #expect(yt?.listIds == ["social", "school"])
        #expect(yt?.until == at(0, 12))
        // Jen škola: ostatní weby zablokované, školní ne.
        #expect(state.check(host: "seznam.cz")?.listIds == ["school"])
        #expect(state.check(host: "is.muni.cz", path: "/auth") == nil)
        #expect(state.check(host: "localhost") == nil)
        // Cesta: jen x.com/home.
        #expect(state.check(host: "x.com", path: "/home")?.listIds.contains("social") == true)
        // Jen škola blokuje i ostatní aplikace – ale nikdy Finder ani Study Tracker.
        #expect(state.check(app: "com.apple.Notes", name: "Poznámky")?.listIds == ["school"])
        #expect(state.check(app: "com.apple.Safari", name: "Safari") == nil)
        #expect(state.check(app: "com.apple.finder", name: "Finder") == nil)
        #expect(state.check(app: "cz.rawzuu.studytracker.dev", name: "Study Tracker") == nil)
    }

    @Test func allowOnlyWithoutAppsDoesNotRestrictApps() {
        var sitesOnly = schoolOnly
        sitesOnly.apps = []
        let lock = FocusLock(listIds: ["school"], start: at(0, 8), end: at(0, 12))
        let state = FocusEngine.evaluate(config([], lists: [sitesOnly], locks: [lock]), context: FocusContext(now: at(0, 9)), clock: clock)
        #expect(state.check(app: "com.apple.Notes", name: "Poznámky") == nil)
        #expect(state.check(host: "seznam.cz") != nil)
    }

    @Test func mergedStrictnessAndQuit() {
        var strict = social
        strict.id = "strict"
        strict.strictness = .strict
        strict.appAction = .quit
        let plan = FocusPlan(name: "Ráno", listIds: ["social", "strict"], trigger: .schedule([TimeWindow(weekdays: [0], start: 480, end: 720)]))
        let lock = FocusLock(listIds: ["social"], start: at(0, 8), end: at(0, 13), strictness: .typing)
        let state = FocusEngine.evaluate(config([plan], lists: [social, strict], locks: [lock]), context: FocusContext(now: at(0, 9)), clock: clock)
        let social = state.rules.first { $0.list.id == "social" }
        #expect(social?.sources == ["Ráno", "Ruční zámek"])
        #expect(social?.until == at(0, 13))
        #expect(social?.strictness.typingCharacters == 120)
        let hit = state.check(app: "com.hnc.Discord", name: "Discord")
        #expect(hit?.strictness.locked == true)
        #expect(hit?.appAction == .quit)
        #expect(hit?.until == at(0, 13))
    }

    @Test func exceptionsUnlockOnlyWhenNotLocked() {
        let lock = FocusLock(listIds: ["social"], start: at(0, 8), end: at(0, 12))
        let exceptions = [FocusException(target: .site("youtube.com"), until: at(0, 9, 5)),
                          FocusException(target: .app("com.hnc.Discord"), until: at(0, 8, 30))]
        let state = FocusEngine.evaluate(config([], locks: [lock]), context: FocusContext(now: at(0, 9)), exceptions: exceptions, clock: clock)
        #expect(state.check(host: "m.youtube.com") == nil)
        #expect(state.check(host: "reddit.com") != nil)
        // Výjimka už propadla.
        #expect(state.check(app: "com.hnc.Discord", name: "Discord") != nil)

        var strictLock = lock
        strictLock.strictness = .strict
        let locked = FocusEngine.evaluate(config([], locks: [strictLock]), context: FocusContext(now: at(0, 9)), exceptions: exceptions, clock: clock)
        #expect(locked.check(host: "youtube.com") != nil)
    }

    @Test func commitmentsOutliveConfigChanges() {
        let lock = FocusLock(listIds: ["social"], start: at(0, 8), end: at(0, 12), strictness: .strict)
        let now = FocusContext(now: at(0, 9))
        let state = FocusEngine.evaluate(config([], locks: [lock]), context: now, clock: clock)
        let new = FocusEngine.newCommitments(state, existing: [])
        #expect(new.count == 1)
        #expect(new.first?.until == at(0, 12))
        #expect(FocusEngine.newCommitments(state, existing: new).isEmpty)

        // Zámek smazaný, Soustředění vypnuté, seznam vyprázdněný – závazek platí dál se starým seznamem.
        var emptied = social
        emptied.sites = []
        emptied.apps = []
        let after = FocusEngine.evaluate(FocusConfig(enabled: false, lists: [emptied]), context: FocusContext(now: at(0, 10)),
                                         commitments: new, clock: clock)
        #expect(after.check(host: "youtube.com")?.strictness.locked == true)
        #expect(FocusEngine.newCommitments(after, existing: new).isEmpty)
        // Po konci už ne.
        #expect(!FocusEngine.evaluate(.empty, context: FocusContext(now: at(0, 12)), commitments: new, clock: clock).isActive)
    }

    @Test func protectionOnlyWhileLocked() {
        var c = config([], locks: [FocusLock(listIds: ["social"], start: at(0, 8), end: at(0, 12))])
        c.protection = Protection(systemTools: true, systemSettings: true)
        let soft = FocusEngine.evaluate(c, context: FocusContext(now: at(0, 9)), clock: clock)
        #expect(soft.check(app: "com.apple.ActivityMonitor", name: "Monitor aktivity") == nil)
        c.locks[0].strictness = .strict
        let locked = FocusEngine.evaluate(c, context: FocusContext(now: at(0, 9)), clock: clock)
        let hit = locked.check(app: "com.apple.systempreferences", name: "Nastavení systému")
        #expect(hit?.strictness.locked == true)
        #expect(hit?.until == at(0, 12))
        #expect(locked.check(app: "com.apple.Terminal", name: "Terminál") != nil)
    }

    @Test func examBoost() {
        var c = config([duringBlock])
        c.examBoost = ExamBoost(daysBefore: 3, strictness: .strict)
        let study = FocusContext.Study(paused: false, isWork: true, phaseEnd: nil)
        let soon = FocusContext(now: at(0, 10), study: study, examDays: [clock.addDays(monday, 3)])
        let boosted = FocusEngine.evaluate(c, context: soon, clock: clock)
        #expect(boosted.rules.first?.strictness.locked == true)
        #expect(boosted.rules.first?.sources == ["Během učení", "Před zkouškou"])
        let later = FocusContext(now: at(0, 10), study: study, examDays: [clock.addDays(monday, 4), clock.addDays(monday, -1)])
        #expect(FocusEngine.evaluate(c, context: later, clock: clock).rules.first?.strictness.locked == false)
    }

    @Test func studyPlanTrigger() {
        let plan = FocusPlan(name: "Plán", listIds: ["social"], trigger: .studyPlan)
        let ctx = FocusContext(now: at(0, 10), planBlocks: [.init(start: at(0, 9, 30), end: at(0, 10, 30))])
        #expect(FocusEngine.evaluate(config([plan]), context: ctx, clock: clock).rules.first?.until == at(0, 10, 30))
        let outside = FocusContext(now: at(0, 10, 30), planBlocks: ctx.planBlocks)
        #expect(!FocusEngine.evaluate(config([plan]), context: outside, clock: clock).isActive)
    }

    @Test func contextFromSnapshot() {
        var timer = WidgetSnapshot.TimerInfo.idle
        timer.status = .running
        timer.segmentStart = at(0, 10)
        timer.phaseDurationMs = 25 * minute
        let snapshot = WidgetSnapshot(generatedAt: at(0, 10), days: [], goalSec: 0, studiedSec: 0, weekSec: 0, weekGoalSec: 0, week: [],
                                      todayIndex: 0, streak: 0, subjects: [:],
                                      plan: [.init(id: "b", subjectId: "s", title: "", topic: "", start: at(0, 9), end: at(0, 11), done: false),
                                             .init(id: "c", subjectId: "s", title: "", topic: "", start: at(0, 9), end: at(0, 11), done: true)],
                                      exams: [.init(id: "e", subjectId: "s", name: "Zkouška", day: clock.addDays(monday, 2), time: "")],
                                      timer: timer, nextUp: [])
        let ctx = FocusContext(snapshot: snapshot, now: at(0, 10, 5))
        #expect(ctx.study == .init(paused: false, isWork: true, phaseEnd: at(0, 10, 25)))
        #expect(ctx.planBlocks.count == 1)
        #expect(ctx.examDays == [clock.addDays(monday, 2)])
        // Odpočet doběhl a aplikace neběží: blok skončil.
        #expect(FocusContext(snapshot: snapshot, now: at(0, 10, 25)).study == nil)
    }

    @Test func allowance() {
        let hit = FocusHit(target: .site("youtube.com"), name: "youtube.com", listIds: ["social"], listNames: ["Sociální sítě"],
                           strictness: Strictness(weeklyAllowance: 3), appAction: .shield, until: nil)
        #expect(FocusState.allowanceLeft(hit, unlocksThisWeek: [["social"], ["other"], ["social", "x"]]) == 1)
        #expect(FocusState.allowanceLeft(hit, unlocksThisWeek: [["social"], ["social"], ["social"], ["social"]]) == 0)
        var free = hit
        free.strictness = .soft
        #expect(FocusState.allowanceLeft(free, unlocksThisWeek: [["social"]]) == nil)
    }

    @Test func configRoundTrip() throws {
        var c = config([duringBlock, FocusPlan(name: "Okna", listIds: ["school"], trigger: .schedule([TimeWindow(weekdays: [0, 2], start: 60, end: 30)]),
                                               strictness: .delay),
                        FocusPlan(name: "Plán", listIds: [], trigger: .studyPlan)],
                       locks: [FocusLock(listIds: ["social"], start: 1, end: 2)])
        c.examBoost = ExamBoost()
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(FocusConfig.self, from: data) == c)
    }

    @Test func templatesAreValid() {
        #expect(Set(FocusTemplates.all.map(\.id)).count == FocusTemplates.all.count)
        for t in FocusTemplates.all {
            #expect(t.sites.allSatisfy { SiteRule($0) != nil }, "\(t.name)")
            #expect(!t.makeList().id.isEmpty)
        }
        #expect(FocusTemplates.all[0].makeList().id != FocusTemplates.all[0].makeList().id)
    }
}

@Suite struct UsageMeterTests {
    private let safari = UsageActivity(bundleId: "com.apple.Safari", appName: "Safari", host: "youtube.com")
    private let notes = UsageActivity(bundleId: "com.apple.Notes", appName: "Poznámky")

    @Test func switchesAndIdle() {
        var m = UsageMeter()
        let t = at(0, 10)
        #expect(m.update(safari, at: t).isEmpty)
        #expect(m.update(safari, at: t + 15_000).isEmpty)
        #expect(m.update(notes, at: t + 30_000) == [UsageSegment(activity: safari, start: t, end: t + 30_000)])
        // Odešel: poslední aktivita před 5 minutami se počítá zpětně.
        _ = m.update(notes, at: t + 45_000)
        #expect(m.update(nil, at: t + 40_000) == [UsageSegment(activity: notes, start: t + 30_000, end: t + 40_000)])
        #expect(m.update(nil, at: t + 60_000).isEmpty)
        #expect(m.update(notes, at: t + 75_000).isEmpty)
        #expect(m.flush(at: t + 90_000) == [UsageSegment(activity: notes, start: t + 75_000, end: t + 90_000)])
        #expect(m.flush(at: t + 100_000) == [UsageSegment(activity: notes, start: t + 90_000, end: t + 100_000)])
    }

    @Test func gapIsNotCounted() {
        var m = UsageMeter(maxGap: 60_000)
        let t = at(0, 10)
        _ = m.update(safari, at: t)
        _ = m.update(safari, at: t + 15_000)
        // Mac spal hodinu: úsek končí poslední kontrolou, pak začne nový.
        #expect(m.update(safari, at: t + 3_600_000) == [UsageSegment(activity: safari, start: t, end: t + 15_000)])
        #expect(m.flush(at: t + 3_610_000) == [UsageSegment(activity: safari, start: t + 3_600_000, end: t + 3_610_000)])
    }

    @Test func splitsByHourAndDay() {
        let s = UsageSegment(activity: notes, start: at(0, 23, 50), end: at(1, 1, 10))
        let parts = s.byHour(clock: clock)
        #expect(parts.map(\.day) == ["2026-10-26", "2026-10-27", "2026-10-27"])
        #expect(parts.map(\.hour) == [23, 0, 1])
        #expect(parts.map(\.ms) == [10 * minute, 60 * minute, 10 * minute])
    }
}

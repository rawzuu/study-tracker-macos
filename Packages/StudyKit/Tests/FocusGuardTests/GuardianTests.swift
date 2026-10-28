import Engine
import Focus
import FocusStore
import Foundation
import Testing
import WidgetData
@testable import FocusGuard

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let monday = clock.parseDayKey("2026-10-26")!
private func at(_ h: Int, _ m: Int = 0, _ s: Int = 0) -> Int { clock.atMinutes(monday, h * 60 + m) + s * 1000 }

private let discord = RunningApp(pid: 11, bundleId: "com.hnc.Discord", name: "Discord")
private let notes = RunningApp(pid: 12, bundleId: "com.apple.Notes", name: "Poznámky")
private let safariApp = RunningApp(pid: 13, bundleId: "com.apple.Safari", name: "Safari")

@MainActor private final class FakeApps: AppControl {
    var front: RunningApp?
    var all: [RunningApp] = []
    var hidden: [String] = []
    var quit: [String] = []
    func frontmost() -> RunningApp? { front }
    func running() -> [RunningApp] { all }
    func hide(_ app: RunningApp) { hidden.append(app.bundleId) }
    func quit(_ app: RunningApp) { quit.append(app.bundleId) }
}

@MainActor private final class FakeSafari: SafariControl {
    var url: URL?
    var left = 0
    var isRunning = true
    var isFrontmost = false
    var asked: [Bool] = []
    func permission(ask: Bool) async -> GuardReport.SafariWatch {
        asked.append(ask)
        return .on
    }
    func currentURL() -> URL? { url }
    func leaveBlockedPage() {
        left += 1
        url = URL(string: "about:blank")
    }
}

@MainActor private final class FakeShield: ShieldControl {
    var shown: [ShieldInfo] = []
    var isShown = false
    func show(_ info: ShieldInfo) {
        shown.append(info)
        isShown = true
    }
    func close() { isShown = false }
}

@MainActor private final class Harness {
    var t = at(10)
    var idle: Double = 0
    var config: FocusConfig
    let apps = FakeApps()
    let safari = FakeSafari()
    let shield = FakeShield()
    let store: FocusStore
    let files: FocusFiles
    let dir: URL
    var guardian: Guardian!

    init(_ config: FocusConfig) throws {
        self.config = config
        store = try FocusStore.inMemory()
        dir = URL.temporaryDirectory.appending(path: "guard-\(UUID().uuidString)")
        files = FocusFiles(directory: dir, group: "test.\(UUID().uuidString)")
        guardian = Guardian(Guardian.Dependencies(
            apps: apps, safari: safari, shield: shield, store: store, files: files,
            readConfig: { [unowned self] in self.config }, readSnapshot: { nil },
            now: { [unowned self] in self.t }, idleSeconds: { [unowned self] in self.idle }, clock: clock, version: "test"))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

private let social = FocusList(id: "social", name: "Sociální sítě", apps: [FocusApp(bundleId: "com.hnc.Discord", name: "Discord")],
                               sites: ["youtube.com"], keywords: ["serial"])

private func locked(_ list: FocusList = social, strictness: Strictness? = nil, appAction: FocusList.AppAction = .shield) -> FocusConfig {
    var l = list
    l.appAction = appAction
    var c = FocusConfig(enabled: true, lists: [l], locks: [FocusLock(listIds: [l.id], start: at(9), end: at(12), strictness: strictness)])
    c.tracking.enabled = false
    return c
}

@MainActor @Suite struct GuardianTests {
    @Test func blockedAppIsHiddenWithShieldAndCounted() async throws {
        let h = try Harness(locked())
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.apps.hidden == ["com.hnc.Discord"])
        #expect(h.shield.shown.last == ShieldInfo(name: "Discord", isSite: false, lists: ["Sociální sítě"], attempt: 1, until: at(12), locked: false))
        // Opakované kliknutí v Docku hned potom je stejný pokus.
        h.t += 1000
        await h.guardian.appActivated(discord)
        #expect(h.shield.shown.last?.attempt == 1)
        h.t += 10_000
        await h.guardian.appActivated(discord)
        #expect(h.shield.shown.last?.attempt == 2)
        #expect(try await h.store.attemptCount(.app("com.hnc.Discord"), since: at(0)) == 2)
        // Povolená aplikace obrazovku zavře.
        await h.guardian.appActivated(notes)
        #expect(!h.shield.isShown)
        #expect(h.apps.hidden.count == 3)
        #expect(h.files.readReport()?.attemptsToday["app:com.hnc.Discord"] == 2)
    }

    @Test func quitActionAndRunningAppsAtStart() async throws {
        let h = try Harness(locked(appAction: .quit))
        h.apps.all = [discord, notes]
        h.apps.front = notes
        h.t = at(8, 59)
        await h.guardian.refresh()
        #expect(h.apps.quit.isEmpty)
        // Zámek začne: běžící Discord se ukončí, obrazovka ne (nebyl v popředí).
        h.t = at(9)
        await h.guardian.refresh()
        #expect(h.apps.quit == ["com.hnc.Discord"])
        #expect(h.shield.shown.isEmpty)
        // Další vyhodnocení beze změny už nic neukončuje.
        h.t = at(9, 1)
        await h.guardian.refresh()
        #expect(h.apps.quit == ["com.hnc.Discord"])
    }

    @Test func strictLockSurvivesConfigChange() async throws {
        let h = try Harness(locked(strictness: .strict))
        await h.guardian.refresh()
        #expect(try await h.store.commitments(now: h.t).count == 1)
        // Uživatel zámek smaže a Soustředění vypne – Discord zůstane zablokovaný do 12:00.
        h.config = .empty
        h.t = at(10, 30)
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.shield.shown.last?.locked == true)
        #expect(h.files.readReport()?.state.isLocked == true)
        h.t = at(12)
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.shield.shown.count == 1)
    }

    @Test func safariFallbackWithoutExtension() async throws {
        let h = try Harness(locked())
        h.apps.front = safariApp
        h.safari.url = URL(string: "https://www.youtube.com/watch?v=1")
        await h.guardian.tick()
        #expect(h.safari.asked == [true])
        #expect(h.safari.left == 1)
        #expect(h.shield.shown.last?.name == "youtube.com")
        #expect(h.shield.shown.last?.isSite == true)
        // Slovo v adrese.
        h.t += 10_000
        h.safari.url = URL(string: "https://example.com/serialy/online")
        await h.guardian.tick()
        #expect(h.safari.left == 2)
        // Povolený web nic.
        h.safari.url = URL(string: "https://is.muni.cz")
        await h.guardian.tick()
        #expect(h.safari.left == 2)
        // Na souhlas Automatizace se ptá jen jednou.
        h.t += 20_000
        await h.guardian.tick()
        #expect(h.safari.asked == [true, false])
    }

    @Test func safariExtensionGetsGraceThenTamper() async throws {
        let h = try Harness(locked())
        h.files.markExtensionSeen(at: h.t)
        h.apps.front = safariApp
        h.safari.url = URL(string: "https://youtube.com/")
        await h.guardian.tick()
        #expect(h.safari.left == 0)
        h.t += 1500
        await h.guardian.tick()
        #expect(h.safari.left == 0)
        h.t += 2000
        await h.guardian.tick()
        #expect(h.safari.left == 1)
        let tamper = try await h.store.events(from: at(0), to: at(23)).filter { $0.kind == .tamper }
        #expect(tamper.count == 1)
    }

    @Test func safariAttemptsFromExtension() async throws {
        let h = try Harness(locked())
        await h.guardian.refresh()
        try h.files.send(SafariAttempt(at: h.t, host: "m.youtube.com", path: "/"))
        try h.files.send(SafariAttempt(at: h.t, host: "seznam.cz", path: "/"))
        await h.guardian.ingestSafariAttempts()
        let events = try await h.store.events(from: at(0), to: at(23))
        #expect(events.map(\.name) == ["youtube.com"])
        #expect(events.first?.listIds == ["social"])
    }

    @Test func measuresUsageWithoutIdleAndShield() async throws {
        var c = FocusConfig.empty
        c.tracking = Tracking(enabled: true, idleMinutes: 5, retentionDays: 30)
        let h = try Harness(c)
        h.apps.front = notes
        await h.guardian.tick()
        h.t += 30_000
        await h.guardian.tick()
        // Odešel: 6 minut bez vstupu – počítá se jen do poslední aktivity.
        h.t += 6 * 60_000
        h.idle = 6 * 60
        await h.guardian.tick()
        h.idle = 0
        h.t += 5000
        h.apps.front = RunningApp(pid: 99, bundleId: "cz.rawzuu.studytracker.dev.guard", name: "Strážce")
        await h.guardian.tick()
        h.t += 60_000
        await h.guardian.tick()
        await h.guardian.flush()
        let rows = try await h.store.usage(fromDay: "2026-10-26", toDay: "2026-10-26")
        #expect(rows.map(\.bundleId) == ["com.apple.Notes"])
        #expect(rows.first?.ms == 30_000)
    }

    @Test func dailyLimit() async throws {
        var c = FocusConfig(enabled: true, lists: [social], plans: [FocusPlan(name: "Limit", listIds: ["social"], trigger: .dailyLimit(minutes: 30))])
        c.tracking.enabled = false
        let h = try Harness(c)
        let yt = UsageActivity(bundleId: "com.apple.Safari", appName: "Safari", host: "youtube.com")
        try await h.store.add([UsageSegment(activity: yt, start: at(8), end: at(8, 20))], clock: clock)
        await h.guardian.refresh()
        #expect(!h.guardian.state.isActive)
        try await h.store.add([UsageSegment(activity: yt, start: at(9), end: at(9, 10))], clock: clock)
        h.t += 20_000
        await h.guardian.refresh()
        #expect(h.guardian.state.rules.first?.until == clock.addDays(monday, 1))
    }
}

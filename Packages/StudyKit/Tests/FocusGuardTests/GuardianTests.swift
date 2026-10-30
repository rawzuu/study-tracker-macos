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
    var opened: [String] = []
    func open(bundleId: String) { opened.append(bundleId) }
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
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    var open: [SafariTab] = []
    var blanked: [SafariTab] = []
    func tabs() -> [SafariTab] { open }
    func blank(_ tabs: [SafariTab]) { blanked += tabs }
}

@MainActor private final class FakeNotifier: FocusNotifier {
    var posted: [(id: String, title: String, body: String)] = []
    func post(id: String, title: String, body: String) { posted.append((id, title, body)) }
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
    var boot = 1
    var mono = 0
    var config: FocusConfig
    let apps = FakeApps()
    let safari = FakeSafari()
    let shield = FakeShield()
    let notifier = FakeNotifier()
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
            now: { [unowned self] in self.t }, idleSeconds: { [unowned self] in self.idle }, clock: clock, version: "test",
            bootTime: { [unowned self] in self.boot }, monotonic: { [unowned self] in self.mono }, notifier: notifier))
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

/// Obrazovka se aktualizuje v úloze na pozadí – nechat ji doběhnout.
@MainActor private func settle() async throws {
    for _ in 0..<5 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
}

@MainActor @Suite struct GuardianTests {
    @Test func notifiesBeforeAtStartAndAtEnd() async throws {
        let h = try Harness(locked())
        h.t = at(8, 50)
        await h.guardian.refresh()
        h.t = at(8, 56)
        await h.guardian.refresh()
        h.t = at(8, 57)
        await h.guardian.refresh()
        #expect(h.notifier.posted.map(\.title) == ["Za 4 min začne blokování"])
        h.t = at(9)
        await h.guardian.refresh()
        #expect(h.notifier.posted.last?.title == "Blokování začalo do 12:00" && h.notifier.posted.last?.body == "Sociální sítě")
        h.t = at(12)
        await h.guardian.refresh()
        #expect(h.notifier.posted.last?.title == "Blokování skončilo")
        // Vypnutá oznámení.
        h.config.notify = false
        h.config.locks.append(FocusLock(listIds: ["social"], start: at(12, 1), end: at(13)))
        h.t = at(12, 1)
        await h.guardian.refresh()
        #expect(h.notifier.posted.count == 3)
    }

    @Test func freezeHidesFinderAndOffersAllowedApps() async throws {
        let finder = RunningApp(pid: 1, bundleId: "com.apple.finder", name: "Finder")
        var config = FocusConfig(enabled: true, freeze: FreezeSettings(allowedApps: [FocusApp(bundleId: "com.apple.Notes", name: "Poznámky")]))
        config.locks = [FocusLock(listIds: [], start: at(9), end: at(12), freeze: true)]
        config.tracking.enabled = false
        let h = try Harness(config)
        h.apps.all = [finder, notes, discord]
        h.apps.front = finder
        await h.guardian.refresh()
        #expect(Set(h.apps.hidden) == ["com.apple.finder", "com.hnc.Discord"])
        #expect(h.shield.shown.last?.frozenApps == [FocusApp(bundleId: "com.apple.Notes", name: "Poznámky")])
        #expect(h.shield.shown.last?.name == "Finder")
        h.guardian.shieldOpen(bundleId: "com.apple.Notes")
        #expect(!h.shield.isShown && h.apps.opened == ["com.apple.Notes"])
        await h.guardian.appActivated(notes)
        #expect(!h.shield.isShown)
    }

    @Test func movingTheClockForwardDoesNotEndStrictLock() async throws {
        let h = try Harness(locked(strictness: .strict))
        h.t = at(10)
        await h.guardian.tick()
        #expect(h.guardian.state.isLocked)
        // Normální běh: 5 s nástěnného i monotónního času.
        h.t += 5000
        h.mono += 5000
        await h.guardian.tick()
        // Hodiny posunuté na 12:30, ve skutečnosti uběhlo 5 s: zámek (do 12:00) běží dál, o skok déle.
        let jump = at(12, 30) - (h.t + 5000)
        h.t = at(12, 30)
        h.mono += 5000
        await h.guardian.tick()
        #expect(h.guardian.state.isLocked)
        #expect(h.guardian.state.rules.compactMap(\.until).max() == at(12) + jump)
        let tamper = try await h.store.events(from: at(0), to: at(23)).filter { $0.kind == .tamper }
        #expect(tamper.count == 1 && tamper[0].detail.contains("Čas Macu se posunul dopředu o 149 min"))
    }

    @Test func otherBrowsersAreBlockedWhileWebsitesAre() async throws {
        let chrome = RunningApp(pid: 21, bundleId: "com.google.Chrome", name: "Google Chrome")
        let h = try Harness(locked())
        await h.guardian.refresh()
        await h.guardian.appActivated(chrome)
        #expect(h.apps.hidden == ["com.google.Chrome"])
        #expect(h.shield.shown.last?.lists == ["Jiné prohlížeče"])
        #expect(h.shield.shown.last?.until == at(12))
        // Seznam bez webů prohlížeče neblokuje.
        var appsOnly = social
        appsOnly.sites = []
        appsOnly.keywords = []
        h.config = locked(appsOnly)
        await h.guardian.refresh()
        await h.guardian.appActivated(chrome)
        #expect(h.apps.hidden.count == 1)
        // Vypnutá pojistka taky ne.
        h.config = locked()
        h.config.protection.otherBrowsers = false
        await h.guardian.refresh()
        await h.guardian.appActivated(chrome)
        #expect(h.apps.hidden.count == 1)
    }

    @Test func blockStartClosesBlockedSafariTabs() async throws {
        let h = try Harness(locked())
        func tab(_ index: Int, _ url: String, current: Bool = false) -> SafariTab {
            SafariTab(window: 7, index: index, isCurrent: current, url: URL(string: url)!)
        }
        h.safari.open = [tab(1, "https://www.youtube.com/watch?v=1", current: true), tab(2, "https://cs.wikipedia.org/wiki/Graf"),
                         tab(3, "https://m.youtube.com/"), tab(4, "https://example.com/serial-online")]
        h.t = at(8, 59)
        await h.guardian.refresh()
        #expect(h.safari.blanked.isEmpty)
        // Zámek začne: zablokované záložky se zavřou, aktivní záložku Safari v popředí řeší obrazovka.
        h.safari.isFrontmost = true
        h.t = at(9)
        await h.guardian.refresh()
        #expect(h.safari.blanked.map(\.index) == [3, 4])
        // Safari na pozadí: i aktivní záložka.
        h.safari.blanked = []
        h.safari.isFrontmost = false
        await h.guardian.appActivated(safariApp)
        #expect(h.safari.blanked.map(\.index) == [1, 3, 4])
    }

    @Test func blockedAppIsHiddenWithShieldAndCounted() async throws {
        let h = try Harness(locked())
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.apps.hidden == ["com.hnc.Discord"])
        #expect(h.shield.shown.last == ShieldInfo(name: "Discord", isSite: false, lists: ["Sociální sítě"], attempt: 1, until: at(12), locked: false,
                                                  unlock: .request("Odemknout na 5 min")))
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

    @Test func softUnlockIsOneClick() async throws {
        let h = try Harness(locked())
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.shield.shown.last?.unlock == .request("Odemknout na 5 min"))
        await h.guardian.requestUnlock()
        #expect(!h.shield.isShown)
        #expect(h.apps.opened == ["com.hnc.Discord"])
        let unlocks = try await h.store.events(from: at(0), to: at(23)).filter { $0.kind == .unlock }
        #expect(unlocks.map(\.until) == [h.t + 5 * 60_000])
        // Odemčeno na 5 minut: Discord se neblokuje, pak zase ano.
        h.apps.hidden = []
        await h.guardian.appActivated(discord)
        #expect(h.apps.hidden.isEmpty)
        h.t += 5 * 60_000
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        #expect(h.apps.hidden == ["com.hnc.Discord"])
    }

    @Test func typingAndDelayUnlock() async throws {
        let h = try Harness(locked(strictness: Strictness(delayMinutes: 2, typingCharacters: 10)))
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        await h.guardian.requestUnlock()
        #expect(h.shield.shown.last?.unlock == .wait(until: h.t + 2 * 60_000))
        h.t += 2 * 60_000
        await h.guardian.requestUnlock()
        guard case let .type(text) = h.shield.shown.last?.unlock else {
            Issue.record("čeká se opsání textu")
            return
        }
        await h.guardian.submit(typed: "spatne")
        #expect(h.shield.shown.last?.error != nil)
        #expect(h.shield.isShown)
        // Žádost přežije restart Strážce (je v databázi).
        await h.guardian.submit(typed: text)
        #expect(!h.shield.isShown)
        #expect(try await h.store.unlockRequests().isEmpty)
    }

    @Test func restartAndPasswordUnlock() async throws {
        let h = try Harness(locked(strictness: Strictness(requireRestart: true, password: Unlock.makePassword("kamarad"))))
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        await h.guardian.requestUnlock()
        #expect(h.shield.shown.last?.unlock == .restart)
        #expect(try await h.store.unlockRequests().count == 1)
        h.boot = 2
        await h.guardian.refresh()
        await h.guardian.requestUnlock()
        #expect(h.shield.shown.last?.unlock == .password)
        await h.guardian.submit(password: "spatne")
        #expect(h.shield.shown.last?.error == "Heslo nesouhlasí.")
        await h.guardian.submit(password: "kamarad")
        #expect(!h.shield.isShown)
    }

    @Test func strictCannotUnlockAndSafariUnlockReturnsToPage() async throws {
        let h = try Harness(locked(strictness: .strict))
        await h.guardian.refresh()
        await h.guardian.appActivated(discord)
        await h.guardian.requestUnlock()
        #expect(h.shield.shown.last?.unlock == .unavailable("Přísný zámek – do konce bloku nejde zrušit."))
        #expect(try await h.store.unlockRequests().isEmpty)

        let soft = try Harness(locked())
        await soft.guardian.refresh()
        try soft.files.send(SafariAttempt(at: soft.t, host: "youtube.com", path: "/watch", unlock: true, url: "https://youtube.com/watch?v=1"))
        await soft.guardian.ingestSafariAttempts()
        await soft.guardian.requestUnlock()
        #expect(soft.safari.opened == [URL(string: "https://youtube.com/watch?v=1")!])
        #expect(try await soft.store.events(from: at(0), to: at(23)).map(\.kind) == [.unlock])
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

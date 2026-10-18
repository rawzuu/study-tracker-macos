import AppKit
import AppModel
import DesignSystem
import Engine
import Foundation
import SwiftUI
import Testing
@testable import Features

/// Náhledy obrazovek bez displeje (ImageRenderer) s ukázkovými daty – jen na požádání:
/// `ST_SNAPSHOT_DIR=/cesta swift test --filter Náhledy`. Ovládací prvky AppKitu (výběr, textové pole)
/// se v náhledu nevykreslí; slouží ke kontrole rozvržení, kruhu a barev.
@MainActor
@Suite("Náhledy", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"] != nil))
struct SnapshotTests {
    /// Stránka vedle postranního panelu: okno na notebooku a okno přes celý monitor 2560 × 1440.
    enum Screen: String, CaseIterable, CustomTestStringConvertible {
        case laptop, monitor

        var size: CGSize { self == .laptop ? CGSize(width: 1440, height: 920) : CGSize(width: 2360, height: 1340) }
        var testDescription: String { rawValue }
    }

    @Test("Časovač: v klidu, běží, pauza", arguments: ["idle", "running", "break", "paused"], Screen.allCases)
    func timer(_ variant: String, _ screen: Screen) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        app.updateSettings { $0.noiseType = .brown }
        // Blok začal před 9:25 – kruh běžícího časovače počítá s opravdovým „teď“.
        var t = now - 9 * 60_000 - 25_000
        let timer = TimerStore(app: app) { t }
        timer.configure(TimerSetup(subjectId: "demo-anat", topic: "Lebka"))
        if variant != "idle" {
            timer.start()
            if variant == "break" {
                t = now - 60_000
                timer.finishWork()
                timer.skipRating()
            }
            t = now
            if variant == "paused" { timer.pause() }
        }
        try render(TimerView(snapshotSize: screen.size).environment(app).environment(timer).environment(Advisor(store: app)),
                   name: "timer-\(variant)-\(screen)", size: screen.size)
    }

    @Test("Přehled s běžícím časovačem", arguments: Screen.allCases)
    func dashboard(_ screen: Screen) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        var t = now - 12 * 60_000
        let timer = TimerStore(app: app) { t }
        timer.configure(TimerSetup(subjectId: "demo-anat", topic: "Lebka"))
        timer.start()
        t = now
        try render(DashboardView(snapshotNow: now, width: screen.size.width).environment(app).environment(timer).environment(Advisor(store: app)).environment(Toasts())
                    .environment(await calendars(app, now: now)),
                   name: "dashboard-\(screen)", size: CGSize(width: screen.size.width, height: screen == .laptop ? 1400 : 1340))
    }

    @Test("Historie a předměty", arguments: Screen.allCases)
    func lists(_ screen: Screen) async throws {
        let app = AppStore(environment: .uiTesting())
        await app.start()
        try render(HistoryView(snapshotWidth: screen.size.width).environment(app).environment(Toasts()),
                   name: "history-\(screen)", size: CGSize(width: screen.size.width, height: 1800))
        try render(SubjectsView(snapshotWidth: screen.size.width).environment(app), name: "subjects-\(screen)", size: screen.size)
    }

    @Test("Kalendář: týden a měsíc", arguments: ["week", "month"])
    func calendar(_ variant: String) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        var t = now - 20 * 60_000
        let timer = TimerStore(app: app) { t }
        timer.configure(TimerSetup(subjectId: "demo-lat", topic: "Deklinace"))
        timer.start()
        t = now
        try render(CalendarView(snapshotNow: now, mode: variant == "week" ? .week : .month).environment(app).environment(timer).environment(Toasts())
                    .environment(await calendars(app, now: now)),
                   name: "calendar-\(variant)", size: CGSize(width: 1440, height: variant == "week" ? 1900 : 1500))
    }

    @Test("Ranní plán")
    func dayPlan() async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        let clock = app.clock
        // Návrh na dopoledne, ať je v náhledu vždy co ukázat.
        let morning = clock.atMinutes(clock.startOfDay(now), 7 * 60 + 40)
        let items = DayPlan.propose(app.document, now: morning, extra: 1, clock: clock)
        try render(DayPlanSheet(items: items, scrolls: false).environment(app).environment(Toasts()).environment(await calendars(app, now: now)).background(Palette.bg),
                   name: "dayplan", size: CGSize(width: 720, height: 640))
    }

    @Test("Apple Kalendář v Nastavení: vypnuto a zapnuto", arguments: [false, true])
    func appleCalendar(_ enabled: Bool) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        let sync = await calendars(app, now: now, access: enabled ? .granted : .notDetermined)
        if enabled { await sync.enable() }
        try render(AppleCalendarSettings().environment(app).environment(sync).environment(Toasts()).padding(32).background(Palette.bg),
                   name: "apple-calendar-\(enabled ? "on" : "off")", size: CGSize(width: 780, height: enabled ? 760 : 300))
    }

    /// Ukázkové kalendáře s obsazeným časem (trénink dnes 16:00, porada zítra 10:00).
    private func calendars(_ app: AppStore, now: Int, access: CalendarAccess = .granted) async -> AppleCalendarSync {
        let sync = AppleCalendarSync(app: app, service: DemoCalendars.service(now: now, clock: app.clock, access: access))
        await sync.start()
        return sync
    }

    private func render(_ view: some View, name: String, size: CGSize = Screen.laptop.size) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"]!)
        for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let content = view.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            var image: CGImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let rep = NSBitmapImageRep(cgImage: try #require(image))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
        }
    }
}

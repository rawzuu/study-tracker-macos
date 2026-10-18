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
    @Test("Časovač: v klidu, běží, pauza", arguments: ["idle", "running", "break", "paused"])
    func timer(_ variant: String) async throws {
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
        try render(TimerView(snapshotSize: CGSize(width: 1440, height: 920)).environment(app).environment(timer).environment(Advisor(store: app)),
                   name: "timer-\(variant)")
    }

    @Test("Přehled s běžícím časovačem")
    func dashboard() async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        var t = now - 12 * 60_000
        let timer = TimerStore(app: app) { t }
        timer.configure(TimerSetup(subjectId: "demo-anat", topic: "Lebka"))
        timer.start()
        t = now
        try render(DashboardView(snapshotNow: now).environment(app).environment(timer).environment(Advisor(store: app)).environment(Toasts()),
                   name: "dashboard", height: 1400)
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
        try render(CalendarView(snapshotNow: now, mode: variant == "week" ? .week : .month).environment(app).environment(timer).environment(Toasts()),
                   name: "calendar-\(variant)", height: variant == "week" ? 1900 : 1500)
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
        try render(DayPlanSheet(items: items, scrolls: false).environment(app).environment(Toasts()).background(Palette.bg),
                   name: "dayplan", width: 720, height: 640)
    }

    private func render(_ view: some View, name: String, width: CGFloat = 1440, height: CGFloat = 920) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"]!)
        for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let content = view.frame(width: width, height: height, alignment: .top).environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            var image: CGImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let rep = NSBitmapImageRep(cgImage: try #require(image))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
        }
    }
}

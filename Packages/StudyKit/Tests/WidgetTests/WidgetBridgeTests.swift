import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import AppModel
@testable import WidgetData
@testable import WidgetUI

@MainActor
private final class Reloads {
    var count = 0
}

@MainActor
@Suite("Widgety – most v aplikaci", .serialized)
struct WidgetBridgeTests {
    private func setup() async -> (WidgetBridge, AppStore, TimerStore, WidgetFiles, Reloads) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        let timer = TimerStore(app: app)
        let files = WidgetFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("st-wb-\(UUID().uuidString)"),
                                group: "test.\(UUID().uuidString)")
        let reloads = Reloads()
        let bridge = WidgetBridge(app: app, timer: timer, advisor: Advisor(store: app), files: files, delay: .milliseconds(10)) { reloads.count += 1 }
        return (bridge, app, timer, files, reloads)
    }

    @Test("Souhrn z dat: dnešek, plán, zkoušky, Co teď?; zapíše se jen při změně")
    func snapshot() async throws {
        let (bridge, app, timer, files, reloads) = await setup()
        bridge.update()
        let s = try #require(files.readSnapshot())
        let clock = app.clock
        let today = clock.startOfDay(app.nowMs)
        #expect(s.days == [today, clock.addDays(today, 1), clock.addDays(today, 2)])
        #expect(s.goalSec == app.document.settings.dailyGoalMin * 60)
        #expect(s.subjects["demo-anat"]?.name == "Anatomie")
        #expect(s.plan.allSatisfy { $0.start >= today && $0.start < clock.addDays(today, 2) })
        #expect(!s.exams.isEmpty && s.exams.map(\.day) == s.exams.map(\.day).sorted())
        #expect(!s.nextUp.isEmpty && s.timer == .idle)
        // Předměty v týdnu: jen aktivní s cílem nebo s učením, předměty s cílem první, nejvýš šest.
        let active = app.document.alive(Subject.self).filter { !$0.archived }
        #expect(!s.subjectWeek.isEmpty && s.subjectWeek.count <= 6)
        #expect(s.subjectWeek.allSatisfy { w in active.contains { $0.id == w.subjectId } && (w.goalSec > 0 || w.sec > 0) })
        #expect(s.subjectWeek.map { $0.goalSec > 0 } == s.subjectWeek.map { $0.goalSec > 0 }.sorted { $0 && !$1 })
        #expect(s.subjectWeek.reduce(0) { $0 + $1.sec } <= s.weekSec)
        #expect(reloads.count == 1)
        bridge.update()
        #expect(reloads.count == 1, "beze změny se widgety nepřekreslují")

        timer.configure(TimerSetup(subjectId: "demo-anat", topic: "Lebka"))
        timer.start()
        bridge.update()
        let running = try #require(files.readSnapshot()).timer
        #expect(running.status == .running && running.isWork && running.subjectId == "demo-anat" && running.phaseEnd != nil)
        #expect(reloads.count == 2)
    }

    @Test("Tlačítka ve widgetu ovládají skutečný časovač")
    func commands() async throws {
        let (bridge, app, timer, files, _) = await setup()
        bridge.start()
        try files.send(WidgetCommand(action: .start, subjectId: "demo-lat", at: app.nowMs))
        bridge.runCommands()
        #expect(timer.state.status == .running && timer.state.subjectId == "demo-lat")
        try files.send(WidgetCommand(action: .pause, at: app.nowMs))
        bridge.runCommands()
        #expect(timer.state.status == .paused)
        #expect(try #require(files.readSnapshot()).timer.status == .paused)
        try files.send(WidgetCommand(action: .stop, at: app.nowMs))
        bridge.runCommands()
        #expect(timer.state.status == .idle)
    }
}

/// Náhledy widgetů – jen na požádání: `ST_SNAPSHOT_DIR=/cesta swift test --filter WidgetSnapshots`.
@MainActor
@Suite("Widgety – náhledy", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"] != nil))
struct WidgetSnapshots {
    static let sizes: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)), (.systemExtraLarge, CGSize(width: 764, height: 382)),
    ]

    @Test("Všechny widgety, v klidu i s běžícím blokem")
    func all() throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        // 15:10 – blok 14:00 už je za námi, 16:00 přijde
        let cal = Calendar.current
        let at = Int(cal.date(bySettingHour: 15, minute: 10, second: 0, of: Date(timeIntervalSince1970: Double(now) / 1000))!.timeIntervalSince1970 * 1000)
        let idle = StudyEntry(date: Date(timeIntervalSince1970: Double(at) / 1000), snapshot: .sample(now: at))
        let running = WidgetSnapshot.sampleTimer(now: at)
        let busy = StudyEntry(date: idle.date, snapshot: .sample(now: at, timer: running))
        var paused = running
        paused.status = .paused
        paused.accumulated = running.elapsed(at: at)
        paused.segmentStart = nil
        var rest = running
        rest.isWork = false
        rest.phaseDurationMs = 5 * 60_000
        rest.segmentStart = at - 100_000
        var ready = running
        ready.status = .ready
        ready.segmentStart = nil
        let states = [("paused", paused), ("break", rest), ("ready", ready)].map { ($0, StudyEntry(date: idle.date, snapshot: .sample(now: at, timer: $1))) }
        for (family, size) in Self.sizes {
            let tag = "\(family)".replacingOccurrences(of: "system", with: "").lowercased()
            if [.systemSmall, .systemMedium].contains(family) {
                try render(TodayWidgetView(entry: idle, family: family), "today-\(tag)", size)
                try render(TimerWidgetView(entry: busy, family: family), "timer-\(tag)", size)
                try render(TimerWidgetView(entry: idle, family: family), "timer-idle-\(tag)", size)
                for (name, entry) in states { try render(TimerWidgetView(entry: entry, family: family), "timer-\(name)-\(tag)", size) }
                try render(TodayWidgetView(entry: busy, family: family), "today-busy-\(tag)", size)
                try render(ExamsWidgetView(entry: idle, family: family), "exams-\(tag)", size)
            }
            if [.systemMedium, .systemLarge].contains(family) {
                try render(PlanWidgetView(entry: idle, family: family), "plan-\(tag)", size)
            }
            if [.systemLarge, .systemExtraLarge].contains(family) {
                try render(OverviewWidgetView(entry: idle, family: family), "overview-\(tag)", size)
                try render(OverviewWidgetView(entry: busy, family: family), "overview-busy-\(tag)", size)
                try render(OverviewWidgetView(entry: states[0].1, family: family), "overview-paused-\(tag)", size)
            }
        }
        try render(TodayWidgetView(entry: StudyEntry(date: .now, snapshot: nil), family: .systemSmall), "nodata-small", CGSize(width: 170, height: 170))
    }

    private func render(_ view: some View, _ name: String, _ size: CGSize) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"]!)
        for (scheme, appearance) in [(ColorScheme.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            // Jako na ploše: zaoblená karta s pozadím widgetu a okraji obsahu.
            let card = view
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(Palette.fixed(Palette.bg, scheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(12)
                .background(scheme == .dark ? Color(white: 0.28) : Color(white: 0.82))
                .environment(\.colorScheme, scheme)
                .environment(\.widgetStaticClock, true)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            var image: CGImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let rep = NSBitmapImageRep(cgImage: try #require(image))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("widget-\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}

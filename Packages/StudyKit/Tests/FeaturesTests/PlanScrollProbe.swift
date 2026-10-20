import AppKit
import AppModel
import Engine
import Foundation
import SwiftUI
import Testing
@testable import Features

/// Měření posunu ranního plánu na týden mimo obrazovku – jen na požádání: `ST_PROBE=1 swift test --filter PlanScrollProbe`.
/// Každý krok posunu o 60 bodů na nové místo (první vykreslení řádků) má trvat jednotky ms; s prvky AppKitu
/// v řádcích (zaškrtnutí, výběr času a délky) to bylo ~50 ms a rychlý posun se sekal.
@MainActor
@Suite("Sonda: posun ranního plánu", .enabled(if: ProcessInfo.processInfo.environment["ST_PROBE"] != nil))
struct PlanScrollProbe {
    @Test func scroll() async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let app = AppStore(environment: .uiTesting(now: now))
        await app.start()
        let sync = AppleCalendarSync(app: app, service: DemoCalendars.service(now: now, clock: app.clock, access: .granted))
        await sync.start()
        let t0 = Date()
        let plan = DayPlanSheet.proposal(app, calendar: sync, span: .nextWeek)
        print("PROBE návrh: \(Int(Date().timeIntervalSince(t0) * 1000)) ms, bloků \(plan.flatMap(\.items).count)")
        let host = NSHostingView(rootView: DayPlanSheet(plan: plan, span: .nextWeek).environment(app).environment(Toasts()).environment(sync))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 760, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let t1 = Date()
        host.layoutSubtreeIfNeeded(); host.display()
        print("PROBE první vykreslení: \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
        guard let sv = scrollViews(host).max(by: { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }) else { print("PROBE bez scrollview"); return }
        print("PROBE obsah \(Int(sv.documentView?.frame.height ?? 0)) bodů, viditelně \(Int(sv.contentView.bounds.height))")
        var worst = 0.0, total = 0.0
        for k in 1...40 {
            let y = CGFloat(k) * 60
            let t = Date()
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
            host.layoutSubtreeIfNeeded(); host.display()
            try? await Task.sleep(for: .milliseconds(1))
            let ms = Date().timeIntervalSince(t) * 1000
            worst = max(worst, ms); total += ms
        }
        print("PROBE posun: průměr \(Int(total / 40)) ms, nejhorší \(Int(worst)) ms")
        window.contentView = nil
    }
}

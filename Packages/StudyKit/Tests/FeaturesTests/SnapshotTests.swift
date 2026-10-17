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
        try render(TimerView(snapshotSize: CGSize(width: 1440, height: 920)).environment(app).environment(timer), name: "timer-\(variant)")
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
        try render(DashboardView(snapshotNow: now).environment(app).environment(timer), name: "dashboard", height: 1500)
    }

    private func render(_ view: some View, name: String, height: CGFloat = 920) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"]!)
        for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let content = view.frame(width: 1440, height: height, alignment: .top).environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            var image: CGImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let rep = NSBitmapImageRep(cgImage: try #require(image))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
        }
    }
}

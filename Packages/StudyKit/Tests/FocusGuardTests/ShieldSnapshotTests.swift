import AppKit
import Focus
import SwiftUI
import Testing
@testable import FocusGuard

/// Náhled blokovací obrazovky do PNG (`ST_SNAPSHOT_DIR`) – jen pro kontrolu vzhledu, bez porovnání.
@MainActor @Suite struct ShieldSnapshotTests {
    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["ST_SNAPSHOT_DIR"] else { return }
        let until = Int(Date().timeIntervalSince1970 * 1000) + (83 * 60 + 12) * 1000
        let cases: [(String, ShieldInfo)] = [
            ("shield-request", ShieldInfo(name: "YouTube", isSite: true, lists: ["Video", "Sociální sítě"], attempt: 7, until: until, locked: false,
                                          unlock: .request("Odemknout na 5 min · počkat 5 min, opsat 120 znaků · zbývá 2 odemknutí tento týden"))),
            ("shield-locked", ShieldInfo(name: "Discord", isSite: false, lists: ["Chat"], attempt: 2, until: until, locked: true,
                                         unlock: .unavailable("Přísný zámek – do konce bloku nejde zrušit."))),
        ]
        for (name, info) in cases {
            let model = ShieldModel()
            model.info = info
            let view = ShieldView(model: model, actions: .init(close: {}, back: {}, unlock: {}, typed: { _ in }, password: { _ in }))
                .frame(width: 1280, height: 800)
            let renderer = ImageRenderer(content: view)
            NSApp?.appearance = NSAppearance(named: .darkAqua)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(filePath: dir).appending(path: "\(name).png"))
        }
    }
}

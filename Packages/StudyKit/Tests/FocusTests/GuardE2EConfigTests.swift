import Engine
import Foundation
import Testing
@testable import Focus

/// Nastavení pro zkoušku skutečného Strážce na CI (`Tools/ci/guard-e2e.sh`): soubory musí jít přečíst
/// aktuálním kódem, jinak by Strážce na CI nic neblokoval a zkouška by neměla smysl.
/// `ST_WRITE_E2E=1 swift test --filter GuardE2EConfigTests` je vygeneruje znovu.
@Suite struct GuardE2EConfigTests {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tools/ci/guard-e2e")
    /// Do roku 2100 – zámek platí po celou zkoušku.
    static let end = 4_102_444_800_000
    static let textEdit = FocusApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    static let base = FocusConfig(tracking: Tracking(enabled: false, idleMinutes: 5, retentionDays: 1), watchSafari: false)

    /// Ruční zámek s volnou přísností na TextEdit.
    static var block: FocusConfig {
        var c = base
        c.lists = [FocusList(id: "e2e", name: "Zkouška", apps: [textEdit])]
        c.locks = [FocusLock(id: "e2e-lock", listIds: ["e2e"], start: 0, end: end, strictness: Strictness())]
        c.notify = false
        return c
    }

    /// Zmrazení celého Macu (volná přísnost – na CI se nic neodemyká, Strážce se na konci ukončí).
    static var freeze: FocusConfig {
        var c = base
        c.locks = [FocusLock(id: "e2e-freeze", listIds: [], start: 0, end: end, freeze: true)]
        c.freeze = FreezeSettings(strictness: Strictness())
        c.notify = false
        return c
    }

    /// Nic se neblokuje (po zmrazení se má všechno vrátit).
    static var free: FocusConfig {
        var c = base
        c.notify = false
        return c
    }

    @Test(arguments: [("block", block, true), ("freeze", freeze, true), ("free", free, false)])
    func fixture(name: String, config: FocusConfig, blocksTextEdit: Bool) throws {
        let url = Self.directory.appending(path: "\(name).json")
        if ProcessInfo.processInfo.environment["ST_WRITE_E2E"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: url)
        }
        let decoded = try JSONDecoder().decode(FocusConfig.self, from: Data(contentsOf: url))
        #expect(decoded == config)
        let state = FocusEngine.evaluate(decoded, context: FocusContext(now: 1_800_000_000_000), clock: StudyClock(timeZone: .current))
        #expect((state.check(app: Self.textEdit.bundleId, name: Self.textEdit.name) != nil) == blocksTextEdit)
    }
}

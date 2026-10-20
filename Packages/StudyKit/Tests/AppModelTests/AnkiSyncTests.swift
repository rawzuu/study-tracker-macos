import Core
import Engine
import Foundation
import Networking
import Persistence
import Testing
@testable import AppModel

private let clock = StudyClock.current
private let minute = StudyClock.minute

@MainActor
private func store(_ seed: AppDocument = .empty) async -> AppStore {
    let local = try! LocalStore.inMemory()
    let store = AppStore(environment: AppEnvironment(
        openStore: { local }, secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: "st-anki-\(UUID().uuidString)")!,
        backupService: OfflineBackupService(), clock: clock, network: { AsyncStream { $0.finish() } }, seed: seed
    ))
    await store.start()
    return store
}

/// Dvacet karet z Anatomie před hodinou (po 15 s).
private func result(reviewedToday: Int = 20) -> AnkiConnectResult {
    let start = Int(Date().timeIntervalSince1970 * 1000) - 60 * minute
    return AnkiConnectResult(
        decks: [AnkiConnectDeck(name: "Anatomie", newCount: 5, learnCount: 1, reviewCount: 30, total: 400)],
        reviewedToday: reviewedToday,
        reviews: (0..<20).map { AnkiConnectReview(deck: "Anatomie", time: start + $0 * 15_000, durationMs: 15_000) },
        reviewsFetched: true
    )
}

@MainActor
@Suite("Anki na Macu", .serialized)
struct AnkiSyncTests {
    @Test("Vypnuto (výchozí): Anki se nenačítá a data se nemění")
    func offByDefault() async {
        let app = await store()
        let anki = InMemoryAnki(result: result())
        let sync = AnkiSync(app: app, service: anki)
        sync.start()
        await sync.syncNow()
        #expect(!sync.enabled && sync.status == .off)
        #expect(await anki.calls.isEmpty)
        #expect(app.document.alive(Session.self).isEmpty)
    }

    @Test("Zapnutí: stav balíčků, předmět Anki a blok opakování; další kolo bez nového opakování nic nestahuje ani nezapisuje")
    func enable() async {
        let app = await store()
        let anki = InMemoryAnki(result: result())
        let sync = AnkiSync(app: app, service: anki, interval: .seconds(3600))
        sync.setEnabled(true)
        for _ in 0..<200 where !(app.document.alive(Session.self).count == 1) { try? await Task.sleep(for: .milliseconds(5)) }
        let session = app.document.alive(Session.self).first
        #expect(session?.mode == "anki" && session?.subjectId == AnkiImport.subjectId && session?.note == "20 karet" && session?.durationSec == 300)
        #expect(app.document.record(Subject.self, id: AnkiImport.subjectId)?.name == "Anki")
        #expect(AnkiImport.today(app.document, now: app.nowMs, clock: clock)?.due == 36)
        if case .ok = sync.status {} else { Issue.record("stav \(sync.status)") }

        let before = app.document
        await sync.syncNow()
        #expect(await anki.calls.last?.known == 20, "známý počet dnešních karet")
        #expect(app.document == before, "beze změny se nic nezapisuje")
    }

    @Test("Přiřazení balíčku k předmětu přepočítá historii; Anki neběží → chyba, data zůstanou")
    func mappingAndErrors() async {
        var seed = AppDocument.empty
        seed.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 300, "archived": false]), now: 1)
        let app = await store(seed)
        let anki = InMemoryAnki(result: result())
        let sync = AnkiSync(app: app, service: anki, interval: .seconds(3600))
        sync.setEnabled(true)
        for _ in 0..<200 where app.document.alive(Session.self).isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        sync.updateSettings(recompute: true) { $0.deckSubjects = ["Anatomie": "anat"] }
        for _ in 0..<200 where app.document.alive(Session.self).first?.subjectId != "anat" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(app.document.alive(Session.self).map(\.subjectId) == ["anat"])
        #expect(app.document.settings.anki.deckSubjects == ["Anatomie": "anat"])

        await anki.fail(.offline)
        let before = app.document
        await sync.syncNow(fullHistory: true)
        #expect(sync.status == .failed(.offline, at: { if case .failed(_, let at) = sync.status { at } else { 0 } }()))
        #expect(app.document == before)

        sync.setEnabled(false)
        #expect(sync.status == .off)
    }
}

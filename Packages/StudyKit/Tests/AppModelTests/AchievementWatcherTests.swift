import Core
import Engine
import Foundation
import Persistence
import Testing
@testable import AppModel

@MainActor
@Suite("Úspěchy na Macu", .serialized)
struct AchievementWatcherTests {
    private func store() async -> AppStore {
        let local = try! LocalStore.inMemory()
        let store = AppStore(environment: AppEnvironment(
            openStore: { local }, secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: "st-ach-\(UUID().uuidString)")!,
            backupService: OfflineBackupService(), clock: .current, network: { AsyncStream { $0.finish() } }, seed: .empty
        ))
        await store.start()
        return store
    }

    private func session(_ id: String, minutes: Int) -> Session {
        let end = Int(Date().timeIntervalSince1970 * 1000) - 60_000
        return Session(raw: ["id": .string(id), "subjectId": "a", "topic": "", "start": .number(Double(end - minutes * 60_000)), "end": .number(Double(end)),
                             "durationSec": .number(Double(minutes * 60)), "mode": "pomodoro", "interruptions": 0, "note": ""])
    }

    @Test("Získané úspěchy se uloží do dat; první spuštění tiše, další nový úspěch s hláškou „Zobrazit“")
    func persistAndAnnounce() async {
        let app = await store()
        let toasts = Toasts()
        var opened = false
        let watcher = AchievementWatcher(app: app, toasts: toasts, delay: .milliseconds(20)) { opened = true }
        app.upsert(session("s1", minutes: 30))
        watcher.start()
        let ids = Set(app.document.alive(AchievementRecord.self).map(\.id))
        #expect(ids.contains("sessions.1") && !ids.contains("hours.1"))
        #expect(toasts.current == nil, "první vyhodnocení na Macu bez hlášky")

        app.upsert(session("s2", minutes: 40))
        for _ in 0..<200 where !app.document.alive(AchievementRecord.self).contains(where: { $0.id == "hours.1" }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(app.document.alive(AchievementRecord.self).contains { $0.id == "hours.1" })
        #expect(toasts.current?.text.hasPrefix("Odemčeno: Hodiny I") == true && toasts.current?.actionTitle == "Zobrazit")
        toasts.undo()
        #expect(opened)
    }
}

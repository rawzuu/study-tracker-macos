import Core
import Foundation
import Persistence
import Testing
@testable import Sync

/// Kontrola na skutečných datech – jen lokálně, data do repa nepatří.
/// `ST_REAL_DATA` = cesta k data.json, `ST_REAL_OUT` = kam uložit obsah, který by Mac nahrál (pro kontrolu kódem webu).
@Suite("Skutečná data", .enabled(if: ProcessInfo.processInfo.environment["ST_REAL_DATA"] != nil))
struct RealDataSyncTests {
    @Test("První synchronizace se zápisem nic nezmění a úprava z Macu změní jen upravený záznam")
    func firstWriteSync() async throws {
        let env = ProcessInfo.processInfo.environment
        let original = try String(contentsOfFile: env["ST_REAL_DATA"]!, encoding: .utf8)
        let remote = FakeGitHub(text: original)
        let engine = SyncEngine(store: try LocalStore.inMemory(), stored: nil, remote: remote, mode: .readWrite,
                                timing: .init(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)))

        // 1) Zapnutí zápisu: data jsou stejná → žádný commit.
        await engine.syncNow()
        #expect(await remote.commits.isEmpty)
        #expect(Merge.serialize(await engine.document) == original)

        // 2) Úprava jednoho předmětu na Macu.
        var doc = await engine.document
        let subject = try #require(doc.alive(Subject.self).first)
        var edited = subject
        edited.weeklyGoalMin += 30
        doc.upsert(edited, now: Int(Date().timeIntervalSince1970 * 1000))
        await engine.localDidChange(doc)
        await engine.settle()

        let commits = await remote.commits
        #expect(commits.count == 1)
        let pushed = try #require(commits.first?.text)
        #expect(Merge.serialize(try AppDocument(parsing: Data(pushed.utf8))) == pushed)

        // Kromě upraveného předmětu je všechno bajtově stejné.
        let before = try AppDocument(parsing: Data(original.utf8))
        let after = try AppDocument(parsing: Data(pushed.utf8))
        for key in CollectionKey.allCases where key != .subjects {
            #expect(after.raw[key.rawValue] == before.raw[key.rawValue], "\(key)")
        }
        #expect(after.raw["settings"] == before.raw["settings"])
        let changed = zip(before.rawRecords(.subjects), after.rawRecords(.subjects)).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.0.string("id") == subject.id)
        #expect(after.record(Subject.self, id: subject.id)?.weeklyGoalMin == subject.weeklyGoalMin + 30)

        if let out = env["ST_REAL_OUT"] { try pushed.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

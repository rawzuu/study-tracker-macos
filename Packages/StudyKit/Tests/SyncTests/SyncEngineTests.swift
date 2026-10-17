import Core
import Foundation
import Networking
import Persistence
import Testing
@testable import Sync

private let fast = SyncEngine.Timing(debounce: .milliseconds(20), interval: .seconds(3600), persistDelay: .milliseconds(5))

/// Dokument s předměty (id, název, čas změny).
private func doc(_ subjects: (String, String, Int)...) -> AppDocument {
    var d = AppDocument.empty
    for (id, name, t) in subjects {
        d.upsert(Subject(raw: ["id": .string(id), "name": .string(name)]), now: t)
    }
    return d
}

private func adding(_ base: AppDocument, _ id: String, _ name: String, at t: Int) -> AppDocument {
    var d = base
    d.upsert(Subject(raw: ["id": .string(id), "name": .string(name)]), now: t)
    return d
}

private func names(_ d: AppDocument?) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (d?.alive(Subject.self) ?? []).map { ($0.id, $0.name) })
}

private func makeEngine(
    _ remote: FakeGitHub?,
    stored: StoredDocument? = nil,
    mode: SyncMode = .readWrite,
    store: LocalStore? = nil
) async throws -> (SyncEngine, LocalStore) {
    let store = try store ?? LocalStore.inMemory()
    // Jako v aplikaci: uložený dokument pochází z databáze.
    if let stored { try await store.save(stored) }
    return (SyncEngine(store: store, stored: stored, remote: remote, mode: mode, timing: fast), store)
}

private func failure(_ engine: SyncEngine) async -> SyncFailure? {
    if case .failed(let f, _) = await engine.state.status { f } else { nil }
}

@Suite("Synchronizace")
struct SyncEngineTests {
    // MARK: - Jen čtení

    @Test("Jen čtení: čerstvá instalace převezme data z GitHubu a nic nezapíše")
    func readOnlyFreshInstall() async throws {
        let remote = FakeGitHub(document: doc(("s1", "Anatomie", 1_000)))
        let (engine, store) = try await makeEngine(remote, mode: .readOnly)
        await engine.syncNow()
        await engine.settle()
        #expect(names(await engine.document) == ["s1": "Anatomie"])
        #expect(await remote.commits.isEmpty)
        let state = await engine.state
        #expect(state.dirty == false)
        guard case .synced = state.status else { Issue.record("stav \(state.status)"); return }
        let saved = try #require(try await store.load())
        #expect(saved.document == (try await remote.document))
        #expect(saved.remoteSha == "v1")
    }

    @Test("Jen čtení: lokální rozdíly se sloučí, ale na GitHub nikdy neodejdou")
    func readOnlyNeverPushes() async throws {
        let remote = FakeGitHub(document: doc(("s1", "Anatomie", 1_000)))
        let local = StoredDocument(document: doc(("s2", "Fyziologie", 2_000)), dirty: true, remoteSha: nil)
        let (engine, _) = try await makeEngine(remote, stored: local, mode: .readOnly)
        await engine.syncNow()
        await engine.localDidChange(adding(await engine.document, "s3", "Histologie", at: 3_000))
        await engine.settle()
        await engine.syncNow()
        #expect(names(await engine.document) == ["s1": "Anatomie", "s2": "Fyziologie", "s3": "Histologie"])
        #expect(await remote.commits.isEmpty)
        #expect(await engine.state.dirty)
    }

    // MARK: - Zápis

    @Test("Lokální změna se odešle jedním commitem a web pak soubor nepřepíše")
    func pushesLocalChange() async throws {
        let remote = FakeGitHub(document: doc(("s1", "Anatomie", 1_000)))
        let (engine, store) = try await makeEngine(remote)
        await engine.syncNow()
        await engine.localDidChange(adding(await engine.document, "s2", "Fyziologie", at: 2_000))
        await engine.settle()

        let commits = await remote.commits
        #expect(commits.count == 1)
        #expect(commits.first?.message.hasPrefix("Sync dat (Mac) · ") == true)
        let text = try #require(await remote.text)
        #expect(text == Merge.serialize(await engine.document))
        #expect(names(try await remote.document) == ["s1": "Anatomie", "s2": "Fyziologie"])
        // Web po stažení spočítá stejný text → nemá důvod zapisovat.
        #expect(Merge.serialize(try AppDocument(parsing: Data(text.utf8))) == text)
        #expect(await engine.state.dirty == false)
        #expect(try await store.load()?.dirty == false)
    }

    @Test("Bez změn žádný commit")
    func noCommitWithoutChanges() async throws {
        let remote = FakeGitHub(document: doc(("s1", "Anatomie", 1_000)))
        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        await engine.syncNow()
        #expect(await remote.commits.isEmpty)
        #expect(await remote.fetchCount == 2)
    }

    @Test("Chybějící soubor se vytvoří (jen při zápisu)", arguments: [SyncMode.readWrite, .readOnly])
    func createsMissingFile(mode: SyncMode) async throws {
        let remote = FakeGitHub()
        let local = StoredDocument(document: doc(("s1", "Anatomie", 1_000)), dirty: true, remoteSha: nil)
        let (engine, _) = try await makeEngine(remote, stored: local, mode: mode)
        await engine.syncNow()
        if mode == .readWrite {
            #expect(await remote.text == Merge.serialize(local.document))
            #expect(await remote.commits.count == 1)
        } else {
            #expect(await remote.text == nil)
        }
    }

    // MARK: - Souběh s webem

    @Test("Web zapíše mezi stažením a zápisem z Macu → sloučí se obojí")
    func conflictWithWeb() async throws {
        let base = doc(("s1", "Anatomie", 1_000))
        let remote = FakeGitHub(document: base)
        let web = adding(adding(base, "s1", "Anatomie II", at: 5_000), "s3", "Histologie", at: 5_000)
        await remote.webWritesBeforeNextPush(Merge.serialize(web))

        let local = StoredDocument(document: adding(base, "s2", "Fyziologie", at: 2_000), dirty: true, remoteSha: "v1")
        let (engine, _) = try await makeEngine(remote, stored: local)
        await engine.syncNow()

        #expect(names(try await remote.document) == ["s1": "Anatomie II", "s2": "Fyziologie", "s3": "Histologie"])
        #expect(names(await engine.document) == names(try await remote.document))
        #expect(await remote.commits.count == 1)
        #expect(await remote.fetchCount == 2)
        #expect(await engine.state.dirty == false)
    }

    @Test("Po 4 konfliktech to vzdá, lokální změny zůstanou")
    func conflictGivesUp() async throws {
        let base = doc(("s1", "Anatomie", 1_000))
        let remote = FakeGitHub(document: base)
        for i in 1...4 { await remote.webWritesBeforeNextPush(Merge.serialize(adding(base, "w\(i)", "Web \(i)", at: 1_000 + i))) }
        let local = StoredDocument(document: adding(base, "s2", "Fyziologie", at: 2_000), dirty: true, remoteSha: "v1")
        let (engine, store) = try await makeEngine(remote, stored: local)
        await engine.syncNow()

        #expect(await failure(engine) == .github(.conflict(status: 409)))
        #expect(await remote.fetchCount == 4)
        #expect(await remote.commits.isEmpty)
        #expect(names(await engine.document)["s2"] == "Fyziologie")
        #expect(await engine.state.dirty)
        await engine.settle()
        #expect(names(try await store.load()?.document)["s2"] == "Fyziologie")
    }

    @Test("Změny z obou stran během opakovaných synchronizací se nikdy neztratí")
    func interleavedEdits() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        for i in 0..<10 {
            let webDoc = adding(try await remote.document!, "web\(i)", "W", at: 10_000 + i)
            await remote.webWrite(Merge.serialize(webDoc))
            await engine.localDidChange(adding(await engine.document, "mac\(i)", "M", at: 20_000 + i))
            await engine.syncNow()
        }
        await engine.settle()
        let final = names(try await remote.document)
        #expect(final.count == 21)
        #expect(final == names(await engine.document))
    }

    // MARK: - Chyby

    @Test("Výpadek sítě: změny zůstanou a odešlou se po návratu sítě")
    func offline() async throws {
        let remote = FakeGitHub(document: doc(("s1", "Anatomie", 1_000)))
        await remote.failNextFetches(.network(code: URLError.Code.notConnectedToInternet.rawValue))
        let local = StoredDocument(document: doc(("s1", "Anatomie", 1_000), ("s2", "Fyziologie", 2_000)), dirty: true, remoteSha: "v1")
        let (engine, _) = try await makeEngine(remote, stored: local)
        await engine.syncNow()

        let f = await failure(engine)
        #expect(f == .github(.network(code: URLError.Code.notConnectedToInternet.rawValue)))
        #expect(f?.isTransient == true)
        #expect(await engine.state.dirty)
        #expect(await remote.commits.isEmpty)

        await engine.networkAvailabilityChanged(true)
        #expect(names(try await remote.document) == ["s1": "Anatomie", "s2": "Fyziologie"])
        #expect(await engine.state.dirty == false)
    }

    @Test("Data z novější verze se nikdy nepřepíšou")
    func tooNewSchema() async throws {
        let newer = #"{"schemaVersion":2,"subjects":[],"settings":{"updatedAt":1}}"#
        let remote = FakeGitHub(text: newer)
        let local = StoredDocument(document: doc(("s1", "Anatomie", 1_000)), dirty: true, remoteSha: nil)
        let (engine, _) = try await makeEngine(remote, stored: local)
        await engine.syncNow()
        #expect(await failure(engine) == .schemaTooNew(version: 2))
        #expect(await remote.text == newer)
        #expect(await remote.commits.isEmpty)
        #expect(names(await engine.document) == ["s1": "Anatomie"])
    }

    @Test("Nečitelný soubor na GitHubu se nikdy nepřepíše")
    func unreadableRemote() async throws {
        let broken = "{\"schemaVersion\":1,\"subjects\":[" // useknutý soubor
        let remote = FakeGitHub(text: broken)
        let local = StoredDocument(document: doc(("s1", "Anatomie", 1_000)), dirty: true, remoteSha: nil)
        let (engine, _) = try await makeEngine(remote, stored: local)
        await engine.syncNow()
        #expect(await failure(engine) == .unreadableRemote)
        #expect(await remote.text == broken)
        #expect(await remote.commits.isEmpty)
    }

    @Test("Neplatný token se ukáže jako chyba")
    func unauthorized() async throws {
        let remote = FakeGitHub(document: .empty)
        await remote.failNextFetches(.unauthorized)
        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        #expect(await failure(engine) == .github(.unauthorized))
        #expect(await failure(engine)?.localizedDescription == "Neplatný token.")
    }

    // MARK: - Dopředná kompatibilita a čerstvá instalace

    @Test("Čerstvá instalace převezme nastavení z GitHubu i s updatedAt 0")
    func freshInstallAdoptsSettings() async throws {
        var raw = AppDocument.empty.raw
        var settings = raw.object("settings")!
        settings["theme"] = "light"
        settings["zBudoucnosti"] = true
        raw["settings"] = .object(settings)
        let remoteDoc = try AppDocument(normalizing: .object(raw))
        let remote = FakeGitHub(document: remoteDoc)
        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        #expect(await engine.document.settings.raw.string("theme") == "light")
        #expect(await engine.document.settings.raw.bool("zBudoucnosti") == true)
        #expect(await remote.commits.isEmpty)
    }

    @Test("Pole a kolekce z novější verze webu přežijí zápis z Macu")
    func unknownDataSurvives() async throws {
        var raw = doc(("s1", "Anatomie", 1_000)).raw
        var subjects = raw.array("subjects")!
        var s1 = subjects[0].objectValue!
        s1["zBudoucnosti"] = ["x": 1]
        subjects[0] = .object(s1)
        raw["subjects"] = .array(subjects)
        raw["budouciKolekce"] = [["id": "b1", "createdAt": 1, "updatedAt": 1, "v": "ahoj"]]
        raw["budouciHodnota"] = 42
        let remote = FakeGitHub(document: try AppDocument(normalizing: .object(raw)))

        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        await engine.localDidChange(adding(await engine.document, "s2", "Fyziologie", at: 2_000))
        await engine.settle()

        let pushed = try #require(try await remote.document).raw
        #expect(pushed.array("subjects")?.first?.objectValue?["zBudoucnosti"] == ["x": 1])
        #expect(pushed["budouciKolekce"] == raw["budouciKolekce"])
        #expect(pushed["budouciHodnota"] == 42)
        #expect(await remote.commits.count == 1)
    }

    // MARK: - Plánování

    @Test("Rychlé změny po sobě = jeden commit")
    func coalescesRapidChanges() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let (engine, _) = try await makeEngine(remote)
        await engine.syncNow()
        for i in 0..<5 {
            await engine.localDidChange(adding(await engine.document, "n\(i)", "N", at: 2_000 + i))
        }
        await engine.settle()
        #expect(await remote.commits.count == 1)
        #expect(names(try await remote.document).count == 6)
    }

    @Test("Souběžné spuštění synchronizace neudělá zbytečné commity")
    func concurrentSyncNow() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let local = StoredDocument(document: doc(("s1", "A", 1_000), ("s2", "B", 2_000)), dirty: true, remoteSha: "v1")
        let (engine, _) = try await makeEngine(remote, stored: local)
        async let a: Void = engine.syncNow()
        async let b: Void = engine.syncNow()
        async let c: Void = engine.syncNow()
        _ = await (a, b, c)
        await engine.settle()
        #expect(await remote.commits.count == 1)
        #expect(await remote.fetchCount <= 2)
    }

    @Test("Změny doručené v obráceném pořadí neztratí novější úpravu")
    func outOfOrderChanges() async throws {
        let (engine, _) = try await makeEngine(nil, stored: StoredDocument(document: doc(("s1", "A", 1_000)), dirty: false, remoteSha: nil))
        let older = adding(await engine.document, "s1", "Starší", at: 2_000)
        let newer = adding(await engine.document, "s1", "Novější", at: 3_000)
        await engine.localDidChange(newer)
        await engine.localDidChange(older)
        #expect(names(await engine.document)["s1"] == "Novější")
    }

    @Test("Data se uloží na Mac a po restartu načtou")
    func persistsAndReopens() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let (engine, store) = try await makeEngine(remote)
        await engine.syncNow()
        await engine.localDidChange(adding(await engine.document, "s2", "B", at: 2_000))
        await engine.settle()

        let reopened = try await SyncEngine.open(store: store, remote: remote, mode: .readWrite, timing: fast)
        #expect(await reopened.document == (await engine.document))
        #expect(await reopened.state.dirty == false)
        await reopened.syncNow()
        #expect(await remote.commits.count == 1)
    }

    @Test("Ukončení aplikace odešle neodeslané změny")
    func terminationFlushes() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let timing = SyncEngine.Timing(debounce: .seconds(3600), interval: .seconds(3600), persistDelay: .seconds(3600))
        let store = try LocalStore.inMemory()
        let engine = SyncEngine(store: store, stored: nil, remote: remote, mode: .readWrite, timing: timing)
        await engine.syncNow()
        await engine.localDidChange(adding(await engine.document, "s2", "B", at: 2_000))
        await engine.prepareForTermination()
        #expect(names(try await remote.document) == ["s1": "A", "s2": "B"])
        #expect(names(try await store.load()?.document) == ["s1": "A", "s2": "B"])
    }

    @Test("Odpojení zastaví synchronizaci, data zůstanou na Macu")
    func disconnect() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let (engine, store) = try await makeEngine(remote)
        await engine.syncNow()
        await engine.configure(remote: nil, mode: .readWrite)
        await engine.localDidChange(adding(await engine.document, "s2", "B", at: 2_000))
        await engine.settle()
        await engine.syncNow()
        #expect(await engine.state.status == .off)
        #expect(await remote.fetchCount == 1)
        #expect(names(try await store.load()?.document) == ["s1": "A", "s2": "B"])
    }

    @Test("Změny z GitHubu přijdou aplikaci přes updates")
    func updatesStream() async throws {
        let remote = FakeGitHub(document: doc(("s1", "A", 1_000)))
        let (engine, _) = try await makeEngine(remote, mode: .readOnly)
        let collector = Task { () -> AppDocument? in
            for await update in engine.updates {
                if case .document(let d) = update { return d }
            }
            return nil
        }
        await engine.syncNow()
        let received = await collector.value
        #expect(names(received) == ["s1": "A"])
    }

    @Test("Zpráva commitu jako na webu, s označením Macu")
    func commitMessage() {
        let tz = TimeZone(identifier: "Europe/Prague")!
        var c = DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 5, second: 3)
        c.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: c)!
        #expect(SyncEngine.commitMessage(at: date, timeZone: tz) == "Sync dat (Mac) · 17. 10. 2026 9:05:03")
    }
}

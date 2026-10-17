import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

private func sampleDocument() -> AppDocument {
    var doc = AppDocument.empty
    // Pole „zBudoucnosti“ tahle verze nezná – musí přežít uložení i se svým místem.
    doc.upsert(Subject(raw: ["id": "s1", "name": "Anatomie", "zBudoucnosti": ["a": 1], "color": "#7a5c3e"]), now: 1_700_000_000_000)
    doc.upsert(Subject(raw: ["id": "s2", "name": "Fyziologie – žluťoučký kůň"]), now: 1_700_000_000_500)
    doc.remove(.subjects, id: "s2", now: 1_700_000_001_000)
    return doc
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "st-tests-\(UUID().uuidString)/data.sqlite")
}

@Suite("Lokální úložiště")
struct LocalStoreTests {
    @Test("Prázdná databáze nemá dokument")
    func emptyStore() async throws {
        let store = try LocalStore.inMemory()
        #expect(try await store.load() == nil)
    }

    @Test("Uložení a načtení zachová dokument bajtově stejně")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        let doc = sampleDocument()
        let saved = StoredDocument(document: doc, dirty: true, remoteSha: "abc", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(saved)
        let loaded = try #require(try await store.load())
        #expect(loaded == saved)
        #expect(Merge.serialize(loaded.document) == Merge.serialize(doc))
        #expect(loaded.document.rawRecords(.subjects)[0].keys.contains("zBudoucnosti"))
    }

    @Test("Další uložení přepíše jediný řádek")
    func overwrite() async throws {
        let store = try LocalStore.inMemory()
        try await store.save(StoredDocument(document: .empty, dirty: true, remoteSha: nil))
        try await store.save(StoredDocument(document: sampleDocument(), dirty: false, remoteSha: "s2"))
        let loaded = try #require(try await store.load())
        #expect(loaded.dirty == false && loaded.remoteSha == "s2")
        #expect(loaded.document == sampleDocument())
        let rows = try await store.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM document") }
        #expect(rows == 1)
    }

    @Test("Data přežijí restart aplikace (soubor, WAL)")
    func survivesRestart() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try LocalStore(at: url)
            try await store.save(StoredDocument(document: sampleDocument(), dirty: true, remoteSha: "r1"))
            let mode = try await store.db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
        let reopened = try LocalStore(at: url)
        let loaded = try #require(try await reopened.load())
        #expect(loaded.document == sampleDocument())
        #expect(loaded.dirty && loaded.remoteSha == "r1")
    }

    @Test("Data z novější verze se nenačtou jako aktuální")
    func tooNewSchema() async throws {
        let store = try LocalStore.inMemory()
        try await store.db.write { db in
            try db.execute(
                sql: "INSERT INTO document (id, json, dirty, savedAt) VALUES (1, ?, 0, ?)",
                arguments: [#"{"schemaVersion":2,"subjects":[]}"#, Date.now]
            )
        }
        await #expect(throws: SchemaError.tooNew(version: 2)) { try await store.load() }
    }

    @Test("Zálohy: nejnovější první, nad limit se mažou nejstarší")
    func snapshots() async throws {
        let store = try LocalStore.inMemory()
        for i in 1...5 {
            var doc = AppDocument.empty
            doc.upsert(Subject(raw: ["id": .string("s\(i)"), "name": .string("P\(i)")]), now: i)
            try await store.snapshot(doc, reason: "z\(i)", keep: 3)
        }
        let list = try await store.snapshots()
        #expect(list.map(\.reason) == ["z5", "z4", "z3"])
        #expect(list.allSatisfy { $0.bytes > 0 })
        let restored = try #require(try await store.snapshotDocument(id: list[0].id))
        #expect(restored.alive(Subject.self).map(\.id) == ["s5"])
    }
}

@Suite("Tajné údaje")
struct SecretStoreTests {
    @Test("Paměťové úložiště")
    func inMemory() throws {
        let store = InMemorySecretStore()
        #expect(try store.secret(for: "github") == nil)
        try store.setSecret("t1", for: "github")
        try store.setSecret("t2", for: "github")
        #expect(try store.secret(for: "github") == "t2")
        try store.setSecret(nil, for: "github")
        #expect(try store.secret(for: "github") == nil)
    }

    /// Sahá na skutečnou Klíčenku (zvláštní služba, na konci se smaže), proto jen na vyžádání.
    @Test("Klíčenka macOS", .enabled(if: ProcessInfo.processInfo.environment["ST_KEYCHAIN_TESTS"] == "1"))
    func keychain() throws {
        let store = KeychainStore(service: "cz.rawzuu.studytracker.tests.\(UUID().uuidString)")
        defer { try? store.setSecret(nil, for: "github") }
        #expect(try store.secret(for: "github") == nil)
        try store.setSecret("github_pat_první", for: "github")
        #expect(try store.secret(for: "github") == "github_pat_první")
        try store.setSecret("github_pat_druhý", for: "github")
        #expect(try store.secret(for: "github") == "github_pat_druhý")
        try store.setSecret(nil, for: "github")
        #expect(try store.secret(for: "github") == nil)
        try store.setSecret(nil, for: "github")  // smazání neexistujícího není chyba
    }
}

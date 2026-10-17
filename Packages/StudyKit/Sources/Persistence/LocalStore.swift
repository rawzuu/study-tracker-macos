import Core
import Foundation
import GRDB

/// Dokument uložený na Macu a jeho vztah k verzi na GitHubu.
public struct StoredDocument: Sendable, Hashable {
    public var document: AppDocument
    /// Na Macu jsou změny, které ještě nejsou na GitHubu.
    public var dirty: Bool
    /// `sha` verze na GitHubu, se kterou byl dokument naposledy sloučený.
    public var remoteSha: String?
    public var savedAt: Date

    public init(document: AppDocument, dirty: Bool, remoteSha: String?, savedAt: Date = .now) {
        self.document = document
        self.dirty = dirty
        self.remoteSha = remoteSha
        self.savedAt = savedAt
    }
}

/// Záloha dokumentu na Macu (např. před migrací) – poslední záchrana, kdyby se něco pokazilo.
public struct SnapshotInfo: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var reason: String
    public var bytes: Int
}

/// Lokální kopie dat v SQLite (GRDB). Všechny operace jsou asynchronní a neblokují hlavní vlákno.
///
/// Dokument má jen desítky kB, proto se ukládá vcelku jedním zápisem – je to atomické
/// (buď celý nový, nebo celý starý) a WAL zápis nezdržuje čtení. JSON se ukládá kompaktně
/// se zachovaným pořadím klíčů, takže se po načtení zapíše na GitHub bajtově stejně.
public final class LocalStore: Sendable {
    let db: DatabaseQueue

    /// Otevře (nebo vytvoří) databázi v souboru.
    public convenience init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.label = "StudyTracker"
        try self.init(DatabaseQueue(path: url.path, configuration: config))
    }

    /// Databáze jen v paměti – pro testy a náhledy.
    public static func inMemory() throws -> LocalStore {
        try LocalStore(DatabaseQueue())
    }

    private init(_ db: DatabaseQueue) throws {
        self.db = db
        try Self.migrator.migrate(db)
    }

    /// Výchozí umístění: `~/Library/Containers/<app>/Data/Library/Application Support/StudyTracker/data.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "StudyTracker/data.sqlite", directoryHint: .notDirectory)
    }

    // MARK: - Dokument

    /// Načte uložený dokument. Starší data převede na aktuální verzi a předtím je zálohuje.
    public func load() async throws -> StoredDocument? {
        try await db.write { db in
            guard let row = try DocumentRow.fetchOne(db, key: 1) else { return nil }
            let value = try JSONValue.parse(row.json)
            let version = value.objectValue?.number("schemaVersion").map(Int.init) ?? 1
            if version < Schema.version {
                try Self.insertSnapshot(db, json: row.json, reason: "před migrací z verze \(version)", keep: Self.defaultKeep)
            }
            return StoredDocument(
                document: try AppDocument(normalizing: value),
                dirty: row.dirty,
                remoteSha: row.remoteSha,
                savedAt: row.savedAt
            )
        }
    }

    public func save(_ stored: StoredDocument) async throws {
        let row = DocumentRow(stored)
        try await db.write { db in try row.save(db) }
    }

    // MARK: - Zálohy

    public static let defaultKeep = 50

    /// Uloží zálohu dokumentu; nejstarší nad limit `keep` smaže.
    public func snapshot(_ document: AppDocument, reason: String, keep: Int = defaultKeep) async throws {
        let json = JSONValue.object(document.raw).serialized()
        try await db.write { db in try Self.insertSnapshot(db, json: json, reason: reason, keep: keep) }
    }

    public func snapshots() async throws -> [SnapshotInfo] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, createdAt, reason, length(CAST(json AS BLOB)) AS bytes FROM snapshot ORDER BY id DESC")
                .map { SnapshotInfo(id: $0["id"], createdAt: $0["createdAt"], reason: $0["reason"], bytes: $0["bytes"]) }
        }
    }

    public func snapshotDocument(id: Int64) async throws -> AppDocument? {
        let json = try await db.read { db in try String.fetchOne(db, sql: "SELECT json FROM snapshot WHERE id = ?", arguments: [id]) }
        return try json.map { try AppDocument(normalizing: JSONValue.parse($0)) }
    }

    private static func insertSnapshot(_ db: Database, json: String, reason: String, keep: Int) throws {
        try db.execute(sql: "INSERT INTO snapshot (createdAt, reason, json) VALUES (?, ?, ?)", arguments: [Date.now, reason, json])
        try db.execute(sql: "DELETE FROM snapshot WHERE id NOT IN (SELECT id FROM snapshot ORDER BY id DESC LIMIT ?)", arguments: [keep])
    }

    // MARK: - Schéma databáze

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "document") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("json", .text).notNull()
                t.column("dirty", .boolean).notNull()
                t.column("remoteSha", .text)
                t.column("savedAt", .datetime).notNull()
            }
            try db.create(table: "snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("reason", .text).notNull()
                t.column("json", .text).notNull()
            }
        }
        return m
    }
}

private struct DocumentRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "document"
    var id: Int64 = 1
    var json: String
    var dirty: Bool
    var remoteSha: String?
    var savedAt: Date

    init(_ s: StoredDocument) {
        json = JSONValue.object(s.document.raw).serialized()
        dirty = s.dirty
        remoteSha = s.remoteSha
        savedAt = s.savedAt
    }
}

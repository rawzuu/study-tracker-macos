import Engine
import Focus
import Foundation
import GRDB

/// Událost Soustředění: pokus otevřít zakázané, odemknutí, nebo zásah do blokování (porušení).
public struct FocusEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case attempt, unlock, tamper
    }

    public var at: Int
    public var kind: Kind
    public var target: FocusTarget?
    /// Název aplikace nebo doména.
    public var name: String
    public var listIds: [String]
    /// Odemknutí: do kdy platí.
    public var until: Int?
    /// Porušení: co se stalo („Rozšíření Safari je vypnuté“).
    public var detail: String

    public init(at: Int, kind: Kind, target: FocusTarget?, name: String, listIds: [String] = [], until: Int? = nil, detail: String = "") {
        self.at = at
        self.kind = kind
        self.target = target
        self.name = name
        self.listIds = listIds
        self.until = until
        self.detail = detail
    }
}

/// Čas v aplikaci (a doméně) za jednu hodinu jednoho dne.
public struct UsageRow: Sendable, Equatable {
    public var day: String
    public var hour: Int
    public var bundleId: String
    public var appName: String
    public var host: String
    public var ms: Int
}

/// Databáze Soustředění ve sdíleném kontejneru: měření, události a přísné závazky. Zapisuje do ní
/// hlavně Strážce, aplikace čte (statistiky). Dva procesy nad jedním souborem: WAL a čekání na zámek.
public final class FocusStore: Sendable {
    let db: any DatabaseWriter

    public convenience init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "Focus"
        config.busyMode = .timeout(5)
        try self.init(DatabasePool(path: url.path, configuration: config))
    }

    public static func inMemory() throws -> FocusStore {
        try FocusStore(DatabaseQueue())
    }

    private init(_ db: any DatabaseWriter) throws {
        self.db = db
        try Self.migrator.migrate(db)
    }

    // MARK: - Měření

    /// Přičte úseky po hodinách.
    public func add(_ segments: [UsageSegment], clock: StudyClock) async throws {
        let rows = segments.flatMap { s in s.byHour(clock: clock).map { (s.activity, $0) } }
        guard !rows.isEmpty else { return }
        try await db.write { db in
            for (activity, part) in rows {
                try db.execute(sql: """
                    INSERT INTO usage (day, hour, bundleId, host, appName, ms) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (day, hour, bundleId, host) DO UPDATE SET ms = ms + excluded.ms, appName = excluded.appName
                    """, arguments: [part.day, part.hour, activity.bundleId, activity.host, activity.appName, part.ms])
            }
        }
    }

    /// Měření ve dnech `from`…`to` (klíče `YYYY-MM-DD` včetně).
    public func usage(fromDay from: String, toDay to: String) async throws -> [UsageRow] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM usage WHERE day >= ? AND day <= ? ORDER BY day, hour",
                             arguments: [from, to]).map {
                UsageRow(day: $0["day"], hour: $0["hour"], bundleId: $0["bundleId"], appName: $0["appName"], host: $0["host"], ms: $0["ms"])
            }
        }
    }

    // MARK: - Události

    public func record(_ event: FocusEvent) async throws {
        let listIds = String(decoding: try JSONEncoder().encode(event.listIds), as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO event (at, kind, target, name, listIds, until, detail) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           arguments: [event.at, event.kind.rawValue, event.target?.key ?? "", event.name, listIds, event.until, event.detail])
        }
    }

    /// Události v intervalu `[from, to)` podle času.
    public func events(from: Int, to: Int) async throws -> [FocusEvent] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM event WHERE at >= ? AND at < ? ORDER BY at, id", arguments: [from, to]).map(Self.event)
        }
    }

    /// Kolikrát se dnes (od `since`) zkoušelo otevřít totéž – „dnes už 7.“
    public func attemptCount(_ target: FocusTarget, since: Int) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE kind = 'attempt' AND target = ? AND at >= ?",
                             arguments: [target.key, since]) ?? 0
        }
    }

    /// Pokusy od `since` podle cíle (`FocusTarget.key`).
    public func attemptCounts(since: Int) async throws -> [String: Int] {
        try await db.read { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT target, COUNT(*) AS n FROM event WHERE kind = 'attempt' AND at >= ? GROUP BY target",
                                        arguments: [since]) {
                out[row["target"]] = row["n"]
            }
            return out
        }
    }

    /// Dnešní součty po aplikacích a doménách (denní limity).
    public func totals(day: String) async throws -> [UsageTotal] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT bundleId, host, SUM(ms) AS ms FROM usage WHERE day = ? GROUP BY bundleId, host", arguments: [day])
                .map { UsageTotal(bundleId: $0["bundleId"], host: $0["host"], ms: $0["ms"]) }
        }
    }

    /// Odemknutí, která ještě platí.
    public func activeExceptions(now: Int) async throws -> [FocusException] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT target, until FROM event WHERE kind = 'unlock' AND until > ?", arguments: [now]).compactMap { row in
                let key: String = row["target"]
                return FocusTarget(key: key).map { FocusException(target: $0, until: row["until"]) }
            }
        }
    }

    /// Seznamy u odemknutí od `since` (týdenní limit).
    public func unlockLists(since: Int) async throws -> [[String]] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT listIds FROM event WHERE kind = 'unlock' AND at >= ?", arguments: [since])
                .map { (try? JSONDecoder().decode([String].self, from: Data($0.utf8))) ?? [] }
        }
    }

    // MARK: - Přísné závazky

    public func commitments(now: Int) async throws -> [Commitment] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM commitment WHERE until > ? ORDER BY until", arguments: [now])
                .compactMap { try? JSONDecoder().decode(Commitment.self, from: Data($0.utf8)) }
        }
    }

    public func save(_ commitments: [Commitment]) async throws {
        guard !commitments.isEmpty else { return }
        let rows = try commitments.map { ($0.id, $0.until, String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) }
        try await db.write { db in
            for (id, until, json) in rows {
                try db.execute(sql: "INSERT OR IGNORE INTO commitment (id, until, json) VALUES (?, ?, ?)", arguments: [id, until, json])
            }
        }
    }

    // MARK: - Úklid

    /// Smaže měření a události starší než `keepDays` dní a doběhlé závazky.
    public func prune(keepDays: Int, now: Int, clock: StudyClock) async throws {
        let cutoff = clock.addDays(clock.startOfDay(now), -max(1, keepDays))
        let day = clock.dayKey(cutoff)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM usage WHERE day < ?", arguments: [day])
            try db.execute(sql: "DELETE FROM event WHERE at < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM commitment WHERE until < ?", arguments: [now])
        }
    }

    /// Smaže celou historii (měření a události). Závazky zůstanou – smazání historie zámek nezruší.
    public func deleteHistory() async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM usage")
            try db.execute(sql: "DELETE FROM event")
        }
    }

    // MARK: - Schéma

    private static func event(_ row: Row) -> FocusEvent {
        let key: String = row["target"]
        let lists: String = row["listIds"]
        return FocusEvent(at: row["at"], kind: FocusEvent.Kind(rawValue: row["kind"]) ?? .attempt, target: FocusTarget(key: key),
                          name: row["name"], listIds: (try? JSONDecoder().decode([String].self, from: Data(lists.utf8))) ?? [],
                          until: row["until"], detail: row["detail"])
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "usage") { t in
                t.column("day", .text).notNull()
                t.column("hour", .integer).notNull()
                t.column("bundleId", .text).notNull()
                t.column("host", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("ms", .integer).notNull()
                t.primaryKey(["day", "hour", "bundleId", "host"])
            }
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .integer).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("target", .text).notNull()
                t.column("name", .text).notNull()
                t.column("listIds", .text).notNull()
                t.column("until", .integer)
                t.column("detail", .text).notNull()
            }
            try db.create(table: "commitment") { t in
                t.primaryKey("id", .text)
                t.column("until", .integer).notNull()
                t.column("json", .text).notNull()
            }
        }
        return m
    }
}

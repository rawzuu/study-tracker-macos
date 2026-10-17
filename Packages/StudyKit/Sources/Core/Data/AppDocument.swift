import Foundation

/// Celý obsah `data.json` – neměnná hodnota, kterou lze bezpečně předávat mezi actory.
///
/// Drží původní JSON včetně polí, která tahle verze nezná, takže zápis nikdy nic neztratí.
/// Typované pohledy (`records(Session.self)`, `settings`) se čtou z něj.
public struct AppDocument: Sendable, Hashable {
    public private(set) var raw: JSONObject

    /// Prázdná data (`emptyData()` na webu).
    public static var empty: AppDocument {
        var raw: JSONObject = ["schemaVersion": .number(Double(Schema.version))]
        for key in CollectionKey.allCases { raw[key.rawValue] = .array([]) }
        raw["settings"] = .object(Schema.defaultSettings)
        return AppDocument(trusted: raw)
    }

    /// Převede libovolná (i starší nebo neúplná) data na aktuální verzi – jako `migrate()` na webu.
    /// Nic nemaže; chybějící kolekce a nastavení doplní výchozími hodnotami.
    public init(normalizing input: JSONValue) throws(SchemaError) {
        var d = input.objectValue ?? JSONObject()
        var v = d.number("schemaVersion").map { Int($0) } ?? 1
        if v > Schema.version { throw .tooNew(version: v) }
        while v < Schema.version {
            guard let step = Migrations.steps[v] else { throw .missingMigration(from: v) }
            d = step(d)
            v = d.int("schemaVersion") ?? v + 1
        }
        self.raw = Migrations.normalize(d)
    }

    public init(parsing data: Data) throws {
        try self.init(normalizing: JSONValue.parse(data))
    }

    init(trusted raw: JSONObject) {
        self.raw = raw
    }

    public var schemaVersion: Int { raw.int("schemaVersion") ?? Schema.version }

    // MARK: - Čtení

    public func rawRecords(_ key: CollectionKey) -> [JSONObject] {
        (raw.array(key.rawValue) ?? []).compactMap(\.objectValue)
    }

    /// Všechny záznamy kolekce včetně smazaných.
    public func records<R: EntityRecord>(_ type: R.Type) -> [R] {
        rawRecords(R.collection).map(R.init(raw:))
    }

    /// Jen nesmazané záznamy (`alive()` na webu).
    public func alive<R: EntityRecord>(_ type: R.Type) -> [R] {
        records(type).filter { !$0.isDeleted }
    }

    public func record<R: EntityRecord>(_ type: R.Type, id: String) -> R? {
        rawRecords(R.collection).first { $0.string("id") == id }.map(R.init(raw:))
    }

    public var settings: Settings { Settings(raw: raw.object("settings") ?? Schema.defaultSettings) }

    // MARK: - Zápis (stejná pravidla jako `store.tsx` na webu)

    /// Vloží nebo upraví záznamy. `createdAt` zůstává z existujícího záznamu, `updatedAt` = `now`.
    /// Úprava se do existujícího záznamu „rozlije“ (`{ ...existující, ...nový }`), neznámá pole zůstanou.
    public mutating func upsert<R: EntityRecord>(_ items: [R], now: Int) {
        var list = raw.array(R.collection.rawValue) ?? []
        for item in items {
            let id = item.id
            let index = list.firstIndex { $0.objectValue?.string("id") == id }
            let existing = index.flatMap { list[$0].objectValue }
            var stamped = item.raw
            // `existing?.createdAt ?? item.createdAt ?? now` – `null` se v JS bere jako chybějící hodnota
            stamped["createdAt"] = existing?["createdAt"].nonNull ?? item.raw["createdAt"].nonNull ?? .number(Double(now))
            stamped["updatedAt"] = .number(Double(now))
            if let index, let existing {
                list[index] = .object(existing.spreading(stamped))
            } else {
                list.append(.object(stamped))
            }
        }
        raw[R.collection.rawValue] = .array(list)
    }

    public mutating func upsert<R: EntityRecord>(_ item: R, now: Int) {
        upsert([item], now: now)
    }

    /// Měkké smazání – záznam zůstane s `deletedAt`, aby se smazání dostalo i na ostatní zařízení.
    public mutating func remove(_ key: CollectionKey, id: String, now: Int) {
        modifyRecords(key) { o in
            guard o.string("id") == id else { return }
            o["deletedAt"] = .number(Double(now))
            o["updatedAt"] = .number(Double(now))
        }
    }

    /// Úprava záznamů kolekce na místě (`d[key].map(...)` na webu): `change` dostane každý záznam
    /// a může ho změnit. Pořadí záznamů i jejich klíčů zůstává, razítka nastavuje `change` sám.
    public mutating func modifyRecords(_ key: CollectionKey, _ change: (inout JSONObject) -> Void) {
        guard var list = raw.array(key.rawValue) else { return }
        for i in list.indices {
            guard var o = list[i].objectValue else { continue }
            change(&o)
            list[i] = .object(o)
        }
        raw[key.rawValue] = .array(list)
    }

    /// Úprava nastavení; `updatedAt` nastavení se posune na `now`.
    public mutating func updateSettings(now: Int, _ change: (inout Settings) -> Void) {
        var s = settings
        change(&s)
        var o = s.raw
        o["updatedAt"] = .number(Double(now))
        raw["settings"] = .object(o)
    }
}

extension Optional<JSONValue> {
    /// Hodnota, pokud existuje a není `null` (operátor `??` v JS).
    var nonNull: JSONValue? {
        if case .some(let v) = self, !v.isNull { return v }
        return nil
    }
}

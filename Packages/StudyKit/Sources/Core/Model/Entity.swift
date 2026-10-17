import Foundation

/// Typovaný pohled na objekt JSON. Čte a zapisuje přímo do `raw`, takže pole, o kterých
/// pohled neví, zůstávají beze změny a na svém místě.
public protocol JSONLens: Sendable, Hashable {
    var raw: JSONObject { get set }
    init(raw: JSONObject)
}

/// Záznam synchronizované kolekce: `id`, `createdAt`, `updatedAt` (ms), volitelně `deletedAt`.
public protocol EntityRecord: JSONLens, Identifiable where ID == String {
    static var collection: CollectionKey { get }
}

extension EntityRecord {
    public var id: String {
        get { raw.string("id") ?? "" }
        set { raw["id"] = .string(newValue) }
    }
    public var createdAt: Int { raw.int("createdAt") ?? 0 }
    public var updatedAt: Int { raw.int("updatedAt") ?? 0 }
    public var deletedAt: Int? { raw.int("deletedAt") }
    public var isDeleted: Bool {
        // JS: `!e.deletedAt` – 0 i chybějící hodnota znamenají „nesmazáno“
        guard let d = raw.number("deletedAt") else { return false }
        return d != 0
    }

    /// Nový záznam s náhodným id ve stejném tvaru jako `crypto.randomUUID()` na webu.
    public static func newID() -> String { UUID().uuidString.lowercased() }
}

// MARK: - Zápis polí

extension JSONObject {
    mutating func set(_ key: String, _ value: String) { self[key] = .string(value) }
    mutating func set(_ key: String, _ value: Bool) { self[key] = .bool(value) }
    mutating func set(_ key: String, _ value: Int) { self[key] = .number(Double(value)) }
    mutating func set(_ key: String, _ value: Double) { self[key] = .number(value) }
    mutating func set(_ key: String, _ value: Int?) { self[key] = value.map { .number(Double($0)) } }
    mutating func set(_ key: String, _ value: String?) { self[key] = value.map { .string($0) } }
    mutating func set<L: JSONLens>(_ key: String, _ value: L?) { self[key] = value.map { .object($0.raw) } }
    mutating func set<L: JSONLens>(_ key: String, _ value: [L]) { self[key] = .array(value.map { .object($0.raw) }) }
    mutating func set(_ key: String, _ value: [String]) { self[key] = .array(value.map { .string($0) }) }
    mutating func set(_ key: String, _ value: [String: String]) {
        var o = self.object(key) ?? JSONObject()
        for k in o.keys where value[k] == nil { o[k] = nil }
        for (k, v) in value.sorted(by: { $0.key < $1.key }) where o.string(k) != v { o[k] = .string(v) }
        self[key] = .object(o)
    }

    func lens<L: JSONLens>(_ key: String) -> L? { object(key).map(L.init(raw:)) }
    func lenses<L: JSONLens>(_ key: String) -> [L] { (array(key) ?? []).compactMap(\.objectValue).map(L.init(raw:)) }
    func strings(_ key: String) -> [String] { (array(key) ?? []).compactMap(\.stringValue) }
    func stringMap(_ key: String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in object(key) ?? JSONObject() { if let s = v.stringValue { out[k] = s } }
        return out
    }
}

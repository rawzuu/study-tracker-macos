/// Objekt JSON, který řadí klíče přesně jako JavaScript.
///
/// Pořadí klíčů v JS: nejdřív klíče, které vypadají jako index pole („0“, „12“), vzestupně podle čísla,
/// potom ostatní v pořadí vložení. Přepsání existujícího klíče jeho pozici nemění.
/// Díky tomu zapíšeme `data.json` ve stejném tvaru jako web a ten nemá důvod soubor přepisovat.
///
/// Rovnost (`==`) pořadí klíčů nebere v úvahu – dva objekty se stejným obsahem jsou si rovny.
public struct JSONObject: Sendable {
    private var storage: [String: JSONValue] = [:]
    private var indexKeys: [String] = []  // seřazené podle číselné hodnoty
    private var namedKeys: [String] = []  // v pořadí vložení

    public init() {}

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Klíče v pořadí, v jakém je vrací `Object.keys` v JS.
    public var keys: [String] { indexKeys.isEmpty ? namedKeys : indexKeys + namedKeys }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    /// Přiřazení `nil` klíč odstraní (jako `delete` v JS). Hodnota `null` se zapisuje jako `.null`.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { insertKey(key) }
            } else if storage.removeValue(forKey: key) != nil {
                removeKey(key)
            }
        }
    }

    /// `{ ...self, ...other }` – klíče z `other` přepíšou hodnoty, nové se přidají na konec.
    public func spreading(_ other: JSONObject) -> JSONObject {
        var out = self
        for key in other.keys { out[key] = other.storage[key] }
        return out
    }

    private mutating func insertKey(_ key: String) {
        guard let index = Self.arrayIndex(key) else {
            namedKeys.append(key)
            return
        }
        let pos = indexKeys.firstIndex { Self.arrayIndex($0)! > index } ?? indexKeys.endIndex
        indexKeys.insert(key, at: pos)
    }

    private mutating func removeKey(_ key: String) {
        if Self.arrayIndex(key) != nil {
            indexKeys.removeAll { $0 == key }
        } else {
            namedKeys.removeAll { $0 == key }
        }
    }

    /// Klíč je index pole, pokud je to kanonický zápis celého čísla 0 … 2³² − 2 („01“ ani „-1“ nejsou).
    static func arrayIndex(_ key: String) -> UInt32? {
        let utf8 = key.utf8
        guard let first = utf8.first, utf8.count <= 10, first >= 0x30, first <= 0x39 else { return nil }
        if first == 0x30 { return utf8.count == 1 ? 0 : nil }
        var value: UInt64 = 0
        for byte in utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + UInt64(byte - 0x30)
        }
        return value < UInt64(UInt32.max) ? UInt32(value) : nil
    }
}

extension JSONObject: Hashable {
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

extension JSONObject: Sequence {
    public func makeIterator() -> some IteratorProtocol<(key: String, value: JSONValue)> {
        let storage = self.storage
        return keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements { self[k] = v }
    }
}

// MARK: - Typované čtení

extension JSONObject {
    public func string(_ key: String) -> String? { storage[key]?.stringValue }
    public func number(_ key: String) -> Double? { storage[key]?.numberValue }
    public func bool(_ key: String) -> Bool? { storage[key]?.boolValue }
    public func object(_ key: String) -> JSONObject? { storage[key]?.objectValue }
    public func array(_ key: String) -> [JSONValue]? { storage[key]?.arrayValue }

    /// Celé číslo (časy v ms, počty). Necelé hodnoty zaokrouhlí, mimo rozsah vrátí `nil`.
    public func int(_ key: String) -> Int? {
        guard let n = number(key), n.isFinite, abs(n) < 9.2e18 else { return nil }
        return Int(n.rounded())
    }
}

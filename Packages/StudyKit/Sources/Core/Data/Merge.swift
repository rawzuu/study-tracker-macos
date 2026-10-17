import Foundation

/// Slučování dat z více zařízení (`src/data/merge.ts` na webu).
///
/// Pro známá data se chová přesně jako web (ověřují to paritní testy). Navíc je dopředně kompatibilní:
///  - Pole záznamů s `id` a `updatedAt`, které tahle verze nezná (nová kolekce z novější verze webu),
///    slučuje po záznamech stejně jako známé kolekce. Web by vzal celé pole z jedné strany.
///  - Ostatní neznámá pole bere ze vzdálené strany – tahle aplikace je nikdy nemění, takže novější
///    hodnotu mohla zapsat jen jiná (novější) aplikace.
public enum Merge {
    /// Pro každé `id` vyhraje záznam s novějším `updatedAt`; při shodě zůstává `a`. Pořadí podle prvního výskytu.
    static func mergeEntities(_ a: [JSONValue], _ b: [JSONValue]) -> [JSONValue] {
        var order: [EntityKey] = []
        var map: [EntityKey: JSONValue] = [:]
        order.reserveCapacity(a.count + b.count)
        for e in a {
            let k = EntityKey(e)
            if map.updateValue(e, forKey: k) == nil { order.append(k) }
        }
        for e in b {
            let k = EntityKey(e)
            if let existing = map[k] {
                if jsGreater(updatedAt(e), updatedAt(existing)) { map[k] = e }
            } else {
                map[k] = e
                order.append(k)
            }
        }
        return order.map { map[$0]! }
    }

    /// Sloučí lokální a vzdálená data (obě už normalizovaná).
    public static func mergeData(local: AppDocument, remote: AppDocument) -> AppDocument {
        let l = local.raw
        let r = remote.raw
        // Pořadí klíčů jako `{ ...remote, ...local }` na webu.
        var out = r.spreading(l)
        for key in out.keys where key != "settings" && key != "schemaVersion" {
            let known = CollectionKey(rawValue: key) != nil
            if known || (isEntityList(l[key]) && isEntityList(r[key])) {
                out[key] = .array(mergeEntities(l[key]?.arrayValue ?? [], r[key]?.arrayValue ?? []))
            } else if !known, let remoteValue = r[key] {
                out[key] = remoteValue
            }
        }
        let ls = l.object("settings") ?? JSONObject()
        let rs = r.object("settings") ?? JSONObject()
        out["settings"] = .object(jsGreater(rs.number("updatedAt"), ls.number("updatedAt")) ? rs : ls)
        return AppDocument(trusted: out)
    }

    /// Obsahuje `incoming` něco, co v `local` chybí nebo je novější? (`hasNewer` na webu)
    public static func hasNewer(local: AppDocument, incoming: AppDocument) -> Bool {
        if jsGreater(incoming.settings.raw.number("updatedAt"), local.settings.raw.number("updatedAt")) { return true }
        for key in CollectionKey.allCases {
            var have: [EntityKey: Double?] = [:]
            for e in local.raw.array(key.rawValue) ?? [] { have[EntityKey(e)] = updatedAt(e) }
            for e in incoming.raw.array(key.rawValue) ?? [] {
                // `t === undefined` platí i pro lokální záznam bez `updatedAt`
                guard let entry = have[EntityKey(e)], let t = entry else { return true }
                if jsGreater(updatedAt(e), t) { return true }
            }
        }
        return false
    }

    /// Stabilní zápis do `data.json` – bajtově shodný s `serialize()` na webu:
    /// známé kolekce seřazené podle `createdAt` a `id`, odsazení 1 mezerou, nový řádek na konci.
    public static func serialize(_ doc: AppDocument) -> String {
        var sorted = doc.raw
        for key in CollectionKey.allCases {
            guard let list = sorted.array(key.rawValue) else { continue }
            sorted[key.rawValue] = .array(list.sorted(by: serializeOrder))
        }
        return JSONValue.object(sorted).serialized(indent: 1) + "\n"
    }

    // MARK: - Pomocné

    /// `x.createdAt - y.createdAt || x.id.localeCompare(y.id)`. Web řadí podle jazyka prohlížeče (čeština);
    /// pořadí při shodném `createdAt` je jen kosmetické – na to, jestli se má zapisovat, vliv nemá.
    static func serializeOrder(_ x: JSONValue, _ y: JSONValue) -> Bool {
        let xo = x.objectValue, yo = y.objectValue
        if let a = xo?.number("createdAt"), let b = yo?.number("createdAt"), a != b { return a < b }
        let xi = xo?.string("id") ?? "", yi = yo?.string("id") ?? ""
        return xi.compare(yi, options: [], range: nil, locale: collationLocale) == .orderedAscending
    }

    private static let collationLocale = Locale(identifier: "cs_CZ")

    /// Pole objektů s `id` (text) a `updatedAt` (číslo); prázdné nebo chybějící pole nevadí.
    static func isEntityList(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard let list = value.arrayValue else { return false }
        return list.allSatisfy { $0.objectValue?.string("id") != nil && $0.objectValue?.number("updatedAt") != nil }
    }

    static func updatedAt(_ e: JSONValue) -> Double? { e.objectValue?.number("updatedAt") }

    /// `a > b` v JS: s chybějící hodnotou (`undefined` → NaN) je výsledek vždy false.
    static func jsGreater(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return a > b
    }

    /// Klíč mapy v JS je `e.id`; záznamy bez textového id sdílejí klíč `undefined`.
    enum EntityKey: Hashable {
        case id(String)
        case undefined

        init(_ e: JSONValue) {
            if let id = e.objectValue?.string("id") { self = .id(id) } else { self = .undefined }
        }
    }
}

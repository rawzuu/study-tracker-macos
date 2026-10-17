/// Migrace dat mezi verzemi schématu (`src/data/migrations.ts` na webu).
/// Klíč = verze, ZE které se migruje; funkce vrací data o verzi vyšší.
enum Migrations {
    static let steps: [Int: @Sendable (JSONObject) -> JSONObject] = [:]

    /// Doplní chybějící kolekce a nastavení. Nic nemaže. Pořadí klíčů přesně jako na webu:
    /// `{ ...d, schemaVersion }`, chybějící kolekce na konec, `settings = { ...defaultSettings(), ...d.settings }`.
    static func normalize(_ d: JSONObject) -> JSONObject {
        var out = d
        out["schemaVersion"] = .number(Double(Schema.version))
        for key in CollectionKey.allCases where out.array(key.rawValue) == nil {
            out[key.rawValue] = .array([])
        }
        out["settings"] = .object(Schema.defaultSettings.spreading(d.object("settings") ?? JSONObject()))
        return out
    }
}

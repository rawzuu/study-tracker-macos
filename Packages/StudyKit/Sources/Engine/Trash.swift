import Core

// Koš (`src/lib/trash.ts` na webu): mazání je měkké (`deletedAt`), takže smazané jde vrátit.
// Obnovení = odebrání `deletedAt` a nové `updatedAt`, takže při synchronizaci vyhraje i na ostatních zařízeních.

extension AppDocument {
    /// Vrátí smazanou položku (`restoreEntity` na webu). U zkoušky vrátí i její bloky plánu,
    /// u předmětu jeho bloky, zkoušky a témata – vše, co se smazalo ve stejné chvíli jako ona
    /// (s tolerancí 5 s pro starší data, kde se mazalo ve dvou krocích).
    public mutating func restore(_ key: CollectionKey, id: String, now: Int) {
        guard let target = rawRecords(key).first(where: { $0.string("id") == id }), let at = Self.deletedAt(target) else { return }
        let deletedTogether = { (o: JSONObject) in Self.deletedAt(o).map { abs($0 - at) < 5000 } ?? false }
        undelete(key, now: now) { $0.string("id") == id }
        switch key {
        case .exams:
            undelete(.planBlocks, now: now) { $0.string("examId") == id && deletedTogether($0) }
        case .subjects:
            for related in [CollectionKey.planBlocks, .exams, .topics] {
                undelete(related, now: now) { $0.string("subjectId") == id && deletedTogether($0) }
            }
        default:
            break
        }
    }

    /// `deletedAt` smazaného záznamu; `0` a chybějící hodnota znamenají „nesmazáno“ (`!e.deletedAt`).
    static func deletedAt(_ o: JSONObject) -> Double? {
        guard let d = o.number("deletedAt"), d != 0 else { return nil }
        return d
    }

    private mutating func undelete(_ key: CollectionKey, now: Int, where match: (JSONObject) -> Bool) {
        modifyRecords(key) { o in
            guard match(o) else { return }
            o["deletedAt"] = nil
            o["updatedAt"] = .number(Double(now))
        }
    }
}

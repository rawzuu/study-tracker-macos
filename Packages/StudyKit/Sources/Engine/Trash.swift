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

/// Koš v Nastavení (`trashItems` na webu): smazané položky za posledních 30 dní, nejnovější první.
public enum Trash {
    public static let days = 30

    public struct Item: Sendable, Hashable, Identifiable {
        public let key: CollectionKey
        public let id: String
        public let deletedAt: Int
        public let title: String
        public let detail: String

        public var label: String { Trash.label(key) }
    }

    /// `TRASH_LABEL` na webu.
    public static func label(_ key: CollectionKey) -> String {
        switch key {
        case .sessions: "Sezení"
        case .topics: "Téma"
        case .exams: "Zkouška"
        case .planBlocks: "Blok plánu"
        case .subjects: "Předmět"
        case .presets: "Režim časovače"
        case .timetables: "Rozvrh"
        case .reflections: "Reflexe"
        default: ""
        }
    }

    /// Systémová mazání (sezení z Anki, přegenerované bloky zkoušek) vynechá.
    public static func items(_ doc: AppDocument, now: Int, clock: StudyClock) -> [Item] {
        let since = Double(now - days * StudyClock.day)
        var names: [String: String] = [:]
        for s in doc.records(Subject.self) where names[s.id] == nil { names[s.id] = s.name }
        let subject = { (id: String) in names[id] ?? "Smazaný předmět" }
        let when = { (t: Int) in "\(Format.date(t, .dayNumericMonth, clock: clock)) \(Format.time(t, clock: clock))" }
        let reversedDay = { (key: String) in key.split(separator: "-", omittingEmptySubsequences: false).reversed().joined(separator: ". ") }
        var out: [Item] = []
        func add<R: EntityRecord>(_ key: CollectionKey, _ e: R, _ title: String, _ detail: String) {
            guard let at = AppDocument.deletedAt(e.raw), at >= since else { return }
            out.append(Item(key: key, id: e.id, deletedAt: Int(at), title: title, detail: detail))
        }
        for s in doc.records(Session.self) where s.mode != "anki" {
            add(.sessions, s, subject(s.subjectId), "\(when(s.start)) · \(Format.duration(s.raw.number("durationSec") ?? 0))\(s.topic.isEmpty ? "" : " · " + s.topic)")
        }
        for t in doc.records(Topic.self) { add(.topics, t, t.name, subject(t.subjectId)) }
        for e in doc.records(Exam.self) { add(.exams, e, e.name, "\(subject(e.subjectId)) · \(reversedDay(e.date))") }
        for b in doc.records(PlanBlock.self) where (b.examId ?? "").isEmpty {
            add(.planBlocks, b, subject(b.subjectId), "\(when(b.start)) · \(JSNumber.format(b.raw.number("durationMin") ?? 0)) min\(b.title.isEmpty ? "" : " · " + b.title)")
        }
        for s in doc.records(Subject.self) { add(.subjects, s, s.name, "") }
        for p in doc.records(TimerPreset.self) {
            add(.presets, p, p.name, "\(JSNumber.format(p.workMin)) / \(JSNumber.format(p.shortBreakMin))")
        }
        for t in doc.records(Timetable.self) { add(.timetables, t, t.name, "\(t.events.count) termínů") }
        for r in doc.records(Reflection.self) { add(.reflections, r, "Týden od \(reversedDay(r.weekStart))", "") }
        return out.stableSorted { $0.deletedAt > $1.deletedAt }
    }
}

// Typované pohledy na záznamy z `data.json`. Názvy polí odpovídají `src/data/schema.ts` na webu.
// Chybějící pole se čtou jako výchozí hodnota; zapisuje se jen pole, které se opravdu nastaví.

public struct Subject: EntityRecord {
    public static let collection = CollectionKey.subjects
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    public var color: String { get { raw.string("color") ?? "#9aa3ad" } set { raw.set("color", newValue) } }
    /// 0 = bez cíle
    public var weeklyGoalMin: Int { get { raw.int("weeklyGoalMin") ?? 0 } set { raw.set("weeklyGoalMin", newValue) } }
    public var archived: Bool { get { raw.bool("archived") ?? false } set { raw.set("archived", newValue) } }
}

public struct Session: EntityRecord {
    public static let collection = CollectionKey.sessions
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var subjectId: String { get { raw.string("subjectId") ?? "" } set { raw.set("subjectId", newValue) } }
    public var topic: String { get { raw.string("topic") ?? "" } set { raw.set("topic", newValue) } }
    public var start: Int { get { raw.int("start") ?? 0 } set { raw.set("start", newValue) } }
    public var end: Int { get { raw.int("end") ?? 0 } set { raw.set("end", newValue) } }
    /// Čistý čas učení bez pauz.
    public var durationSec: Int { get { raw.int("durationSec") ?? 0 } set { raw.set("durationSec", newValue) } }
    /// Id režimu časovače, `manual` nebo `anki`.
    public var mode: String { get { raw.string("mode") ?? "manual" } set { raw.set("mode", newValue) } }
    /// 1–5
    public var focus: Int? { get { raw.int("focus") } set { raw.set("focus", newValue) } }
    public var interruptions: Int { get { raw.int("interruptions") ?? 0 } set { raw.set("interruptions", newValue) } }
    public var note: String { get { raw.string("note") ?? "" } set { raw.set("note", newValue) } }
    public var topicId: String? { get { raw.string("topicId") } set { raw.set("topicId", newValue) } }
    /// Co si pamatuješ po bloku (retrieval practice).
    public var recall: String? { get { raw.string("recall") } set { raw.set("recall", newValue) } }
}

public struct Topic: EntityRecord {
    public static let collection = CollectionKey.topics
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var subjectId: String { get { raw.string("subjectId") ?? "" } set { raw.set("subjectId", newValue) } }
    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    /// Starý žebřík intervalů (-1 = neučeno); web ho dál vyplňuje kvůli starším verzím.
    public var stage: Int { get { raw.int("stage") ?? -1 } set { raw.set("stage", newValue) } }
    public var lastStudiedAt: Int? { get { raw.int("lastStudiedAt") } set { raw.set("lastStudiedAt", newValue) } }
    public var nextReviewAt: Int? { get { raw.int("nextReviewAt") } set { raw.set("nextReviewAt", newValue) } }
    public var reviews: Int { get { raw.int("reviews") ?? 0 } set { raw.set("reviews", newValue) } }
    public var mastered: Bool { get { raw.bool("mastered") ?? false } set { raw.set("mastered", newValue) } }
    public var note: String { get { raw.string("note") ?? "" } set { raw.set("note", newValue) } }
    public var fsrs: TopicFsrs? { get { raw.lens("fsrs") } set { raw.set("fsrs", newValue) } }
    public var log: [ReviewLog] { get { raw.lenses("log") } set { raw.set("log", newValue) } }
}

/// Paměťový stav tématu podle FSRS (stabilita, obtížnost, vybavitelnost).
public struct TopicFsrs: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    /// Stabilita ve dnech
    public var s: Double { get { raw.number("s") ?? 0 } set { raw.set("s", newValue) } }
    /// Obtížnost 1–10
    public var d: Double { get { raw.number("d") ?? 5 } set { raw.set("d", newValue) } }
    /// 0 nové, 1 učení, 2 opakování, 3 znovu učení
    public var state: Int { get { raw.int("state") ?? 0 } set { raw.set("state", newValue) } }
    public var reps: Int { get { raw.int("reps") ?? 0 } set { raw.set("reps", newValue) } }
    public var lapses: Int { get { raw.int("lapses") ?? 0 } set { raw.set("lapses", newValue) } }
    public var scheduledDays: Double { get { raw.number("scheduledDays") ?? 0 } set { raw.set("scheduledDays", newValue) } }
    public var lastReview: Int? { get { raw.int("lastReview") } set { raw.set("lastReview", newValue) } }
    public var due: Int { get { raw.int("due") ?? 0 } set { raw.set("due", newValue) } }
}

public struct ReviewLog: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var at: Int { get { raw.int("at") ?? 0 } set { raw.set("at", newValue) } }
    /// 1 Znovu, 2 Těžko, 3 Dobře, 4 Snadno
    public var rating: Int { get { raw.int("rating") ?? 3 } set { raw.set("rating", newValue) } }
    /// Hodnocení doplněné automaticky (blok z časovače bez ohodnocení).
    public var auto: Bool { get { raw.bool("auto") ?? false } set { raw["auto"] = newValue ? .bool(true) : nil } }
}

public struct PlanBlock: EntityRecord {
    public static let collection = CollectionKey.planBlocks
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var subjectId: String { get { raw.string("subjectId") ?? "" } set { raw.set("subjectId", newValue) } }
    public var title: String { get { raw.string("title") ?? "" } set { raw.set("title", newValue) } }
    public var start: Int { get { raw.int("start") ?? 0 } set { raw.set("start", newValue) } }
    public var durationMin: Int { get { raw.int("durationMin") ?? 0 } set { raw.set("durationMin", newValue) } }
    public var done: Bool { get { raw.bool("done") ?? false } set { raw.set("done", newValue) } }
    /// Blok vygenerovaný plánem opakování ke zkoušce.
    public var examId: String? { get { raw.string("examId") } set { raw.set("examId", newValue) } }
    public var note: String { get { raw.string("note") ?? "" } set { raw.set("note", newValue) } }
}

public struct Exam: EntityRecord {
    public static let collection = CollectionKey.exams
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var subjectId: String { get { raw.string("subjectId") ?? "" } set { raw.set("subjectId", newValue) } }
    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    /// YYYY-MM-DD
    public var date: String { get { raw.string("date") ?? "" } set { raw.set("date", newValue) } }
    /// HH:MM nebo prázdné
    public var time: String { get { raw.string("time") ?? "" } set { raw.set("time", newValue) } }
    public var note: String { get { raw.string("note") ?? "" } set { raw.set("note", newValue) } }
}

public struct TimerPreset: EntityRecord {
    public static let collection = CollectionKey.presets
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    public var workMin: Double { get { raw.number("workMin") ?? 25 } set { raw.set("workMin", newValue) } }
    public var shortBreakMin: Double { get { raw.number("shortBreakMin") ?? 5 } set { raw.set("shortBreakMin", newValue) } }
    public var longBreakMin: Double { get { raw.number("longBreakMin") ?? 15 } set { raw.set("longBreakMin", newValue) } }
    public var roundsBeforeLong: Int { get { raw.int("roundsBeforeLong") ?? 4 } set { raw.set("roundsBeforeLong", newValue) } }
}

public struct Reflection: EntityRecord {
    public static let collection = CollectionKey.reflections
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    /// Pondělí týdne, YYYY-MM-DD
    public var weekStart: String { get { raw.string("weekStart") ?? "" } set { raw.set("weekStart", newValue) } }
    /// 1–5
    public var rating: Int { get { raw.int("rating") ?? 0 } set { raw.set("rating", newValue) } }
    public var wentWell: String { get { raw.string("wentWell") ?? "" } set { raw.set("wentWell", newValue) } }
    public var blocked: String { get { raw.string("blocked") ?? "" } set { raw.set("blocked", newValue) } }
    public var focusNext: String { get { raw.string("focusNext") ?? "" } set { raw.set("focusNext", newValue) } }
}

/// Poslední stav z Anki (id `snapshot`).
public struct AnkiSnapshot: EntityRecord {
    public static let collection = CollectionKey.anki
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var at: Int { get { raw.int("at") ?? 0 } set { raw.set("at", newValue) } }
    public var decks: [AnkiDeckStat] { get { raw.lenses("decks") } set { raw.set("decks", newValue) } }
    public var reviewedToday: Int { get { raw.int("reviewedToday") ?? 0 } set { raw.set("reviewedToday", newValue) } }
    public var msToday: Int { get { raw.int("msToday") ?? 0 } set { raw.set("msToday", newValue) } }
}

public struct AnkiDeckStat: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    public var newCount: Int { get { raw.int("newCount") ?? 0 } set { raw.set("newCount", newValue) } }
    public var learnCount: Int { get { raw.int("learnCount") ?? 0 } set { raw.set("learnCount", newValue) } }
    public var reviewCount: Int { get { raw.int("reviewCount") ?? 0 } set { raw.set("reviewCount", newValue) } }
    public var total: Int { get { raw.int("total") ?? 0 } set { raw.set("total", newValue) } }
}

/// Importovaný rozvrh (.ics) – obsazený čas v kalendáři a ranním plánu. Celý rozvrh je jedna entita.
public struct Timetable: EntityRecord {
    public static let collection = CollectionKey.timetables
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var name: String { get { raw.string("name") ?? "" } set { raw.set("name", newValue) } }
    public var importedAt: Int { get { raw.int("importedAt") ?? 0 } set { raw.set("importedAt", newValue) } }
    public var events: [TimetableEvent] { get { raw.lenses("events") } set { raw.set("events", newValue) } }
    /// Skryté řady (předměty) – platí i po novém importu.
    public var hiddenSeries: [String] { get { raw.strings("hiddenSeries") } set { raw.set("hiddenSeries", newValue) } }
    /// Klíče termínů, které odpadají.
    public var skipped: [String] { get { raw.strings("skipped") } set { raw.set("skipped", newValue) } }
    /// Řada → id předmětu (opakování po přednášce).
    public var seriesSubjects: [String: String] { get { raw.stringMap("seriesSubjects") } set { raw.set("seriesSubjects", newValue) } }
}

public struct TimetableEvent: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    /// Řada + začátek – stabilní mezi importy.
    public var key: String { get { raw.string("key") ?? "" } set { raw.set("key", newValue) } }
    public var series: String { get { raw.string("series") ?? "" } set { raw.set("series", newValue) } }
    public var title: String { get { raw.string("title") ?? "" } set { raw.set("title", newValue) } }
    public var location: String { get { raw.string("location") ?? "" } set { raw.set("location", newValue) } }
    public var start: Int { get { raw.int("start") ?? 0 } set { raw.set("start", newValue) } }
    public var end: Int { get { raw.int("end") ?? 0 } set { raw.set("end", newValue) } }
}

/// Získaný úspěch – uložený natrvalo. `id` je stabilní id úspěchu (např. `hours.3`).
public struct AchievementRecord: EntityRecord {
    public static let collection = CollectionKey.achievements
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var at: Int { get { raw.int("at") ?? 0 } set { raw.set("at", newValue) } }
}

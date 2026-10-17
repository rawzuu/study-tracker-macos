/// Synchronizované nastavení (`data.settings`). Slučuje se jako celek podle `updatedAt`.
public struct Settings: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    private func num(_ key: String) -> Double { raw.number(key) ?? Schema.defaultSettings.number(key) ?? 0 }
    private func flag(_ key: String) -> Bool { raw.bool(key) ?? Schema.defaultSettings.bool(key) ?? false }
    private func text(_ key: String) -> String { raw.string(key) ?? Schema.defaultSettings.string(key) ?? "" }

    public var updatedAt: Int { raw.int("updatedAt") ?? 0 }
    public var theme: ThemePreference {
        get { ThemePreference(rawValue: text("theme")) ?? .dark }
        set { raw.set("theme", newValue.rawValue) }
    }
    public var dailyGoalMin: Int { get { Int(num("dailyGoalMin")) } set { raw.set("dailyGoalMin", newValue) } }
    public var defaultMode: String { get { text("defaultMode") } set { raw.set("defaultMode", newValue) } }
    public var autoStartBreaks: Bool { get { flag("autoStartBreaks") } set { raw.set("autoStartBreaks", newValue) } }
    public var autoStartWork: Bool { get { flag("autoStartWork") } set { raw.set("autoStartWork", newValue) } }
    public var sound: Bool { get { flag("sound") } set { raw.set("sound", newValue) } }
    /// 0–1
    public var volume: Double { get { num("volume") } set { raw.set("volume", newValue) } }
    public var notifications: Bool { get { flag("notifications") } set { raw.set("notifications", newValue) } }
    public var askFocusRating: Bool { get { flag("askFocusRating") } set { raw.set("askFocusRating", newValue) } }
    /// Pauza = práce / ratio (Flowtime)
    public var flowtimeRatio: Double { get { num("flowtimeRatio") } set { raw.set("flowtimeRatio", newValue) } }
    /// Kratší sezení se neukládají.
    public var minSessionSec: Int { get { Int(num("minSessionSec")) } set { raw.set("minSessionSec", newValue) } }
    public var askRecall: Bool { get { flag("askRecall") } set { raw.set("askRecall", newValue) } }
    public var noiseType: NoiseType {
        get { NoiseType(rawValue: text("noiseType")) ?? .off }
        set { raw.set("noiseType", newValue.rawValue) }
    }
    public var noiseVolume: Double { get { num("noiseVolume") } set { raw.set("noiseVolume", newValue) } }
    public var weeklyReflection: Bool { get { flag("weeklyReflection") } set { raw.set("weeklyReflection", newValue) } }
    public var calendarFeed: CalendarFeed? {
        get { raw.lens("calendarFeed") }
        set { raw["calendarFeed"] = newValue.map { .object($0.raw) } ?? .null }
    }
    /// Cílová pravděpodobnost vybavení (FSRS)
    public var desiredRetention: Double { get { num("desiredRetention") } set { raw.set("desiredRetention", newValue) } }
    public var maxIntervalDays: Int { get { Int(num("maxIntervalDays")) } set { raw.set("maxIntervalDays", newValue) } }
    public var anki: AnkiSettings {
        get { AnkiSettings(raw: raw.object("anki") ?? Schema.defaultSettings.object("anki")!) }
        set { raw.set("anki", newValue) }
    }
    /// HH:MM – od kdy plánovat den
    public var planDayStart: String { get { text("planDayStart") } set { raw.set("planDayStart", newValue) } }
    public var planDayEnd: String { get { text("planDayEnd") } set { raw.set("planDayEnd", newValue) } }
    public var calibration: [CalibrationEntry] { get { raw.lenses("calibration") } set { raw.set("calibration", newValue) } }
    /// Stránky skryté z nabídky (např. `reflexe`).
    public var hiddenPages: [String] { get { raw.strings("hiddenPages") } set { raw.set("hiddenPages", newValue) } }
    public var morningPrompt: Bool { get { flag("morningPrompt") } set { raw.set("morningPrompt", newValue) } }
    public var lectureRecap: Bool { get { flag("lectureRecap") } set { raw.set("lectureRecap", newValue) } }
    /// Kolik dní volna týdně sérii nepřeruší (0–2).
    public var streakRestDays: Int { get { Int(num("streakRestDays")) } set { raw.set("streakRestDays", newValue) } }
    /// Od kolika minut se den počítá do série (0 = jakékoli učení).
    public var streakMinMin: Int { get { Int(num("streakMinMin")) } set { raw.set("streakMinMin", newValue) } }
    public var tokenWarning: Bool { get { flag("tokenWarning") } set { raw.set("tokenWarning", newValue) } }
    public var blockDoneLogs: Bool { get { flag("blockDoneLogs") } set { raw.set("blockDoneLogs", newValue) } }
    public var multiTopicReview: Bool { get { flag("multiTopicReview") } set { raw.set("multiTopicReview", newValue) } }
    /// Po kolika minutách čekání na další blok se série časovače ukončí (0 = nikdy).
    public var seriesTimeoutMin: Int { get { Int(num("seriesTimeoutMin")) } set { raw.set("seriesTimeoutMin", newValue) } }
}

public enum ThemePreference: String, Sendable, CaseIterable {
    case dark, light, system
}

public enum NoiseType: String, Sendable, CaseIterable {
    case off, brown, pink, white
}

public struct AnkiSettings: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var enabled: Bool { get { raw.bool("enabled") ?? false } set { raw.set("enabled", newValue) } }
    /// Započítávat čas z Anki jako sezení.
    public var countTime: Bool { get { raw.bool("countTime") ?? true } set { raw.set("countTime", newValue) } }
    /// Balíček → id předmětu.
    public var deckSubjects: [String: String] { get { raw.stringMap("deckSubjects") } set { raw.set("deckSubjects", newValue) } }
    public var importDays: Int { get { raw.int("importDays") ?? 60 } set { raw.set("importDays", newValue) } }
}

/// Odebíraný kalendář – tajný gist se souborem `studijni-plan.ics`.
public struct CalendarFeed: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public var gistId: String { get { raw.string("gistId") ?? "" } set { raw.set("gistId", newValue) } }
    public var owner: String { get { raw.string("owner") ?? "" } set { raw.set("owner", newValue) } }
    public var includeExams: Bool { get { raw.bool("includeExams") ?? true } set { raw.set("includeExams", newValue) } }
    public var alarmMin: Int? {
        get { raw.int("alarmMin") }
        set { raw["alarmMin"] = newValue.map { .number(Double($0)) } ?? .null }
    }
}

/// Návrh z měsíčního reportu (použitý nebo ponechaný).
public struct CalibrationEntry: JSONLens {
    public var raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    /// YYYY-MM
    public var month: String { get { raw.string("month") ?? "" } set { raw.set("month", newValue) } }
    /// `dailyGoal`, `weeklyGoals` nebo `dayWindow`
    public var key: String { get { raw.string("key") ?? "" } set { raw.set("key", newValue) } }
    /// `applied` nebo `kept`
    public var action: String { get { raw.string("action") ?? "" } set { raw.set("action", newValue) } }
    public var at: Int { get { raw.int("at") ?? 0 } set { raw.set("at", newValue) } }
    public var before: JSONValue? { get { raw["before"] } set { raw["before"] = newValue } }
    public var after: JSONValue? { get { raw["after"] } set { raw["after"] = newValue } }
}

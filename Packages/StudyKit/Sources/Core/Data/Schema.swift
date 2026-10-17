/// Schéma dat sdílené s webovou aplikací (`src/data/schema.ts` v repu study-tracker).
///
/// PRAVIDLA (stejná jako na webu):
///  1. Nové volitelné pole nebo nová kolekce verzi nemění – neznámá pole se zachovávají.
///  2. Změna tvaru existujících dat = vyšší `schemaVersion` + migrace. Data s vyšší verzí, než
///     tahle aplikace zná, se jen čtou a nikdy nezapisují (`SchemaError.tooNew`).
///  3. Každá entita má `id`, `createdAt`, `updatedAt` (ms) a volitelně `deletedAt` (měkké mazání).
public enum Schema {
    public static let version = 1

    /// Výchozí nastavení – pořadí klíčů musí odpovídat `defaultSettings()` na webu,
    /// protože web je doplňuje jako `{ ...defaultSettings(), ...uložené }`.
    public static let defaultSettings: JSONObject = [
        "updatedAt": 0,
        "theme": "dark",
        "dailyGoalMin": 120,
        "defaultMode": "pomodoro",
        "autoStartBreaks": true,
        "autoStartWork": false,
        "sound": true,
        "volume": 0.6,
        "notifications": false,
        "askFocusRating": true,
        "flowtimeRatio": 5,
        "minSessionSec": 60,
        "askRecall": true,
        "noiseType": "off",
        "noiseVolume": 0.35,
        "weeklyReflection": true,
        "calendarFeed": nil,
        "desiredRetention": 0.9,
        "maxIntervalDays": 365,
        "anki": ["enabled": false, "countTime": true, "deckSubjects": [:], "importDays": 60],
        "planDayStart": "08:00",
        "planDayEnd": "22:00",
        "calibration": [],
        "hiddenPages": [],
        "morningPrompt": true,
        "lectureRecap": true,
        "streakRestDays": 0,
        "streakMinMin": 0,
        "tokenWarning": true,
        "blockDoneLogs": true,
        "multiTopicReview": true,
        "seriesTimeoutMin": 20,
    ]
}

/// Kolekce entit, které se slučují po jednotlivých záznamech (`COLLECTIONS` na webu).
public enum CollectionKey: String, CaseIterable, Sendable {
    case subjects, sessions, planBlocks, exams, presets, topics, reflections, anki, timetables, achievements
}

public enum SchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Data zapsala novější verze webu, kterou tahle aplikace nezná.
    case tooNew(version: Int)
    case missingMigration(from: Int)

    public var description: String {
        switch self {
        case .tooNew(let v):
            "Data mají verzi \(v), ale aplikace zná jen verzi \(Schema.version). Aktualizuj aplikaci – do té doby data jen čte."
        case .missingMigration(let v):
            "Chybí migrace z verze \(v)."
        }
    }
}

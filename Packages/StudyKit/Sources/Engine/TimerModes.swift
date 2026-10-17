import Core

/// Režim časovače (`src/features/timer/modes.ts` na webu).
public struct TimerMode: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case interval, flowtime, stopwatch
    }

    public let id: String
    public let name: String
    /// `nil` = počítá nahoru (Flowtime, stopky).
    public let workMin: Double?
    public let shortBreakMin: Double
    public let longBreakMin: Double
    public let roundsBeforeLong: Int
    public let kind: Kind
    public let tagline: String
    /// Vlastní režim uživatele (kolekce `presets`).
    public let custom: Bool

    public var workDurationMs: Int? { workMin.map { Int(($0 * Double(StudyClock.minute)).rounded()) } }

    /// Ukazovat kolečka kol do dlouhé pauzy (99 = dlouhá pauza nikdy).
    public var showsRounds: Bool { kind == .interval && roundsBeforeLong > 0 && roundsBeforeLong < 99 }

    public init(
        id: String, name: String, workMin: Double?, shortBreakMin: Double, longBreakMin: Double,
        roundsBeforeLong: Int, kind: Kind, tagline: String, custom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.workMin = workMin
        self.shortBreakMin = shortBreakMin
        self.longBreakMin = longBreakMin
        self.roundsBeforeLong = roundsBeforeLong
        self.kind = kind
        self.tagline = tagline
        self.custom = custom
    }

    /// Vlastní režim z kolekce `presets` (`presetToMode`).
    public init(preset p: TimerPreset) {
        func js(_ n: Double) -> String { JSONValue.number(n).serialized() }
        self.init(
            id: p.id, name: p.name, workMin: p.workMin, shortBreakMin: p.shortBreakMin, longBreakMin: p.longBreakMin,
            roundsBeforeLong: p.roundsBeforeLong, kind: .interval,
            tagline: "\(js(p.workMin)) / \(js(p.shortBreakMin)) · dlouhá \(js(p.longBreakMin)) min po \(p.roundsBeforeLong) kolech",
            custom: true
        )
    }

    public static let builtin: [TimerMode] = [
        TimerMode(id: "pomodoro", name: "Pomodoro", workMin: 25, shortBreakMin: 5, longBreakMin: 20, roundsBeforeLong: 4, kind: .interval, tagline: "25 / 5 · dlouhá pauza po 4 kolech"),
        TimerMode(id: "pomodoro-long", name: "Dlouhé Pomodoro", workMin: 50, shortBreakMin: 10, longBreakMin: 30, roundsBeforeLong: 3, kind: .interval, tagline: "50 / 10 · pro hlubokou práci"),
        TimerMode(id: "52-17", name: "52 / 17", workMin: 52, shortBreakMin: 17, longBreakMin: 17, roundsBeforeLong: 99, kind: .interval, tagline: "52 / 17 · delší pauzy"),
        TimerMode(id: "ultradian", name: "Ultradiánní blok", workMin: 90, shortBreakMin: 20, longBreakMin: 30, roundsBeforeLong: 3, kind: .interval, tagline: "90 / 20 · dlouhé soustředění"),
        TimerMode(id: "flowtime", name: "Flowtime", workMin: nil, shortBreakMin: 0, longBreakMin: 0, roundsBeforeLong: 99, kind: .flowtime, tagline: "Učíš se, dokud jsi ve flow · pauza ≈ 1/5"),
        TimerMode(id: "stopwatch", name: "Stopky", workMin: nil, shortBreakMin: 0, longBreakMin: 0, roundsBeforeLong: 99, kind: .stopwatch, tagline: "Jen měří čas, žádné pauzy"),
    ]

    /// Vestavěné režimy a vlastní (nesmazané) režimy uživatele (`allModes`).
    public static func all(presets: [TimerPreset]) -> [TimerMode] {
        builtin + presets.filter { !$0.isDeleted }.map(TimerMode.init(preset:))
    }

    /// Režim podle id; neznámý (třeba smazaný vlastní) = Pomodoro, jako na webu.
    public static func find(_ id: String, presets: [TimerPreset]) -> TimerMode {
        all(presets: presets).first { $0.id == id } ?? builtin[0]
    }

    /// Tipy na pauzu (`BREAK_TIPS`).
    public static let breakTips = [
        "Vstaň a projdi se – pohyb zlepšuje prokrvení mozku.",
        "Napij se vody. I mírná dehydratace zhoršuje pozornost.",
        "Podívej se 20 sekund do dálky (pravidlo 20-20-20) – odpočinou si oči.",
        "Nech mobil ležet. Scrollování mozek neodpočine, jen přepne.",
        "Pár hlubokých nádechů nebo protažení zad a krku.",
        "Zkus si bez poznámek říct, co ses právě naučil – retrieval practice patří k nejúčinnějším metodám.",
        "Vyvětrej. Čerstvý vzduch a nižší CO₂ pomáhají soustředění.",
        "Zavři oči a minutu nic nedělej. Klidný odpočinek pomáhá ukládat nové informace.",
    ]
}

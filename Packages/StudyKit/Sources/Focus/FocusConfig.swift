import Foundation

/// Nastavení Soustředění – blokování aplikací a webů a měření času u obrazovky. Jen na tomto Macu:
/// v `data.json` nic není a web ho nezná. Zapisuje ho aplikace do sdíleného kontejneru, Strážce
/// (pomocník na pozadí) ho čte a vynucuje i bez spuštěné aplikace.
public struct FocusConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = FocusConfig.currentVersion
    /// Hlavní vypínač blokování. Přísné závazky platí i po vypnutí, měření má vlastní vypínač.
    public var enabled: Bool
    public var lists: [FocusList]
    public var plans: [FocusPlan]
    /// Ruční zámky („zamknout na 2 h“).
    public var locks: [FocusLock]
    /// Přísnější úroveň pár dní před zkouškou (`nil` = vypnuto).
    public var examBoost: ExamBoost?
    public var protection: Protection
    public var tracking: Tracking

    public init(enabled: Bool = false, lists: [FocusList] = [], plans: [FocusPlan] = [], locks: [FocusLock] = [],
                examBoost: ExamBoost? = nil, protection: Protection = .off, tracking: Tracking = .default) {
        self.enabled = enabled
        self.lists = lists
        self.plans = plans
        self.locks = locks
        self.examBoost = examBoost
        self.protection = protection
        self.tracking = tracking
    }

    public static let empty = FocusConfig()

    public func list(_ id: String) -> FocusList? { lists.first { $0.id == id } }
}

/// Seznam aplikací a webů. Buď se blokuje, co je v něm, nebo naopak všechno ostatní („povolit jen tyhle“).
public struct FocusList: Codable, Sendable, Equatable, Identifiable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case block
        /// Povolené jsou jen aplikace a weby ze seznamu. Prázdná část (třeba žádné aplikace) neomezuje nic.
        case allowOnly
    }

    /// Co udělat se zakázanou aplikací.
    public enum AppAction: String, Codable, Sendable, CaseIterable {
        /// Schovat a ukázat blokovací obrazovku – rozdělaná práce zůstane.
        case shield
        /// Ukončit (neuložená data se mohou ztratit).
        case quit
    }

    public var id: String
    public var name: String
    public var mode: Mode
    public var apps: [FocusApp]
    /// Weby: doména (`youtube.com` i se subdoménami) nebo doména s cestou (`youtube.com/shorts`).
    public var sites: [String]
    public var appAction: AppAction
    public var strictness: Strictness

    public init(id: String = UUID().uuidString, name: String, mode: Mode = .block, apps: [FocusApp] = [], sites: [String] = [],
                appAction: AppAction = .shield, strictness: Strictness = .soft) {
        self.id = id
        self.name = name
        self.mode = mode
        self.apps = apps
        self.sites = sites
        self.appAction = appAction
        self.strictness = strictness
    }

    public var siteRules: [SiteRule] { sites.compactMap(SiteRule.init) }
}

public struct FocusApp: Codable, Sendable, Hashable {
    public var bundleId: String
    public var name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Jak těžké je blokování zrušit. Jednotlivé překážky se sčítají (odklad i opsání textu zároveň);
/// když platí víc pravidel najednou, bere se z každé překážky ta přísnější.
public struct Strictness: Codable, Sendable, Equatable {
    /// Přísná: do konce nejde odemknout vůbec.
    public var locked: Bool
    /// Odemknutí začne platit až po tolika minutách (0 = hned).
    public var delayMinutes: Int
    /// Před odemknutím ručně opsat náhodný text o tolika znacích (0 = bez opisování).
    public var typingCharacters: Int
    /// Kolik odemknutí za týden (od pondělí); `nil` = bez omezení.
    public var weeklyAllowance: Int?
    /// Na jak dlouho odemknutí platí.
    public var unlockMinutes: Int

    public init(locked: Bool = false, delayMinutes: Int = 0, typingCharacters: Int = 0, weeklyAllowance: Int? = nil, unlockMinutes: Int = 5) {
        self.locked = locked
        self.delayMinutes = delayMinutes
        self.typingCharacters = typingCharacters
        self.weeklyAllowance = weeklyAllowance
        self.unlockMinutes = unlockMinutes
    }

    /// Volná: odkliknout (zapíše se do statistik).
    public static let soft = Strictness()
    public static let delay = Strictness(delayMinutes: 5)
    public static let typing = Strictness(typingCharacters: 120)
    public static let allowance = Strictness(weeklyAllowance: 3)
    public static let strict = Strictness(locked: true)

    /// Přísnější z obou v každé překážce.
    public func merged(with other: Strictness) -> Strictness {
        let allowance: Int? = switch (weeklyAllowance, other.weeklyAllowance) {
        case let (a?, b?): min(a, b)
        case let (a, b): a ?? b
        }
        return Strictness(locked: locked || other.locked, delayMinutes: max(delayMinutes, other.delayMinutes),
                          typingCharacters: max(typingCharacters, other.typingCharacters), weeklyAllowance: allowance,
                          unlockMinutes: min(unlockMinutes, other.unlockMinutes))
    }

    /// Jde vůbec odemknout (bez týdenního limitu – ten závisí na tom, kolik odemknutí už padlo).
    public var canUnlock: Bool { !locked && weeklyAllowance != 0 }
}

/// Kdy se seznamy blokují.
public struct FocusPlan: Codable, Sendable, Equatable, Identifiable {
    public enum Trigger: Codable, Sendable, Equatable {
        /// Během bloku učení v časovači.
        case studyBlock(StudyBlockOptions)
        /// V časových oknech podle dnů v týdnu.
        case schedule([TimeWindow])
        /// Během bloků Studijního plánu (plán na dnešek, jak ho ukazuje i Apple Kalendář).
        case studyPlan
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var listIds: [String]
    public var trigger: Trigger
    /// Přísnost pro celý plán místo přísnosti jednotlivých seznamů (`nil` = podle seznamů).
    public var strictness: Strictness?

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, listIds: [String], trigger: Trigger, strictness: Strictness? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.listIds = listIds
        self.trigger = trigger
        self.strictness = strictness
    }
}

public struct StudyBlockOptions: Codable, Sendable, Equatable {
    /// Blokovat i o přestávce (jinak je přestávka volná).
    public var duringBreaks: Bool
    /// Blokovat i v pozastaveném bloku – jinak by stačilo blok pozastavit.
    public var whilePaused: Bool

    public init(duringBreaks: Bool = false, whilePaused: Bool = true) {
        self.duringBreaks = duringBreaks
        self.whilePaused = whilePaused
    }
}

/// Časové okno ve vybrané dny. Konec před začátkem (nebo stejný) = přes půlnoc do dalšího dne.
public struct TimeWindow: Codable, Sendable, Equatable {
    /// 0 = pondělí … 6 = neděle (den, kdy okno začíná).
    public var weekdays: [Int]
    /// Minuty od půlnoci, 0–1439.
    public var start: Int
    /// Minuty od půlnoci, 1–1440.
    public var end: Int

    public init(weekdays: [Int], start: Int, end: Int) {
        self.weekdays = weekdays
        self.start = start
        self.end = end
    }

    public var overnight: Bool { end <= start }
}

/// Ruční zámek: vybrané seznamy do daného okamžiku.
public struct FocusLock: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var listIds: [String]
    public var start: Int
    public var end: Int
    /// `nil` = podle seznamů.
    public var strictness: Strictness?

    public init(id: String = UUID().uuidString, listIds: [String], start: Int, end: Int, strictness: Strictness? = nil) {
        self.id = id
        self.listIds = listIds
        self.start = start
        self.end = end
        self.strictness = strictness
    }
}

/// Před zkouškou se ke všem aktivním pravidlům přidá přísnější úroveň.
public struct ExamBoost: Codable, Sendable, Equatable {
    /// Kolik dní před zkouškou (0 = jen v den zkoušky).
    public var daysBefore: Int
    public var strictness: Strictness

    public init(daysBefore: Int = 3, strictness: Strictness = .strict) {
        self.daysBefore = daysBefore
        self.strictness = strictness
    }
}

/// Pojistka proti obcházení: během přísného zámku blokovat i nástroje, kterými by šel Strážce vypnout.
public struct Protection: Codable, Sendable, Equatable {
    /// Monitor aktivity a terminály.
    public var systemTools: Bool
    /// Nastavení systému (Login Items, kde jde Strážce vypnout).
    public var systemSettings: Bool

    public init(systemTools: Bool, systemSettings: Bool) {
        self.systemTools = systemTools
        self.systemSettings = systemSettings
    }

    public static let off = Protection(systemTools: false, systemSettings: false)

    public static let toolApps = [
        FocusApp(bundleId: "com.apple.ActivityMonitor", name: "Monitor aktivity"),
        FocusApp(bundleId: "com.apple.Terminal", name: "Terminál"),
        FocusApp(bundleId: "com.googlecode.iterm2", name: "iTerm"),
        FocusApp(bundleId: "com.mitchellh.ghostty", name: "Ghostty"),
        FocusApp(bundleId: "dev.warp.Warp-Stable", name: "Warp"),
        FocusApp(bundleId: "com.apple.ScriptEditor2", name: "Editor skriptů"),
    ]
    public static let settingsApps = [FocusApp(bundleId: "com.apple.systempreferences", name: "Nastavení systému")]

    var apps: [FocusApp] { (systemTools ? Self.toolApps : []) + (systemSettings ? Self.settingsApps : []) }
}

/// Měření času u obrazovky (jen na tomto Macu).
public struct Tracking: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Po kolika minutách bez myši a klávesnice se přestane počítat (video bez dotyku se počítá do té doby).
    public var idleMinutes: Int
    /// Jak dlouho historii uchovávat (dny).
    public var retentionDays: Int

    public init(enabled: Bool, idleMinutes: Int, retentionDays: Int) {
        self.enabled = enabled
        self.idleMinutes = idleMinutes
        self.retentionDays = retentionDays
    }

    public static let `default` = Tracking(enabled: true, idleMinutes: 5, retentionDays: 180)
}

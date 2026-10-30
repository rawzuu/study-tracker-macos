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
    /// Strážce čte adresu aktivní záložky Safari (pojistka k rozšíření a měření webů; chce souhlas Automatizace).
    public var watchSafari: Bool
    /// Zmrazení celého Macu: co zůstane povolené a jak přísné je.
    public var freeze: FreezeSettings
    /// Oznámení: blokování začne za 5 minut, začalo, skončilo.
    public var notify: Bool

    public init(enabled: Bool = false, lists: [FocusList] = [], plans: [FocusPlan] = [], locks: [FocusLock] = [],
                examBoost: ExamBoost? = nil, protection: Protection = .off, tracking: Tracking = .default, watchSafari: Bool = true,
                freeze: FreezeSettings = FreezeSettings(), notify: Bool = true) {
        self.enabled = enabled
        self.lists = lists
        self.plans = plans
        self.locks = locks
        self.examBoost = examBoost
        self.protection = protection
        self.tracking = tracking
        self.watchSafari = watchSafari
        self.freeze = freeze
        self.notify = notify
    }

    /// Chybějící klíče (nastavení ze starší verze) = výchozí hodnoty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decode(Bool.self, forKey: .enabled), lists: try c.decode([FocusList].self, forKey: .lists),
                  plans: try c.decode([FocusPlan].self, forKey: .plans), locks: try c.decode([FocusLock].self, forKey: .locks),
                  examBoost: try c.decodeIfPresent(ExamBoost.self, forKey: .examBoost), protection: try c.decode(Protection.self, forKey: .protection),
                  tracking: try c.decode(Tracking.self, forKey: .tracking), watchSafari: try c.decode(Bool.self, forKey: .watchSafari),
                  freeze: try c.decodeIfPresent(FreezeSettings.self, forKey: .freeze) ?? FreezeSettings(),
                  notify: try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    }

    public static let empty = FocusConfig()
    /// Bez uloženého nastavení (Soustředění ještě nikdo nenastavil): Strážce nic nedělá – neměří ani se neptá na Safari.
    public static let inactive = FocusConfig(tracking: Tracking(enabled: false, idleMinutes: 5, retentionDays: 180), watchSafari: false)

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
    /// Výjimky v blokovaném webu: zůstanou povolené (`youtube.com/playlist` při blokovaném `youtube.com`).
    public var allowedSites: [String]
    /// Slova v adrese (doména i cesta), která blokují kterýkoli web – třeba „game“ nebo „serial“.
    public var keywords: [String]
    public var appAction: AppAction
    public var strictness: Strictness
    /// Zmrazení celého Macu: povolené jsou jen `apps` a Study Tracker – i Finder a Nastavení systému se schovají.
    public var freeze: Bool

    public init(id: String = UUID().uuidString, name: String, mode: Mode = .block, apps: [FocusApp] = [], sites: [String] = [],
                allowedSites: [String] = [], keywords: [String] = [], appAction: AppAction = .shield, strictness: Strictness = .soft,
                freeze: Bool = false) {
        self.id = id
        self.name = name
        self.mode = mode
        self.apps = apps
        self.sites = sites
        self.allowedSites = allowedSites
        self.keywords = keywords
        self.appAction = appAction
        self.strictness = strictness
        self.freeze = freeze
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  mode: try c.decode(Mode.self, forKey: .mode), apps: try c.decode([FocusApp].self, forKey: .apps),
                  sites: try c.decode([String].self, forKey: .sites), allowedSites: try c.decodeIfPresent([String].self, forKey: .allowedSites) ?? [],
                  keywords: try c.decodeIfPresent([String].self, forKey: .keywords) ?? [],
                  appAction: try c.decodeIfPresent(AppAction.self, forKey: .appAction) ?? .shield,
                  strictness: try c.decodeIfPresent(Strictness.self, forKey: .strictness) ?? .soft,
                  freeze: try c.decodeIfPresent(Bool.self, forKey: .freeze) ?? false)
    }

    /// Seznam, kterým se Mac zmrazí (povolené aplikace z nastavení Zmrazení).
    public static let freezeId = "freeze"

    public static func freezeList(_ settings: FreezeSettings) -> FocusList {
        FocusList(id: freezeId, name: "Zmrazení", mode: .allowOnly, apps: settings.allowedApps, strictness: settings.strictness, freeze: true)
    }

    public var siteRules: [SiteRule] { sites.compactMap(SiteRule.init) }
    public var allowedRules: [SiteRule] { allowedSites.compactMap(SiteRule.init) }
    /// Klíčová slova malými písmeny, aspoň tři znaky (kratší by blokovala skoro všechno).
    public var keywordRules: [String] {
        keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.count >= 3 }
    }
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
    /// Odemknutí začne platit až po tolika minutách od žádosti (0 = hned).
    public var delayMinutes: Int
    /// Před odemknutím ručně opsat náhodný text o tolika znacích (0 = bez opisování).
    public var typingCharacters: Int
    /// Kolik odemknutí za týden (od pondělí); `nil` = bez omezení.
    public var weeklyAllowance: Int?
    /// Na jak dlouho odemknutí platí.
    public var unlockMinutes: Int
    /// Odemknout jde až po restartu Macu (žádost → restart → odemknout).
    public var requireRestart: Bool
    /// Heslo, které zná někdo jiný (uložený jen otisk SHA-256 se solí).
    public var password: PasswordLock?
    /// Odemykat jde jen v těchto oknech (prázdné = kdykoli).
    public var unlockWindows: [TimeWindow]

    public init(locked: Bool = false, delayMinutes: Int = 0, typingCharacters: Int = 0, weeklyAllowance: Int? = nil, unlockMinutes: Int = 5,
                requireRestart: Bool = false, password: PasswordLock? = nil, unlockWindows: [TimeWindow] = []) {
        self.locked = locked
        self.delayMinutes = delayMinutes
        self.typingCharacters = typingCharacters
        self.weeklyAllowance = weeklyAllowance
        self.unlockMinutes = unlockMinutes
        self.requireRestart = requireRestart
        self.password = password
        self.unlockWindows = unlockWindows
    }

    /// Chybějící klíče (starší nastavení) = výchozí hodnoty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(locked: try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false,
                  delayMinutes: try c.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 0,
                  typingCharacters: try c.decodeIfPresent(Int.self, forKey: .typingCharacters) ?? 0,
                  weeklyAllowance: try c.decodeIfPresent(Int.self, forKey: .weeklyAllowance),
                  unlockMinutes: try c.decodeIfPresent(Int.self, forKey: .unlockMinutes) ?? 5,
                  requireRestart: try c.decodeIfPresent(Bool.self, forKey: .requireRestart) ?? false,
                  password: try c.decodeIfPresent(PasswordLock.self, forKey: .password),
                  unlockWindows: try c.decodeIfPresent([TimeWindow].self, forKey: .unlockWindows) ?? [])
    }

    /// Volná: odkliknout (zapíše se do statistik).
    public static let soft = Strictness()
    public static let delay = Strictness(delayMinutes: 5)
    public static let typing = Strictness(typingCharacters: 120)
    public static let allowance = Strictness(weeklyAllowance: 3)
    public static let restart = Strictness(requireRestart: true)
    public static let strict = Strictness(locked: true)

    /// Přísnější z obou v každé překážce.
    public func merged(with other: Strictness) -> Strictness {
        let allowance: Int? = switch (weeklyAllowance, other.weeklyAllowance) {
        case let (a?, b?): min(a, b)
        case let (a, b): a ?? b
        }
        // Okna odemykání: obě omezení zároveň – průnik se těžko vyjádří, bere se to s méně okny.
        let windows = [unlockWindows, other.unlockWindows].filter { !$0.isEmpty }.min { $0.count < $1.count } ?? []
        return Strictness(locked: locked || other.locked, delayMinutes: max(delayMinutes, other.delayMinutes),
                          typingCharacters: max(typingCharacters, other.typingCharacters), weeklyAllowance: allowance,
                          unlockMinutes: min(unlockMinutes, other.unlockMinutes), requireRestart: requireRestart || other.requireRestart,
                          password: password ?? other.password, unlockWindows: windows)
    }

    /// Jde vůbec odemknout (bez týdenního limitu – ten závisí na tom, kolik odemknutí už padlo).
    public var canUnlock: Bool { !locked && weeklyAllowance != 0 }

    /// Bez jakékoli překážky – stačí kliknout.
    public var isSoft: Bool {
        !locked && delayMinutes == 0 && typingCharacters == 0 && weeklyAllowance == nil && !requireRestart && password == nil && unlockWindows.isEmpty
    }
}

/// Heslo k odemknutí: jen sůl a otisk, heslo samo se nikde neukládá.
public struct PasswordLock: Codable, Sendable, Equatable {
    public var salt: String
    public var hash: String

    public init(salt: String, hash: String) {
        self.salt = salt
        self.hash = hash
    }
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
        /// Denní limit: po tolika minutách v aplikacích a na webech ze seznamů se do půlnoci blokuje.
        case dailyLimit(minutes: Int)
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var listIds: [String]
    public var trigger: Trigger
    /// Přísnost pro celý plán místo přísnosti jednotlivých seznamů (`nil` = podle seznamů).
    public var strictness: Strictness?
    /// Místo seznamů (nebo k nim) zmrazit celý Mac.
    public var freeze: Bool
    /// Přestávky v časových oknech: po `work` minutách `rest` minut volna (jako Pomodoro). `nil` = bez přestávek.
    public var breaks: Breaks?

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, listIds: [String], trigger: Trigger, strictness: Strictness? = nil,
                freeze: Bool = false, breaks: Breaks? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.listIds = listIds
        self.trigger = trigger
        self.strictness = strictness
        self.freeze = freeze
        self.breaks = breaks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  enabled: try c.decode(Bool.self, forKey: .enabled), listIds: try c.decode([String].self, forKey: .listIds),
                  trigger: try c.decode(Trigger.self, forKey: .trigger), strictness: try c.decodeIfPresent(Strictness.self, forKey: .strictness),
                  freeze: try c.decodeIfPresent(Bool.self, forKey: .freeze) ?? false, breaks: try c.decodeIfPresent(Breaks.self, forKey: .breaks))
    }
}

/// Přestávky během časového okna: blokuje se `work` minut, pak je `rest` minut volno, a znovu od začátku okna.
public struct Breaks: Codable, Sendable, Equatable {
    public var work: Int
    public var rest: Int

    public init(work: Int = 50, rest: Int = 10) {
        self.work = work
        self.rest = rest
    }
}

/// Zmrazení celého Macu (jako Frozen Turkey): povolené aplikace a přísnost. Study Tracker je povolený vždy.
public struct FreezeSettings: Codable, Sendable, Equatable {
    public var allowedApps: [FocusApp]
    public var strictness: Strictness

    public init(allowedApps: [FocusApp] = [], strictness: Strictness = .delay) {
        self.allowedApps = allowedApps
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
    /// Zmrazit celý Mac (seznamy se pak neuvádějí).
    public var freeze: Bool

    public init(id: String = UUID().uuidString, listIds: [String], start: Int, end: Int, strictness: Strictness? = nil, freeze: Bool = false) {
        self.id = id
        self.listIds = listIds
        self.start = start
        self.end = end
        self.strictness = strictness
        self.freeze = freeze
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), listIds: try c.decode([String].self, forKey: .listIds),
                  start: try c.decode(Int.self, forKey: .start), end: try c.decode(Int.self, forKey: .end),
                  strictness: try c.decodeIfPresent(Strictness.self, forKey: .strictness), freeze: try c.decodeIfPresent(Bool.self, forKey: .freeze) ?? false)
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
    /// Když se blokují weby, blokovat i prohlížeče kromě Safari (weby se v nich hlídat nedají).
    public var otherBrowsers: Bool

    public init(systemTools: Bool, systemSettings: Bool, otherBrowsers: Bool = true) {
        self.systemTools = systemTools
        self.systemSettings = systemSettings
        self.otherBrowsers = otherBrowsers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemTools = try c.decode(Bool.self, forKey: .systemTools)
        systemSettings = try c.decode(Bool.self, forKey: .systemSettings)
        otherBrowsers = try c.decodeIfPresent(Bool.self, forKey: .otherBrowsers) ?? true
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
    /// Prohlížeče, ve kterých Strážce weby hlídat neumí.
    public static let browserApps = [
        FocusApp(bundleId: "com.google.Chrome", name: "Google Chrome"), FocusApp(bundleId: "com.google.Chrome.beta", name: "Google Chrome Beta"),
        FocusApp(bundleId: "com.google.Chrome.canary", name: "Google Chrome Canary"), FocusApp(bundleId: "org.chromium.Chromium", name: "Chromium"),
        FocusApp(bundleId: "org.mozilla.firefox", name: "Firefox"), FocusApp(bundleId: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition"),
        FocusApp(bundleId: "org.mozilla.nightly", name: "Firefox Nightly"), FocusApp(bundleId: "com.microsoft.edgemac", name: "Microsoft Edge"),
        FocusApp(bundleId: "company.thebrowser.Browser", name: "Arc"), FocusApp(bundleId: "company.thebrowser.dia", name: "Dia"),
        FocusApp(bundleId: "com.brave.Browser", name: "Brave"), FocusApp(bundleId: "com.operasoftware.Opera", name: "Opera"),
        FocusApp(bundleId: "com.operasoftware.OperaGX", name: "Opera GX"), FocusApp(bundleId: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        FocusApp(bundleId: "com.kagi.kagimacOS", name: "Orion"), FocusApp(bundleId: "app.zen-browser.zen", name: "Zen"),
        FocusApp(bundleId: "org.torproject.torbrowser", name: "Tor Browser"), FocusApp(bundleId: "com.duckduckgo.macos.browser", name: "DuckDuckGo"),
        FocusApp(bundleId: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"),
    ]

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

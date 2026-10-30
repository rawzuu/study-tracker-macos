import Engine
import Foundation
import WidgetData

/// Co je v daném okamžiku potřeba vědět o učení: běžící blok, plán na dnešek, zkoušky.
/// Strážce to bere ze souhrnu pro widgety, takže funguje i bez spuštěné aplikace.
public struct FocusContext: Sendable, Equatable {
    public struct Study: Sendable, Equatable {
        public var paused: Bool
        public var isWork: Bool
        /// Konec fáze (`nil` = počítá nahoru nebo je pozastaveno).
        public var phaseEnd: Int?

        public init(paused: Bool, isWork: Bool, phaseEnd: Int?) {
            self.paused = paused
            self.isWork = isWork
            self.phaseEnd = phaseEnd
        }
    }

    public struct Interval: Sendable, Equatable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public var now: Int
    public var study: Study?
    /// Nesplněné bloky Studijního plánu.
    public var planBlocks: [Interval]
    /// Půlnoci dnů se zkouškou.
    public var examDays: [Int]
    /// Dnešní čas v jednotlivých aplikacích a na webech (denní limity).
    public var usageToday: [UsageTotal]

    public init(now: Int, study: Study? = nil, planBlocks: [Interval] = [], examDays: [Int] = [], usageToday: [UsageTotal] = []) {
        self.now = now
        self.study = study
        self.planBlocks = planBlocks
        self.examDays = examDays
        self.usageToday = usageToday
    }

    /// Ze souhrnu pro widgety. Odpočet, který už doběhl, se nepočítá – bez aplikace na konci fáze
    /// nikdo nepřepne a blok je fakticky u konce.
    public init(snapshot: WidgetSnapshot?, now: Int, usageToday: [UsageTotal] = []) {
        self.init(now: now, usageToday: usageToday)
        guard let snapshot else { return }
        let timer = snapshot.timer
        if timer.isActive, timer.phaseEnd.map({ now < $0 }) ?? true {
            study = Study(paused: timer.status == .paused, isWork: timer.isWork, phaseEnd: timer.phaseEnd)
        }
        planBlocks = snapshot.plan.filter { !$0.done }.map { Interval(start: $0.start, end: $0.end) }
        examDays = snapshot.exams.map(\.day)
    }
}

/// Seznam, který právě platí, s výslednou přísností.
public struct ActiveRule: Codable, Sendable, Equatable {
    public var list: FocusList
    public var strictness: Strictness
    /// Kdy nejdřív skončí (`nil` = neví se, třeba stopky).
    public var until: Int?
    /// Proč platí: názvy plánů, „Ruční zámek“, „Závazek“…
    public var sources: [String]

    public init(list: FocusList, strictness: Strictness, until: Int?, sources: [String]) {
        self.list = list
        self.strictness = strictness
        self.until = until
        self.sources = sources
    }
}

/// Přísný závazek: když začne přísné pravidlo se známým koncem, Strážce si seznam zapamatuje a do konce
/// ho vynucuje i po změně nastavení, vypnutí plánu nebo zastavení bloku.
public struct Commitment: Codable, Sendable, Equatable {
    public var list: FocusList
    public var strictness: Strictness
    public var until: Int
    public var source: String

    public init(list: FocusList, strictness: Strictness, until: Int, source: String) {
        self.list = list
        self.strictness = strictness
        self.until = until
        self.source = source
    }

    public var id: String { "\(list.id)@\(until)" }
}

/// Odemknutí (výjimka) aplikace nebo webu do daného okamžiku.
public struct FocusException: Codable, Sendable, Equatable {
    public var target: FocusTarget
    public var until: Int

    public init(target: FocusTarget, until: Int) {
        self.target = target
        self.until = until
    }
}

/// Zablokovaná věc: aplikace (bundle id) nebo web (doména).
public enum FocusTarget: Hashable, Sendable, Codable {
    case app(String)
    case site(String)

    public var key: String {
        switch self {
        case let .app(id): "app:\(id)"
        case let .site(host): "site:\(host)"
        }
    }

    public init?(key: String) {
        if key.hasPrefix("app:") { self = .app(String(key.dropFirst(4))) }
        else if key.hasPrefix("site:") { self = .site(String(key.dropFirst(5))) }
        else { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        guard let target = FocusTarget(key: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Neznámý cíl \(key)"))
        }
        self = target
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

/// Výsledek kontroly: co blokuje a jak přísně.
public struct FocusHit: Codable, Sendable, Equatable {
    public var target: FocusTarget
    /// Název aplikace nebo doména.
    public var name: String
    public var listIds: [String]
    public var listNames: [String]
    public var strictness: Strictness
    public var appAction: FocusList.AppAction
    public var until: Int?
}

/// Pravidla platná v jednom okamžiku.
public struct ActiveFocus: Codable, Sendable, Equatable {
    public var rules: [ActiveRule]
    /// Aplikace pojistky proti obcházení (jen během přísného zámku).
    public var protectionApps: [FocusApp]
    /// Jiné prohlížeče než Safari – blokované, dokud se blokují weby.
    public var browserApps: [FocusApp]
    public var exceptions: [FocusException]
    public var now: Int

    public init(rules: [ActiveRule] = [], protectionApps: [FocusApp] = [], browserApps: [FocusApp] = [], exceptions: [FocusException] = [],
                now: Int = 0) {
        self.rules = rules
        self.protectionApps = protectionApps
        self.browserApps = browserApps
        self.exceptions = exceptions
        self.now = now
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decode([ActiveRule].self, forKey: .rules)
        protectionApps = try c.decode([FocusApp].self, forKey: .protectionApps)
        browserApps = try c.decodeIfPresent([FocusApp].self, forKey: .browserApps) ?? []
        exceptions = try c.decode([FocusException].self, forKey: .exceptions)
        now = try c.decode(Int.self, forKey: .now)
    }

    public var isActive: Bool { !rules.isEmpty }
    public var isLocked: Bool { rules.contains { $0.strictness.locked } }

    /// Aplikace, které se nikdy neblokují (systém a Study Tracker sám).
    public static let alwaysAllowed: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine",
        "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent", "com.apple.AccessibilityUIServer",
        "com.apple.WindowManager", "com.apple.screencaptureui",
    ]

    public static func isAlwaysAllowed(_ bundleId: String) -> Bool {
        alwaysAllowed.contains(bundleId) || isOwnApp(bundleId)
    }

    /// Study Tracker a jeho Strážce.
    public static func isOwnApp(_ bundleId: String) -> Bool {
        bundleId == "cz.rawzuu.studytracker" || bundleId.hasPrefix("cz.rawzuu.studytracker.")
    }

    /// Zmrazení teď platí (do kdy, které aplikace zůstaly povolené, a jestli je přísné).
    public var freeze: (until: Int?, apps: [FocusApp], locked: Bool)? {
        let frozen = rules.filter(\.list.freeze)
        guard let first = frozen.first else { return nil }
        let until = frozen.contains { $0.until == nil } ? nil : frozen.compactMap(\.until).max()
        return (until, first.list.apps, frozen.contains(where: \.strictness.locked))
    }

    /// Smí se aplikace použít? `nil` = ano.
    public func check(app bundleId: String, name: String) -> FocusHit? {
        var hits: [(ActiveRule, FocusList.AppAction)] = []
        let allowed = Self.isAlwaysAllowed(bundleId)
        for rule in rules {
            let listed = rule.list.apps.contains { $0.bundleId == bundleId }
            let blocked = if rule.list.freeze {
                // Zmrazení schová i Finder a Nastavení systému – povolený je jen Study Tracker a vybrané aplikace.
                !listed && !Self.isOwnApp(bundleId)
            } else if allowed {
                false
            } else {
                switch rule.list.mode {
                case .block: listed
                case .allowOnly: !rule.list.apps.isEmpty && !listed
                }
            }
            if blocked { hits.append((rule, rule.list.freeze ? .shield : rule.list.appAction)) }
        }
        if browserApps.contains(where: { $0.bundleId == bundleId }) {
            let web = rules.filter(\.blocksWeb)
            if let first = web.first {
                let strictness = web.dropFirst().reduce(first.strictness) { $0.merged(with: $1.strictness) }
                let until = web.contains { $0.until == nil } ? nil : web.compactMap(\.until).max()
                let browsers = FocusList(id: "browsers", name: "Jiné prohlížeče", strictness: strictness)
                hits.append((ActiveRule(list: browsers, strictness: strictness, until: until, sources: ["Weby se hlídají jen v Safari"]), .shield))
            }
        }
        if protectionApps.contains(where: { $0.bundleId == bundleId }) {
            let protection = FocusList(id: "protection", name: "Pojistka proti obcházení", strictness: .strict)
            hits.append((ActiveRule(list: protection, strictness: .strict, until: rules.lockedUntil, sources: ["Přísný zámek"]), .shield))
        }
        return merge(hits, target: .app(bundleId), name: name)
    }

    /// Smí se web otevřít? `host` a `path` jsou z navštívené adresy.
    public func check(host: String, path: String = "") -> FocusHit? {
        let visited = SiteRule.normalize(host: host)
        guard !visited.isEmpty, visited != "localhost", visited != "127.0.0.1" else { return nil }
        var hits: [(ActiveRule, FocusList.AppAction)] = []
        var name = visited
        let address = visited + path.lowercased()
        for rule in rules {
            let siteRules = rule.list.siteRules
            let match = siteRules.first { $0.matches(host: visited, path: path) }
            switch rule.list.mode {
            case .block:
                if rule.list.allowedRules.contains(where: { $0.matches(host: visited, path: path) }) { continue }
                if let match {
                    hits.append((rule, .shield))
                    name = match.host
                } else if rule.list.keywordRules.contains(where: address.contains) {
                    hits.append((rule, .shield))
                }
            case .allowOnly:
                if !siteRules.isEmpty, match == nil { hits.append((rule, .shield)) }
            }
        }
        return merge(hits, target: .site(name), name: name)
    }

    private func merge(_ hits: [(ActiveRule, FocusList.AppAction)], target: FocusTarget, name: String) -> FocusHit? {
        guard let first = hits.first else { return nil }
        var strictness = first.0.strictness
        for (rule, _) in hits.dropFirst() { strictness = strictness.merged(with: rule.strictness) }
        if !strictness.locked, exceptions.contains(where: { $0.until > now && $0.target.covers(target) }) { return nil }
        let untils = hits.map(\.0.until)
        var ids: [String] = []
        var names: [String] = []
        for (rule, _) in hits where !ids.contains(rule.list.id) {
            ids.append(rule.list.id)
            names.append(rule.list.name)
        }
        return FocusHit(target: target, name: name, listIds: ids, listNames: names, strictness: strictness,
                        appAction: hits.contains { $0.1 == .quit } ? .quit : .shield,
                        until: untils.contains(nil) ? nil : untils.compactMap { $0 }.max())
    }

    /// Kolik odemknutí zbývá tento týden (`nil` = bez omezení). `unlocks` = seznamy dřívějších odemknutí v tomto týdnu.
    public static func allowanceLeft(_ hit: FocusHit, unlocksThisWeek unlocks: [[String]]) -> Int? {
        guard let allowance = hit.strictness.weeklyAllowance else { return nil }
        let used = unlocks.filter { !Set($0).isDisjoint(with: hit.listIds) }.count
        return max(0, allowance - used)
    }
}

extension FocusTarget {
    /// Odemknutí webu platí i pro jeho subdomény.
    func covers(_ other: FocusTarget) -> Bool {
        switch (self, other) {
        case let (.app(a), .app(b)): a == b
        case let (.site(a), .site(b)): b == a || b.hasSuffix("." + a)
        default: false
        }
    }
}

extension ActiveRule {
    /// Blokuje weby (domény, slova, nebo „jen tyhle weby“).
    public var blocksWeb: Bool { !list.siteRules.isEmpty || !list.keywordRules.isEmpty }
}

extension [ActiveRule] {
    /// Konec nejdelšího přísného pravidla.
    var lockedUntil: Int? {
        let locked = filter(\.strictness.locked)
        return locked.contains { $0.until == nil } ? nil : locked.compactMap(\.until).max()
    }
}

/// Vyhodnocení pravidel: které seznamy právě platí a jak přísně.
public enum FocusEngine {
    public static func evaluate(_ config: FocusConfig, context c: FocusContext, commitments: [Commitment] = [],
                                exceptions: [FocusException] = [], clock: StudyClock) -> ActiveFocus {
        var rules: [ActiveRule] = []

        func add(_ list: FocusList, _ strictness: Strictness?, until: Int?, source: String) {
            let s = strictness ?? list.strictness
            if let i = rules.firstIndex(where: { $0.list.id == list.id }) {
                rules[i].strictness = rules[i].strictness.merged(with: s)
                rules[i].until = rules[i].until.flatMap { a in until.map { max(a, $0) } }
                if !rules[i].sources.contains(source) { rules[i].sources.append(source) }
            } else {
                rules.append(ActiveRule(list: list, strictness: s, until: until, sources: [source]))
            }
        }

        let freezeList = FocusList.freezeList(config.freeze)
        if config.enabled {
            for plan in config.plans where plan.enabled {
                guard let until = plan.activeUntil(c, lists: plan.listIds.compactMap(config.list), clock: clock) else { continue }
                for id in plan.listIds { if let list = config.list(id) { add(list, plan.strictness, until: until.value, source: plan.name) } }
                if plan.freeze { add(freezeList, plan.strictness, until: until.value, source: plan.name) }
            }
        }
        // Ruční zámky a zmrazení platí i s vypnutými plány – uživatel je spustil výslovně.
        for lock in config.locks where lock.start <= c.now && c.now < lock.end {
            for id in lock.listIds { if let list = config.list(id) { add(list, lock.strictness, until: lock.end, source: "Ruční zámek") } }
            if lock.freeze { add(freezeList, lock.strictness, until: lock.end, source: "Ruční zmrazení") }
        }
        if config.enabled {
            if let boost = config.examBoost, examSoon(c, within: boost.daysBefore, clock: clock) {
                for i in rules.indices {
                    rules[i].strictness = rules[i].strictness.merged(with: boost.strictness)
                    rules[i].sources.append("Před zkouškou")
                }
            }
        }
        // Závazky zvlášť (i se starou podobou seznamu): co se slíbilo, platí, i když se seznam mezitím změnil.
        for commitment in commitments where commitment.until > c.now {
            rules.append(ActiveRule(list: commitment.list, strictness: commitment.strictness, until: commitment.until,
                                    sources: [commitment.source]))
        }
        let protection = rules.contains(where: \.strictness.locked) ? config.protection.apps : []
        let browsers = config.protection.otherBrowsers && rules.contains(where: \.blocksWeb) ? Protection.browserApps : []
        return ActiveFocus(rules: rules, protectionApps: protection, browserApps: browsers, exceptions: exceptions, now: c.now)
    }

    /// Co začne do `within` ms: ruční zámky a zmrazení a časová okna plánů (pro oznámení předem).
    public static func upcoming(_ config: FocusConfig, now: Int, within: Int, clock: StudyClock) -> [Upcoming] {
        var out: [Upcoming] = []
        for lock in config.locks where lock.start > now && lock.start <= now + within {
            out.append(Upcoming(key: "lock:\(lock.id)", name: lock.freeze ? "Zmrazení Macu" : "Ruční zámek", start: lock.start))
        }
        guard config.enabled else { return out }
        let today = clock.startOfDay(now)
        for plan in config.plans where plan.enabled {
            guard case let .schedule(windows) = plan.trigger else { continue }
            for day in [today, clock.addDays(today, 1)] {
                let weekday = clock.weekdayIndex(day)
                for w in windows where w.weekdays.contains(weekday) {
                    let start = clock.atMinutes(day, w.start)
                    if start > now, start <= now + within { out.append(Upcoming(key: "plan:\(plan.id)@\(start)", name: plan.name, start: start)) }
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Kdy se mezi `from` a `to` podle plánu blokuje: časová okna plánů a ruční zámky (pro Kalendář).
    /// Blok učení a denní limit se dopředu neví; bloky Studijního plánu Kalendář ukazuje sám.
    public static func intervals(_ config: FocusConfig, from: Int, to: Int, clock: StudyClock) -> [Interval] {
        var out: [Interval] = []
        for lock in config.locks where lock.end > from && lock.start < to {
            out.append(Interval(start: max(from, lock.start), end: min(to, lock.end), name: lock.freeze ? "Zmrazení" : "Ruční zámek", freeze: lock.freeze))
        }
        guard config.enabled else { return out.sorted { $0.start < $1.start } }
        var day = clock.addDays(clock.startOfDay(from), -1)
        while day < to {
            let weekday = clock.weekdayIndex(day)
            for plan in config.plans where plan.enabled {
                guard case let .schedule(windows) = plan.trigger else { continue }
                for w in windows where w.weekdays.contains(weekday) {
                    let start = clock.atMinutes(day, w.start)
                    let end = w.overnight ? clock.atMinutes(clock.addDays(day, 1), w.end) : clock.atMinutes(day, w.end)
                    if end > from, start < to {
                        out.append(Interval(start: max(from, start), end: min(to, end), name: plan.name, freeze: plan.freeze))
                    }
                }
            }
            day = clock.addDays(day, 1)
        }
        return out.sorted { $0.start < $1.start }
    }

    public struct Interval: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public var name: String
        public var freeze: Bool

        public init(start: Int, end: Int, name: String, freeze: Bool) {
            self.start = start
            self.end = end
            self.name = name
            self.freeze = freeze
        }
    }

    public struct Upcoming: Sendable, Equatable {
        public var key: String
        public var name: String
        public var start: Int
    }

    /// Nové přísné závazky: přísná pravidla se známým koncem, která ještě nejsou zapamatovaná.
    public static func newCommitments(_ state: ActiveFocus, existing: [Commitment]) -> [Commitment] {
        let known = Set(existing.map(\.id))
        return state.rules.compactMap { rule -> Commitment? in
            guard rule.strictness.locked, let until = rule.until, until > state.now,
                  !rule.sources.contains(Commitment.source) else { return nil }
            let c = Commitment(list: rule.list, strictness: rule.strictness, until: until, source: Commitment.source)
            return known.contains(c.id) ? nil : c
        }
    }

    /// Dnešní čas v aplikacích a na webech ze seznamů (jen seznamy „blokovat tyhle“).
    public static func usedMs(_ usage: [UsageTotal], lists: [FocusList]) -> Int {
        let blockLists = lists.filter { $0.mode == .block }
        let apps = Set(blockLists.flatMap { $0.apps.map(\.bundleId) })
        let sites = blockLists.flatMap(\.siteRules)
        return usage.reduce(0) { sum, u in
            let counts = u.host.isEmpty ? apps.contains(u.bundleId) : sites.contains { $0.matches(host: u.host) } || apps.contains(u.bundleId)
            return counts ? sum + u.ms : sum
        }
    }

    static func examSoon(_ c: FocusContext, within days: Int, clock: StudyClock) -> Bool {
        let today = clock.startOfDay(c.now)
        let last = clock.addDays(today, max(0, days))
        return c.examDays.contains { $0 >= today && $0 <= last }
    }
}

extension Commitment {
    public static let source = "Přísný závazek"
}

/// Konec okna jako hodnota – `nil` uvnitř znamená „platí, konec se neví“.
struct Until {
    var value: Int?
}

extension FocusPlan {
    /// Platí plán teď? Jako spouštěč, jen v časových oknech s přestávkami je přestávka volná.
    func activeUntil(_ c: FocusContext, lists: [FocusList], clock: StudyClock) -> Until? {
        guard let until = trigger.activeUntil(c, lists: lists, clock: clock) else { return nil }
        guard let breaks, breaks.work > 0, breaks.rest > 0, case let .schedule(windows) = trigger else { return until }
        // Začátek okna, ve kterém jsme (u více oken to, které začalo nejdřív a ještě trvá).
        guard let start = windows.compactMap({ $0.start(containing: c.now, clock: clock) }).min() else { return until }
        let cycle = (breaks.work + breaks.rest) * StudyClock.minute
        let position = (c.now - start) % cycle
        guard position < breaks.work * StudyClock.minute else { return nil }
        let breakStarts = c.now - position + breaks.work * StudyClock.minute
        return Until(value: until.value.map { min($0, breakStarts) } ?? breakStarts)
    }
}

extension FocusPlan.Trigger {
    /// Platí spouštěč teď? Vrací konec (`Until(nil)` = neznámý), nebo `nil`, když neplatí.
    func activeUntil(_ c: FocusContext, lists: [FocusList], clock: StudyClock) -> Until? {
        switch self {
        case let .studyBlock(options):
            guard let study = c.study else { return nil }
            if study.paused, !options.whilePaused { return nil }
            if !study.isWork, !options.duringBreaks { return nil }
            return Until(value: study.paused ? nil : study.phaseEnd)
        case let .schedule(windows):
            let ends = windows.compactMap { $0.end(containing: c.now, clock: clock) }
            return ends.max().map { Until(value: $0) }
        case .studyPlan:
            let ends = c.planBlocks.filter { $0.start <= c.now && c.now < $0.end }.map(\.end)
            return ends.max().map { Until(value: $0) }
        case let .dailyLimit(minutes):
            guard FocusEngine.usedMs(c.usageToday, lists: lists) >= minutes * StudyClock.minute else { return nil }
            return Until(value: clock.addDays(clock.startOfDay(c.now), 1))
        }
    }
}

extension TimeWindow {
    /// Začátek výskytu okna, který obsahuje `t`, nebo `nil` (v místním čase – i přes změnu času).
    public func start(containing t: Int, clock: StudyClock) -> Int? {
        let day = clock.startOfDay(t)
        let weekday = clock.weekdayIndex(day)
        let minute = clock.minutesOfDay(t)
        if !overnight {
            guard weekdays.contains(weekday), minute >= Double(start), minute < Double(end) else { return nil }
            return clock.atMinutes(day, start)
        }
        if weekdays.contains(weekday), minute >= Double(start) { return clock.atMinutes(day, start) }
        if weekdays.contains((weekday + 6) % 7), minute < Double(end) { return clock.atMinutes(clock.addDays(day, -1), start) }
        return nil
    }

    /// Konec výskytu okna, který obsahuje `t`, nebo `nil`.
    public func end(containing t: Int, clock: StudyClock) -> Int? {
        let day = clock.startOfDay(t)
        let weekday = clock.weekdayIndex(day)
        let minute = clock.minutesOfDay(t)
        if !overnight {
            guard weekdays.contains(weekday), minute >= Double(start), minute < Double(end) else { return nil }
            return clock.atMinutes(day, end)
        }
        if weekdays.contains(weekday), minute >= Double(start) { return clock.atMinutes(clock.addDays(day, 1), end) }
        if weekdays.contains((weekday + 6) % 7), minute < Double(end) { return clock.atMinutes(day, end) }
        return nil
    }
}

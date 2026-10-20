import Core
import Foundation

/// Úspěchy (`src/features/achievements/achievements.ts` na webu). Počítají se vždy z dat – jsou zpětné,
/// synchronizované a nikdy „neutečou“; jednou získaný úspěch se uloží do `achievements` a zůstane.
/// Id jsou stabilní („hours.3“, „exam-ready“) – stejná jako na webu. Ověřeno kontrolními daty z kódu webu
/// (Tools/parity/generate-achievements.ts).
public enum Achievements {
    public enum Group: String, CaseIterable, Sendable {
        case time = "Čas", regularity = "Pravidelnost", focus = "Soustředění", memory = "Paměť", planning = "Plánování"
        case variety = "Pestrost", special = "Zvláštní"
    }

    public enum Unit: String, Sendable { case h, d, x, min, none = "" }

    /// Hodnota a kdy byl daný práh poprvé dosažen (`nil` = neznámo nebo nedosaženo).
    struct Metric {
        let value: Double
        let reachedAt: (Double) -> Int?

        /// Kumulativní metrika z (čas, přírůstek).
        static func cumulative(_ events: [(Int, Double)]) -> Metric {
            let sorted = stable(events) { $0.0 < $1.0 }
            var acc = 0.0
            let line = sorted.map { e -> (Int, Double) in
                acc += e.1
                return (e.0, acc)
            }
            return Metric(value: acc) { th in line.first { $0.1 >= th - 1e-9 }?.0 }
        }

        static func count(_ times: [Int]) -> Metric { cumulative(times.map { ($0, 1) }) }

        /// Maximum z (čas, hodnota) – rekordy.
        static func record(_ points: [(Int, Double)]) -> Metric {
            let sorted = stable(points) { $0.0 < $1.0 }
            return Metric(value: sorted.reduce(0) { max($0, $1.1) }) { th in sorted.first { $0.1 >= th }?.0 }
        }

        static func plain(_ value: Double) -> Metric { Metric(value: value) { _ in nil } }
    }

    /// Řada úspěchů s úrovněmi („Hodiny I–VIII“).
    public struct Family: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let group: Group
        /// Patří ke stránce, kterou jde skrýt (např. „reflexe“) – při skrytí se nepočítá.
        public let feature: String?
        public let icon: String
        public let thresholds: [Double]
        public let unit: Unit
        let describe: @Sendable (Double) -> String
        let metric: @Sendable (Facts) -> Metric

        public func desc(_ t: Double) -> String { describe(t) }
    }

    /// Jednorázový úspěch („Plánovač“, skryté svátky).
    public struct Single: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let group: Group
        public let feature: String?
        public let icon: String
        public let desc: String
        public let secret: Bool
        /// Čas odemčení, `nil` = zamčeno.
        let check: @Sendable (Facts) -> Int?
    }

    /// Fakta spočítaná jednou z dat; úspěchy z nich jen čtou (`buildFacts`).
    struct Facts {
        let now: Int
        let clock: StudyClock
        /// Všechna nesmazaná sezení, seřazená podle konce.
        let sessions: [Session]
        /// Bez Anki.
        let focus: [Session]
        let perDay: [(key: String, sec: Int)]
        let perDayIndex: [String: Int]
        let daysSorted: [String]
        let subjectsDay: [(key: String, subjects: Set<String>)]
        let doc: AppDocument

        init(_ doc: AppDocument, now: Int, clock: StudyClock) {
            self.now = now
            self.clock = clock
            self.doc = doc
            sessions = stable(doc.alive(Session.self)) { $0.end < $1.end }
            var order: [String] = [], sec: [String: Int] = [:], subjects: [String: Set<String>] = [:]
            for s in sessions {
                let k = clock.dayKey(s.start)
                if sec[k] == nil { order.append(k) }
                sec[k, default: 0] += s.durationSec
                subjects[k, default: []].insert(s.subjectId)
            }
            perDay = order.map { ($0, sec[$0]!) }
            perDayIndex = sec
            daysSorted = order.sorted()
            subjectsDay = order.map { ($0, subjects[$0]!) }
            focus = sessions.filter { $0.mode != "anki" }
        }

        func day(_ key: String) -> Int { clock.parseDayKey(key) ?? 0 }
    }

    // MARK: - Výsledky

    public struct Tier: Sendable, Hashable {
        public let threshold: Double
        public let unlocked: Bool
        public let at: Int?
    }

    public struct FamilyResult: Sendable, Identifiable {
        public let family: Family
        public let value: Double
        /// Počet odemčených úrovní (0 = nic).
        public let tier: Int
        public let tiers: [Tier]
        public let next: Double?
        /// 0–1 k další úrovni.
        public let progress: Double
        public var id: String { family.id }
    }

    public struct SingleResult: Sendable, Identifiable {
        public let single: Single
        public let unlocked: Bool
        public let at: Int?
        public var id: String { single.id }
    }

    public struct Results: Sendable {
        public let families: [FamilyResult]
        public let singles: [SingleResult]
        public let unlockedIds: [String]
        public let total: Int
        public var unlocked: Int { unlockedIds.count }
    }

    public static let roman = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]

    /// Úspěchy z dat k okamžiku `now` (`evaluate`).
    public static func evaluate(_ doc: AppDocument, now: Int, clock: StudyClock) -> Results {
        let f = Facts(doc, now: now, clock: clock)
        // Jednou získaný úspěch zůstává (uložený v datech) – i když se později změní cíle nebo se smaže téma.
        // `new Map(… [a.id, a.at])` – při stejném id platí poslední; bez času se nepočítá (`kept != null`).
        var stored: [String: Int?] = [:]
        for a in doc.alive(AchievementRecord.self) { stored[a.id] = a.raw.int("at") }
        let kept = { (id: String) -> Int? in stored[id] ?? nil }
        let hidden = Set(doc.settings.hiddenPages)
        let visible = { (feature: String?) in feature.map { !hidden.contains($0) } ?? true }

        let families: [FamilyResult] = Self.families.filter { visible($0.feature) }.map { fam in
            let m = fam.metric(f)
            let tiers = fam.thresholds.enumerated().map { i, th -> Tier in
                let computed = m.value >= th - 1e-9
                let key = "\(fam.id).\(i + 1)"
                let unlocked = computed || kept(key) != nil
                let at = computed ? (m.reachedAt(th) ?? kept(key)) : kept(key)
                return Tier(threshold: th, unlocked: unlocked, at: at)
            }
            let tier = tiers.firstIndex { !$0.unlocked } ?? tiers.count
            let next = tier < fam.thresholds.count ? fam.thresholds[tier] : nil
            let prev = tier > 0 ? fam.thresholds[tier - 1] : 0
            let progress = next.map { max(0, min(1, (m.value - prev) / ($0 - prev))) } ?? 1
            return FamilyResult(family: fam, value: m.value, tier: tier, tiers: tiers, next: next, progress: progress)
        }
        let singles: [SingleResult] = Self.singles.filter { visible($0.feature) }.map { s in
            let computed = s.check(f)
            let at = computed.flatMap { $0 >= 0 ? $0 : nil } ?? kept(s.id)
            return SingleResult(single: s, unlocked: computed != nil || kept(s.id) != nil, at: at)
        }
        let ids = families.flatMap { r in (0..<r.tier).map { "\(r.family.id).\($0 + 1)" } } + singles.filter(\.unlocked).map(\.single.id)
        let total = families.reduce(0) { $0 + $1.family.thresholds.count } + singles.count
        return Results(families: families, singles: singles, unlockedIds: ids, total: total)
    }

    /// Získané úspěchy, které ještě nejsou uložené natrvalo (k zapsání do dat; `toPersist`).
    public static func toPersist(_ doc: AppDocument, _ res: Results, now: Int) -> [AchievementRecord] {
        let known = Set(doc.records(AchievementRecord.self).map(\.id))
        var atOf: [String: Int?] = [:]
        for r in res.families { for (i, t) in r.tiers.enumerated() { atOf["\(r.family.id).\(i + 1)"] = t.at } }
        for s in res.singles { atOf[s.single.id] = s.at }
        return res.unlockedIds.filter { !known.contains($0) }.map { id in
            AchievementRecord(raw: ["id": .string(id), "at": .number(Double((atOf[id] ?? nil) ?? now))])
        }
    }

    /// Název a popis úspěchu podle id (pro oznámení; `describe`).
    public static func describe(_ id: String) -> (name: String, desc: String)? {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, let fam = families.first(where: { $0.id == parts[0] }), let t = Int(parts[1]), t >= 1, t <= fam.thresholds.count {
            return ("\(fam.name) \(roman[t - 1])", fam.desc(fam.thresholds[t - 1]))
        }
        return singles.first { $0.id == id }.map { ($0.name, $0.desc) }
    }

    /// Kov podle úrovně (`materialFor`): ocel → bronz → stříbro → zlato → platina.
    public static func material(tier: Int, of tiers: Int) -> Int {
        tiers <= 1 ? 3 : Int(JS.round(Double(tier - 1) / Double(tiers - 1) * 4))
    }

    public static let materials = ["ocel", "bronz", "stříbro", "zlato", "platina"]

    // MARK: - Definice

    static let H = 3600.0
    static func n(_ t: Double) -> String { Format.count(Int(t)) }
    static func cz(_ t: Double, _ one: String, _ few: String, _ many: String) -> String { t == 1 ? one : t >= 2 && t <= 4 ? few : many }
    static func i(_ t: Double) -> String { t == t.rounded() ? "\(Int(t))" : "\(t)" }

    /// Série podle stejných pravidel jako na přehledu (dny volna, minimum minut).
    static func streak(_ f: Facts) -> Metric {
        let days = Stats.streakDays(f.sessions, minMin: f.doc.settings.streakMinMin, clock: f.clock)
        guard let first = days.min().flatMap(f.clock.parseDayKey) else { return .plain(0) }
        return .record(Stats.streakRuns(days, from: first, until: f.now, restDays: f.doc.settings.streakRestDays, clock: f.clock).map { ($0.t, Double($0.run)) })
    }

    static func weekTotals(_ f: Facts) -> [(Int, Double)] {
        var order: [Int] = [], sec: [Int: Int] = [:]
        for s in f.sessions {
            let w = f.clock.startOfWeek(s.start)
            if sec[w] == nil { order.append(w) }
            sec[w, default: 0] += s.durationSec
        }
        return order.map { ($0, Double(sec[$0]!) / H) }
    }

    static func subjectCrossings(_ f: Facts, hours: Double) -> [Int] {
        var acc: [String: Int] = [:]
        var crossed: [Int] = []
        for s in f.focus {
            let before = acc[s.subjectId] ?? 0, after = before + s.durationSec
            acc[s.subjectId] = after
            if Double(before) < hours * H && Double(after) >= hours * H { crossed.append(s.end) }
        }
        return crossed
    }

    static func family(_ id: String, _ name: String, _ group: Group, _ icon: String, _ unit: Unit, _ thresholds: [Double], feature: String? = nil,
                       desc: @escaping @Sendable (Double) -> String, metric: @escaping @Sendable (Facts) -> Metric) -> Family {
        Family(id: id, name: name, group: group, feature: feature, icon: icon, thresholds: thresholds, unit: unit, describe: desc, metric: metric)
    }

    public static let families: [Family] = [
        // Čas
        family("hours", "Hodiny", .time, "clock", .h, [1, 10, 25, 50, 100, 250, 500, 1000], desc: { "\(n($0)) \(cz($0, "hodina", "hodiny", "hodin")) učení celkem" },
               metric: { f in .cumulative(f.sessions.map { ($0.end, Double($0.durationSec) / H) }) }),
        family("day", "Silný den", .time, "sun.max", .h, [2, 4, 6, 8], desc: { "\(i($0)) h učení za jeden den" },
               metric: { f in .record(f.perDay.map { (f.day($0.key), Double($0.sec) / H) }) }),
        family("week", "Silný týden", .time, "calendar", .h, [10, 20, 30, 40], desc: { "\(i($0)) h učení za jeden týden" },
               metric: { f in .record(weekTotals(f)) }),
        family("specialist", "Specialista", .time, "book", .h, [10, 50, 100, 250], desc: { "\(i($0)) h v jednom předmětu" }, metric: { f in
            var vals: [String: Double] = [:]
            for s in f.focus { vals[s.subjectId, default: 0] += Double(s.durationSec) / H }
            return Metric(value: max(0, vals.values.max() ?? 0)) { th in subjectCrossings(f, hours: th).min() }
        }),
        family("anki", "Kartičkář", .time, "rectangle.stack", .h, [1, 10, 50, 100], desc: { "\(i($0)) h opakování v Anki" },
               metric: { f in .cumulative(f.sessions.filter { $0.mode == "anki" }.map { ($0.end, Double($0.durationSec) / H) }) }),

        // Pravidelnost
        family("streak", "Série", .regularity, "flame", .d, [3, 7, 14, 30, 60, 100, 200, 365], desc: { "\(i($0)) \(cz($0, "den", "dny", "dní")) učení v řadě" },
               metric: { streak($0) }),
        family("daily-goal", "Denní cíl", .regularity, "target", .d, [1, 7, 30, 100, 365], desc: { "denní cíl splněn \(i($0))×" }, metric: { f in
            let goal = f.doc.settings.dailyGoalMin * 60
            guard goal > 0 else { return .plain(0) }
            return .count(f.perDay.filter { $0.sec >= goal }.map { f.day($0.key) + StudyClock.day - 1 })
        }),
        family("perfect-week", "Perfektní týden", .regularity, "trophy", .x, [1, 4, 12, 26], desc: { "\(i($0))× všechny týdenní cíle splněny" }, metric: { f in
            let goals = f.doc.alive(Subject.self).filter { $0.weeklyGoalMin > 0 && !$0.archived }
            guard !goals.isEmpty else { return .plain(0) }
            var order: [Int] = [], weeks: [Int: [String: Int]] = [:]
            for s in f.sessions {
                let w = f.clock.startOfWeek(s.start)
                if weeks[w] == nil { order.append(w) }
                weeks[w, default: [:]][s.subjectId, default: 0] += s.durationSec
            }
            let ok = order.filter { w in
                f.clock.addDays(w, 7) <= f.now + StudyClock.day && goals.allSatisfy { (weeks[w]![$0.id] ?? 0) >= $0.weeklyGoalMin * 60 }
            }
            return .count(ok.map { f.clock.addDays($0, 7) - 1 })
        }),
        family("weekend", "Víkendář", .regularity, "cup.and.saucer", .x, [1, 5, 20], desc: { "\(i($0))× učení v sobotu i v neděli" }, metric: { f in
            let sats = f.daysSorted.filter { k in
                let t = f.day(k)
                return f.clock.weekdayIndex(t) == 5 && f.perDayIndex[f.clock.dayKey(f.clock.addDays(t, 1))] != nil
            }
            return .count(sats.map { f.clock.addDays(f.day($0), 2) - 1 })
        }),
        family("reflections", "Reflexe", .regularity, "text.bubble", .x, [1, 4, 12, 26, 52], feature: "reflexe",
               desc: { "\(i($0)) \(cz($0, "týdenní reflexe", "týdenní reflexe", "týdenních reflexí"))" },
               metric: { f in .count(f.doc.alive(Reflection.self).map(\.createdAt)) }),

        // Soustředění
        family("sessions", "Bloky", .focus, "square.stack.3d.up", .x, [1, 10, 50, 100, 250, 500, 1000], desc: { "\(n($0)) \(cz($0, "blok", "bloky", "bloků")) učení" },
               metric: { f in .count(f.focus.map(\.end)) }),
        family("deep", "Hluboká práce", .focus, "mountain.2", .x, [1, 10, 50, 100, 250], desc: { "\(i($0))× blok delší než 50 minut" },
               metric: { f in .count(f.focus.filter { $0.durationSec >= 50 * 60 }.map(\.end)) }),
        family("marathon", "Maraton", .focus, "hourglass", .min, [90, 120, 180], desc: { "jeden blok delší než \(i($0)) minut" },
               metric: { f in .record(f.focus.map { ($0.end, Double($0.durationSec) / 60) }) }),
        family("flow", "Flow", .focus, "star", .x, [1, 10, 50, 100], desc: { "\(i($0))× soustředění ohodnoceno 5/5" },
               metric: { f in .count(f.focus.filter { $0.focus == 5 }.map(\.end)) }),
        family("undisturbed", "Nerušeně", .focus, "shield", .x, [10, 50, 200], desc: { "\(i($0)) bloků z časovače (25+ min) bez vyrušení" },
               metric: { f in .count(f.focus.filter { $0.mode != "manual" && $0.durationSec >= 25 * 60 && $0.interruptions == 0 }.map(\.end)) }),

        // Paměť
        family("reviews", "Opakování", .memory, "arrow.triangle.2.circlepath", .x, [1, 25, 100, 250, 500, 1000], desc: { "\(n($0)) opakování témat" },
               metric: { f in .plain(Double(f.doc.alive(Topic.self).reduce(0) { $0 + $1.reviews })) }),
        family("stability", "Pevná paměť", .memory, "pin", .d, [30, 90, 180, 365], desc: { "téma se stabilitou \(i($0))+ dní (FSRS)" },
               metric: { f in .plain(max(0, f.doc.alive(Topic.self).map { $0.fsrs?.s ?? 0 }.max() ?? 0)) }),
        family("mastered", "Zvládnuto", .memory, "checkmark", .x, [1, 5, 20, 50], desc: { "\(i($0)) \(cz($0, "téma", "témata", "témat")) označeno jako zvládnuté" },
               metric: { f in .count(f.doc.alive(Topic.self).filter(\.mastered).map(\.updatedAt)) }),
        family("recall", "Vybavování", .memory, "brain", .x, [1, 10, 50, 100], desc: { "\(i($0))× sepsáno, co si pamatuješ po bloku" },
               metric: { f in .count(f.focus.filter { !($0.recall ?? "").jsTrimmed.isEmpty }.map(\.end)) }),

        // Plánování
        family("plan-done", "Podle plánu", .planning, "checklist", .x, [1, 10, 50, 100, 250],
               desc: { "\(i($0)) \(cz($0, "splněný blok", "splněné bloky", "splněných bloků")) z plánu" },
               metric: { f in .count(f.doc.alive(PlanBlock.self).filter(\.done).map(\.start)) }),

        // Pestrost
        family("polymath", "Polyhistor", .variety, "square.grid.3x3", .x, [2, 3, 5, 8], desc: { "\(i($0)) předmětů s 10+ hodinami" },
               metric: { f in .count(subjectCrossings(f, hours: 10)) }),
        family("interleave", "Prokládání", .variety, "shuffle", .x, [1, 10, 30], desc: { "\(i($0))× tři a více předmětů za den" },
               metric: { f in .count(f.subjectsDay.filter { $0.subjects.count >= 3 }.map { f.day($0.key) + StudyClock.day - 1 }) }),
        family("early", "Ranní ptáče", .variety, "sunrise", .x, [1, 10, 50], desc: { "\(i($0))× začátek učení před 7:00" },
               metric: { f in .count(f.focus.filter { let h = f.clock.hour($0.start); return h < 7 && h >= 4 }.map(\.end)) }),
        family("night", "Noční sova", .variety, "moon", .x, [1, 10, 50], desc: { "\(i($0))× začátek učení po 22:00" },
               metric: { f in .count(f.focus.filter { f.clock.hour($0.start) >= 22 }.map(\.end)) }),
    ]

    static func single(_ id: String, _ name: String, _ group: Group, _ icon: String, _ desc: String, feature: String? = nil, secret: Bool = false,
                       check: @escaping @Sendable (Facts) -> Int?) -> Single {
        Single(id: id, name: name, group: group, feature: feature, icon: icon, desc: desc, secret: secret, check: check)
    }

    /// Nejmenší `createdAt` (`reduce((m, x) => m == null || x.createdAt < m ? x.createdAt : m, null)`).
    static func firstCreated(_ list: [some EntityRecord]) -> Int? {
        list.reduce(nil) { m, x in m.map { x.createdAt < $0 ? x.createdAt : $0 } ?? x.createdAt }
    }

    static func onDay(_ f: Facts, month: Int, day: Int) -> Int? {
        f.sessions.first { s in
            let c = f.clock.calendar.dateComponents([.month, .day], from: f.clock.date(s.start))
            return c.month == month && c.day == day
        }?.end
    }

    public static let singles: [Single] = [
        single("first-plan", "Plánovač", .planning, "calendar", "Naplánuj první blok učení") { f in firstCreated(f.doc.alive(PlanBlock.self)) },
        single("first-exam", "Termín", .planning, "graduationcap", "Přidej první zkoušku") { f in firstCreated(f.doc.alive(Exam.self)) },
        single("exam-ready", "Připraven", .planning, "graduationcap", "Před zkouškou splň všechna naplánovaná opakování") { f in
            let blocks = f.doc.alive(PlanBlock.self)
            for e in f.doc.alive(Exam.self) {
                let t = f.clock.parseDayKey(e.date) ?? .max
                let list = blocks.filter { $0.examId == e.id }
                if t <= f.now && !list.isEmpty && list.allSatisfy(\.done) { return t }
            }
            return nil
        },
        single("experimenter", "Experimentátor", .focus, "flask", "Vyzkoušej všech 6 režimů časovače") { f in
            let ids = Set(TimerMode.builtin.map(\.id))
            var seen: [String: Int] = [:]
            for s in f.focus where ids.contains(s.mode) && seen[s.mode] == nil { seen[s.mode] = s.end }
            return seen.count == ids.count ? seen.values.max() : nil
        },
        single("comeback", "Návrat", .regularity, "arrow.uturn.backward", "Vrať se k učení po pauze delší než 14 dní") { f in
            for i in f.sessions.indices.dropFirst() where f.sessions[i].start - f.sessions[i - 1].end >= 14 * StudyClock.day { return f.sessions[i].end }
            return nil
        },
        single("full-month", "Bez výpadku", .regularity, "trophy", "Uč se každý den celého kalendářního měsíce") { f in
            var order: [String] = [], counts: [String: Int] = [:]
            for k in f.daysSorted {
                let m = String(k.prefix(7))
                if counts[m] == nil { order.append(m) }
                counts[m, default: 0] += 1
            }
            for m in order {
                guard let first = f.clock.parseDayKey("\(m)-01") else { continue }
                let days = f.clock.calendar.range(of: .day, in: .month, for: f.clock.date(first))?.count ?? 31
                if counts[m]! >= days { return f.clock.addDays(first, days - 1) + StudyClock.day - 1 }
            }
            return nil
        },
        single("first-reflection", "Zpětný pohled", .regularity, "text.bubble", "Napiš první týdenní reflexi", feature: "reflexe") { f in
            firstCreated(f.doc.alive(Reflection.self))
        },
        single("anki-link", "Propojeno", .memory, "rectangle.stack", "Propoj Study Tracker s Anki") { f in
            f.doc.records(AnkiSnapshot.self).first { $0.id == "snapshot" }?.raw.int("createdAt")
        },
        single("new-year", "Předsevzetí", .special, "sparkles", "Uč se 1. ledna", secret: true) { onDay($0, month: 1, day: 1) },
        single("pi-day", "Den π", .special, "function", "Uč se 14. března", secret: true) { onDay($0, month: 3, day: 14) },
        single("christmas", "Štědrý den", .special, "gift", "Uč se na Štědrý den", secret: true) { onDay($0, month: 12, day: 24) },
        single("midnight", "Přes půlnoc", .special, "moon.stars", "Blok učení přes půlnoc", secret: true) { f in
            f.focus.first { f.clock.startOfDay($0.start) != f.clock.startOfDay($0.end - 1) }?.end
        },
    ]
}

/// Stabilní řazení (`Array.prototype.sort` v JS je stabilní).
func stable<T>(_ list: [T], by less: (T, T) -> Bool) -> [T] { list.stableSorted(by: less) }

extension Stats {
    /// Průběh série den po dni od `from` do dne `until` včetně (`streakRuns`).
    public static func streakRuns(_ days: Set<String>, from: Int, until: Int, restDays: Int, clock: StudyClock) -> [(t: Int, run: Int)] {
        let end = clock.startOfDay(until)
        var out: [(Int, Int)] = []
        var run = 0, week = -1, rest = 0
        var t = clock.startOfDay(from)
        while t <= end {
            let w = clock.startOfWeek(t)
            if w != week {
                week = w
                rest = 0
            }
            if days.contains(clock.dayKey(t)) {
                run += 1
            } else if t == end {
                // dnešek ještě běží
            } else if run > 0 && rest < restDays {
                rest += 1
            } else {
                run = 0
            }
            out.append((t, run))
            t = clock.addDays(t, 1)
        }
        return out
    }
}

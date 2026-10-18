import Core
import Foundation

private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

/// Co dělat: typ doporučení „Co teď?“ nebo bloku ranního plánu.
public enum Activity: String, Sendable, Hashable {
    /// Blok z plánu, který je na řadě teď.
    case plan
    /// Příprava na blízkou zkoušku – procvičování a testování.
    case exam
    /// Pokračování v látce, kterou ses u předmětu učil naposledy.
    case `continue`
    /// Kartičky v Anki.
    case anki
    /// Nedokončený blok z minulých dní, který ranní plán přesune na dnešek.
    case carry

    /// Popisek u doporučení (`ACTIVITY_LABEL` na webu).
    public var label: String {
        switch self {
        case .plan: "podle plánu"
        case .exam: "příprava na zkoušku"
        case .continue: "pokračování"
        case .anki: "kartičky"
        case .carry: "nedokončeno"
        }
    }
}

/// Jedno doporučení „Co teď?“.
public struct Recommendation: Sendable, Hashable, Identifiable {
    /// Signály 0–1, ze kterých je skóre (`R` mají jen kartičky z Anki).
    public struct Signals: Sendable, Hashable {
        public var E = 0.0, R = 0.0, G = 0.0, N = 0.0, P = 0.0, X = 0.0
    }

    public var id: String { key }
    public let key: String
    /// `nil` = kartičky z Anki bez předmětu.
    public let subjectId: String?
    public let activity: Activity
    public let title: String
    /// Co předvyplnit do časovače.
    public let topic: String
    public let minutes: Int
    public let modeId: String
    public internal(set) var score: Double
    public let signals: Signals
    /// Důvody v lidské řeči, nejsilnější první.
    public let reasons: [String]
    /// Blok plánu, který se po uložení sezení odškrtne.
    public let planBlockId: String?
}

/// „Co se mám teď učit?“ (`src/lib/recommend.ts` na webu) – stejné skóre, důvody i délka bloku.
///
/// Pro každý aktivní předmět spočítá signály (0–1) a skóre jako vážený součet:
///
///  E  zkouška      – plynule rostoucí naléhavost 1 / (1 + (dny/7)²): za 3 dny 0,84 · za týden 0,5 · za měsíc 0,05
///  G  týdenní cíl  – zaostávání za cílem úměrně tomu, jakou část týdne už obvykle máš za sebou
///  N  zanedbání    – dny od posledního učení předmětu: 1 − e^(−dny/4)
///  P  plán         – blok naplánovaný na teď (1), dnes zmeškaný (0,6), později dnes (0,4)
///  X  prostřídat   – kolik ses předmětu věnoval za poslední 3 h (+ jestli byl poslední) – prokládání a únava;
///                    blízká zkouška únavu toleruje víc, „hned znovu totéž“ ale ne
///
///  skóre = 0,30·E + 0,20·G + 0,10·N + 0,15·P − 0,35·(únava·(1 − 0,6·E) + 0,3 když je předmět hned po sobě)
///
/// Opakování na Macu není: signál R (témata k opakování podle FSRS) je vždy 0, činnosti „vybavování“
/// a „nové téma“ nevznikají a témata se nečtou. Opakování po přednášce taky ne.
///
/// Všechno, co nezávisí na simulaci ranního plánu, se spočítá jednou při vytvoření – ranní plán pak
/// volá `recommend(_:)` opakovaně bez dalšího průchodu sezeními.
public struct Recommender: Sendable {
    public enum Weight {
        public static let E = 0.3, R = 0.25, G = 0.2, N = 0.1, P = 0.15, X = 0.35
    }

    /// Simulace ranního plánu: předměty už zařazené do návrhu.
    public struct Simulation: Sendable {
        public var extraMinutes: [String: Double] = [:]
        public var recentMinutes: [String: Double] = [:]
        public var lastSubject: String?
        public init() {}
    }

    /// Předmět, který má smysl doporučit, s předpočítanými údaji.
    struct Candidate: Sendable {
        let id: String
        let goal: Int
        let lastStudied: Int
        let exam: Exam?
        let examDays: Double
        let E: Double
        let P: Double
        let planBlock: PlanBlock?
        /// Minuty od začátku týdne.
        let doneWeek: Double
        /// Minuty za poslední 3 h.
        let recentMin: Double
        /// Poslední téma z vlastního učení (ne z Anki).
        let lastTopic: String?
    }

    public let now: Int
    let candidates: [Candidate]
    let share: Double
    let lowFocus: Bool
    let lastSubject: String?
    let defaultMode: String
    let block: (minutes: Int, modeId: String)
    let anki: Recommendation?

    public init(document doc: AppDocument, now: Int, clock: StudyClock) {
        self.init(document: doc, sessions: SessionFacts.alive(in: doc), now: now, clock: clock)
    }

    /// `sessions` = nesmazaná sezení z `doc` (ranní plán je přečte jednou pro všechny výpočty).
    init(document doc: AppDocument, sessions: [SessionFacts], now: Int, clock: StudyClock) {
        self.now = now
        let today = clock.startOfDay(now)
        let tomorrow = clock.addDays(today, 1)
        let weekStart = clock.startOfWeek(now)
        let rated = Rated.list(sessions, clock: clock)
        share = Self.weekShare(sessions, now: now, clock: clock)
        lowFocus = Self.lowFocusNow(rated, now: now, clock: clock)
        defaultMode = doc.settings.defaultMode
        block = Self.personalBlock(rated, now: now, clock: clock)

        // Jeden průchod sezeními pro všechny předměty
        struct Facts { var lastStudied = 0, doneWeek = 0.0, recentMin = 0.0, lastTopic: (end: Int, topic: String)? }
        var facts: [String: Facts] = [:]
        var last: SessionFacts?
        for s in sessions {
            var f = facts[s.subjectId] ?? Facts()
            f.lastStudied = max(f.lastStudied, s.end)
            if s.start >= weekStart { f.doneWeek += Double(s.durationSec) / 60 }
            if s.end > now - 3 * StudyClock.hour && s.start <= now { f.recentMin += Double(s.durationSec) / 60 }
            if !s.topic.isEmpty && s.mode != "anki" && (f.lastTopic.map { s.end > $0.end } ?? true) { f.lastTopic = (s.end, s.topic) }
            facts[s.subjectId] = f
            if s.end <= now + StudyClock.minute && (last.map { s.end > $0.end } ?? true) { last = s }
        }
        lastSubject = last.flatMap { now - $0.end < 45 * StudyClock.minute ? $0.subjectId : nil }

        let exams = doc.alive(Exam.self)
        let blocks = doc.alive(PlanBlock.self)
        candidates = doc.alive(Subject.self).filter { !$0.archived && $0.id != "anki" }.compactMap { subj in
            let f = facts[subj.id] ?? Facts()
            // nejbližší zkouška, která ještě neproběhla (při shodě data první v datech)
            var exam: (Exam, day: Int)?
            for e in exams where e.subjectId == subj.id {
                guard let day = clock.parseDayKey(e.date), day + StudyClock.day > now else { continue }
                if exam.map({ e.date < $0.0.date }) ?? true { exam = (e, day) }
            }
            let planned = blocks.filter { $0.subjectId == subj.id && !$0.done && $0.start >= today && $0.start < tomorrow }
            let active = subj.weeklyGoalMin > 0 || exam != nil || !planned.isEmpty || (f.lastStudied != 0 && now - f.lastStudied < 30 * StudyClock.day)
            guard active else { return nil }

            let examDays = exam.map { max(0, Double($0.day - now) / Double(StudyClock.day)) } ?? .infinity
            let q = examDays / 7
            var P = 0.0
            var planBlock: PlanBlock?
            for b in planned {
                let p = b.start <= now + 30 * StudyClock.minute && b.start + b.durationMin * StudyClock.minute >= now - 30 * StudyClock.minute ? 1
                    : b.start > now ? 0.4 : 0.6
                if p > P {
                    P = p
                    planBlock = b
                }
            }
            return Candidate(
                id: subj.id, goal: subj.weeklyGoalMin, lastStudied: f.lastStudied, exam: exam?.0, examDays: examDays,
                E: exam != nil ? 1 / (1 + q * q) : 0, P: P, planBlock: planBlock, doneWeek: f.doneWeek, recentMin: f.recentMin,
                lastTopic: f.lastTopic?.topic
            )
        }
        anki = Self.ankiRecommendation(doc, now: now, today: today, lowFocus: lowFocus, clock: clock)
    }

    /// Doporučení seřazená od nejlepšího. Se simulací (ranní plán) bez plánu, Anki a opakování po přednášce.
    public func recommend(_ sim: Simulation? = nil) -> [Recommendation] {
        let W = Weight.self
        let lastSubject = sim != nil ? sim!.lastSubject : self.lastSubject
        var out: [Recommendation] = []
        for c in candidates {
            let extra = sim?.extraMinutes[c.id] ?? 0
            let E = c.E
            let R = 0.0
            let doneWeek = c.doneWeek + extra
            let goal = Double(c.goal)
            let G = c.goal > 0 ? clamp((goal * share - doneWeek) / goal) : 0
            let daysSince = c.lastStudied != 0 ? Double(now - c.lastStudied) / Double(StudyClock.day) : 30
            let N = extra > 0 ? 0 : clamp(1 - exp(-daysSince / 4))
            // při plánování dne se plán teprve tvoří
            let P = sim != nil ? 0 : c.P
            let recentMin = c.recentMin + (sim?.recentMinutes[c.id] ?? 0)
            let isLast = lastSubject == c.id ? 0.3 : 0
            let X = clamp(recentMin / 120 + isLast)
            let penalty = W.X * (clamp(recentMin / 120) * (1 - 0.6 * E) + isLast)
            let score = W.E * E + W.R * R + W.G * G + W.N * N + W.P * P - penalty

            let activity: Activity
            let title: String
            let topic: String
            if P >= 1, let b = c.planBlock {
                activity = .plan
                title = b.title.isEmpty ? "Blok podle plánu" : "Podle plánu: \(b.title)"
                topic = blockTopics(b.title).first ?? ""
            } else if E >= 0.35, let exam = c.exam {
                activity = .exam
                title = "Příprava na zkoušku: \(exam.name)"
                topic = exam.name
            } else {
                activity = .continue
                title = c.lastTopic.map { "Pokračovat: \($0)" } ?? "Nová látka"
                topic = c.lastTopic ?? ""
            }
            let block: (minutes: Int, modeId: String) = activity == .plan ? (c.planBlock!.durationMin, defaultMode) : self.block

            var reasons: [(Double, String)] = []
            if E > 0.05 {
                let d = Int(c.examDays.rounded(.up))
                reasons.append((W.E * E, d <= 0 ? "zkouška dnes" : "zkouška za \(d) \(Self.days(d))"))
            }
            if G > 0.05 { reasons.append((W.G * G, "\(Int(JS.round(goal * share - doneWeek))) min pod týdenním plánem")) }
            if N > 0.4 && c.lastStudied != 0 {
                let d = Int(daysSince.rounded(.down))
                reasons.append((W.N * N, "\(d) \(Self.days(d)) bez učení"))
            }
            if P > 0 {
                reasons.append((W.P * P, P >= 1 ? "naplánováno na teď" : P > 0.5 ? "dnes naplánováno a zatím neodučeno" : "naplánováno později dnes"))
            }
            if X > 0.3 { reasons.append((-W.X * X, "nedávno na řadě – vhodné prostřídat")) }

            out.append(Recommendation(
                key: "\(c.id):\(activity.rawValue)", subjectId: c.id, activity: activity, title: title, topic: topic,
                minutes: block.minutes, modeId: block.modeId, score: score, signals: .init(E: E, R: R, G: G, N: N, P: P, X: X),
                reasons: JS.sort(reasons) { Self.order($1.0 - $0.0) }.map(\.1),
                planBlockId: activity == .plan ? c.planBlock?.id : nil
            ))
        }
        if sim == nil, let anki { out.append(anki) }
        // V „slabší“ denní době mírně upřednostni lehčí činnosti, náročnou látku odsuň
        if lowFocus { for i in out.indices where out[i].activity == .continue { out[i].score -= 0.05 } }
        return JS.sort(out) { Self.order($1.score - $0.score) }
    }

    // MARK: - Signály a délka bloku

    // MARK: - Sezení

    /// Hodnocené sezení (ne z Anki) s částí dne, kdy začalo – pro délku bloku a „slabší“ denní dobu.
    struct Rated: Sendable {
        let focus: Int
        let durationSec: Int
        let part: Int

        static func list(_ sessions: [SessionFacts], clock: StudyClock) -> [Rated] {
            sessions.compactMap { s in
                s.focusValue != 0 && s.mode != "anki" ? Rated(focus: s.focusValue, durationSec: s.durationSec, part: dayPart(clock.hour(s.start))) : nil
            }
        }

        /// Průměrné soustředění (`avgFocus` na webu).
        static func average(_ list: some Collection<Rated>) -> Double? {
            list.isEmpty ? nil : Double(list.reduce(0) { $0 + $1.focus }) / Double(list.count)
        }
    }

    /// Jaká část týdenní práce bývá hotová do tohoto okamžiku týdne – podle posledních 8 týdnů (kdo se učí
    /// hlavně o víkendu, toho ve středu týdenní cíl ještě netlačí). Bez dostatku dat rovnoměrně přes 7 dní;
    /// osobní tempo se mírně „přitahuje“ k rovnoměrnému.
    public static func weekShare(_ sessions: [Session], now: Int, clock: StudyClock) -> Double {
        weekShare(sessions.map(SessionFacts.init), now: now, clock: clock)
    }

    static func weekShare(_ sessions: [SessionFacts], now: Int, clock: StudyClock) -> Double {
        let weekStart = clock.startOfWeek(now)
        let elapsed = clamp(Double(now - weekStart) / Double(7 * StudyClock.day))
        let uniform = max(elapsed, 1.0 / 7)
        let from = clock.addDays(weekStart, -56)
        let hist = sessions.filter { $0.start >= from && $0.start < weekStart && $0.mode != "anki" }
        let total = hist.reduce(0) { $0 + $1.durationSec }
        // týdny s učením: začátky 8 minulých týdnů se spočítají jednou, sezení se k nim jen přiřadí
        let starts = (1...8).map { clock.addDays(weekStart, -7 * $0) }
        let weeks = Set(hist.map { s in starts.firstIndex { s.start >= $0 } })
        guard total >= 5 * 3600, weeks.count >= 3 else { return uniform }
        func pos(_ t: Int) -> Double { Double(clock.weekdayIndex(t) * 1440) + clock.minutesOfDay(t) }
        let nowPos = pos(now)
        let before = hist.filter { pos($0.start) < nowPos }.reduce(0) { $0 + $1.durationSec }
        return max(0.75 * (Double(before) / Double(total)) + 0.25 * elapsed, 1.0 / 14)
    }

    /// Část dne: dopoledne, odpoledne, večer, noc.
    static func dayPart(_ hour: Int) -> Int {
        hour >= 5 && hour < 12 ? 0 : hour >= 12 && hour < 17 ? 1 : hour >= 17 && hour < 22 ? 2 : 3
    }

    /// Délka bloku podle tvých dat: v jaké délce bloků máš v tuto denní dobu nejlepší soustředění.
    /// Průměr každé délky se „přitahuje“ k celkovému (3 bloky), delší blok vyhraje jen se zřetelně lepším
    /// soustředěním (+0,15). Bez dat 50 min.
    static func personalBlock(_ all: [Rated], now: Int, clock: StudyClock) -> (minutes: Int, modeId: String) {
        let part = dayPart(clock.hour(now))
        let rated = all.filter { $0.part == part }
        let buckets: [(max: Double, minutes: Int, modeId: String)] = [(35, 25, "pomodoro"), (70, 50, "pomodoro-long"), (.infinity, 90, "ultradian")]
        let g = Rated.average(rated) ?? 3
        let k = 3.0
        var best: (minutes: Int, modeId: String)?
        var bestF = 0.0
        for (i, b) in buckets.enumerated() {
            let lo = i == 0 ? 0 : buckets[i - 1].max
            let list = rated.filter { Double($0.durationSec) / 60 > lo && Double($0.durationSec) / 60 <= b.max }
            guard list.count >= 3 else { continue }
            let f = (Double(list.reduce(0) { $0 + $1.focus }) + k * g) / (Double(list.count) + k)
            if f > bestF + 0.15 {
                best = (b.minutes, b.modeId)
                bestF = f
            }
        }
        return best ?? (50, "pomodoro-long")
    }

    /// Je teď pro tebe „slabší“ denní doba? (soustředění v této části dne výrazně pod průměrem)
    public static func lowFocusNow(_ sessions: [Session], now: Int, clock: StudyClock) -> Bool {
        lowFocusNow(Rated.list(sessions.map(SessionFacts.init), clock: clock), now: now, clock: clock)
    }

    static func lowFocusNow(_ rated: [Rated], now: Int, clock: StudyClock) -> Bool {
        let part = dayPart(clock.hour(now))
        let here = rated.filter { $0.part == part }
        guard here.count >= 5, rated.count >= 10 else { return false }
        return (Rated.average(here) ?? 0) <= (Rated.average(rated) ?? 0) - 0.4
    }

    /// Krátká hláška nad doporučením (pozdní hodina, splněný cíl, slabší denní doba).
    public static func contextNote(_ doc: AppDocument, now: Int, clock: StudyClock) -> String? {
        let today = clock.startOfDay(now)
        let sessions = doc.alive(Session.self)
        let todaySec = sessions.filter { $0.start >= today }.reduce(0) { $0 + $1.durationSec }
        let goal = doc.settings.dailyGoalMin * 60
        let h = clock.hour(now)
        if h >= 23 || h < 4 { return "Je pozdě – spánek je pro ukládání do paměti stejně důležitý jako učení. Když už, tak krátce." }
        if goal > 0 && Double(todaySec) >= Double(goal) * 1.5 { return "Dnešní cíl máš splněný s rezervou. Klidně si dej volno – i odpočinek je součást učení." }
        if lowFocusNow(sessions, now: now, clock: clock) { return "V tuhle denní dobu ti soustředění obvykle jde hůř – vhodné spíš na kartičky a lehčí látku." }
        return nil
    }

    // MARK: - Anki

    static let answersPerCard = (new: 2.5, learn: 1.5, review: 1.1)

    /// Kartičky z dnešního stavu Anki – lehká činnost, hodí se hlavně ve „slabší“ denní době nebo mezi bloky.
    static func ankiRecommendation(_ doc: AppDocument, now: Int, today: Int, lowFocus: Bool, clock: StudyClock) -> Recommendation? {
        guard let snap = doc.records(AnkiSnapshot.self).first(where: { $0.id == "snapshot" && !$0.isDeleted }),
              clock.startOfDay(snap.at) == today else { return nil }
        let due = snap.decks.reduce(0) { $0 + $1.newCount + $1.learnCount + $1.reviewCount }
        guard due > 0 else { return nil }
        let secPerAnswer = ankiSecPerAnswer(doc.records(Session.self), today: snap, now: now)
        let minutes = ankiEstimateMin(snap.decks, secPerAnswer: secPerAnswer)
        let fresh = snap.decks.reduce(0) { $0 + $1.newCount }
        var reasons = ["odhad ~\(minutes) min podle tvého tempa (\(Int(JS.round(secPerAnswer))) s na odpověď)"]
        if fresh > 0 { reasons.append("\(fresh) \(fresh == 1 ? "nová karta se" : fresh < 5 ? "nové karty se" : "nových karet se") dnes ukáže víckrát") }
        if lowFocus { reasons.append("teď ti soustředění obvykle jde hůř – kartičky jsou ideální") }
        return Recommendation(
            key: "anki", subjectId: nil, activity: .anki, title: "Anki: \(due) \(Format.plural(due, "karta", "karty", "karet"))", topic: "",
            minutes: minutes, modeId: "stopwatch", score: 0.12 + 0.25 * clamp(Double(due) / 150) + (lowFocus ? 0.15 : 0),
            signals: .init(R: clamp(Double(due) / 150)), reasons: reasons, planBlockId: nil
        )
    }

    /// Tempo v sekundách na odpověď: z Anki sezení za posledních 30 dní, jinak z dneška, jinak 10 s.
    static func ankiSecPerAnswer(_ sessions: [Session], today: AnkiSnapshot?, now: Int) -> Double {
        var sec = 0, answers = 0.0
        for s in sessions where s.mode == "anki" && !s.isDeleted && s.start >= now - 30 * StudyClock.day {
            let n = s.note.firstMatch(of: /([0-9]+) karet/).flatMap { Double($0.1) } ?? 0
            if n > 0 {
                sec += s.durationSec
                answers += n
            }
        }
        if answers >= 50 { return Double(sec) / answers }
        if let today, today.reviewedToday >= 10, today.msToday > 0 { return Double(today.msToday) / 1000 / Double(today.reviewedToday) }
        return 10
    }

    /// Odhad času na dnešní karty v minutách (po 5 min, 5–180); nové karty se první den ukazují víckrát.
    static func ankiEstimateMin(_ decks: [AnkiDeckStat], secPerAnswer: Double) -> Int {
        let a = answersPerCard
        let answers = decks.reduce(0.0) { $0 + Double($1.newCount) * a.new + Double($1.learnCount) * a.learn + Double($1.reviewCount) * a.review }
        return max(5, min(180, Int(JS.round(answers * secPerAnswer / 60 / 5)) * 5))
    }

    // MARK: - Pomocné

    static func days(_ n: Int) -> String { Format.plural(n, "den", "dny", "dní") }

    /// Rozdíl jako výsledek porovnání pro `JS.sort` (záporný = dřív).
    static func order(_ d: Double) -> Int { d < 0 ? -1 : d > 0 ? 1 : 0 }
}

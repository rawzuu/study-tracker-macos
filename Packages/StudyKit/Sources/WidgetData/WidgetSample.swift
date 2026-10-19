import Foundation

extension WidgetSnapshot {
    /// Smyšlený souhrn pro galerii widgetů a náhledy (nikdy skutečná data).
    public static func sample(now: Int, timer: TimerInfo? = nil) -> WidgetSnapshot {
        let cal = Calendar.current
        let date = Date(timeIntervalSince1970: Double(now) / 1000)
        let today = Int(cal.startOfDay(for: date).timeIntervalSince1970 * 1000)
        func day(_ n: Int) -> Int { Int((cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: date)) ?? date).timeIntervalSince1970 * 1000) }
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int { day(d) + (h * 60 + m) * 60_000 }
        let weekday = (cal.component(.weekday, from: date) + 5) % 7
        return WidgetSnapshot(
            generatedAt: now,
            days: [today, day(1), day(2)],
            goalSec: 2 * 3600,
            studiedSec: 85 * 60,
            weekSec: 6 * 3600 + 30 * 60,
            weekGoalSec: 13 * 3600,
            week: (0..<7).map { $0 < weekday ? [3_600, 0, 4_800, 2_100, 6_300, 6_000][$0 % 6] : $0 == weekday ? 85 * 60 : 0 },
            todayIndex: weekday,
            streak: 5,
            subjectWeek: [
                .init(subjectId: "anat", sec: 3 * 3600 + 10 * 60, goalSec: 5 * 3600),
                .init(subjectId: "fyz", sec: 3600 + 50 * 60, goalSec: 4 * 3600),
                .init(subjectId: "bio", sec: 3600 + 30 * 60, goalSec: 4 * 3600),
            ],
            subjects: [
                "anat": .init(name: "Anatomie", color: "#c98a5b"),
                "fyz": .init(name: "Fyziologie", color: "#7da0c9"),
                "bio": .init(name: "Biochemie", color: "#8fae8b"),
            ],
            plan: [
                .init(id: "p1", subjectId: "bio", title: "Glykolýza", topic: "Glykolýza", start: at(0, 8), end: at(0, 8, 50), done: true),
                .init(id: "p2", subjectId: "anat", title: "Horní končetina", topic: "Horní končetina", start: at(0, 10), end: at(0, 10, 50), done: true),
                .init(id: "p3", subjectId: "fyz", title: "Srdeční cyklus", topic: "Srdeční cyklus", start: at(0, 14), end: at(0, 14, 45), done: false),
                .init(id: "p4", subjectId: "anat", title: "Lebka", topic: "Lebka", start: at(0, 16), end: at(0, 16, 50), done: false),
                .init(id: "p5", subjectId: "bio", title: "", topic: "", start: at(0, 19), end: at(0, 19, 25), done: false),
                .init(id: "p6", subjectId: "fyz", title: "Ledviny", topic: "Ledviny", start: at(1, 9), end: at(1, 9, 50), done: false),
            ],
            exams: [
                .init(id: "e1", subjectId: "anat", name: "Zápočet z anatomie", day: day(4), time: "9:00"),
                .init(id: "e2", subjectId: "fyz", name: "Zkouška z fyziologie", day: day(16), time: ""),
                .init(id: "e3", subjectId: "bio", name: "Test z biochemie", day: day(23), time: "13:30"),
            ],
            timer: timer ?? .idle,
            nextUp: [
                .init(subjectId: "anat", title: "Příprava na zkoušku: Zápočet z anatomie", topic: "", modeId: "pomodoro", minutes: 50,
                      reason: "zkouška za 4 dny"),
                .init(subjectId: "fyz", title: "", topic: "Srdeční cyklus", modeId: "pomodoro", minutes: 25,
                      reason: "naplánováno později dnes"),
            ]
        )
    }

    /// Běžící blok učení pro náhledy: Anatomie, 25 min, běží 9:25.
    public static func sampleTimer(now: Int) -> TimerInfo {
        TimerInfo(status: .running, isWork: true, subjectId: "anat", topic: "Lebka", modeName: "Pomodoro", countsUp: false,
                  segmentStart: now - (9 * 60 + 25) * 1000, accumulated: 0, phaseDurationMs: 25 * 60_000, planBlockId: nil)
    }
}

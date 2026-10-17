import Core
import Engine
import Foundation

/// Smyšlená ukázková data pro UI testy a náhledy (nikdy skutečná data uživatele).
public enum DemoData {
    public static func document(now: Int, clock: StudyClock) -> AppDocument {
        var doc = AppDocument.empty
        let subjects: [(id: String, name: String, color: String, goalMin: Int)] = [
            ("demo-anat", "Anatomie", "#c98a5b", 360),
            ("demo-fyz", "Fyziologie", "#7fa6c9", 240),
            ("demo-bio", "Biochemie", "#8fae8b", 180),
            ("demo-lat", "Latina", "#b48ead", 0),
        ]
        let created = clock.addDays(now, -60)
        doc.upsert(subjects.map { s in
            Subject(raw: ["id": .string(s.id), "name": .string(s.name), "color": .string(s.color), "weeklyGoalMin": .number(Double(s.goalMin)), "archived": false])
        }, now: created)

        // Deterministický rozpis sezení za poslední 3 týdny (bez náhody, ať UI testy vidí vždy totéž).
        let topics = ["Horní končetina", "Srdeční cyklus", "Glykolýza", "Deklinace", "Ledviny", "Lebka"]
        var sessions: [Session] = []
        let today = clock.startOfDay(now)
        for dayOffset in 0..<21 where dayOffset % 7 != 5 {
            let day = clock.addDays(today, -dayOffset)
            for slot in 0..<(dayOffset % 3 + 1) {
                let subject = subjects[(dayOffset + slot) % 3]
                let start = day + (8 + slot * 3) * StudyClock.hour + (dayOffset % 4) * 10 * StudyClock.minute
                guard start + 50 * StudyClock.minute <= now else { continue }
                let minutes = 25 + ((dayOffset * 7 + slot * 11) % 4) * 10
                sessions.append(Session(raw: [
                    "id": .string("demo-s-\(dayOffset)-\(slot)"),
                    "subjectId": .string(subject.id),
                    "topic": .string(topics[(dayOffset + slot * 2) % topics.count]),
                    "start": .number(Double(start)),
                    "end": .number(Double(start + (minutes + 5) * StudyClock.minute)),
                    "durationSec": .number(Double(minutes * 60)),
                    "mode": .string(slot == 0 ? "pomodoro" : "52-17"),
                    "focus": .number(Double(3 + (dayOffset + slot) % 3)),
                    "interruptions": .number(Double(slot)),
                    "note": "",
                ]))
            }
        }
        doc.upsert(sessions, now: created)

        // Dnešní blok plánu, ze kterého jde spustit časovač.
        doc.upsert(PlanBlock(raw: [
            "id": "demo-plan", "subjectId": "demo-fyz", "title": "Opakování: Ledviny, Srdce",
            "start": .number(Double(today + 20 * StudyClock.hour)), "durationMin": 45, "done": false, "note": "",
        ]), now: created)

        // Kalendář: blok zítra, hotový blok včera (kryje se se sezením, ve „Vše“ ho nahradí) a blok přes půlnoc.
        func block(_ id: String, _ subject: String, _ title: String, day: Int, minute: Int, duration: Int, done: Bool = false) -> PlanBlock {
            PlanBlock(raw: [
                "id": .string(id), "subjectId": .string(subject), "title": .string(title),
                "start": .number(Double(clock.atMinutes(clock.addDays(today, day), minute))), "durationMin": .number(Double(duration)),
                "done": .bool(done), "note": "",
            ])
        }
        doc.upsert([
            block("demo-plan-zitra", "demo-anat", "Horní končetina", day: 1, minute: 9 * 60, duration: 90),
            block("demo-plan-vcera", "demo-bio", "", day: -1, minute: 11 * 60, duration: 45, done: true),
            block("demo-plan-noc", "demo-lat", "Deklinace", day: 2, minute: 23 * 60, duration: 60),
        ], now: created)
        doc.upsert([
            Exam(raw: ["id": "demo-exam-anat", "subjectId": "demo-anat", "name": "Zápočet z anatomie",
                       "date": .string(clock.dayKey(clock.addDays(today, 4))), "time": "09:00", "note": ""]),
            Exam(raw: ["id": "demo-exam-fyz", "subjectId": "demo-fyz", "name": "Zkouška z fyziologie",
                       "date": .string(clock.dayKey(clock.addDays(today, 16))), "time": "", "note": ""]),
        ], now: created)

        // Rychlý vlastní režim (3 s učení) a minimum 1 s, ať UI test projde celý blok bez čekání.
        doc.upsert(TimerPreset(raw: [
            "id": "demo-rychly", "name": "Rychlý test", "workMin": 0.05, "shortBreakMin": 0.05, "longBreakMin": 0.1, "roundsBeforeLong": 4,
        ]), now: created)
        doc.updateSettings(now: created) { $0.minSessionSec = 1 }
        return doc
    }
}

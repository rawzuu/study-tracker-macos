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

        // Rychlý vlastní režim (3 s učení) a minimum 1 s, ať UI test projde celý blok bez čekání.
        doc.upsert(TimerPreset(raw: [
            "id": "demo-rychly", "name": "Rychlý test", "workMin": 0.05, "shortBreakMin": 0.05, "longBreakMin": 0.1, "roundsBeforeLong": 4,
        ]), now: created)
        doc.updateSettings(now: created) { $0.minSessionSec = 1 }
        return doc
    }
}

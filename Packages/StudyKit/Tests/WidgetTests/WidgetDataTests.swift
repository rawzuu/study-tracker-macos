import Foundation
import Testing
@testable import WidgetData

private let minute = 60_000
private let hour = 60 * minute
private let day = 24 * hour

/// Pevný souhrn: půlnoc dne 0, blok 10:00–10:50 hotový, 14:00–14:45, zítra 9:00.
private func snapshot(timer: WidgetSnapshot.TimerInfo = .idle) -> WidgetSnapshot {
    WidgetSnapshot(
        generatedAt: 9 * hour, days: [0, day, 2 * day], goalSec: 7200, studiedSec: 3000, weekSec: 9000, weekGoalSec: 36000,
        week: [1000, 2000, 3000, 0, 0, 0, 0], todayIndex: 2, streak: 4,
        subjectWeek: [.init(subjectId: "a", sec: 5000, goalSec: 18000)],
        subjects: ["a": .init(name: "Anatomie", color: "#c98a5b")],
        plan: [
            .init(id: "done", subjectId: "a", title: "", topic: "", start: 10 * hour, end: 10 * hour + 50 * minute, done: true),
            .init(id: "p", subjectId: "a", title: "Lebka", topic: "Lebka", start: 14 * hour, end: 14 * hour + 45 * minute, done: false),
            .init(id: "z", subjectId: "a", title: "", topic: "", start: day + 9 * hour, end: day + 10 * hour, done: false),
        ],
        exams: [.init(id: "e", subjectId: "a", name: "Zápočet", day: 4 * day, time: "")],
        timer: timer, nextUp: []
    )
}

private func running(at start: Int, length: Int = 25 * minute) -> WidgetSnapshot.TimerInfo {
    .init(status: .running, isWork: true, subjectId: "a", topic: "", modeName: "Pomodoro", countsUp: false,
          segmentStart: start, accumulated: 0, phaseDurationMs: length, planBlockId: nil)
}

@Suite("Widgety – stav v čase")
struct WidgetMomentTests {
    @Test("Dnešek: plán, aktuální a další blok, dny do zkoušky")
    func today() {
        let s = snapshot()
        let m = WidgetMoment(s, at: 14 * hour + 10 * minute)
        #expect(m.day == 0 && m.plan.map(\.id) == ["done", "p"])
        #expect(m.current?.id == "p" && m.next == nil)
        #expect(m.studiedSec == 3000 && m.exams.map(\.daysLeft) == [4])
        #expect(WidgetMoment(s, at: 11 * hour).next?.id == "p")
    }

    @Test("Po půlnoci bez aplikace: zítřek, dnešní čas od nuly, zkouška o den blíž")
    func rollover() {
        let m = WidgetMoment(snapshot(), at: day + 8 * hour)
        #expect(m.day == day && m.plan.map(\.id) == ["z"] && m.next?.id == "z")
        #expect(m.studiedSec == 0 && m.exams.map(\.daysLeft) == [3])
        #expect(m.todayIndex == 3 && !m.isStale)
        #expect(WidgetMoment(snapshot(), at: 2 * day + 1).isStale)
    }

    @Test("Běžící blok se do dneška počítá živě, nejvýš do konce fáze")
    func live() {
        let s = snapshot(timer: running(at: 12 * hour))
        #expect(WidgetMoment(s, at: 12 * hour + 10 * minute).studiedSec == 3000 + 600)
        let over = WidgetMoment(s, at: 13 * hour)
        #expect(over.studiedSec == 3000 + 1500 && over.phaseOver)
        #expect(WidgetMoment(s, at: 12 * hour + 10 * minute).subjectWeek.first?.sec == 5000 + 600, "i do týdne předmětu")
        // Pondělí po neděli bez aplikace: nový týden od nuly.
        var sunday = snapshot()
        sunday.todayIndex = 6
        let monday = WidgetMoment(sunday, at: day + hour)
        #expect(monday.weekSec == 0 && monday.subjectWeek.first?.sec == 0 && monday.week == Array(repeating: 0, count: 7))
        #expect(WidgetMoment(snapshot(), at: day + hour).subjectWeek.first?.sec == 5000, "jinak týden běží dál")
    }

    @Test("Časová osa: minuty během bloku, začátky a konce bloků, půlnoc")
    func timeline() {
        let idle = WidgetTimeline.dates(snapshot(), from: 13 * hour, hours: 12)
        #expect(idle == [13 * hour, 14 * hour, 14 * hour + 45 * minute, day])
        let busy = WidgetTimeline.dates(snapshot(timer: running(at: 13 * hour)), from: 13 * hour + 30_000, hours: 1)
        #expect(busy.first == 13 * hour + 30_000 && busy.contains(13 * hour + 25 * minute) && busy.contains(14 * hour) && busy.count == 27)
        #expect(WidgetTimeline.refresh(snapshot(), from: 20 * hour) == day + 1000)
    }

    @Test("Odhad po stisku: pauza drží čas, pokračování běží dál, ukončení přičte blok k dnešku")
    func optimistic() {
        let s = snapshot(timer: running(at: 12 * hour))
        let paused = s.applying(.pause, at: 12 * hour + 10 * minute)
        #expect(paused.timer.status == .paused && paused.timer.remaining(at: 13 * hour) == 15 * minute)
        let resumed = paused.applying(.resume, at: 12 * hour + 20 * minute)
        #expect(resumed.timer.remaining(at: 12 * hour + 25 * minute) == 10 * minute)
        let stopped = s.applying(.stop, at: 12 * hour + 10 * minute)
        #expect(stopped.timer == .idle && stopped.studiedSec == 3600)
        #expect(s.applying(.start, at: 0) == s, "spuštění ukáže až aplikace")
    }
}

@Suite("Widgety – soubory a příkazy")
struct WidgetFilesTests {
    private func files() -> WidgetFiles {
        WidgetFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("st-widget-\(UUID().uuidString)"), group: "test.group")
    }

    @Test("Souhrn se zapíše a přečte; jiná verze se nečte")
    func snapshotRoundTrip() throws {
        let f = files()
        #expect(f.readSnapshot() == nil)
        let s = snapshot(timer: running(at: 5))
        try f.write(s)
        #expect(f.readSnapshot() == s)
        var old = s
        old.version = 0
        try f.write(old)
        #expect(f.readSnapshot() == nil)
    }

    @Test("Příkazy v pořadí stisku; staré se zahodí; přečtené zmizí")
    func commands() throws {
        let f = files()
        let now = 10 * hour
        try f.send(WidgetCommand(action: .finish, at: now - minute))
        try f.send(WidgetCommand(action: .pause, at: now - 2 * minute + 1))
        try f.send(WidgetCommand(action: .start, subjectId: "a", at: now - 10 * minute))
        #expect(f.takeCommands(now: now).map(\.action) == [.pause, .finish])
        #expect(f.takeCommands(now: now).isEmpty)
    }
}

import Core
import Foundation
import Testing
@testable import Engine

private func doc() -> AppDocument {
    var d = AppDocument.empty
    d.upsert([
        Subject(raw: ["id": "mat", "name": "Matematika", "archived": false]),
        Subject(raw: ["id": "fyz", "name": "Fyziologie", "archived": false]),
        Subject(raw: ["id": "fyz2", "name": "Fyzika", "archived": false]),
        Subject(raw: ["id": "pra", "name": "Právo – úvod", "archived": false]),
        Subject(raw: ["id": "old", "name": "Latina", "archived": true]),
    ], now: 1)
    return d
}

@Suite("Odkaz na časovač")
struct TimerLinkTests {
    @Test("Čtení odkazu jako URLSearchParams na webu")
    func parse() throws {
        let link = try #require(TimerLink(url: URL(string: "studytracker://casovac?start=1&predmet=Pr%C3%A1vo+%C3%BAvod&tema=Derivace%2Blimity")!))
        #expect(link == TimerLink(subject: "Právo úvod", topic: "Derivace+limity"))
        #expect(TimerLink(url: URL(string: "studytracker://casovac?start=&predmet=&tema=")!) == TimerLink())
        #expect(TimerLink(url: URL(string: "STUDYTRACKER:///casovac/?start")!) == TimerLink())
        #expect(TimerLink(url: URL(string: "studytracker://casovac")!) == nil, "bez start jen otevře časovač")
        #expect(TimerLink(url: URL(string: "studytracker://prehled?start=1")!) == nil)
        #expect(TimerLink(url: URL(string: "https://casovac?start=1")!) == nil)
        #expect(TimerLink.isTimerPage(URL(string: "studytracker://casovac")!))
    }

    @Test("Předmět podle názvu: celý, pak začátek, bez diakritiky; jinak poslední použitý")
    func subject() {
        let d = doc()
        #expect(TimerLink(subject: "fyzika").subjectId(in: d, current: "") == "fyz2", "přesná shoda má přednost")
        #expect(TimerLink(subject: "FYZ").subjectId(in: d, current: "") == "fyz", "jinak první začínající")
        #expect(TimerLink(subject: "pravo uvod").subjectId(in: d, current: "") == "pra")
        #expect(TimerLink(subject: "latina").subjectId(in: d, current: "mat") == "mat", "archivovaný se nehledá")
        #expect(TimerLink(subject: "neznámý").subjectId(in: d, current: "old") == nil, "poslední použitý je v archivu")
        #expect(TimerLink().subjectId(in: d, current: "") == nil)
    }

    @Test("Spuštění: běžící blok nepřeruší, bez předmětu nic")
    func open() {
        let d = doc()
        var s = TimerState(modeId: "pomodoro")
        s.open(TimerLink(subject: "mat", topic: "Integrály"), in: d, now: 1000, presets: [])
        #expect(s.status == .running && s.subjectId == "mat" && s.topic == "Integrály" && s.workStartedAt == 1000)

        s.open(TimerLink(subject: "fyziologie"), in: d, now: 2000, presets: [])
        #expect(s.subjectId == "mat" && s.workStartedAt == 1000)

        var empty = TimerState(modeId: "pomodoro")
        empty.open(TimerLink(), in: d, now: 1000, presets: [])
        #expect(empty.status == .idle)
    }
}

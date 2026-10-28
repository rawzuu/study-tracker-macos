import Engine
import Foundation
import Testing
@testable import Focus

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let monday = clock.parseDayKey("2026-10-26")!
private let minute = StudyClock.minute
private func at(_ h: Int, _ m: Int = 0) -> Int { clock.atMinutes(monday, h * 60 + m) }

private func hit(_ s: Strictness) -> FocusHit {
    FocusHit(target: .site("youtube.com"), name: "youtube.com", listIds: ["v"], listNames: ["Video"], strictness: s, appAction: .shield, until: nil)
}

private func request(_ h: FocusHit, at t: Int, boot: Int = 1, challenge: String = "") -> UnlockRequest {
    UnlockRequest(target: h.target, name: h.name, listIds: h.listIds, requestedAt: t, bootTime: boot, challenge: challenge)
}

@Suite struct UnlockTests {
    @Test func blockedCases() {
        #expect(Unlock.step(hit(.strict), request: nil, allowanceLeft: nil, now: at(10), bootTime: 1, clock: clock)
            == .unavailable("Přísný zámek – do konce bloku nejde zrušit."))
        #expect(Unlock.step(hit(.allowance), request: nil, allowanceLeft: 0, now: at(10), bootTime: 1, clock: clock)
            == .unavailable("Tento týden už žádné odemknutí nezbývá."))
        let evenings = Strictness(unlockWindows: [TimeWindow(weekdays: [0, 1, 2, 3, 4, 5, 6], start: 18 * 60, end: 22 * 60)])
        #expect(Unlock.step(hit(evenings), request: nil, allowanceLeft: nil, now: at(10), bootTime: 1, clock: clock)
            == .unavailable("Odemknout jde jen v nastaveném čase (18:00–22:00)."))
        #expect(Unlock.step(hit(evenings), request: nil, allowanceLeft: nil, now: at(19), bootTime: 1, clock: clock)
            == .request("Odemknout na 5 min"))
    }

    @Test func stepsInOrder() {
        let s = Strictness(delayMinutes: 5, typingCharacters: 10, weeklyAllowance: 3, requireRestart: true, password: Unlock.makePassword("tajne"))
        let h = hit(s)
        #expect(Unlock.step(h, request: nil, allowanceLeft: 2, now: at(10), bootTime: 1, clock: clock)
            == .request("Odemknout na 5 min · restartovat Mac, počkat 5 min, opsat 10 znaků, zadat heslo · zbývá 2 odemknutí tento týden"))
        var r = request(h, at: at(10), boot: 1, challenge: "abcde fghjk")
        #expect(Unlock.step(h, request: r, allowanceLeft: 2, now: at(10), bootTime: 1, clock: clock) == .restart)
        // Po restartu: odklad běží od žádosti.
        #expect(Unlock.step(h, request: r, allowanceLeft: 2, now: at(10, 3), bootTime: 2, clock: clock) == .wait(until: at(10, 5)))
        #expect(Unlock.step(h, request: r, allowanceLeft: 2, now: at(10, 5), bootTime: 2, clock: clock) == .type("abcde fghjk"))
        r.typed = true
        #expect(Unlock.step(h, request: r, allowanceLeft: 2, now: at(10, 5), bootTime: 2, clock: clock) == .password)
        r.passwordOK = true
        #expect(Unlock.step(h, request: r, allowanceLeft: 2, now: at(10, 5), bootTime: 2, clock: clock) == .ready)
        // Žádost k jinému cíli se nepočítá.
        var other = r
        other.target = .app("x")
        #expect(Unlock.step(h, request: other, allowanceLeft: 2, now: at(10, 5), bootTime: 2, clock: clock) != .ready)
    }

    @Test func challengeAndPassword() {
        var rng = SeededRNG(seed: 7)
        let text = Unlock.challenge(length: 12, using: &rng)
        #expect(text.count == 14)
        #expect(text.split(separator: " ").map(\.count) == [5, 5, 2])
        #expect(text.allSatisfy { $0 == " " || Unlock.alphabet.contains($0) })
        #expect(Unlock.matches(" \(text) ", text))
        #expect(!Unlock.matches(text.lowercased() == text ? text + "x" : text.lowercased(), text))
        #expect(!Unlock.matches("", ""))
        #expect(Unlock.challenge(length: 0).isEmpty)
        let lock = Unlock.makePassword("Heslo 1")
        #expect(Unlock.verify("Heslo 1", lock))
        #expect(!Unlock.verify("heslo 1", lock))
        #expect(lock.hash != Unlock.makePassword("Heslo 1").hash)
    }

    @Test func strictnessDecodesOlderData() throws {
        let old = try JSONDecoder().decode(Strictness.self, from: Data(#"{"locked":false,"delayMinutes":3,"typingCharacters":0,"unlockMinutes":10}"#.utf8))
        #expect(old == Strictness(delayMinutes: 3, unlockMinutes: 10))
        #expect(Strictness.soft.isSoft)
        #expect(!Strictness.restart.isSoft)
        #expect(Strictness.soft.merged(with: .restart).requireRestart)
    }
}

/// Opakovatelná náhoda pro testy (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct FocusFormatTests {
    @Test func until() {
        #expect(FocusFormat.until(at(14), now: at(9), clock: clock) == "do 14:00")
        #expect(FocusFormat.until(clock.addDays(at(0, 51), 1), now: at(23), clock: clock) == "zítra do 0:51")
        #expect(FocusFormat.until(clock.addDays(at(8), 8), now: at(9), clock: clock) == "do 3. 11. 8:00")
    }
}

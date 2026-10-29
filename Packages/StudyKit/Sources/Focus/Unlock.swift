import CryptoKit
import Engine
import Foundation

/// Žádost o odemknutí zablokované aplikace nebo webu. Ukládá se (přežije i restart Macu, který si
/// zámek „po restartu“ vyžaduje).
public struct UnlockRequest: Codable, Sendable, Equatable {
    public var target: FocusTarget
    public var name: String
    public var listIds: [String]
    public var requestedAt: Int
    /// Kdy Mac naposledy nastartoval – v okamžiku žádosti (zámek „po restartu“).
    public var bootTime: Int
    /// Text k opsání (prázdný = bez opisování).
    public var challenge: String
    public var typed: Bool
    public var passwordOK: Bool
    /// Web: adresa, na kterou se po odemknutí vrátit.
    public var url: String?

    public init(target: FocusTarget, name: String, listIds: [String], requestedAt: Int, bootTime: Int, challenge: String = "",
                typed: Bool = false, passwordOK: Bool = false, url: String? = nil) {
        self.target = target
        self.name = name
        self.listIds = listIds
        self.requestedAt = requestedAt
        self.bootTime = bootTime
        self.challenge = challenge
        self.typed = typed
        self.passwordOK = passwordOK
        self.url = url
    }
}

/// Další krok odemknutí, jak ho ukazuje blokovací obrazovka.
public enum UnlockStep: Codable, Sendable, Equatable {
    /// Odemknout teď nejde (důvod).
    case unavailable(String)
    /// Ještě se nežádalo – tlačítko s popisem, co bude potřeba.
    case request(String)
    /// Žádost platí, ale Mac se musí nejdřív restartovat.
    case restart
    /// Odklad – odemknout jde až od `until`.
    case wait(until: Int)
    /// Opsat text.
    case type(String)
    /// Zadat heslo.
    case password
    /// Všechny překážky splněné.
    case ready
}

public enum Unlock {
    /// Kde je uživatel v odemykání.
    public static func step(_ hit: FocusHit, request: UnlockRequest?, allowanceLeft: Int?, now: Int, bootTime: Int, clock: StudyClock) -> UnlockStep {
        let s = hit.strictness
        if s.locked { return .unavailable("Přísný zámek – do konce bloku nejde zrušit.") }
        if allowanceLeft == 0 { return .unavailable("Tento týden už žádné odemknutí nezbývá.") }
        if !s.unlockWindows.isEmpty, !s.unlockWindows.contains(where: { $0.end(containing: now, clock: clock) != nil }) {
            return .unavailable("Odemknout jde jen v nastaveném čase (\(windowsText(s.unlockWindows))).")
        }
        guard let r = request, r.target == hit.target else { return .request(summary(s, allowanceLeft: allowanceLeft)) }
        if s.requireRestart, bootTime <= r.bootTime { return .restart }
        let ready = r.requestedAt + s.delayMinutes * StudyClock.minute
        if now < ready { return .wait(until: ready) }
        if s.typingCharacters > 0, !r.typed { return .type(r.challenge) }
        if s.password != nil, !r.passwordOK { return .password }
        return .ready
    }

    /// „Odemknout na 5 min · počkat 5 min, opsat 120 znaků · zbývá 2 odemknutí tento týden“
    public static func summary(_ s: Strictness, allowanceLeft: Int?) -> String {
        var steps: [String] = []
        if s.requireRestart { steps.append("restartovat Mac") }
        if s.delayMinutes > 0 { steps.append("počkat \(s.delayMinutes) min") }
        if s.typingCharacters > 0 { steps.append("opsat \(s.typingCharacters) znaků") }
        if s.password != nil { steps.append("zadat heslo") }
        var parts = ["Odemknout na \(s.unlockMinutes) min"]
        if !steps.isEmpty { parts.append(steps.joined(separator: ", ")) }
        if let left = allowanceLeft { parts.append("zbývá \(left) odemknutí tento týden") }
        return parts.joined(separator: " · ")
    }

    public static func windowsText(_ windows: [TimeWindow]) -> String {
        func hm(_ m: Int) -> String { "\(m / 60):\(m % 60 < 10 ? "0" : "")\(m % 60)" }
        return windows.map { "\(hm($0.start))–\(hm($0.end))" }.joined(separator: ", ")
    }

    // MARK: - Opsání textu

    /// Znaky bez zaměnitelných (0/O, 1/l/I) – opisuje se ručně.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Náhodný text ve skupinách po pěti znacích.
    public static func challenge(length: Int, using rng: inout some RandomNumberGenerator) -> String {
        guard length > 0 else { return "" }
        var out = ""
        for i in 0..<length {
            if i > 0, i % 5 == 0 { out.append(" ") }
            out.append(alphabet.randomElement(using: &rng)!)
        }
        return out
    }

    public static func challenge(length: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return challenge(length: length, using: &rng)
    }

    /// Opsáno přesně (mezery navíc na krajích nevadí).
    public static func matches(_ typed: String, _ challenge: String) -> Bool {
        !challenge.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines) == challenge
    }

    // MARK: - Heslo

    public static func makePassword(_ password: String) -> PasswordLock {
        let salt = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return PasswordLock(salt: salt, hash: hash(password, salt: salt))
    }

    public static func verify(_ password: String, _ lock: PasswordLock) -> Bool {
        hash(password, salt: lock.salt) == lock.hash
    }

    static func hash(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Texty časů Soustředění („do 14:00“, „zítra do 0:51“, „do 3. 11. 8:00“) – blokovací obrazovka i stránka.
public enum FocusFormat {
    public static func until(_ t: Int, now: Int = Int(Date().timeIntervalSince1970 * 1000), clock: StudyClock = .current) -> String {
        let m = moment(t, now: now, clock: clock)
        return m.hasPrefix("zítra ") ? "zítra do " + m.dropFirst(6) : "do " + m
    }

    /// „14:00“, „zítra 0:51“, „včera 23:10“, „3. 11. 8:00“.
    public static func moment(_ t: Int, now: Int = Int(Date().timeIntervalSince1970 * 1000), clock: StudyClock = .current) -> String {
        let c = clock.calendar.dateComponents([.day, .month, .hour, .minute], from: clock.date(t))
        let time = "\(c.hour ?? 0):\((c.minute ?? 0) < 10 ? "0" : "")\(c.minute ?? 0)"
        let today = clock.startOfDay(now)
        switch clock.startOfDay(t) {
        case today: return time
        case clock.addDays(today, 1): return "zítra \(time)"
        case clock.addDays(today, -1): return "včera \(time)"
        default: return "\(c.day ?? 0). \(c.month ?? 0). \(time)"
        }
    }

    /// „právě teď“, „před 40 s“, „před 3 min“, „před 2 h“.
    public static func ago(_ t: Int, now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        let s = max(0, now - t) / 1000
        if s < 5 { return "právě teď" }
        if s < 60 { return "před \(s) s" }
        if s < 3600 { return "před \(s / 60) min" }
        return "před \(s / 3600) h"
    }
}

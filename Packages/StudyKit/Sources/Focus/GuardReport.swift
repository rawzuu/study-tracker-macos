import Foundation

/// Co Strážce právě vynucuje – zapisuje ho do sdíleného kontejneru při každé změně. Čte ho rozšíření
/// Safari (stejná pravidla pro weby) a aplikace (stránka Soustředění).
public struct GuardReport: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum SafariWatch: String, Codable, Sendable {
        /// Hlídání adresy je vypnuté v nastavení.
        case off
        /// Chybí souhlas v Soukromí → Automatizace.
        case needsPermission
        case on
    }

    public var version = GuardReport.currentVersion
    public var generatedAt: Int
    /// Verze Strážce (`CFBundleShortVersionString`), aplikace pozná starší běžící proces.
    public var guardVersion: String
    public var state: ActiveFocus
    /// Dnešní pokusy podle cíle (`FocusTarget.key`) – „dnes už 7.“
    public var attemptsToday: [String: Int]
    public var safari: SafariWatch
    /// Kdy se naposledy ozvalo rozšíření Safari (`nil` = zatím nikdy).
    public var extensionSeenAt: Int?
    /// Kdy se tenhle proces Strážce spustil (`nil` ve starších verzích).
    public var startedAt: Int?

    public init(generatedAt: Int, guardVersion: String, state: ActiveFocus, attemptsToday: [String: Int], safari: SafariWatch, extensionSeenAt: Int?, startedAt: Int? = nil) {
        self.generatedAt = generatedAt
        self.guardVersion = guardVersion
        self.state = state
        self.attemptsToday = attemptsToday
        self.safari = safari
        self.extensionSeenAt = extensionSeenAt
        self.startedAt = startedAt
    }

    /// Stav s pravidly, která v okamžiku `t` ještě platí (soubor může být pár sekund starý).
    public func state(at t: Int) -> ActiveFocus {
        var s = state
        s.rules.removeAll { $0.until.map { $0 <= t } ?? false }
        s.exceptions.removeAll { $0.until <= t }
        if !s.isLocked { s.protectionApps = [] }
        if !s.rules.contains(where: \.blocksWeb) { s.browserApps = [] }
        s.now = t
        return s
    }
}

/// Výsledek registrace Strážce u launchd (`SMAppService`), jak ho zapsal Strážce.
public struct GuardRegistration: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case enabled
        /// macOS čeká na povolení v Nastavení systému → Obecné → Položky při přihlášení.
        case requiresApproval
        case notRegistered
        /// Vypnutí odmítnuto – běží přísný zámek.
        case locked
        case failed
    }

    public var status: Status
    public var at: Int
    public var error: String?

    public init(status: Status, at: Int, error: String? = nil) {
        self.status = status
        self.at = at
        self.error = error
    }
}

/// Pokus otevřít zablokovaný web, jak ho zachytilo rozšíření Safari (Strážce ho zapíše do databáze).
public struct SafariAttempt: Codable, Sendable, Equatable {
    public var at: Int
    public var host: String
    public var path: String
    /// Uživatel na blokovací stránce klikl na „Odemknout…“ (Strážce ukáže odemykání).
    public var unlock: Bool?
    /// Celá adresa – po odemknutí se na ni Safari vrátí.
    public var url: String?

    public init(at: Int, host: String, path: String, unlock: Bool? = nil, url: String? = nil) {
        self.at = at
        self.host = host
        self.path = path
        self.unlock = unlock
        self.url = url
    }
}

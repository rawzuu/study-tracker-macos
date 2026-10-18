import Engine
import Foundation

/// Přístup aplikace ke kalendářům v systému.
public enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    /// Jen zápis – nestačí: bez čtení se události nedají upravovat ani mazat.
    case writeOnly
    case denied
    case granted
}

/// Účet v Kalendáři, kam se dá založit kalendář (iCloud, Na tomto Macu…).
public struct CalendarAccount: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let isICloud: Bool

    public init(id: String, title: String, isICloud: Bool) {
        self.id = id
        self.title = title
        self.isICloud = isICloud
    }
}

/// Kalendář v systému (pro výběr obsazeného času).
public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case local, cloud, exchange, subscription, birthdays }

    public let id: String
    public let title: String
    public let account: String
    /// `#rrggbb`
    public let color: String
    public let kind: Kind

    public init(id: String, title: String, account: String, color: String, kind: Kind) {
        self.id = id
        self.title = title
        self.account = account
        self.color = color
        self.kind = kind
    }

    /// Bere se jako obsazený čas, dokud uživatel nevybere jinak: vlastní kalendáře ano, odebírané
    /// (svátky, odebíraný studijní plán z gistu) a narozeniny ne.
    public var busyByDefault: Bool { kind != .subscription && kind != .birthdays }
}

/// Kalendáře v systému (EventKit). Aplikace používá `EventKitCalendarService`, testy a UI testy
/// `InMemoryCalendarService` – nikdy nesahají na skutečné kalendáře.
public protocol CalendarService: Sendable {
    func access() async -> CalendarAccess
    /// Systémový dotaz na plný přístup ke kalendářům (jen poprvé, pak vrací uložené rozhodnutí).
    func requestAccess() async -> CalendarAccess
    func accounts() async -> [CalendarAccount]
    func calendars() async -> [CalendarInfo]
    /// Kalendář aplikace: uložený podle `id`, jinak nalezený podle názvu v účtu (jiný Mac ho už založil),
    /// jinak nově založený. Vrací jeho identifikátor.
    func ensureCalendar(id: String?, title: String, accountId: String?, color: String) async throws -> String
    /// Existuje kalendář aplikace ještě (uživatel ho mohl v Kalendáři smazat)?
    func calendarExists(id: String) async -> Bool
    func events(calendarId: String, from: Int, to: Int) async throws -> [CalendarMirror.Existing]
    /// Provede změny jen v kalendáři `calendarId` a uloží je najednou.
    func apply(_ changes: CalendarMirror.Changes, calendarId: String) async throws
    /// Události, které zabírají čas (bez celodenních, volných, zrušených a odmítnutých).
    func busy(calendarIds: Set<String>, from: Int, to: Int) async -> [ExternalBusy]
    func removeCalendar(id: String) async throws
    /// Ozve se po každé změně kalendářů (i z jiného zařízení přes iCloud).
    func changes() -> AsyncStream<Void>
}

public enum CalendarServiceError: Error, LocalizedError, Equatable {
    case noAccount
    case calendarMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noAccount: "V Kalendáři není účet, kam by šel kalendář založit (iCloud ani Na tomto Macu)."
        case .calendarMissing: "Kalendář Studijní plán se nepodařilo najít ani založit."
        case .failed(let message): message
        }
    }
}

/// Kalendáře v paměti – pro testy a UI testy.
public actor InMemoryCalendarService: CalendarService {
    public struct StoredEvent: Sendable, Equatable {
        public var calendarId: String
        public var event: CalendarMirror.Existing
    }

    public private(set) var accessState: CalendarAccess
    /// Co odpoví systémový dotaz na přístup.
    private let grants: Bool
    public private(set) var calendarList: [CalendarInfo]
    public private(set) var stored: [String: StoredEvent] = [:]
    public private(set) var busyEvents: [ExternalBusy] = []
    /// Kolikrát se změny ukládaly (bez změn se nemá ukládat nic).
    public private(set) var applyCount = 0
    private var nextId = 1
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(access: CalendarAccess = .notDetermined, grants: Bool = true, calendars: [CalendarInfo] = [], busy: [ExternalBusy] = []) {
        accessState = access
        self.grants = grants
        calendarList = calendars
        busyEvents = busy
    }

    public func access() -> CalendarAccess { accessState }

    public func requestAccess() -> CalendarAccess {
        if accessState == .notDetermined { accessState = grants ? .granted : .denied }
        return accessState
    }

    public func accounts() -> [CalendarAccount] {
        [CalendarAccount(id: "icloud", title: "iCloud", isICloud: true), CalendarAccount(id: "local", title: "Na tomto Macu", isICloud: false)]
    }

    public func calendars() -> [CalendarInfo] { calendarList }

    public func ensureCalendar(id: String?, title: String, accountId: String?, color: String) throws -> String {
        if let id, calendarList.contains(where: { $0.id == id }) { return id }
        if let found = calendarList.first(where: { $0.title == title && $0.kind != .subscription }) { return found.id }
        let new = CalendarInfo(id: "cal-\(nextId)", title: title, account: accountId == "local" ? "Na tomto Macu" : "iCloud", color: color, kind: .cloud)
        nextId += 1
        calendarList.append(new)
        return new.id
    }

    public func calendarExists(id: String) -> Bool { calendarList.contains { $0.id == id } }

    public func events(calendarId: String, from: Int, to: Int) -> [CalendarMirror.Existing] {
        stored.values.filter { $0.calendarId == calendarId && $0.event.end > from && $0.event.start < to }
            .map(\.event).sorted { $0.identifier < $1.identifier }
    }

    public func apply(_ changes: CalendarMirror.Changes, calendarId: String) throws {
        applyCount += 1
        for e in changes.create {
            let id = "ev-\(nextId)"
            nextId += 1
            stored[id] = StoredEvent(calendarId: calendarId, event: Self.existing(id, e))
        }
        for u in changes.update where stored[u.identifier]?.calendarId == calendarId {
            stored[u.identifier]?.event = Self.existing(u.identifier, u.event)
        }
        for id in changes.remove where stored[id]?.calendarId == calendarId { stored[id] = nil }
        notify()
    }

    public func busy(calendarIds: Set<String>, from: Int, to: Int) -> [ExternalBusy] {
        busyEvents.filter { calendarIds.contains($0.calendarId) && $0.end > from && $0.start < to }
    }

    public func removeCalendar(id: String) {
        calendarList.removeAll { $0.id == id }
        stored = stored.filter { $0.value.calendarId != id }
        notify()
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let id = UUID()
        Task { await self.register(id, continuation) }
        continuation.onTermination = { _ in Task { await self.unregister(id) } }
        return stream
    }

    // MARK: - Pro testy

    /// Událost v cizím kalendáři, která zabírá čas.
    public func addBusy(_ event: ExternalBusy) {
        busyEvents.append(event)
        notify()
    }

    /// Uživatel v Kalendáři událost upravil, smazal nebo přidal vlastní.
    public func edit(_ id: String, _ change: @Sendable (inout CalendarMirror.Existing) -> Void) {
        guard var e = stored[id] else { return }
        change(&e.event)
        stored[id] = e
        notify()
    }

    public func delete(_ id: String) {
        stored[id] = nil
        notify()
    }

    public func insertForeign(_ event: CalendarMirror.Existing, calendarId: String) {
        stored[event.identifier] = StoredEvent(calendarId: calendarId, event: event)
        notify()
    }

    /// Uživatel smazal celý kalendář aplikace v Kalendáři.
    public func deleteCalendar(id: String) { removeCalendar(id: id) }

    private func register(_ id: UUID, _ c: AsyncStream<Void>.Continuation) { continuations[id] = c }
    private func unregister(_ id: UUID) { continuations[id] = nil }
    private func notify() { for c in continuations.values { c.yield() } }

    private static func existing(_ id: String, _ e: CalendarMirror.Event) -> CalendarMirror.Existing {
        CalendarMirror.Existing(identifier: id, url: e.key.url, title: e.title, start: e.start, end: e.end, allDay: e.allDay, notes: e.notes, alarms: e.alarms)
    }
}

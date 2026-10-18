import Core
import Engine
import Foundation
import Observation

/// Plán a zkoušky přímo v Apple Kalendáři (jen na Macu – web to neumí). Mac drží vlastní kalendář
/// „Studijní plán“ (nejlépe v iCloudu, takže je hned v iPhonu, iPadu i hodinkách) jako kopii dat:
/// po každé změně dat se s prodlevou 2 s srovná, a když ho někdo upraví v Kalendáři, vrátí se podle dat.
/// Jiné kalendáře se jen čtou – jejich události jsou obsazený čas pro ranní plán.
///
/// Nastavení je jen pro tento Mac (UserDefaults), data se nemění.
@MainActor
@Observable
public final class AppleCalendarSync {
    public struct Preferences: Codable, Equatable, Sendable {
        public var enabled = false
        /// Kalendář aplikace (`nil` = ještě nezaložený).
        public var calendarId: String?
        /// Účet, kam se kalendář zakládá (`nil` = iCloud, když je, jinak výchozí).
        public var accountId: String?
        public var alarmMin: Int? = 10
        public var includeExams = true
        public var busyEnabled = true
        /// Kalendáře obsazeného času; `nil` = výchozí výběr (`CalendarInfo.busyByDefault`).
        public var busyCalendarIds: [String]?

        public init() {}
    }

    public struct Status: Codable, Equatable, Sendable {
        public let at: Int
        public let error: String?
        /// Kolik událostí kalendář drží (bloky v okně a zkoušky).
        public let events: Int
    }

    public private(set) var preferences: Preferences
    public private(set) var access: CalendarAccess = .notDetermined
    public private(set) var status: Status?
    public private(set) var syncing = false
    public private(set) var calendars: [CalendarInfo] = []
    public private(set) var accounts: [CalendarAccount] = []
    /// Obsazený čas z vybraných kalendářů od včerejška na dva týdny dopředu.
    public private(set) var external: [ExternalBusy] = []

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let service: any CalendarService
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var again = false
    /// Co Mac do kalendáře naposledy zapsal a kolikrát to musel zapsat znovu beze změny v datech.
    /// Kdyby kalendář událost pokaždé uložil jinak, zápis se po třetím pokusu vzdá – nikdy nevznikne smyčka.
    @ObservationIgnored private var written: [CalendarMirror.Key: (event: CalendarMirror.Event, rewrites: Int)] = [:]

    static let preferencesKey = "st.appleCalendar"
    static let statusKey = "st.appleCalendar.status"
    /// Barva nově založeného kalendáře (uživatel ji v Kalendáři může změnit).
    static let color = "#6F86C9"

    public init(app: AppStore, service: any CalendarService, delay: Duration = .seconds(2)) {
        self.app = app
        self.service = service
        self.delay = delay
        preferences = app.defaults.data(forKey: Self.preferencesKey).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        status = app.defaults.data(forKey: Self.statusKey).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
    }

    // MARK: - Veřejné

    /// Po načtení dat: zjistí přístup, načte kalendáře a obsazený čas a začne sledovat změny.
    public func start() async {
        guard !started else { return }
        started = true
        access = await service.access()
        observeDocument()
        listen()
        await refresh()
        if preferences.enabled { await sync() }
    }

    /// Zapne zápis do Apple Kalendáře; poprvé se systém zeptá na přístup. `false` = přístup nedostal.
    @discardableResult
    public func enable() async -> Bool {
        access = await service.requestAccess()
        guard access == .granted else { return false }
        update { $0.enabled = true }
        await refresh()
        await sync()
        return status?.error == nil
    }

    /// Jen přístup ke kalendářům (obsazený čas pro ranní plán i bez zápisu plánu).
    public func requestAccess() async {
        access = await service.requestAccess()
        await refresh()
    }

    /// Vypne zápis. `removeCalendar` smaže i kalendář aplikace (jen ten – ostatní kalendáře nikdy).
    public func disable(removeCalendar: Bool) async {
        pending?.cancel()
        let id = preferences.calendarId
        update {
            $0.enabled = false
            if removeCalendar { $0.calendarId = nil }
        }
        written = [:]
        if removeCalendar, let id, access == .granted {
            do {
                try await service.removeCalendar(id: id)
            } catch {
                record(Status(at: app.nowMs, error: error.localizedDescription, events: 0))
            }
        }
        await refresh()
    }

    /// Události z ostatních kalendářů, které se v ranním plánu a v Kalendáři berou jako obsazený čas.
    public var busyEvents: [ExternalBusy] {
        preferences.busyEnabled && access == .granted ? external : []
    }

    /// Obsazený čas pro ranní plán.
    public var busyIntervals: [BusyInterval] { busyEvents.map(\.interval) }

    public func setAlarm(_ minutes: Int?) { change { $0.alarmMin = minutes } }
    public func setIncludeExams(_ include: Bool) { change { $0.includeExams = include } }

    public func setBusyEnabled(_ on: Bool) {
        update { $0.busyEnabled = on }
        Task { await refreshExternal() }
    }

    /// Kalendář aplikace se založí v jiném účtu – ten původní se smaže (je jen kopie dat).
    public func setAccount(_ id: String) async {
        guard id != preferences.accountId else { return }
        let old = preferences.calendarId
        update {
            $0.accountId = id
            $0.calendarId = nil
        }
        written = [:]
        if let old, access == .granted { try? await service.removeCalendar(id: old) }
        await sync()
        await refresh()
    }

    public func isBusyCalendar(_ id: String) -> Bool { busyCalendarIds.contains(id) }

    public func setBusyCalendar(_ id: String, _ on: Bool) {
        var ids = busyCalendarIds
        if on { ids.insert(id) } else { ids.remove(id) }
        update { $0.busyCalendarIds = ids.sorted() }
        Task { await refreshExternal() }
    }

    /// Synchronizovat teď (i když se data nezměnila).
    public func syncNow() async {
        pending?.cancel()
        written = written.mapValues { ($0.event, 0) }
        await sync()
        await refresh()
    }

    /// Kalendář aplikace mezi kalendáři v systému.
    public var ownCalendar: CalendarInfo? {
        preferences.calendarId.flatMap { id in calendars.first { $0.id == id } }
    }

    /// Kalendáře, které se dají brát jako obsazený čas (bez kalendáře aplikace).
    public var otherCalendars: [CalendarInfo] {
        calendars.filter { $0.id != preferences.calendarId }
    }

    /// Je v Kalendáři i odebíraný studijní plán z gistu? Bloky by pak byly vidět dvakrát.
    public var hasFeedSubscription: Bool {
        calendars.contains { $0.kind == .subscription && $0.title == CalendarMirror.calendarTitle }
    }

    // MARK: - Synchronizace

    /// Srovná kalendář aplikace s daty. Běží vždy jen jedna – změna během ní spustí další kolo.
    func sync() async {
        guard preferences.enabled, access == .granted else { return }
        if syncing {
            again = true
            return
        }
        syncing = true
        defer { syncing = false }
        repeat {
            again = false
            await syncOnce()
        } while again && preferences.enabled
    }

    private func syncOnce() async {
        let now = app.nowMs
        let clock = app.clock
        let options = CalendarMirror.Options(includeExams: preferences.includeExams, alarmMin: preferences.alarmMin)
        let desired = CalendarMirror.events(app.document, options: options, now: now, clock: clock)
        do {
            let id = try await service.ensureCalendar(id: preferences.calendarId, title: CalendarMirror.calendarTitle,
                                                      accountId: preferences.accountId, color: Self.color)
            if id != preferences.calendarId {
                update { $0.calendarId = id }
                written = [:]
                calendars = await service.calendars()
            }
            let from = CalendarMirror.windowStart(now: now, clock: clock)
            // EventKit hledá nejvýš 4 roky najednou.
            let existing = try await service.events(calendarId: id, from: from, to: from + (4 * 365 - 1) * StudyClock.day)
            var changes = CalendarMirror.diff(desired: desired, existing: existing)
            changes.update = changes.update.filter { allowRewrite($0.event) }
            if !changes.isEmpty { try await service.apply(changes, calendarId: id) }
            for e in changes.create + changes.update.map(\.event) {
                written[e.key] = (e, written[e.key].map { $0.event == e ? $0.rewrites : 0 } ?? 0)
            }
            record(Status(at: now, error: nil, events: desired.count))
        } catch {
            record(Status(at: now, error: error.localizedDescription, events: desired.count))
        }
    }

    /// Přepsat událost, kterou Mac už jednou stejně zapsal? Nejvýš třikrát po sobě (pak by šlo o smyčku).
    private func allowRewrite(_ event: CalendarMirror.Event) -> Bool {
        guard let last = written[event.key], last.event == event else { return true }
        guard last.rewrites < 3 else { return false }
        written[event.key] = (event, last.rewrites + 1)
        return true
    }

    /// Kalendáře, účty a obsazený čas.
    private func refresh() async {
        guard access == .granted else {
            calendars = []
            accounts = []
            external = []
            return
        }
        calendars = await service.calendars()
        accounts = await service.accounts()
        // Kalendář aplikace mohl uživatel v Kalendáři smazat – při další synchronizaci se založí znovu.
        if let id = preferences.calendarId, !calendars.contains(where: { $0.id == id }), !(await service.calendarExists(id: id)) {
            update { $0.calendarId = nil }
            written = [:]
        }
        await refreshExternal()
    }

    private func refreshExternal() async {
        guard access == .granted, preferences.busyEnabled else {
            external = []
            return
        }
        let day = app.clock.startOfDay(app.nowMs)
        let ids = busyCalendarIds.subtracting(preferences.calendarId.map { [$0] } ?? [])
        external = ids.isEmpty ? [] : await service.busy(calendarIds: ids, from: app.clock.addDays(day, -1), to: app.clock.addDays(day, 15))
    }

    private var busyCalendarIds: Set<String> {
        if let ids = preferences.busyCalendarIds { return Set(ids) }
        return Set(calendars.filter { $0.busyByDefault && $0.id != preferences.calendarId }.map(\.id))
    }

    // MARK: - Sledování změn

    /// Po změně dat srovnat kalendář s prodlevou – rychlé úpravy za sebou se zapíšou najednou.
    private func schedule() {
        pending?.cancel()
        guard preferences.enabled, access == .granted else { return }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func observeDocument() {
        withObservationTracking {
            _ = app.document
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observeDocument()
            }
        }
    }

    /// Změna v kalendářích (i z iPhonu přes iCloud): nové kalendáře a obsazený čas, a kalendář aplikace
    /// zpátky podle dat, kdyby v něm někdo něco změnil.
    private func listen() {
        let changes = service.changes()
        listening = Task { [weak self] in
            for await _ in changes {
                self?.scheduleRefresh()
            }
        }
    }

    /// Změny chodí v dávkách (iCloud, vlastní zápis) – stačí jedno načtení po jejich odeznění.
    private func scheduleRefresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
            self.schedule()
        }
    }

    // MARK: - Nastavení

    private func change(_ edit: (inout Preferences) -> Void) {
        update(edit)
        schedule()
    }

    private func update(_ edit: (inout Preferences) -> Void) {
        var p = preferences
        edit(&p)
        guard p != preferences else { return }
        preferences = p
        if let data = try? JSONEncoder().encode(p) { app.defaults.set(data, forKey: Self.preferencesKey) }
    }

    private func record(_ status: Status) {
        self.status = status
        if let data = try? JSONEncoder().encode(status) { app.defaults.set(data, forKey: Self.statusKey) }
    }
}

import AppKit
import Engine
import EventKit

/// Skutečné kalendáře přes EventKit. Zapisuje se jen do kalendáře aplikace – každá změna a mazání
/// se před uložením ověří, že událost leží právě v něm. Ostatní kalendáře se jen čtou.
public actor EventKitCalendarService: CalendarService {
    private let store = EKEventStore()

    public init() {}

    public func access() -> CalendarAccess {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestAccess() async -> CalendarAccess {
        guard access() == .notDetermined else { return access() }
        _ = try? await store.requestFullAccessToEvents()
        // Po udělení přístupu načíst kalendáře znovu.
        store.reset()
        return access()
    }

    public func accounts() -> [CalendarAccount] {
        store.sources
            .filter { $0.sourceType == .local || ($0.sourceType == .calDAV && !$0.calendars(for: .event).isEmpty) }
            .map { CalendarAccount(id: $0.sourceIdentifier, title: Self.title(of: $0), isICloud: Self.isICloud($0)) }
            .sorted { ($0.isICloud ? 0 : 1, $0.title) < ($1.isICloud ? 0 : 1, $1.title) }
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { c in
            CalendarInfo(id: c.calendarIdentifier, title: c.title, account: c.source.map(Self.title) ?? "",
                         color: Self.hex(c.cgColor), kind: Self.kind(c))
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public func ensureCalendar(id: String?, title: String, accountId: String?, color: String) throws -> String {
        if let id, let existing = store.calendar(withIdentifier: id), existing.allowsContentModifications {
            return existing.calendarIdentifier
        }
        guard let source = source(accountId) else { throw CalendarServiceError.noAccount }
        // Jiný Mac už kalendář založil – použít ho, ať nejsou dva. Jen když v něm nejsou cizí události:
        // synchronizace by je jinak smazala (třeba ručně založený kalendář se stejným názvem).
        if let found = store.calendars(for: .event).first(where: {
            $0.title == title && $0.type != .subscription && $0.allowsContentModifications
                && $0.source?.sourceIdentifier == source.sourceIdentifier && onlyMirrorEvents($0)
        }) {
            return found.calendarIdentifier
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        calendar.cgColor = Self.cgColor(color)
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw CalendarServiceError.failed("Kalendář se nepodařilo založit v účtu \(Self.title(of: source)): \(error.localizedDescription)")
        }
        return calendar.calendarIdentifier
    }

    /// Obsahuje kalendář jen události Study Trackeru (s odkazem `studytracker://planovac…`)? Prohledá
    /// rok zpátky a čtyři dopředu (EventKit hledá nejvýš 4 roky najednou).
    private func onlyMirrorEvents(_ calendar: EKCalendar) -> Bool {
        let now = Date()
        let year: TimeInterval = 365 * 86_400
        return [(-year, 0.0), (0.0, 4 * year - 86_400)].allSatisfy { from, to in
            let predicate = store.predicateForEvents(withStart: now + from, end: now + to, calendars: [calendar])
            return store.events(matching: predicate).allSatisfy { CalendarMirror.Key(url: $0.url) != nil }
        }
    }

    public func calendarExists(id: String) -> Bool { store.calendar(withIdentifier: id) != nil }

    public func events(calendarId: String, from: Int, to: Int) throws -> [CalendarMirror.Existing] {
        guard let calendar = store.calendar(withIdentifier: calendarId) else { throw CalendarServiceError.calendarMissing }
        let predicate = store.predicateForEvents(withStart: Self.date(from), end: Self.date(to), calendars: [calendar])
        return store.events(matching: predicate).compactMap { e in
            guard let id = e.eventIdentifier else { return nil }
            return CalendarMirror.Existing(
                identifier: id, url: e.url, title: e.title ?? "", start: Self.ms(e.startDate), end: Self.ms(e.endDate), allDay: e.isAllDay,
                notes: (e.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                alarms: (e.alarms ?? []).compactMap { $0.absoluteDate == nil ? Int((-$0.relativeOffset / 60).rounded()) : nil }
            )
        }
    }

    public func apply(_ changes: CalendarMirror.Changes, calendarId: String) throws {
        guard let calendar = store.calendar(withIdentifier: calendarId), calendar.allowsContentModifications else {
            throw CalendarServiceError.calendarMissing
        }
        do {
            for e in changes.create {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                Self.fill(event, e)
                try store.save(event, span: .thisEvent, commit: false)
            }
            for u in changes.update {
                guard let event = store.event(withIdentifier: u.identifier), event.calendar?.calendarIdentifier == calendarId else { continue }
                Self.fill(event, u.event)
                try store.save(event, span: .thisEvent, commit: false)
            }
            for id in changes.remove {
                guard let event = store.event(withIdentifier: id), event.calendar?.calendarIdentifier == calendarId else { continue }
                try store.remove(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            // Nic napůl – neuložené změny zahodit, příště se srovná celé znovu.
            store.reset()
            throw CalendarServiceError.failed("Zápis do Kalendáře selhal: \(error.localizedDescription)")
        }
    }

    public func busy(calendarIds: Set<String>, from: Int, to: Int) -> [ExternalBusy] {
        let calendars = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: Self.date(from), end: Self.date(to), calendars: calendars)
        return store.events(matching: predicate).compactMap { e in
            guard !e.isAllDay, e.availability != .free, e.status != .canceled, let calendar = e.calendar,
                  !(e.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) else { return nil }
            let start = Self.ms(e.startDate), end = Self.ms(e.endDate)
            guard end > start else { return nil }
            return ExternalBusy(id: "\(e.eventIdentifier ?? UUID().uuidString)@\(start)", title: e.title ?? "Událost", start: start, end: end,
                                calendarId: calendar.calendarIdentifier, calendarTitle: calendar.title, color: Self.hex(calendar.cgColor))
        }
        .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    public func removeCalendar(id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(calendar, commit: true)
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            continuation.yield()
        }
        let observer = Observer(token: token)
        continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer.token) }
        return stream
    }

    // MARK: - Převody

    private func source(_ id: String?) -> EKSource? {
        let sources = store.sources
        if let id, let chosen = sources.first(where: { $0.sourceIdentifier == id }) { return chosen }
        return sources.first(where: Self.isICloud) ?? store.defaultCalendarForNewEvents?.source ?? sources.first { $0.sourceType == .local }
    }

    private static func fill(_ event: EKEvent, _ e: CalendarMirror.Event) {
        event.title = e.title
        event.isAllDay = e.allDay
        event.startDate = date(e.start)
        // Celodenní událost na jeden den: začátek i konec v tomtéž dni.
        event.endDate = date(e.allDay ? e.start : e.end)
        event.notes = e.notes
        event.url = e.key.url
        event.availability = .busy
        event.alarms = e.alarms.map { EKAlarm(relativeOffset: -Double($0 * 60)) }
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func kind(_ c: EKCalendar) -> CalendarInfo.Kind {
        switch c.type {
        case .local: .local
        case .calDAV: .cloud
        case .exchange: .exchange
        case .subscription: .subscription
        case .birthday: .birthdays
        @unknown default: .local
        }
    }

    private static func isICloud(_ s: EKSource) -> Bool {
        s.sourceType == .calDAV && s.title.localizedCaseInsensitiveContains("icloud")
    }

    private static func title(of s: EKSource) -> String {
        s.sourceType == .local ? "Na tomto Macu" : s.title
    }

    private static func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private static func ms(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }

    private static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#8e8e93" }
        func byte(_ v: CGFloat) -> String {
            let n = Int((max(0, min(1, v)) * 255).rounded())
            return (n < 16 ? "0" : "") + String(n, radix: 16)
        }
        return "#" + byte(rgb.redComponent) + byte(rgb.greenComponent) + byte(rgb.blueComponent)
    }

    private static func cgColor(_ hex: String) -> CGColor {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0x6F86C9
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private final class Observer: @unchecked Sendable {
        let token: NSObjectProtocol
        init(token: NSObjectProtocol) { self.token = token }
    }
}

import Core
import Foundation

/// Plán a zkoušky jako události vlastního kalendáře „Studijní plán“ v Apple Kalendáři. Obsah odpovídá
/// odebíranému kalendáři (`IcsExport.feed`): bloky od dvou týdnů zpět a zkoušky. Kalendář je jen kopie dat –
/// zdrojem pravdy zůstává `data.json`, takže změny v Kalendáři se při další synchronizaci přepíšou.
public enum CalendarMirror {
    /// Název kalendáře, který Mac založí (a na jiném Macu najde).
    public static let calendarTitle = "Studijní plán"

    public struct Options: Sendable, Equatable {
        public var includeExams: Bool
        /// Připomenutí před blokem v minutách (`nil` = bez připomenutí).
        public var alarmMin: Int?

        public init(includeExams: Bool = true, alarmMin: Int? = 10) {
            self.includeExams = includeExams
            self.alarmMin = alarmMin
        }
    }

    /// Odkud událost pochází – uloženo v odkazu události (`studytracker://planovac?blok=…`).
    public struct Key: Hashable, Sendable {
        public enum Kind: String, Sendable { case block = "blok", exam = "zkouska" }
        public let kind: Kind
        public let id: String

        public init(_ kind: Kind, _ id: String) {
            self.kind = kind
            self.id = id
        }

        /// Odkaz na událost: otevře v aplikaci kalendář na týdnu bloku nebo zkoušky.
        public var url: URL {
            var c = URLComponents()
            c.scheme = TimerLink.scheme
            c.host = "planovac"
            c.queryItems = [URLQueryItem(name: kind.rawValue, value: id)]
            return c.url!
        }

        public init?(url: URL?) {
            guard let url, url.scheme?.lowercased() == TimerLink.scheme, url.host == "planovac",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count == 1,
                  let kind = Kind(rawValue: items[0].name), let id = items[0].value, !id.isEmpty else { return nil }
            self.init(kind, id)
        }
    }

    /// Událost, jak má v kalendáři vypadat.
    public struct Event: Sendable, Equatable {
        public let key: Key
        public var title: String
        public var start: Int
        public var end: Int
        public var allDay: Bool
        public var notes: String
        /// Připomenutí v minutách před začátkem.
        public var alarms: [Int]

        public init(key: Key, title: String, start: Int, end: Int, allDay: Bool, notes: String, alarms: [Int]) {
            self.key = key
            self.title = title
            self.start = start
            self.end = end
            self.allDay = allDay
            self.notes = notes
            self.alarms = alarms
        }
    }

    /// Událost, která v kalendáři aplikace už je.
    public struct Existing: Sendable, Equatable {
        public let identifier: String
        public var url: URL?
        public var title: String
        public var start: Int
        public var end: Int
        public var allDay: Bool
        public var notes: String
        public var alarms: [Int]

        public init(identifier: String, url: URL?, title: String, start: Int, end: Int, allDay: Bool, notes: String, alarms: [Int]) {
            self.identifier = identifier
            self.url = url
            self.title = title
            self.start = start
            self.end = end
            self.allDay = allDay
            self.notes = notes
            self.alarms = alarms
        }
    }

    /// Co se v kalendáři musí změnit, aby odpovídal datům.
    public struct Changes: Sendable, Equatable {
        public var create: [Event] = []
        public var update: [Update] = []
        /// Identifikátory událostí k odstranění (smazané bloky, cizí nebo zdvojené události).
        public var remove: [String] = []

        public struct Update: Sendable, Equatable {
            public let identifier: String
            public let event: Event
        }

        public init() {}

        public var isEmpty: Bool { create.isEmpty && update.isEmpty && remove.isEmpty }
        public var count: Int { create.count + update.count + remove.count }
    }

    /// Patička poznámky – na iPhonu je hned vidět, kde se plán upravuje.
    static let footer = "Ze Study Trackeru – změny dělej v aplikaci, tady by se přepsaly."

    /// Od kdy se kalendář udržuje (starší události zůstanou, jak jsou – historie).
    public static func windowStart(now: Int, clock: StudyClock) -> Int {
        clock.addDays(clock.startOfDay(now), -14)
    }

    /// Události z dat: bloky od dvou týdnů zpět, zkoušky od stejného dne (jako odebíraný kalendář).
    /// Hotový blok má ✓ a žádné připomenutí.
    public static func events(_ doc: AppDocument, options: Options, now: Int, clock: StudyClock) -> [Event] {
        let from = windowStart(now: now, clock: clock)
        var names: [String: String] = [:]
        for s in doc.records(Subject.self) { names[s.id] = s.name }

        var out: [Event] = []
        for b in doc.alive(PlanBlock.self) where b.start >= from {
            let name = names[b.subjectId] ?? "Učení"
            out.append(Event(
                key: Key(.block, b.id),
                title: (b.done ? "✓ " : "") + "📚 \(name)\(b.title.isEmpty ? "" : " – \(b.title)")",
                start: b.start, end: b.start + max(1, b.durationMin) * StudyClock.minute, allDay: false,
                notes: notes(b.note),
                alarms: b.done ? [] : options.alarmMin.map { [$0] } ?? []
            ))
        }
        guard options.includeExams else { return out }
        for e in doc.alive(Exam.self) {
            guard let day = clock.parseDayKey(e.date), day >= from else { continue }
            let name = names[e.subjectId] ?? ""
            let title = "🎓 \(e.name)\(name.isEmpty ? "" : " (\(name))")"
            if let start = time(e.time, day: day, clock: clock) {
                out.append(Event(key: Key(.exam, e.id), title: title, start: start, end: start + 90 * StudyClock.minute, allDay: false,
                                 notes: notes(e.note), alarms: [24 * 60]))
            } else {
                out.append(Event(key: Key(.exam, e.id), title: title, start: day, end: clock.addDays(day, 1), allDay: true,
                                 notes: notes(e.note), alarms: [24 * 60]))
            }
        }
        return out
    }

    /// Rozdíl mezi daty a kalendářem aplikace. Kalendář patří jen aplikaci, takže událost bez platného
    /// odkazu (nebo druhá se stejným odkazem) se odstraní – v cizích kalendářích se nikdy nic nemění.
    public static func diff(desired: [Event], existing: [Existing]) -> Changes {
        var changes = Changes()
        var byKey: [Key: Existing] = [:]
        for e in existing {
            guard let key = Key(url: e.url), byKey[key] == nil else {
                changes.remove.append(e.identifier)
                continue
            }
            byKey[key] = e
        }
        var wanted = Set<Key>()
        for event in desired where wanted.insert(event.key).inserted {
            if let current = byKey[event.key] {
                if !same(event, current) { changes.update.append(.init(identifier: current.identifier, event: event)) }
            } else {
                changes.create.append(event)
            }
        }
        for (key, e) in byKey where !wanted.contains(key) { changes.remove.append(e.identifier) }
        changes.remove.sort()
        return changes
    }

    /// Stejná událost? Časy na sekundy (kalendář milisekundy nedrží), u celodenní jen den začátku.
    static func same(_ a: Event, _ b: Existing) -> Bool {
        guard a.title == b.title, a.allDay == b.allDay, a.notes == b.notes.trimmingCharacters(in: .whitespacesAndNewlines),
              a.alarms.sorted() == b.alarms.sorted(), a.start.floorDiv(1000) == b.start.floorDiv(1000) else { return false }
        return a.allDay || a.end.floorDiv(1000) == b.end.floorDiv(1000)
    }

    private static func notes(_ note: String) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? footer : note + "\n\n" + footer
    }

    /// `HH:MM` zkoušky; prázdný čas = celodenní.
    private static func time(_ value: String, day: Int, clock: StudyClock) -> Int? {
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        return clock.atMinutes(day, parts[0] * 60 + (parts.count > 1 ? parts[1] : 0))
    }
}

/// Událost z ostatních kalendářů (práce, výuka, osobní), která v ranním plánu zabírá čas.
public struct ExternalBusy: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let start: Int
    public let end: Int
    public let calendarId: String
    public let calendarTitle: String
    /// `#rrggbb` barva kalendáře.
    public let color: String

    public init(id: String, title: String, start: Int, end: Int, calendarId: String, calendarTitle: String, color: String) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.color = color
    }

    public var interval: BusyInterval { BusyInterval(start: start, end: end) }
}

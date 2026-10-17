import Core
import Foundation

/// Export plánu a zkoušek do formátu iCalendar (`src/features/planner/ics.ts` a `calendarFeed.ts` na webu).
/// Časy jsou v UTC (přípona Z), takže nezáleží na časovém pásmu zařízení. Události mají stálá UID,
/// takže opakovaný import i odebíraný kalendář aktualizují stejné události.
public enum IcsExport {
    /// Soubor v tajném gistu, který si Apple Kalendář pravidelně stahuje.
    public static let feedFile = "studijni-plan.ics"

    /// Kalendář `.ics` (`buildIcs` na webu). `feed` = odebíraný kalendář (přidá interval obnovování).
    public static func build(blocks: [PlanBlock], exams: [Exam], subjects: [Subject], alarmMin: Int?, feed: Bool = false,
                             now: Int, clock: StudyClock) -> String {
        // `new Map(subjects.map(...))` – při stejném id platí poslední záznam
        var names: [String: String] = [:]
        for s in subjects { names[s.id] = s.name }
        let stamp = utc(now)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Study Tracker//CS", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Studijní plán"]
        if feed { lines += ["REFRESH-INTERVAL;VALUE=DURATION:PT1H", "X-PUBLISHED-TTL:PT1H"] }

        for b in blocks {
            let name = names[b.subjectId] ?? "Učení"
            lines += [
                "BEGIN:VEVENT", "UID:\(b.id)@study-tracker", "DTSTAMP:\(stamp)", "DTSTART:\(utc(b.start))",
                "DTEND:\(utc(b.start + b.durationMin * StudyClock.minute))",
                "SUMMARY:" + escape("📚 \(name)\(b.title.isEmpty ? "" : " – \(b.title)")"), "CATEGORIES:" + escape(name),
            ]
            if !b.note.isEmpty { lines.append("DESCRIPTION:" + escape(b.note)) }
            if let alarmMin {
                lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + escape(name), "TRIGGER:-PT\(alarmMin)M", "END:VALARM"]
            }
            lines.append("END:VEVENT")
        }

        for e in exams {
            let name = names[e.subjectId] ?? ""
            lines += ["BEGIN:VEVENT", "UID:exam-\(e.id)@study-tracker", "DTSTAMP:\(stamp)"]
            let day = clock.parseDayKey(e.date) ?? 0
            if !e.time.isEmpty {
                let parts = e.time.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                let start = clock.atMinutes(day, parts[0] * 60 + (parts.count > 1 ? parts[1] : 0))
                lines += ["DTSTART:\(utc(start))", "DTEND:\(utc(start + 90 * StudyClock.minute))"]
            } else {
                lines += ["DTSTART;VALUE=DATE:\(dateOnly(day, clock: clock))", "DTEND;VALUE=DATE:\(dateOnly(clock.addDays(day, 1), clock: clock))"]
            }
            lines.append("SUMMARY:" + escape("🎓 \(e.name)\(name.isEmpty ? "" : " (\(name))")"))
            if !e.note.isEmpty { lines.append("DESCRIPTION:" + escape(e.note)) }
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + escape(e.name), "TRIGGER:-P1D", "END:VALARM", "END:VEVENT"]
        }

        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Obsah odebíraného kalendáře (`buildFeed` na webu): bloky od dvou týdnů zpět a budoucí zkoušky.
    public static func feed(_ doc: AppDocument, includeExams: Bool, alarmMin: Int?, now: Int, clock: StudyClock) -> String {
        let from = clock.addDays(clock.startOfDay(now), -14)
        // Na webu `new Date(e.date)` – datum bez času je půlnoc UTC (ne místní půlnoc).
        let exams = includeExams ? doc.alive(Exam.self).filter { utcMidnight($0.date).map { $0 >= from } ?? false } : []
        return build(blocks: doc.alive(PlanBlock.self).filter { $0.start >= from }, exams: exams, subjects: doc.records(Subject.self),
                     alarmMin: alarmMin, feed: true, now: now, clock: clock)
    }

    /// Otisk obsahu bez časového razítka – mění se jen při skutečné změně plánu (`feedHash` na webu).
    public static func hash(_ ics: String) -> String {
        var h: Int32 = 5381
        var lineStart = true
        var skipping = false
        let units = Array(ics.utf16)
        let stampPrefix = Array("DTSTAMP:".utf16)
        var i = 0
        while i < units.count {
            let u = units[i]
            let terminator = u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029
            if terminator {
                skipping = false
                lineStart = true
            } else if lineStart {
                // `/^DTSTAMP:.*$/gm` – řádek s razítkem vypadne celý, konce řádků zůstanou
                skipping = units.count - i >= stampPrefix.count && Array(units[i..<i + stampPrefix.count]) == stampPrefix
                lineStart = false
            }
            if !skipping { h = (h &<< 5) &+ h &+ Int32(u) }
            i += 1
        }
        return String(h)
    }

    /// Adresa souboru v gistu a odkaz pro Apple Kalendář (`webcal:`).
    public static func feedURL(owner: String, gistId: String) -> URL? {
        URL(string: "https://gist.githubusercontent.com/\(owner)/\(gistId)/raw/\(feedFile)")
    }

    public static func webcalURL(owner: String, gistId: String) -> URL? {
        feedURL(owner: owner, gistId: gistId).flatMap { URL(string: "webcal:" + $0.absoluteString.dropFirst("https:".count)) }
    }

    // MARK: - Formát

    /// `20261017T204013Z`
    static func utc(_ t: Int) -> String {
        let d = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(t) / 1000))
        return "\(d.year!)\(two(d.month!))\(two(d.day!))T\(two(d.hour!))\(two(d.minute!))\(two(d.second!))Z"
    }

    private static func dateOnly(_ t: Int, clock: StudyClock) -> String {
        let d = clock.calendar.dateComponents([.year, .month, .day], from: clock.date(t))
        return "\(d.year!)\(two(d.month!))\(two(d.day!))"
    }

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `YYYY-MM-DD` jako půlnoc UTC (`new Date('2026-11-02')`; den nad konec měsíce přeteče do dalšího).
    /// Jiné tvary data aplikace nezapisuje – ty se berou jako neplatné.
    private static func utcMidnight(_ day: String) -> Int? {
        let p = day.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), p.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return ICal.epochMs(y, m - 1, d)
    }

    /// Text hodnoty: `\` `;` `,` a konec řádku (LF) se escapují – po znacích Unicode, aby se LF
    /// v CRLF nahradil stejně jako regulárním výrazem na webu.
    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case ",": out += "\\,"
            case ";": out += "\\;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// RFC 5545: řádky delší než 75 bajtů se zalamují (pokračování začíná mezerou, má nejvýš 74 bajtů).
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out: [String] = []
        var current = ""
        var length = 0
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if length + size > (out.isEmpty ? 75 : 74) {
                out.append(current)
                current = ""
                length = 0
            }
            current.unicodeScalars.append(scalar)
            length += size
        }
        out.append(current)
        return out.joined(separator: "\r\n ")
    }
}

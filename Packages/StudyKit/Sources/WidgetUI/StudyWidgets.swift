import SwiftUI
import WidgetData
import WidgetKit

// Widgety Study Trackeru: Dnešek, Časovač, Plán, Zkoušky a Přehled. Rozšíření widgetů je jen
// registruje; obsah, časová osa i vzhled jsou tady (a mají náhledy v testech).

/// Položka časové osy: okamžik a souhrn od aplikace (`nil` = aplikace ještě nic nezapsala).
public struct StudyEntry: TimelineEntry {
    public let date: Date
    public let snapshot: WidgetSnapshot?

    public init(date: Date, snapshot: WidgetSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }

    var moment: WidgetMoment? { snapshot.map { WidgetMoment($0, at: WidgetFormat.ms(date)) } }
}

/// Časová osa ze souhrnu ve sdíleném kontejneru – widget se překreslí sám na začátku a konci bloků,
/// o půlnoci a během běžícího bloku každou minutu; aplikace ho navíc překreslí po každé změně.
public struct StudyProvider: TimelineProvider {
    let files: @Sendable () -> WidgetFiles?

    public init(files: @escaping @Sendable () -> WidgetFiles? = { WidgetFiles.shared() }) {
        self.files = files
    }

    public func placeholder(in context: Context) -> StudyEntry {
        StudyEntry(date: .now, snapshot: .sample(now: WidgetFormat.ms(.now)))
    }

    public func getSnapshot(in context: Context, completion: @escaping @Sendable (StudyEntry) -> Void) {
        let now = WidgetFormat.ms(.now)
        let saved = files()?.readSnapshot()
        completion(StudyEntry(date: .now, snapshot: saved ?? (context.isPreview ? .sample(now: now) : nil)))
    }

    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StudyEntry>) -> Void) {
        let now = WidgetFormat.ms(.now)
        guard let s = files()?.readSnapshot() else {
            completion(Timeline(entries: [StudyEntry(date: .now, snapshot: nil)], policy: .after(.now.addingTimeInterval(3600))))
            return
        }
        let entries = WidgetTimeline.dates(s, from: now).map { StudyEntry(date: WidgetFormat.date($0), snapshot: s) }
        completion(Timeline(entries: entries, policy: .after(WidgetFormat.date(WidgetTimeline.refresh(s, from: now)))))
    }
}

/// Společný rám: pozadí ve vzhledu Deník a odkaz do aplikace.
private struct WidgetFrame<Content: View>: View {
    let page: String
    let content: Content

    init(page: String, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        Themed { t in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(for: .widget) { t.bg }
                .widgetURL(URL(string: "studytracker://\(page)"))
        }
    }
}

// MARK: - Dnešek

/// Dnešní čas s cílem a sérií; střední velikost přidá „Co teď?“ nebo běžící blok.
public struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: StudyEntry
    /// Velikost pro náhledy (mimo WidgetKit se z prostředí nedá nastavit).
    private var fixedFamily: WidgetFamily?

    public init(entry: StudyEntry) {
        self.entry = entry
    }

    init(entry: StudyEntry, family: WidgetFamily) {
        self.entry = entry
        fixedFamily = family
    }

    private var family: WidgetFamily { fixedFamily ?? environmentFamily }

    public var body: some View {
        WidgetFrame(page: "prehled") {
            if let s = entry.snapshot, let m = entry.moment {
                if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 0) {
                        TodaySummary(s: s, m: m, size: 30)
                        Spacer(minLength: 6)
                        NextLine(s: s, m: m)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            TodaySummary(s: s, m: m, size: 34)
                            Spacer(minLength: 6)
                            NextLine(s: s, m: m)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        Group {
                            if m.timer.isActive || m.timer.status == .ready {
                                TimerPanel(s: s, m: m, clockSize: 30)
                            } else {
                                NextUpPanel(s: s, titleSize: 14, titleLines: 2, showsReason: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                NoData()
            }
        }
    }
}

// MARK: - Časovač

/// Běžící blok s živým odpočtem a tlačítky; v klidu „Co teď?“ se spuštěním.
public struct TimerWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: StudyEntry
    /// Velikost pro náhledy (mimo WidgetKit se z prostředí nedá nastavit).
    private var fixedFamily: WidgetFamily?

    public init(entry: StudyEntry) {
        self.entry = entry
    }

    init(entry: StudyEntry, family: WidgetFamily) {
        self.entry = entry
        fixedFamily = family
    }

    private var family: WidgetFamily { fixedFamily ?? environmentFamily }

    public var body: some View {
        WidgetFrame(page: "casovac") {
            if let s = entry.snapshot, let m = entry.moment {
                let active = m.timer.isActive || m.timer.status == .ready
                if family == .systemSmall {
                    if active {
                        TimerPanel(s: s, m: m, clockSize: 38)
                    } else {
                        NextUpPanel(s: s, titleSize: 14, titleLines: 3, showsReason: false)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        Group {
                            if active {
                                TimerPanel(s: s, m: m, clockSize: 40)
                            } else {
                                NextUpPanel(s: s, titleSize: 16, titleLines: 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            TodaySummary(s: s, m: m, size: 24)
                            Spacer(minLength: 6)
                            NextLine(s: s, m: m)
                        }
                        .frame(width: 132, alignment: .leading)
                    }
                }
            } else {
                NoData()
            }
        }
    }
}

// MARK: - Plán

/// Dnešní plán; velká velikost přidá zítřek a nejbližší zkoušky.
public struct PlanWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: StudyEntry
    /// Velikost pro náhledy (mimo WidgetKit se z prostředí nedá nastavit).
    private var fixedFamily: WidgetFamily?

    public init(entry: StudyEntry) {
        self.entry = entry
    }

    init(entry: StudyEntry, family: WidgetFamily) {
        self.entry = entry
        fixedFamily = family
    }

    private var family: WidgetFamily { fixedFamily ?? environmentFamily }

    public var body: some View {
        WidgetFrame(page: "planovac") {
            if let s = entry.snapshot, let m = entry.moment {
                if family == .systemLarge {
                    VStack(alignment: .leading, spacing: 0) {
                        PlanList(s: s, m: m, limit: 6, strip: true)
                        TomorrowList(s: s, m: m, limit: 2).padding(.top, 12)
                        Spacer(minLength: 8)
                        if let first = m.exams.first {
                            Divider().padding(.bottom, 10)
                            ExamLine(exam: first.exam, daysLeft: first.daysLeft, s: s)
                        }
                    }
                } else {
                    PlanList(s: s, m: m, limit: 3)
                }
            } else {
                NoData()
            }
        }
    }
}

// MARK: - Zkoušky

/// Nejbližší zkouška velkým odpočtem dní; střední velikost tři zkoušky.
public struct ExamsWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: StudyEntry
    /// Velikost pro náhledy (mimo WidgetKit se z prostředí nedá nastavit).
    private var fixedFamily: WidgetFamily?

    public init(entry: StudyEntry) {
        self.entry = entry
    }

    init(entry: StudyEntry, family: WidgetFamily) {
        self.entry = entry
        fixedFamily = family
    }

    private var family: WidgetFamily { fixedFamily ?? environmentFamily }

    public var body: some View {
        WidgetFrame(page: "planovac") {
            if let s = entry.snapshot, let m = entry.moment {
                Themed { t in
                    if m.exams.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Caption("Zkoušky")
                            Spacer()
                            Text("Žádná zkouška v plánu.").font(.system(size: 13, design: .serif)).foregroundStyle(t.text2)
                        }
                    } else if family == .systemSmall, let first = m.exams.first {
                        let subject = s.subject(first.exam.subjectId)
                        VStack(alignment: .leading, spacing: 2) {
                            Caption("Zkouška")
                            Spacer(minLength: 0)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(first.daysLeft)").font(.system(size: 54, design: .serif).monospacedDigit())
                                    .foregroundStyle(first.daysLeft <= 3 ? t.warn : t.text).widgetAccentable()
                                Text(first.daysLeft == 0 ? "dnes" : WidgetFormat.plural(first.daysLeft, "den", "dny", "dní"))
                                    .font(.system(size: 14)).foregroundStyle(t.text2)
                            }
                            Text(first.exam.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text).lineLimit(2)
                            HStack(spacing: 5) {
                                SubjectMark(color: subject.color, size: 7)
                                Text(subject.name).font(.system(size: 11)).foregroundStyle(t.text2).lineLimit(1)
                            }
                            Text(WidgetFormat.day(first.exam.day) + (first.exam.time.isEmpty ? "" : " · \(first.exam.time)"))
                                .font(.system(size: 11)).foregroundStyle(t.text3)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Caption("Zkoušky")
                            ForEach(Array(m.exams.prefix(3).enumerated()), id: \.offset) { _, e in
                                ExamLine(exam: e.exam, daysLeft: e.daysLeft, s: s)
                            }
                        }
                    }
                }
            } else {
                NoData()
            }
        }
    }
}

// MARK: - Přehled

/// Všechno na jednom místě – pro velkou plochu (velký monitor): dnešek a týden, plán, časovač
/// nebo „Co teď?“ a zkoušky.
public struct OverviewWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: StudyEntry
    /// Velikost pro náhledy (mimo WidgetKit se z prostředí nedá nastavit).
    private var fixedFamily: WidgetFamily?

    public init(entry: StudyEntry) {
        self.entry = entry
    }

    init(entry: StudyEntry, family: WidgetFamily) {
        self.entry = entry
        fixedFamily = family
    }

    private var family: WidgetFamily { fixedFamily ?? environmentFamily }

    public var body: some View {
        WidgetFrame(page: "prehled") {
            if let s = entry.snapshot, let m = entry.moment {
                if family == .systemExtraLarge {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 0) {
                            TodaySummary(s: s, m: m, size: 36)
                            Spacer(minLength: 12)
                            if !m.subjectWeek.isEmpty {
                                Caption("Předměty · týden")
                                SubjectWeekList(s: s, m: m, limit: 3).padding(.top, 8)
                                Spacer(minLength: 12)
                            }
                            WeekHeader(s: s, m: m)
                            WeekBars(m: m, height: 44).padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            PlanList(s: s, m: m, limit: 6, strip: true)
                            Spacer(minLength: 8)
                            TomorrowList(s: s, m: m, limit: 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            if m.timer.isActive || m.timer.status == .ready {
                                TimerPanel(s: s, m: m, clockSize: 46, fills: false)
                            } else {
                                NextUpPanel(s: s, titleSize: 17, titleLines: 2, showsAlternative: true, buttonFollowsContent: true)
                            }
                            Spacer(minLength: 12)
                            if !m.exams.isEmpty {
                                Caption("Zkoušky").padding(.bottom, 6)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(m.exams.prefix(3).enumerated()), id: \.offset) { _, e in
                                        ExamLine(exam: e.exam, daysLeft: e.daysLeft, s: s)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 0) {
                                TodaySummary(s: s, m: m, size: 28)
                                Spacer(minLength: 8)
                                NextLine(s: s, m: m)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                            Group {
                                if m.timer.isActive || m.timer.status == .ready {
                                    TimerPanel(s: s, m: m, clockSize: 28)
                                } else {
                                    NextUpPanel(s: s, titleSize: 14, titleLines: 2, showsReason: false)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 142)
                        Divider().padding(.vertical, 12)
                        PlanList(s: s, m: m, limit: 3, strip: true)
                        Spacer(minLength: 8)
                        if let first = m.exams.first {
                            ExamLine(exam: first.exam, daysLeft: first.daysLeft, s: s)
                        }
                    }
                }
            } else {
                NoData()
            }
        }
    }
}

// MARK: - Společné části velkých widgetů

/// Zítřejší bloky plánu (velké widgety).
private struct TomorrowList: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    let limit: Int

    var body: some View {
        let tomorrow = WidgetMoment(s, at: m.day + 86_400_000 + 1)
        if !tomorrow.plan.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Caption("Zítra · \(WidgetFormat.day(tomorrow.day))").padding(.bottom, 4)
                ForEach(tomorrow.plan.prefix(limit)) { PlanLine(block: $0, s: s, m: tomorrow) }
            }
        }
    }
}

/// „Tento týden“ se součtem a týdenním cílem.
private struct WeekHeader: View {
    let s: WidgetSnapshot
    let m: WidgetMoment

    var body: some View {
        Themed { t in
            HStack {
                Caption("Tento týden")
                Spacer(minLength: 4)
                Text(WidgetFormat.duration(m.weekSec) + (s.weekGoalSec > 0 ? " z \(WidgetFormat.duration(s.weekGoalSec))" : ""))
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(t.text3).lineLimit(1)
            }
        }
    }
}

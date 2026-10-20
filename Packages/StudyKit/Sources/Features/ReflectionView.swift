import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Týdenní reflexe (`ReflectionPage` na webu): souhrn týdne, hodnocení a tři otázky; „jedna věc jinak“
/// se pak ukáže na stránce Dnes jako záměr.
public struct ReflectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    /// Pondělí týdne `YYYY-MM-DD`; výchozí minulý týden (reflexe se dělá zpětně).
    @State private var week: String?
    @State private var rating = 0
    @State private var wentWell = ""
    @State private var blocked = ""
    @State private var focusNext = ""
    let openPage: (String) -> Void

    private var snapshot: (width: CGFloat, now: Int)?

    public init(openPage: @escaping (String) -> Void = { _ in }) {
        self.openPage = openPage
    }

    init(snapshotWidth: CGFloat, now: Int) {
        snapshot = (snapshotWidth, now)
        openPage = { _ in }
    }

    static let ratings = ["", "Špatný", "Slabší", "Průměrný", "Dobrý", "Výborný"]

    public var body: some View {
        let now = snapshot?.now ?? Int(Date().timeIntervalSince1970 * 1000)
        let clock = store.clock
        let key = week ?? clock.dayKey(clock.addDays(clock.startOfWeek(now), -7))
        Group {
            if let snapshot {
                page(key, now: now, metrics: PageMetrics(width: snapshot.width))
            } else {
                GeometryReader { proxy in
                    ScrollView { page(key, now: now, metrics: PageMetrics(width: proxy.size.width)) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Reflexe")
        .task(id: key) { load(key) }
    }

    private func existing(_ key: String) -> Reflection? {
        store.document.alive(Reflection.self).first { $0.weekStart == key }
    }

    private func load(_ key: String) {
        let r = existing(key)
        rating = r?.rating ?? 0
        wentWell = r?.wentWell ?? ""
        blocked = r?.blocked ?? ""
        focusNext = r?.raw.string("focusNext") ?? ""
    }

    private func page(_ key: String, now: Int, metrics: PageMetrics) -> some View {
        let clock = store.clock
        let doc = store.document
        let from = clock.parseDayKey(key) ?? clock.startOfWeek(now)
        let to = clock.addDays(from, 7)
        let settings = doc.settings
        let all = doc.alive(Session.self), blocks = doc.records(PlanBlock.self)
        let cur = PeriodStats(sessions: all, blocks: blocks, from: from, to: to, restDays: settings.streakRestDays, minMin: settings.streakMinMin, now: now, clock: clock)
        let prev = PeriodStats(sessions: all, blocks: blocks, from: clock.addDays(from, -7), to: from, restDays: settings.streakRestDays,
                               minMin: settings.streakMinMin, now: now, clock: clock)
        let goals = doc.alive(Subject.self).filter { $0.weeklyGoalMin > 0 && !$0.archived }
        let goalsMet = goals.filter { cur.secOf(subject: $0.id) >= $0.weeklyGoalMin * 60 }.count
        let thisWeek = clock.startOfWeek(now)
        let saved = existing(key)
        return VStack(alignment: .leading, spacing: 40) {
            PageHeader("\(Format.date(from, .dayMonth, clock: clock)) – \(Format.date(clock.addDays(from, 6), .dayMonth, clock: clock))",
                       subtitle: "Týdenní reflexe", glyph: .symbol("text.bubble")) {
                Button { week = clock.dayKey(clock.addDays(from, -7)) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.study(.normal, size: .small)).help("Předchozí týden").accessibilityIdentifier("reflection.prev")
                Button { week = clock.dayKey(to) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.study(.normal, size: .small)).help("Další týden").disabled(to > thisWeek).accessibilityIdentifier("reflection.next")
            }
            FactRows(title: "Týden", facts: [
                Fact.change(label: "Celkem", value: Format.duration(cur.total), change: Report.pct(Double(cur.total), Double(prev.total)), suffix: " proti předchozímu"),
                Fact(label: "Aktivní dny", value: "\(cur.activeDays) z 7", note: "\(cur.sessions) sezení"),
                Fact(label: "Cíle splněny", value: goals.isEmpty ? "–" : "\(goalsMet) z \(goals.count)", note: "týdenní cíle předmětů"),
                Fact(label: "Soustředění", value: cur.focus.map { Format.decimal($0) } ?? "–", note: prev.focus.map { "předtím \(Format.decimal($0))" }),
                Fact(label: "Plnění plánu", value: cur.planAdherence.map { "\(Int(JS.round($0 * 100))) %" } ?? "–", note: "hotových bloků"),
            ], columns: metrics.size == .compact ? 1 : metrics.size == .regular ? 2 : 3)
            ColumnsLayout(columns: metrics.size == .compact ? 1 : 2, spacing: 56, rowSpacing: 44) {
                form(key, saved: saved)
                VStack(alignment: .leading, spacing: 36) {
                    ChartSection("Po dnech") {
                        HighlightBars(labels: Format.weekdaysShort,
                                      minutes: (0..<7).map { Double(cur.secOf(day: clock.dayKey(clock.addDays(from, $0)))) / 60 }, height: 170)
                    }
                    ChartSection("Předměty a cíle") { goalsList(cur, goals: goals) }
                }
            }
            history(except: key)
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.vertical, 48)
        .frame(maxWidth: metrics.size == .regular ? 1280 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func form(_ key: String, saved: Reflection?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ListHeading("Jak se týden povedl?", meta: saved != nil ? "uloženo" : nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("Celkové hodnocení týdne\(rating > 0 ? " · \(Self.ratings[rating])" : "")").foregroundStyle(Palette.text2)
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { n in
                        Button { rating = n } label: {
                            Text("\(n)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .frame(width: 34, height: 28)
                                .foregroundStyle(rating == n ? Palette.accent : Palette.text2)
                                .background(rating == n ? Palette.accentSoft : Palette.panel2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(Self.ratings[n])
                        .accessibilityLabel("\(n) · \(Self.ratings[n])")
                        .accessibilityIdentifier("reflection.rating.\(n)")
                    }
                }
            }
            field("Co fungovalo? Čemu se chceš držet?", text: $wentWell, placeholder: "např. ranní bloky před školou, mobil v jiné místnosti…")
            field("Co tě brzdilo?", text: $blocked, placeholder: "např. odkládání, únava večer, moc velké úkoly…")
            VStack(alignment: .leading, spacing: 6) {
                Text("Jedna konkrétní věc, kterou tento týden uděláš jinak").foregroundStyle(Palette.text2)
                TextField("Konkrétně: kdy, kde, co. Ukáže se ti na stránce Dnes.", text: $focusNext)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("reflection.focusNext")
            }
            HStack(spacing: 8) {
                Button("Uložit reflexi") { save(key, saved: saved) }
                    .buttonStyle(.primary)
                    .disabled(rating == 0 && wentWell.isEmpty && blocked.isEmpty && focusNext.isEmpty)
                    .accessibilityIdentifier("reflection.save")
                Button { openPage("planovac") } label: { Label("Naplánovat týden", systemImage: "calendar") }
                    .buttonStyle(.study(.normal))
            }
        }
        .font(.system(size: 13.5))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(Palette.text2)
            TextEditor(text: text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.lineStrong))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder).foregroundStyle(Palette.text3).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
        }
    }

    private func goalsList(_ cur: PeriodStats, goals: [Subject]) -> some View {
        let lookup = SubjectLookup(store.document)
        var ids = cur.perSubject.map(\.id)
        for g in goals where !ids.contains(g.id) { ids.append(g.id) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(ids, id: \.self) { id in
                let subject = lookup[id]
                let done = cur.secOf(subject: id)
                let goal = (store.document.records(Subject.self).first { $0.id == id }?.weeklyGoalMin ?? 0) * 60
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.subject(subject.color)).frame(width: 7, height: 7)
                        Text(subject.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(goal > 0 ? "\(Format.duration(done)) / \(Format.duration(goal))" : Format.duration(done)).monospacedDigit().foregroundStyle(Palette.text2)
                    }
                    ProgressLine(goal > 0 ? min(1, Double(done) / Double(goal)) : 1, color: Palette.subject(subject.color))
                }
                .font(.system(size: 13))
            }
        }
    }

    @ViewBuilder
    private func history(except key: String) -> some View {
        let clock = store.clock
        let list = store.document.alive(Reflection.self).filter { $0.weekStart != key }.sorted { $0.weekStart > $1.weekStart }.prefix(12)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ListHeading("Předchozí reflexe")
                ForEach(Array(list), id: \.id) { r in
                    Button { week = r.weekStart } label: {
                        HStack(spacing: 12) {
                            let from = clock.parseDayKey(r.weekStart) ?? 0
                            Text("\(Format.date(from, .dayNumericMonth, clock: clock)) – \(Format.date(clock.addDays(from, 6), .dayNumericMonth, clock: clock))")
                                .monospacedDigit().foregroundStyle(Palette.text2).frame(width: 120, alignment: .leading)
                            if r.rating > 0 { Chip("\(r.rating)/5") }
                            Text([r.raw.string("focusNext") ?? "", r.wentWell, r.blocked].first { !$0.isEmpty } ?? "")
                                .lineLimit(1).foregroundStyle(Palette.text)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13.5))
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
        }
    }

    private func save(_ key: String, saved: Reflection?) {
        let trim = { (s: String) in s.jsTrimmed }
        store.upsert(Reflection(raw: [
            "id": .string(saved?.id ?? Reflection.newID()), "weekStart": .string(key), "rating": .number(Double(rating)),
            "wentWell": .string(trim(wentWell)), "blocked": .string(trim(blocked)), "focusNext": .string(trim(focusNext)),
        ]))
        toasts.show("Reflexe uložena")
    }
}

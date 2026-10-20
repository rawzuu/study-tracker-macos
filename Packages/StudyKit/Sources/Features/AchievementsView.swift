import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Úspěchy (`AchievementsPage` na webu) ve vzhledu „Seznam“: místo kovových medailí řádky po skupinách –
/// ikona, úrovně jako tečky (I–VIII), postup k další úrovni a datum získání. Id, úrovně i výpočet jsou
/// stejné jako na webu (`Achievements`).
public struct AchievementsView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String?
    /// „Nové“ = získané od poslední návštěvy této stránky (první návštěva nic neoznačí).
    @State private var fresh: Set<String> = []

    private var snapshot: (width: CGFloat, now: Int)?

    static let viewedKey = "st.ach.viewed"

    public init() {}

    init(snapshotWidth: CGFloat, now: Int) {
        snapshot = (snapshotWidth, now)
    }

    public var body: some View {
        let now = snapshot?.now ?? Int(Date().timeIntervalSince1970 * 1000)
        let res = Achievements.evaluate(store.document, now: now, clock: store.clock)
        Group {
            if let snapshot {
                page(res, metrics: PageMetrics(width: snapshot.width))
            } else {
                GeometryReader { proxy in
                    ScrollView { page(res, metrics: PageMetrics(width: proxy.size.width)) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Úspěchy")
        .onAppear { markViewed(res.unlockedIds) }
        .sheet(item: Binding(get: { selected.map(Selection.init) }, set: { selected = $0?.id })) { s in
            AchievementDetail(id: s.id, results: res).environment(store)
        }
    }

    private struct Selection: Identifiable {
        let id: String
    }

    private func markViewed(_ ids: [String]) {
        guard snapshot == nil else { return }
        let seen = store.defaults.stringArray(forKey: Self.viewedKey)
        fresh = seen.map { s in Set(ids).subtracting(s) } ?? []
        store.defaults.set(ids, forKey: Self.viewedKey)
    }

    private func page(_ res: Achievements.Results, metrics: PageMetrics) -> some View {
        let pct = res.total > 0 ? Int(JS.round(Double(res.unlocked) / Double(res.total) * 100)) : 0
        let columns = metrics.size == .compact ? 1 : 2
        return VStack(alignment: .leading, spacing: 40) {
            PageHeader("Úspěchy", subtitle: "\(res.unlocked) z \(res.total) · \(pct) % všech úspěchů", glyph: .symbol("rosette")) {}
            VStack(alignment: .leading, spacing: 8) {
                ProgressLine(Double(pct) / 100, color: Palette.accent)
                Text(metals(res)).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("achievements.summary")
            ColumnsLayout(columns: columns, spacing: 56, rowSpacing: 40) {
                let close = res.families.filter { $0.next != nil && $0.value > 0 }.stableSorted { $0.progress > $1.progress }.prefix(4)
                if !close.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ListHeading("Na dosah", meta: "nejblíž další úrovni")
                        ForEach(Array(close)) { r in closeRow(r) }
                    }
                }
                let latest = recent(res)
                if !latest.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ListHeading("Nedávno získané")
                        ForEach(latest, id: \.id) { x in
                            Button { selected = x.open } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: x.icon).frame(width: 18).foregroundStyle(Palette.accent)
                                    Text(x.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Format.date(x.at, .dayNumericMonth, clock: store.clock)).monospacedDigit().foregroundStyle(Palette.text3)
                                }
                                .font(.system(size: 13.5))
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ColumnsLayout(columns: columns, spacing: 56, rowSpacing: 40) {
                ForEach(Achievements.Group.allCases, id: \.self) { g in groupSection(g, res) }
            }
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.vertical, 48)
        .frame(maxWidth: metrics.size == .regular ? 1280 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// „ocel 5 · bronz 3 · stříbro 2 · zlato 4 · platina 1“
    private func metals(_ res: Achievements.Results) -> String {
        var counts = Array(repeating: 0, count: 5)
        for r in res.families { for i in 0..<r.tier { counts[Achievements.material(tier: i + 1, of: r.family.thresholds.count)] += 1 } }
        counts[3] += res.singles.filter(\.unlocked).count
        return zip(Achievements.materials, counts).map { "\($0) \($1)" }.joined(separator: " · ")
    }

    private struct Recent {
        let id: String
        let open: String
        let name: String
        let icon: String
        let at: Int
    }

    private func recent(_ res: Achievements.Results) -> [Recent] {
        var out: [Recent] = []
        for r in res.families {
            for (i, t) in r.tiers.enumerated() where t.unlocked {
                guard let at = t.at else { continue }
                let n = r.family.thresholds.count > 1 ? " \(Achievements.roman[i])" : ""
                out.append(Recent(id: "\(r.family.id).\(i + 1)", open: r.family.id, name: r.family.name + n, icon: r.family.icon, at: at))
            }
        }
        for s in res.singles where s.unlocked {
            guard let at = s.at else { continue }
            out.append(Recent(id: s.single.id, open: s.single.id, name: s.single.name, icon: s.single.icon, at: at))
        }
        return Array(out.stableSorted { $0.at > $1.at }.prefix(6))
    }

    private func closeRow(_ r: Achievements.FamilyResult) -> some View {
        Button { selected = r.family.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Image(systemName: r.family.icon).frame(width: 18).foregroundStyle(Palette.text2)
                    Text(r.family.name + (r.family.thresholds.count > 1 ? " \(Achievements.roman[r.tier])" : "")).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(JS.round(r.progress * 100))) % · \(AchievementText.remaining(r))").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                }
                ProgressLine(r.progress, color: Palette.accent).padding(.leading, 28)
            }
            .font(.system(size: 13.5))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func groupSection(_ g: Achievements.Group, _ res: Achievements.Results) -> some View {
        let fams = res.families.filter { $0.family.group == g }
        let singles = res.singles.filter { $0.single.group == g }
        if !fams.isEmpty || !singles.isEmpty {
            let unlocked = fams.reduce(0) { $0 + $1.tier } + singles.filter(\.unlocked).count
            let total = fams.reduce(0) { $0 + $1.family.thresholds.count } + singles.count
            VStack(alignment: .leading, spacing: 0) {
                ListHeading(g.rawValue, meta: "\(unlocked) z \(total)")
                ForEach(fams) { r in familyRow(r) }
                ForEach(singles) { s in singleRow(s) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("achievements.group.\(g.rawValue)")
        }
    }

    private func familyRow(_ r: Achievements.FamilyResult) -> some View {
        let f = r.family
        let on = r.tier > 0
        let isFresh = r.tiers.indices.contains { r.tiers[$0].unlocked && fresh.contains("\(f.id).\($0 + 1)") }
        return Button { selected = f.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: f.icon).frame(width: 18).foregroundStyle(on ? Palette.accent : Palette.text3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(f.name + (on && f.thresholds.count > 1 ? " \(Achievements.roman[r.tier - 1])" : "")).fontWeight(.medium)
                        if isFresh { Text("nové").font(Typo.small).foregroundStyle(Palette.accent) }
                    }
                    Text(on ? f.desc(f.thresholds[r.tier - 1]) : f.desc(f.thresholds[0])).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    TierDots(tier: r.tier, count: f.thresholds.count)
                    Text(r.next == nil ? "vše získáno" : AchievementText.remaining(r)).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(on ? Palette.text : Palette.text2)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityIdentifier("achievement.\(f.id)")
    }

    private func singleRow(_ r: Achievements.SingleResult) -> some View {
        let s = r.single
        let hidden = s.secret && !r.unlocked
        return Button { selected = s.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: hidden ? "questionmark" : s.icon).frame(width: 18).foregroundStyle(r.unlocked ? Palette.accent : Palette.text3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(hidden ? "Skrytý úspěch" : s.name).fontWeight(.medium)
                        if fresh.contains(s.id) { Text("nové").font(Typo.small).foregroundStyle(Palette.accent) }
                    }
                    Text(hidden ? "odhalí se sám" : s.desc).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
                }
                Spacer(minLength: 12)
                if r.unlocked {
                    Text(r.at.map { Format.date($0, .dayNumericMonthYear, clock: store.clock) } ?? "získáno").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    BlockCheck(.done)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(r.unlocked ? Palette.text : Palette.text2)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityIdentifier("achievement.\(s.id)")
    }
}

/// Úrovně jako tečky: získané plné, další obrysem, zbylé tlumené.
private struct TierDots: View {
    let tier: Int
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                if i < tier {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                } else if i == tier {
                    Circle().strokeBorder(Palette.accent, lineWidth: 1.2).frame(width: 6, height: 6)
                } else {
                    Circle().fill(Palette.panel3).frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(tier) z \(count) úrovní")
    }
}

enum AchievementText {
    /// Kolik zbývá do další úrovně – lidsky (`remaining`).
    static func remaining(_ r: Achievements.FamilyResult) -> String {
        guard let next = r.next else { return "" }
        let left = next - r.value
        switch r.family.unit {
        case .h: return "zbývá \(Format.duration(max(60, left * 3600)))"
        case .min: return "blok o \(Int(left.rounded(.up))) min delší"
        case .d:
            let d = Int(left.rounded(.up))
            return "zbývá \(d) \(Format.plural(d, "den", "dny", "dní"))"
        case .x, .none: return "ještě \(Int(left.rounded(.up)))×"
        }
    }
}

/// Podrobnosti úspěchu: všechny úrovně s daty získání (`FamilyDetail` / `SingleDetail`).
private struct AchievementDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    let results: Achievements.Results

    var body: some View {
        EditorSheet(title, width: 520) {
            if let r = results.families.first(where: { $0.family.id == id }) {
                family(r)
            } else if let s = results.singles.first(where: { $0.single.id == id }) {
                single(s)
            }
        } footer: {
            Spacer()
            Button("Zavřít") { dismiss() }.buttonStyle(.study(.normal)).keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        if let r = results.families.first(where: { $0.family.id == id }) {
            return r.family.name + (r.tier > 0 && r.family.thresholds.count > 1 ? " \(Achievements.roman[r.tier - 1])" : "")
        }
        guard let s = results.singles.first(where: { $0.single.id == id }) else { return "" }
        return s.single.secret && !s.unlocked ? "Skrytý úspěch" : s.single.name
    }

    private func family(_ r: Achievements.FamilyResult) -> some View {
        let f = r.family
        let n = f.thresholds.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(f.group.rawValue) · \(r.tier > 0 ? "\(Achievements.materials[Achievements.material(tier: r.tier, of: n)]) · úroveň \(r.tier) z \(n)" : "0 z \(n) úrovní")")
                .font(Typo.small).foregroundStyle(Palette.text3)
            if let next = r.next {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Další: ") + Text(f.desc(next)).fontWeight(.semibold)
                        Spacer()
                        Text("\(Int(JS.round(r.progress * 100))) %").monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    ProgressLine(r.progress, color: Palette.accent)
                    Text(AchievementText.remaining(r)).font(Typo.small).foregroundStyle(Palette.text3)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(r.tiers.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 10) {
                        Text(Achievements.roman[i]).monospacedDigit().frame(width: 34, alignment: .leading).foregroundStyle(t.unlocked ? Palette.accent : Palette.text3)
                        Text(f.desc(t.threshold)).foregroundStyle(t.unlocked ? Palette.text : Palette.text2)
                        Spacer(minLength: 8)
                        Text(t.unlocked ? (t.at.map { Format.date($0, .dayNumericMonthShortYear, clock: store.clock) } ?? "✓") : i == r.tier ? "\(Int(JS.round(r.progress * 100))) %" : "")
                            .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    .font(.system(size: 13.5))
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
        }
    }

    private func single(_ r: Achievements.SingleResult) -> some View {
        let s = r.single
        let hidden = s.secret && !r.unlocked
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(s.group.rawValue)\(s.secret ? " · skrytý" : "")").font(Typo.small).foregroundStyle(Palette.text3)
            Text(hidden ? "Podmínku prozradí až samotné získání." : s.desc).font(.system(size: 14))
            if r.unlocked {
                Text(r.at.map { "získáno \(Format.date($0, .dayNumericMonthYear, clock: store.clock))" } ?? "získáno").font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
    }
}

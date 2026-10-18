import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Karta „Co teď?“ na přehledu (`NextUp` na webu): hlavní doporučení s důvody, další možnosti
/// a na požádání „Proč“ – signály, ze kterých je skóre.
struct NextUpSection: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Advisor.self) private var advisor
    let now: Int
    let openTimer: () -> Void
    @State private var why = false

    var body: some View {
        let advice = advisor.advice(now: now)
        let recs = advice.recommendations
        PageSection("Co teď?", accessory: {
            if !recs.isEmpty {
                Button { why.toggle() } label: {
                    Label("Proč", systemImage: "chevron.down").labelStyle(TrailingIcon(rotated: why))
                }
                .buttonStyle(.denik(.ghost, size: .small))
                .accessibilityIdentifier("next.why")
            }
        }) {
            if let top = recs.first {
                VStack(alignment: .leading, spacing: 18) {
                    main(top, note: advice.note)
                    if recs.count > 1 { alternatives(Array(recs.dropFirst().prefix(3))) }
                    if why { WhyTable(recs: Array(recs.prefix(6))) }
                }
                .padding(.top, 4)
            } else {
                EmptyNote("Zatím není co doporučit", systemImage: "sparkles") {
                    Text("Přidej předměty, cíle nebo zkoušky – doporučení se objeví tady.")
                }
            }
        }
        .accessibilityIdentifier("dash.next")
    }

    /// Blokuje jen běžící nebo pozastavený blok; mezi bloky jde rovnou začít něco jiného.
    private var busy: Bool { !timer.state.canSwitch }

    private func main(_ top: Recommendation, note: String?) -> some View {
        let subject = SubjectInfo(top.subjectId, in: store.document)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ColorMark(color: subject.color)
                Text(subject.name).foregroundStyle(Palette.text2) + Text(" · \(top.activity.label)").foregroundStyle(Palette.text3)
            }
            .font(.system(size: 13))
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("next.subject")
            Text(top.title)
                .font(.system(size: 30, design: .serif))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("next.title")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(top.reasons.prefix(3), id: \.self) { reason in
                    Text(reason)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.text2)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 12)
            if let note {
                Text(note)
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            HStack(spacing: 12) {
                if top.activity == .anki {
                    Label("Otevři Anki – čas se započítá při dalším načtení z Anki.", systemImage: "rectangle.stack")
                        .font(Typo.small).foregroundStyle(Palette.text2)
                } else if busy {
                    Button("Časovač běží – otevřít", action: openTimer).buttonStyle(.denik(.normal))
                    Text("Doporučení spustíš po ukončení bloku.").font(Typo.small).foregroundStyle(Palette.text3)
                } else {
                    Button { start(top) } label: { Label("Začít · \(top.minutes) min", systemImage: "play.fill") }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("next.start")
                    Text(modeName(top.modeId)).font(Typo.small).foregroundStyle(Palette.text3)
                }
            }
            .padding(.top, 14)
        }
    }

    private func alternatives(_ recs: [Recommendation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nebo").font(Typo.small).foregroundStyle(Palette.text3).padding(.bottom, 2)
            ForEach(recs) { r in
                let subject = SubjectInfo(r.subjectId, in: store.document)
                Button { start(r) } label: {
                    HStack(spacing: 10) {
                        ColorMark(color: subject.color)
                        (Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.text) + Text("  \(r.title)").foregroundStyle(Palette.text3))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(r.minutes) min").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    .font(.system(size: 13.5))
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
                .buttonStyle(.plain)
                .disabled(busy || r.activity == .anki)
                .help(busy ? "Časovač běží – nejdřív ukonči blok" : r.reasons.joined(separator: " · "))
                .accessibilityIdentifier("next.alt.\(r.key)")
            }
        }
    }

    private func start(_ r: Recommendation) {
        guard let subjectId = r.subjectId else { return }
        timer.setup(TimerSetup(subjectId: subjectId, topic: r.topic, modeId: r.modeId, planBlockId: r.planBlockId))
        openTimer()
    }

    private func modeName(_ id: String) -> String {
        let presets = Dictionary(store.document.alive(TimerPreset.self).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Format.modeName(id, presets: presets)
    }
}

/// „Proč“: vzorec skóre a signály předmětů jako tenké pruhy (`nx-why` na webu, bez opakování).
private struct WhyTable: View {
    @Environment(AppStore.self) private var store
    let recs: [Recommendation]

    private static let signals: [(label: String, hint: String, value: (Recommendation.Signals) -> Double)] = [
        ("Zkouška", "blízkost zkoušky", \.E),
        ("Týdenní cíl", "zaostávání za cílem", \.G),
        ("Zanedbání", "dny bez učení", \.N),
        ("Plán", "naplánováno na teď", \.P),
        ("Prostřídat", "nedávno na řadě (snižuje skóre)", \.X),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skóre = 0,30·zkouška + 0,20·týdenní cíl + 0,10·zanedbání + 0,15·plán − 0,35·prostřídat (u blízké zkoušky se toleruje víc času na předmětu, ale ne stejný předmět hned po sobě). Všechny signály jsou 0–1. Prokládání předmětů patří k nejlépe podloženým metodám učení.")
                .font(Typo.small).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("Předmět")
                    ForEach(Self.signals, id: \.label) { s in Text(s.label).help(s.hint).gridColumnAlignment(.trailing) }
                    Text("Skóre").gridColumnAlignment(.trailing)
                }
                .font(Typo.small).foregroundStyle(Palette.text3)
                .padding(.bottom, 6)
                ForEach(recs) { r in
                    Divider().overlay(Palette.line).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        let subject = SubjectInfo(r.subjectId, in: store.document)
                        HStack(spacing: 6) {
                            ColorMark(color: subject.color)
                            Text(subject.name).lineLimit(1)
                        }
                        ForEach(Self.signals, id: \.label) { s in
                            SignalBar(value: s.value(r.signals), negative: s.label == "Prostřídat")
                        }
                        Text(Format.decimal(r.score, digits: 2)).monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
            }
            .font(.system(size: 13))
            Text("Váhy: E 0.3 · G 0.2 · N 0.1 · P 0.15 · X 0.35").font(Typo.small).foregroundStyle(Palette.text3)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityIdentifier("next.whyTable")
    }
}

private struct SignalBar: View {
    let value: Double
    let negative: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Palette.lineStrong)
            Rectangle().fill(negative ? Palette.danger : Palette.text2).frame(width: 46 * min(1, max(0, value)))
        }
        .frame(width: 46, height: 3)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) %")
    }
}

/// Kompaktní doporučení na stránce časovače (`NextUpInline` na webu): „Použít“ jen předvyplní časovač.
struct NextUpInline: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Advisor.self) private var advisor

    var body: some View {
        if timer.state.canSwitch, let top = advisor.recommendations(now: store.nowMs).first(where: { $0.subjectId != nil }) {
            let subject = SubjectInfo(top.subjectId, in: store.document)
            HStack(spacing: 10) {
                (Text("DOPORUČUJI  ").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Palette.text3)
                    + Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.subject(subject.color))
                    + Text(" · \(top.title) · \(top.minutes) min").foregroundStyle(Palette.text2))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Použít") {
                    timer.setup(TimerSetup(subjectId: top.subjectId, topic: top.topic, modeId: top.modeId, planBlockId: top.planBlockId))
                }
                .buttonStyle(.denik(.normal, size: .small))
                .accessibilityIdentifier("timer.useRecommendation")
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.lineStrong))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timer.recommendation")
        }
    }
}

extension SubjectInfo {
    /// Předmět doporučení podle id (`nil` = kartičky z Anki).
    init(_ id: String?, in doc: AppDocument) {
        guard let id else {
            self.init(id: "", name: "Anki", color: Self.deleted.color)
            return
        }
        self = doc.record(Subject.self, id: id).map { SubjectInfo(id: id, name: $0.name, color: $0.color) } ?? .deleted
    }
}

/// Malý čtverec barvy předmětu.
struct ColorMark: View {
    let color: String

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Palette.subject(color)).frame(width: 8, height: 8)
    }
}

/// Ikona za textem, otočená, když je obsah rozbalený.
private struct TrailingIcon: LabelStyle {
    let rotated: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(rotated ? 180 : 0))
        }
    }
}

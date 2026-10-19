import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// „Co teď?“ nad seznamem dne: hlavní doporučení jako karta (předmět, název, důvody, Začít), pod ním
/// další možnosti a na požádání „Proč“ – signály, ze kterých je skóre.
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Co teď?").font(Typo.heading).foregroundStyle(Palette.accent).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if !recs.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.18)) { why.toggle() } } label: {
                        Label("Proč", systemImage: "chevron.down").labelStyle(TrailingIcon(rotated: why))
                    }
                    .buttonStyle(.study(.ghost, size: .small))
                    .accessibilityIdentifier("next.why")
                }
            }
            if let top = recs.first {
                VStack(alignment: .leading, spacing: 0) {
                    main(top, note: advice.note)
                    if recs.count > 1 { alternatives(Array(recs.dropFirst().prefix(3))).padding(.top, 14) }
                    if why { WhyTable(recs: Array(recs.prefix(6))).padding(.top, 16) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
                .padding(.horizontal, -16)
            } else {
                EmptyNote("Zatím není co doporučit", systemImage: "sparkles") {
                    Text("Přidej předměty, cíle nebo zkoušky – doporučení se objeví tady.")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dash.next")
    }

    /// Blokuje jen běžící nebo pozastavený blok; mezi bloky jde rovnou začít něco jiného.
    private var busy: Bool { !timer.state.canSwitch }

    private func main(_ top: Recommendation, note: String?) -> some View {
        let subject = SubjectInfo(top.subjectId, in: store.document)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SubjectCapsule(name: subject.name, color: subject.color)
                Text(top.activity.label).font(Typo.small).foregroundStyle(Palette.text3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("next.subject")
            Text(top.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("next.title")
            Text(top.reasons.prefix(3).joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                if top.activity == .anki {
                    Label("Otevři Anki – čas se započítá při dalším načtení z Anki.", systemImage: "rectangle.stack")
                        .font(Typo.small).foregroundStyle(Palette.text2)
                } else if busy {
                    Button("Časovač běží – otevřít", action: openTimer).buttonStyle(.study(.normal, size: .small))
                    Text("Doporučení spustíš po ukončení bloku.").font(Typo.small).foregroundStyle(Palette.text3)
                } else {
                    Button { start(top) } label: { Label("Začít · \(top.minutes) min", systemImage: "play.fill") }
                        .buttonStyle(.study(.primary, size: .small))
                        .accessibilityIdentifier("next.start")
                    Text(modeName(top.modeId)).font(Typo.small).foregroundStyle(Palette.text3)
                }
            }
            .padding(.top, 12)
        }
    }

    private func alternatives(_ recs: [Recommendation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1).padding(.bottom, 6)
            ForEach(recs) { r in
                let subject = SubjectInfo(r.subjectId, in: store.document)
                Button { start(r) } label: {
                    HStack(spacing: 10) {
                        Text("Nebo").font(Typo.small).foregroundStyle(Palette.text3).frame(width: 32, alignment: .leading)
                        ColorMark(color: subject.color)
                        (Text(subject.name).foregroundStyle(Palette.text) + Text("  \(r.title)").foregroundStyle(Palette.text3))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(r.minutes) min").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    .font(.system(size: 13))
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("next.whyTable")
    }
}

private struct SignalBar: View {
    let value: Double
    let negative: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.panel2)
            Capsule().fill(negative ? Palette.danger : Palette.accent).frame(width: 46 * min(1, max(0, value)))
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
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Palette.accent)
                (Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.text)
                    + Text("  \(top.title) · \(top.minutes) min").foregroundStyle(Palette.text2))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Použít") {
                    timer.setup(TimerSetup(subjectId: top.subjectId, topic: top.topic, modeId: top.modeId, planBlockId: top.planBlockId))
                }
                .buttonStyle(.study(.normal, size: .small))
                .accessibilityIdentifier("timer.useRecommendation")
            }
            .padding(.vertical, 8)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// Barevná tečka předmětu.
struct ColorMark: View {
    let color: String

    var body: some View {
        Circle().fill(Palette.subject(color)).frame(width: 7, height: 7)
    }
}

/// Části vedle sebe; když se nevejdou, pod sebou.
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 56) { content }
            VStack(alignment: .leading, spacing: 40) { content }
        }
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

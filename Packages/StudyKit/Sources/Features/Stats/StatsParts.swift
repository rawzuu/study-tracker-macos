import Charts
import DesignSystem
import Engine
import SwiftUI

// Společné části Statistik, Měsíčního reportu a Reflexe ve vzhledu „Seznam“.

/// Řádek souhrnu: popisek vlevo, hodnota a poznámka vpravo.
struct Fact: Hashable {
    let label: String
    let value: String
    var note: String?
    var tone: Color?

    /// Hodnota se změnou proti předchozímu období (▲ zeleně, ▼ červeně).
    static func change(label: String, value: String, change: Int?, suffix: String = "") -> Fact {
        guard let change else { return Fact(label: label, value: value, note: "bez srovnání") }
        return Fact(label: label, value: value, note: "\(change >= 0 ? "▲" : "▼") \(abs(change)) %\(suffix)", tone: change >= 0 ? Palette.success : Palette.danger)
    }
}

/// Souhrn jako řádky v jednom až třech sloupcích – bez dlaždic.
struct FactRows: View {
    let title: String
    let facts: [Fact]
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListHeading(title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: columns), alignment: .leading, spacing: 0) {
                ForEach(facts, id: \.label) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(f.label).foregroundStyle(Palette.text2)
                        Spacer(minLength: 12)
                        Text(f.value).fontWeight(.semibold).monospacedDigit().foregroundStyle(Palette.text)
                        if let note = f.note { Text(note).font(Typo.small).monospacedDigit().foregroundStyle(f.tone ?? Palette.text3) }
                    }
                    .font(.system(size: 13.5))
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Osy a mřížka grafů: drobné šedé popisky, jemné čáry.
    func chartChrome() -> some View {
        font(.system(size: 10.5))
            .foregroundStyle(Palette.text3)
    }
}

/// Nadpis grafu s hodnotou vpravo a obsah pod ním.
struct ChartSection<Content: View>: View {
    let title: String
    let meta: String?
    let content: Content

    init(_ title: String, meta: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.meta = meta
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListHeading(title, meta: meta)
            content
        }
        .accessibilityElement(children: .contain)
    }
}


/// Osa minut po celých hodinách (nebo půlhodinách) podle největší hodnoty, jemná mřížka.
func minutesAxis(max: Double) -> some AxisContent {
    let step: Double = max <= 90 ? 30 : max <= 300 ? 60 : max <= 600 ? 120 : max <= 1200 ? 240 : 480
    return AxisMarks(position: .leading, values: .stride(by: step)) { value in
        AxisGridLine().foregroundStyle(Palette.line)
        AxisValueLabel {
            if let m = value.as(Double.self) { Text(m == 0 ? "0" : m < 60 ? "\(Int(m)) min" : "\(Format.decimal(m / 60, digits: m.truncatingRemainder(dividingBy: 60) == 0 ? 0 : 1)) h") }
        }
    }
}


/// Minuty po dnech (nebo dnech v týdnu) jako sloupce; nejlepší den sytě, ostatní světleji (`highlightBars`).
struct HighlightBars: View {
    let labels: [String]
    let minutes: [Double]
    var height: CGFloat = 220

    var body: some View {
        let top = minutes.max() ?? 0
        Chart {
            ForEach(minutes.indices, id: \.self) { i in
                BarMark(x: .value("Den", labels[i]), y: .value("Minuty", minutes[i]))
                    .foregroundStyle(Palette.accent.opacity(minutes[i] == top && top > 0 ? 1 : 0.42))
                    .cornerRadius(2)
            }
        }
        .chartXScale(domain: labels)
        .chartYAxis { minutesAxis(max: top) }
        .chartXAxis { AxisMarks { _ in AxisValueLabel(collisionResolution: .greedy) } }
        .chartChrome()
        .frame(height: height)
    }
}

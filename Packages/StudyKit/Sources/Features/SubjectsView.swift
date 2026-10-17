import AppModel
import DesignSystem
import Engine
import SwiftUI

/// Předměty s týdenními cíli a celkovým časem (jen pro čtení v M1).
public struct SubjectsView: View {
    @Environment(AppStore.self) private var store

    public init() {}

    public var body: some View {
        let state = SubjectsState(document: store.document, now: Int(Date().timeIntervalSince1970 * 1000), clock: store.clock)
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                PageHeader("Předměty", subtitle: "Barvy, týdenní cíle a archiv – úpravy přijdou se zápisem z Macu.")
                PageSection("Aktivní", accessory: { Text("\(state.active.count)") }) {
                    if state.active.isEmpty {
                        EmptyNote("Zatím žádné předměty", systemImage: "books.vertical")
                    } else {
                        rows(state.active)
                    }
                }
                .accessibilityIdentifier("subjects.active")
                if !state.archived.isEmpty {
                    PageSection("Archiv", accessory: { Text("\(state.archived.count)") }) { rows(state.archived) }
                        .accessibilityIdentifier("subjects.archived")
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageBackground()
        .navigationTitle("Předměty")
    }

    private func rows(_ rows: [SubjectsState.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                ListRow(divider: i < rows.count - 1) {
                    RoundedRectangle(cornerRadius: 5).fill(Palette.subject(row.subject.color)).frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.subject.name)
                        Text(row.summary).font(Typo.small).foregroundStyle(Palette.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if row.goalSec > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Tento týden \(Format.duration(row.weekSec)) z \(Format.duration(row.goalSec))")
                                .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
                            ProgressLine(row.fraction, color: Palette.subject(row.subject.color)).frame(width: 180)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("subject.\(row.id)")
            }
        }
    }
}

import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Historie sezení po dnech: filtr podle předmětu, ruční zápis a úpravy. Starší dny se načítají postupně.
public struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var subjectId: String?
    @State private var limit = 30
    @State private var editing: EditedSession?

    public init() {}

    public var body: some View {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let state = HistoryState(document: store.document, subjectId: subjectId, now: now, clock: store.clock)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                PageHeader("Historie") {
                    HStack(spacing: 8) {
                        Picker("Předmět", selection: $subjectId) {
                            Text("Všechny předměty").tag(String?.none)
                            ForEach(state.subjects, id: \.id) { s in Text(s.name).tag(Optional(s.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .accessibilityIdentifier("history.subject")
                        Button { editing = EditedSession(draft: SessionDraft(now: now, clock: store.clock)) } label: {
                            Label("Ruční zápis", systemImage: "plus")
                        }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("history.add")
                    }
                }
                if state.groups.isEmpty {
                    EmptyNote("Žádná sezení", systemImage: "book")
                } else {
                    ForEach(state.groups.prefix(limit)) { group in
                        PageSection(group.title, accessory: { Chip(group.total) }) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, s in
                                    SessionLine(row: s, divider: i < group.rows.count - 1) { edit(s.id) }
                                }
                            }
                        }
                        .accessibilityIdentifier("history.day.\(group.id)")
                    }
                    if state.groups.count > limit {
                        Button("Načíst starší") { limit += 30 }
                            .accessibilityIdentifier("history.more")
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageBackground()
        .navigationTitle("Historie")
        .sheet(item: $editing) { SessionEditor(draft: $0.draft) }
    }

    private func edit(_ id: String) {
        guard let session = store.document.record(Session.self, id: id) else { return }
        editing = EditedSession(draft: SessionDraft(editing: session, clock: store.clock))
    }
}

/// Otevřený formulář sezení (každé otevření má vlastní id).
private struct EditedSession: Identifiable {
    let id = UUID()
    let draft: SessionDraft
}

private struct SessionLine: View {
    let row: SessionRow
    let divider: Bool
    let edit: () -> Void

    var body: some View {
        ListRow(divider: divider) {
            Text(row.timeRange).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                SubjectTag(name: row.subject.name, color: row.subject.color)
                if !row.detail.isEmpty { Text(row.detail).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(2) }
                if let recall = row.recall {
                    Text(recall).font(Typo.small).italic().foregroundStyle(Palette.text2)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.lineStrong).frame(width: 2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let focus = row.focus {
                Chip("\(focus)/5").help(Format.focusLabels[min(5, max(1, focus))])
            }
            Text(row.duration).fontWeight(.semibold).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.denik(.ghost, size: .small))
                .help("Upravit")
                .accessibilityLabel("Upravit")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Upravit", edit)
        .accessibilityIdentifier("session.\(row.id)")
    }
}

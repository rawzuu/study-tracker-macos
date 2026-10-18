import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import Sync

/// Předměty s týdenními cíli a celkovým časem; nový předmět, úprava a archiv.
public struct SubjectsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: SubjectDraft?

    /// Pevná šířka bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshotWidth: CGFloat?

    public init() {}

    init(snapshotWidth: CGFloat) {
        self.snapshotWidth = snapshotWidth
    }

    /// V režimu jen čtení by se úpravy neodeslaly – proto se nedají dělat.
    private var canEdit: Bool { store.sync.mode == .readWrite }

    public var body: some View {
        let state = SubjectsState(document: store.document, now: Int(Date().timeIntervalSince1970 * 1000), clock: store.clock)
        Group {
            if let snapshotWidth {
                page(state, metrics: PageMetrics(width: snapshotWidth))
            } else {
                GeometryReader { proxy in
                    ScrollView { page(state, metrics: PageMetrics(width: proxy.size.width)) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Předměty")
        .sheet(item: $editing) { draft in SubjectEditor(draft: draft) }
    }

    private func page(_ state: SubjectsState, metrics: PageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 36) {
            PageHeader("Předměty", subtitle: canEdit ? nil : "Režim jen pro čtení – úpravy jdou zapnout v Nastavení.") {
                Button {
                    editing = SubjectDraft(newIn: store.document)
                } label: {
                    Label("Nový předmět", systemImage: "plus")
                }
                .buttonStyle(.primary)
                .disabled(!canEdit)
                .accessibilityIdentifier("subjects.new")
            }
            PageSection("Aktivní", accessory: { Text("\(state.active.count)") }) {
                if state.active.isEmpty {
                    EmptyNote("Zatím žádné předměty", systemImage: "books.vertical")
                } else {
                    rows(state.active, columns: metrics.size == .wide ? 2 : 1)
                }
            }
            .accessibilityIdentifier("subjects.active")
            if !state.archived.isEmpty {
                PageSection("Archiv", accessory: { Text("\(state.archived.count)") }) { rows(state.archived, columns: metrics.size == .wide ? 2 : 1) }
                    .accessibilityIdentifier("subjects.archived")
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Předměty pod sebou, na velkém monitoru ve dvou sloupcích (po řádcích zleva doprava).
    private func rows(_ rows: [SubjectsState.Row], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 56, alignment: .top), count: columns), alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                // Čára pod řádkem kromě posledního řádku mřížky.
                ListRow(divider: i < rows.count - (rows.count - 1) % columns - 1) {
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
                    if canEdit, let subject = store.document.record(Subject.self, id: row.id) {
                        HStack(spacing: 2) {
                            Button { toggleArchive(subject) } label: {
                                Image(systemName: subject.archived ? "archivebox.fill" : "archivebox")
                            }
                            .help(subject.archived ? "Obnovit z archivu" : "Archivovat")
                            .accessibilityLabel(subject.archived ? "Obnovit z archivu" : "Archivovat")
                            .accessibilityIdentifier("subject.archive.\(row.id)")
                            Button { editing = SubjectDraft(editing: subject) } label: { Image(systemName: "pencil") }
                                .help("Upravit")
                                .accessibilityLabel("Upravit")
                                .accessibilityIdentifier("subject.edit.\(row.id)")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.text2)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("subject.\(row.id)")
            }
        }
    }

    private func toggleArchive(_ subject: Subject) {
        var s = subject
        s.archived.toggle()
        store.upsert(s)
    }
}

extension SubjectDraft: Identifiable {
    public var id: String { original?.id ?? "new" }
}

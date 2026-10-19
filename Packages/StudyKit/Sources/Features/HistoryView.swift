import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Historie sezení po dnech: filtr podle předmětu, ruční zápis a úpravy. Starší dny se načítají postupně.
public struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @State private var subjectId: String?
    @State private var limit = 30
    @State private var editing: EditedSession?

    /// Pevná šířka bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshotWidth: CGFloat?

    public init() {}

    init(snapshotWidth: CGFloat) {
        self.snapshotWidth = snapshotWidth
    }

    public var body: some View {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let state = HistoryState(document: store.document, subjectId: subjectId, now: now, clock: store.clock)
        Group {
            if let snapshotWidth {
                page(state, metrics: PageMetrics(width: snapshotWidth), now: now)
            } else {
                GeometryReader { proxy in
                    ScrollView { page(state, metrics: PageMetrics(width: proxy.size.width), now: now) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Historie")
        .sheet(item: $editing, onDismiss: { toasts.presentAfterSheet() }) { SessionEditor(draft: $0.draft) }
    }

    private func page(_ state: HistoryState, metrics: PageMetrics, now: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            PageHeader("Historie", subtitle: subtitle(state), glyph: .history) {
                Picker("Předmět", selection: $subjectId) {
                    Text("Všechny předměty").tag(String?.none)
                    ForEach(state.subjects, id: \.id) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityIdentifier("history.subject")
                Button { editing = EditedSession(draft: SessionDraft(now: now, clock: store.clock)) } label: {
                    Label("Ruční zápis", systemImage: "plus")
                }
                .buttonStyle(.study(.normal, size: .small))
                .accessibilityIdentifier("history.add")
            }
            if state.groups.isEmpty {
                EmptyNote("Žádná sezení", systemImage: "book")
            } else {
                if metrics.size == .wide {
                    // Na velkém monitoru dny ve dvou sloupcích – čte se po řádcích zleva doprava.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 64, alignment: .top), count: 2),
                              alignment: .leading, spacing: 30) {
                        days(state)
                    }
                } else {
                    days(state)
                }
                if state.groups.count > limit {
                    Button("Načíst starší") { limit += 30 }
                        .buttonStyle(.study(.normal, size: .small))
                        .accessibilityIdentifier("history.more")
                }
            }
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.vertical, 48)
        .frame(maxWidth: metrics.size == .regular ? 1080 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtitle(_ state: HistoryState) -> String {
        let n = state.groups.reduce(0) { $0 + $1.rows.count }
        return "\(n) \(Format.plural(n, "sezení", "sezení", "sezení")) · \(state.groups.count) \(Format.plural(state.groups.count, "den", "dny", "dní"))"
    }

    private func days(_ state: HistoryState) -> some View {
        ForEach(state.groups.prefix(limit)) { group in
            VStack(alignment: .leading, spacing: 0) {
                ListHeading(group.title, meta: group.total)
                ForEach(group.rows) { s in
                    SessionLine(row: s) { edit(s.id) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.day.\(group.id)")
        }
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

/// Sezení jako odškrtnutá položka: téma, předmět, podrobnosti, soustředění, délka a čas.
private struct SessionLine: View {
    let row: SessionRow
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BlockCheck(.done, color: Palette.subject(row.subject.color)).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.topic.isEmpty ? row.subject.name : row.topic).font(.system(size: 14)).lineLimit(1)
                    if !row.topic.isEmpty { SubjectCapsule(name: row.subject.name, color: row.subject.color) }
                }
                if !row.extra.isEmpty {
                    Text(row.extra).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(2)
                }
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
            Text(row.timeRange).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.text3)
            Text(row.duration).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.study(.ghost, size: .small))
                .opacity(hovering ? 1 : 0.35)
                .help("Upravit")
                .accessibilityLabel("Upravit")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Upravit", edit)
        .accessibilityIdentifier("session.\(row.id)")
    }
}

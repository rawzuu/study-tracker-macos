import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import UniformTypeIdentifiers

/// Správa rozvrhu (`TimetableModal` na webu): import .ics, nová verze s náhledem změn, skrytí předmětů.
struct TimetableSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    /// Pro který rozvrh se vybírá soubor (`nil` = výběr souboru není otevřený).
    @State private var picking: Target?
    @State private var pending: Pending?
    @State private var error: String?

    enum Target: Equatable {
        case new
        case replace(id: String)

        var replaceId: String? {
            if case .replace(let id) = self { id } else { nil }
        }
    }

    /// Načtený soubor čeká na potvrzení.
    struct Pending {
        let result: ICal.Result
        /// `nil` = nový rozvrh
        let replaceId: String?
        var name: String
    }

    var body: some View {
        let timetables = store.document.alive(Timetable.self)
        EditorSheet("Rozvrh", width: 640) {
            if let error {
                Banner(error, systemImage: "exclamationmark.triangle", tone: .bad)
            }
            if let pending {
                PendingImport(pending: Binding(get: { pending }, set: { self.pending = $0 }), replacing: timetables.first { $0.id == pending.replaceId },
                              now: store.nowMs, clock: store.clock)
            } else if timetables.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nahraj rozvrh ve formátu .ics. Výuka se zobrazí v kalendáři jako obsazený čas.")
                        .foregroundStyle(Palette.text2)
                    Text("Soubor stáhneš ve školním informačním systému u rozvrhu (export do kalendáře / iCal). Když se rozvrh změní, nahraješ novou verzi a změny se promítnou najednou.")
                        .font(Typo.small).foregroundStyle(Palette.text3)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(timetables) { tt in timetable(tt) }
                    }
                }
                .frame(maxHeight: 460)
            }
        } footer: {
            if let pending {
                Spacer()
                Button("Zrušit") { self.pending = nil }.buttonStyle(.study(.ghost)).keyboardShortcut(.cancelAction)
                Button(pending.replaceId == nil ? "Importovat" : "Nahradit", action: confirm)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("timetable.confirm")
            } else {
                Button { picking = .new } label: {
                    Label(timetables.isEmpty ? "Vybrat soubor .ics" : "Přidat další rozvrh", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.study(.normal))
                .accessibilityIdentifier("timetable.import")
                Spacer()
                Button("Hotovo") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [UTType(filenameExtension: "ics") ?? .calendarEvent, .calendarEvent]) { result in
            let target = picking?.replaceId
            picking = nil
            switch result {
            case .success(let url): load(url, replaceId: target)
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private func timetable(_ tt: Timetable) -> some View {
        let clock = store.clock
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tt.name).fontWeight(.semibold)
                    Text("aktualizováno \(Format.dayLabel(tt.importedAt, now: store.nowMs, clock: clock).lowercased()) \(Format.time(tt.importedAt, clock: clock))")
                        .font(Typo.small).foregroundStyle(Palette.text3)
                }
                Spacer()
                Button { picking = .replace(id: tt.id) } label: { Label("Nahrát novou verzi", systemImage: "arrow.clockwise") }
                    .buttonStyle(.study(.normal, size: .small))
                    .help("Nahraj nový export – změny se ukážou před uložením")
                Button { remove(tt) } label: { Image(systemName: "trash") }
                    .buttonStyle(.study(.ghost, size: .small))
                    .help("Odstranit rozvrh")
                    .accessibilityLabel("Odstranit rozvrh")
            }
            VStack(spacing: 0) {
                let series = Timetables.series(of: tt, now: store.nowMs, clock: clock)
                ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                    ListRow(divider: i < series.count - 1) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.series).lineLimit(1).strikethrough(s.hidden).foregroundStyle(s.hidden ? Palette.text3 : Palette.text)
                            Text("\(s.when) · zbývá \(s.upcoming) z \(s.count)").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { toggle(s.series, in: tt) } label: { Image(systemName: s.hidden ? "eye.slash" : "eye") }
                            .buttonStyle(.study(.ghost, size: .small))
                            .help(s.hidden ? "Zobrazit v kalendáři" : "Skrýt (např. nepovinný předmět)")
                            .accessibilityLabel(s.hidden ? "Zobrazit" : "Skrýt")
                    }
                }
            }
        }
    }

    // MARK: - Akce

    private func load(_ url: URL, replaceId: String?) {
        error = nil
        let clock = store.clock
        Task {
            // Čtení a rozbalení opakování může u velkého exportu chvíli trvat – mimo hlavní vlákno.
            let parsed = await Task.detached(priority: .userInitiated) { Result { try Self.parse(url, clock: clock) } }.value
            switch parsed {
            case .success(let result) where result.events.isEmpty:
                error = "V souboru nejsou žádné hodiny s časem začátku a konce."
            case .success(let result):
                let fileName = url.deletingPathExtension().lastPathComponent
                pending = Pending(result: result, replaceId: replaceId, name: result.name.isEmpty ? (fileName.isEmpty ? "Rozvrh" : fileName) : result.name)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private nonisolated static func parse(_ url: URL, clock: StudyClock) throws -> ICal.Result {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Jako `file.text()` na webu: UTF-8, neplatné bajty jako náhradní znak, bez BOM.
        var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return try ICal.parse(text, clock: clock)
    }

    private func confirm() {
        guard let pending else { return }
        let now = store.nowMs
        if let id = pending.replaceId {
            if let tt = store.document.record(Timetable.self, id: id) {
                store.upsert(Timetables.replacingEvents(tt, with: pending.result.events, now: now))
            }
            toasts.showAfterSheet("Rozvrh aktualizován")
        } else {
            store.upsert(Timetables.new(name: pending.name, events: pending.result.events, now: now))
            toasts.showAfterSheet("Rozvrh importován")
        }
        self.pending = nil
    }

    private func toggle(_ series: String, in tt: Timetable) {
        var t = store.document.record(Timetable.self, id: tt.id) ?? tt
        t.hiddenSeries = t.hiddenSeries.contains(series) ? t.hiddenSeries.filter { $0 != series } : t.hiddenSeries + [series]
        store.upsert(t)
    }

    private func remove(_ tt: Timetable) {
        store.remove(.timetables, id: tt.id)
        toasts.showAfterSheet("Rozvrh odstraněn") { [store] in store.restore(.timetables, id: tt.id) }
    }
}

/// Náhled načteného souboru: kolik termínů a předmětů, a u nové verze co se změní.
private struct PendingImport: View {
    @Binding var pending: TimetableSheet.Pending
    let replacing: Timetable?
    let now: Int
    let clock: StudyClock

    var body: some View {
        let events = pending.result.events
        let seriesCount = Set(events.map(\.series)).count
        VStack(alignment: .leading, spacing: 14) {
            if replacing == nil {
                FormField("Název") {
                    TextField("Název", text: $pending.name).textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityIdentifier("timetable.name")
                }
            }
            (Text("\(events.count)").monospacedDigit() + Text(" \(Format.plural(events.count, "termín", "termíny", "termínů")) · ")
                + Text("\(seriesCount)").monospacedDigit() + Text(" \(Format.plural(seriesCount, "předmět", "předměty", "předmětů")) · \(range(events))")
                + Text(pending.result.skippedAllDay > 0 ? " · vynecháno celodenních akcí: \(pending.result.skippedAllDay)" : "").foregroundStyle(Palette.text3))
                .foregroundStyle(Palette.text2)
                .accessibilityIdentifier("timetable.summary")
            if let replacing {
                let diff = Timetables.diff(old: replacing.events, next: events, now: now)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Změny v budoucích termínech").fontWeight(.semibold)
                    HStack(spacing: 18) {
                        Text("+\(diff.added)").fontWeight(.semibold).monospacedDigit() + Text(" nových")
                        Text("−\(diff.removed)").fontWeight(.semibold).monospacedDigit() + Text(" zrušených")
                        (Text("\(diff.unchanged)").fontWeight(.semibold).monospacedDigit() + Text(" beze změny")).foregroundStyle(Palette.text3)
                    }
                    if !diff.addedSeries.isEmpty { Text("Nově: \(diff.addedSeries.joined(separator: ", "))").font(Typo.small).foregroundStyle(Palette.text2) }
                    if !diff.removedSeries.isEmpty { Text("Už není: \(diff.removedSeries.joined(separator: ", "))").font(Typo.small).foregroundStyle(Palette.text2) }
                    Text("Proběhlé hodiny zůstanou beze změny. Skryté předměty a odpadlé termíny zůstanou skryté.")
                        .font(Typo.small).foregroundStyle(Palette.text3)
                }
                .accessibilityIdentifier("timetable.diff")
            }
        }
    }

    private func range(_ events: [TimetableEvent]) -> String {
        guard let first = events.first, let last = events.last else { return "" }
        return "\(Format.date(first.start, .dayNumericMonth, clock: clock)) – \(Format.date(last.start, .dayNumericMonth, clock: clock))"
    }
}

/// Jedna hodina z rozvrhu (`LectureModal` na webu): odpadá, nebo skrýt celý předmět.
struct LectureSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    let timetableId: String
    let key: String
    let manage: () -> Void

    var body: some View {
        let clock = store.clock
        if let tt = store.document.record(Timetable.self, id: timetableId), let lecture = tt.events.first(where: { $0.key == key }) {
            EditorSheet(lecture.title) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Format.capitalized(Format.dayLabel(lecture.start, now: store.nowMs, clock: clock))) · \(Format.time(lecture.start, clock: clock))–\(Format.time(lecture.end, clock: clock))")
                        .monospacedDigit()
                    if !lecture.location.isEmpty { Text(lecture.location).foregroundStyle(Palette.text2) }
                    Text("\(tt.name) · z rozvrhu, dá se upravit novým importem").foregroundStyle(Palette.text3)
                }
                .font(Typo.small)
            } footer: {
                Button("Spravovat rozvrh", action: manage).buttonStyle(.study(.ghost))
                Spacer()
                Button("Skrýt všechny") {
                    change(tt, message: "Předmět skrytý v kalendáři") { $0.hiddenSeries.append(lecture.series) }
                }
                .buttonStyle(.study(.normal))
                Button("Tento termín odpadá") {
                    change(tt, message: "Termín označen jako odpadlý") { $0.skipped.append(lecture.key) }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("lecture.skip")
            }
        } else {
            EditorSheet("Hodina z rozvrhu") {
                Text("Hodina už v rozvrhu není.").foregroundStyle(Palette.text2)
            } footer: {
                Spacer()
                Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    /// Změna rozvrhu s „Vrátit“, které vrátí skryté řady i odpadlé termíny do původního stavu.
    private func change(_ tt: Timetable, message: String, _ edit: (inout Timetable) -> Void) {
        var t = tt
        edit(&t)
        store.upsert(t)
        let before = (hidden: tt.hiddenSeries, skipped: tt.skipped)
        toasts.showAfterSheet(message) { [store] in
            guard var current = store.document.record(Timetable.self, id: tt.id) else { return }
            current.hiddenSeries = before.hidden
            current.skipped = before.skipped
            store.upsert(current)
        }
        dismiss()
    }
}

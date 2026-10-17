import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import UniformTypeIdentifiers

/// Export plánu do souboru .ics pro Apple Kalendář (`ExportModal` na webu).
struct ExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Kolik týdnů dopředu (`nil` = vše od dneška).
    @State private var weeks: Int? = 4
    @State private var alarm: Int? = 10
    @State private var includeExams = true
    @State private var includeDone = false
    @State private var file: IcsFile?

    var body: some View {
        let now = store.nowMs
        let (blocks, exams) = selection(now: now)
        EditorSheet("Export do Apple Kalendáře", width: 520) {
            Banner("Uloží se soubor .ics. Otevři ho dvojklikem a Kalendář nabídne import – doporučuju samostatný kalendář „Učení“. Opakovaný import aktualizuje stejné události. Aby se plán aktualizoval sám, zapni v Nastavení odebíraný kalendář.",
                   systemImage: "calendar.badge.checkmark")
            FormField("Období") {
                Picker("Období", selection: $weeks) {
                    Text("Příští 4 týdny").tag(Int?.some(4))
                    Text("Příštích 12 týdnů").tag(Int?.some(12))
                    Text("Vše od dneška").tag(Int?.none)
                }
                .labelsHidden().fixedSize()
            }
            FormField("Připomenutí před blokem") { AlarmPicker(minutes: $alarm) }
            Toggle("Zahrnout zkoušky", isOn: $includeExams).toggleStyle(.switch)
            Toggle("Zahrnout hotové bloky", isOn: $includeDone).toggleStyle(.switch)
            Text(summary(blocks: blocks, exams: exams, now: now)).font(Typo.small).foregroundStyle(Palette.text3)
        } footer: {
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            Button("Uložit .ics (\(blocks.count + exams.count))") {
                let ics = IcsExport.build(blocks: blocks, exams: exams, subjects: store.document.records(Subject.self), alarmMin: alarm,
                                          now: now, clock: store.clock)
                file = IcsFile(text: ics)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(blocks.isEmpty && exams.isEmpty)
            .accessibilityIdentifier("export.save")
        }
        .fileExporter(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }), document: file,
                      contentType: IcsFile.type, defaultFilename: "studijni-plan-\(store.clock.dayKey(now)).ics") { result in
            if case .success = result { dismiss() }
        }
    }

    /// Bloky v období (hotové jen na přání) a zkoušky od dneška.
    private func selection(now: Int) -> ([PlanBlock], [Exam]) {
        let clock = store.clock
        let from = clock.startOfDay(now)
        let to = weeks.map { clock.addDays(from, $0 * 7) } ?? .max
        let blocks = store.document.alive(PlanBlock.self).filter { $0.start >= from && $0.start < to && (includeDone || !$0.done) }
        let exams = includeExams ? store.document.alive(Exam.self).filter { clock.parseDayKey($0.date).map { $0 >= from } ?? false } : []
        return (blocks, exams)
    }

    private func summary(blocks: [PlanBlock], exams: [Exam], now: Int) -> String {
        var text = "\(blocks.count) \(Format.plural(blocks.count, "blok", "bloky", "bloků"))"
        if !exams.isEmpty { text += " a \(exams.count) \(Format.plural(exams.count, "zkouška", "zkoušky", "zkoušek"))" }
        if let first = blocks.map(\.start).min() {
            text += ", první \(Format.dayLabel(first, now: now, clock: store.clock).lowercased())"
        }
        return text + "."
    }
}

/// Připomenutí před blokem (bez, 5, 10, 15, 30 minut).
struct AlarmPicker: View {
    @Binding var minutes: Int?

    var body: some View {
        Picker("Připomenutí", selection: $minutes) {
            Text("Bez připomenutí").tag(Int?.none)
            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minut").tag(Int?.some($0)) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Soubor .ics pro uložení (`fileExporter`).
struct IcsFile: FileDocument {
    static let type = UTType(filenameExtension: "ics", conformingTo: .calendarEvent) ?? .calendarEvent
    static let readableContentTypes = [type]

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

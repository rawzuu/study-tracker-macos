import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Nová nebo upravovaná zkouška (`ExamModal` na webu, bez generování bloků opakování).
struct ExamEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ExamDraft
    @State private var confirmDelete = false

    init(draft: ExamDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        EditorSheet(draft.original == nil ? "Nová zkouška" : "Upravit zkoušku", width: 520) {
            HStack(alignment: .top, spacing: 16) {
                FormField("Předmět") { SubjectPicker(selection: $draft.subjectId, identifier: "exam.subject") }
                FormField("Název") {
                    TextField("Zápočtový test, zkouška…", text: $draft.name).textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityIdentifier("exam.name")
                }
            }
            HStack(alignment: .top, spacing: 16) {
                FormField("Datum") {
                    DatePicker("Datum", selection: $draft.day, displayedComponents: .date).labelsHidden()
                        .accessibilityIdentifier("exam.date")
                }
                FormField("Čas (volitelné)") {
                    HStack(spacing: 8) {
                        Toggle("Čas", isOn: $draft.hasTime).labelsHidden().toggleStyle(.checkbox)
                        DatePicker("Čas", selection: $draft.time, displayedComponents: .hourAndMinute).labelsHidden()
                            .disabled(!draft.hasTime)
                    }
                }
            }
            FormField("Poznámka") {
                TextField("Místnost, rozsah látky…", text: $draft.note).textFieldStyle(.roundedBorder).labelsHidden()
            }
        } footer: {
            if draft.original != nil {
                Button("Smazat") { confirmDelete = true }.buttonStyle(.denik(.danger)).accessibilityIdentifier("exam.delete")
            }
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            Button("Uložit", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("exam.save")
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete) {
            Button("Smazat", role: .destructive, action: delete).accessibilityIdentifier("exam.confirmDelete")
        } message: {
            Text(deleteDetail)
        }
    }

    private var deleteQuestion: String { "Smazat zkoušku „\(draft.original?.name ?? "")“?" }

    /// Bloky, které ke zkoušce naplánoval web, se smažou spolu s ní (a spolu se i vrátí).
    private var deleteDetail: String {
        guard let id = draft.original?.id else { return "" }
        let n = store.document.upcomingBlocks(ofExam: id, now: store.nowMs).count
        return switch n {
        case 0: "Zkoušku půjde vrátit."
        case 1: "Smaže se i budoucí blok naplánovaný ke zkoušce."
        default: "Smažou se i budoucí bloky naplánované ke zkoušce (\(n))."
        }
    }

    private func save() {
        guard draft.canSave else { return }
        var d = draft
        if let id = d.original?.id, let current = store.document.record(Exam.self, id: id) { d.original = current }
        store.upsert(d.record(clock: store.clock))
        dismiss()
    }

    private func delete() {
        guard let id = draft.original?.id else { return }
        let now = store.nowMs
        store.update { $0.removeExam(id, now: now) }
        toasts.show("Zkouška smazána") { [store] in store.restore(.exams, id: id) }
        dismiss()
    }
}

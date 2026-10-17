import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Ruční zápis, úprava sezení i zápis z bloku plánu (`SessionModal` na webu).
/// Téma je jen text sezení – opakování na Macu není.
struct SessionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionDraft
    @State private var confirmDelete = false

    init(draft: SessionDraft) {
        _draft = State(initialValue: draft)
    }

    private var title: String {
        draft.original != nil ? "Upravit sezení" : draft.planBlock != nil ? "Zapsat odučený blok" : "Zapsat sezení ručně"
    }

    var body: some View {
        EditorSheet(title) {
            if draft.isNew, draft.planBlock != nil {
                Text("Čas se započítá do přehledu a statistik. Pokud učení trvalo jinak dlouho, uprav minuty.")
                    .font(Typo.small).foregroundStyle(Palette.text2)
            }
            FormField("Předmět") { SubjectPicker(selection: $draft.subjectId, identifier: "session.subject") }
            FormField("Téma") {
                TextField("Téma", text: $draft.topic).textFieldStyle(.roundedBorder).labelsHidden()
                    .accessibilityIdentifier("session.topic")
            }
            HStack(alignment: .top, spacing: 16) {
                FormField("Začátek") {
                    DatePicker("Začátek", selection: $draft.start, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                }
                FormField("Čistý čas (min)") {
                    NumberField(value: $draft.minutes, in: 1...1440, step: 5).accessibilityIdentifier("session.minutes")
                }
            }
            FormField("Soustředění") {
                Picker("Soustředění", selection: $draft.focus) {
                    Text("Nehodnoceno").tag(0)
                    ForEach(1...5, id: \.self) { n in Text("\(n) – \(Format.focusLabels[n])").tag(n) }
                }
                .labelsHidden()
                .fixedSize()
            }
            FormField("Poznámka") { TextArea(text: $draft.note) }
        } footer: {
            if draft.isNew, let block = draft.planBlock {
                Button { checkOnly(block) } label: { Label("Jen odškrtnout", systemImage: "checkmark") }
                    .buttonStyle(.denik(.normal))
                    .accessibilityIdentifier("session.checkOnly")
            }
            if draft.original != nil {
                Button("Smazat") { confirmDelete = true }.buttonStyle(.denik(.danger))
            }
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            Button("Uložit", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("session.save")
        }
        .confirmationDialog("Opravdu smazat toto sezení?", isPresented: $confirmDelete) {
            Button("Smazat", role: .destructive, action: delete)
        }
    }

    private func save() {
        guard draft.canSave else { return }
        var d = draft
        // Úprava vychází z aktuálního záznamu – synchronizace ho mohla mezitím změnit.
        if let id = d.original?.id, let current = store.document.record(Session.self, id: id) { d.original = current }
        let session = d.record(clock: store.clock)
        let now = store.nowMs
        store.update { $0.saveSession(session, isNew: d.isNew, planBlockId: d.planBlock?.id, now: now) }
        dismiss()
    }

    /// „Jen odškrtnout“: blok bude hotový bez zapsaného času.
    private func checkOnly(_ block: PlanBlock) {
        var b = store.document.record(PlanBlock.self, id: block.id) ?? block
        b.done = true
        store.upsert(b)
        dismiss()
    }

    private func delete() {
        guard let id = draft.original?.id else { return }
        store.remove(.sessions, id: id)
        toasts.show("Sezení smazáno") { [store] in store.restore(.sessions, id: id) }
        dismiss()
    }
}

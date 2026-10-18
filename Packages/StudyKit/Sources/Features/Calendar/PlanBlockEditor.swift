import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Nový nebo upravovaný blok plánu (`BlockModal` na webu): spuštění časovače, Hotovo a smazání.
struct PlanBlockEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlanBlockDraft
    /// „Hotovo“ u bloku bez zapsaného času → okno přejde na zápis odučeného.
    @State private var logging: SessionDraft?
    let openTimer: () -> Void

    init(draft: PlanBlockDraft, openTimer: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.openTimer = openTimer
    }

    var body: some View {
        if let logging {
            SessionEditor(draft: logging)
        } else {
            form
        }
    }

    private var form: some View {
        EditorSheet(draft.original == nil ? "Nový blok učení" : "Upravit blok") {
            FormField("Předmět") { SubjectPicker(selection: $draft.subjectId, identifier: "block.subject") }
            FormField("Co budeš dělat") {
                TextField("např. Procvičit integrály, kap. 5", text: $draft.title).textFieldStyle(.roundedBorder).labelsHidden()
                    .accessibilityIdentifier("block.title")
            }
            HStack(alignment: .top, spacing: 16) {
                FormField("Datum") {
                    DatePicker("Datum", selection: $draft.start, displayedComponents: .date).labelsHidden()
                }
                FormField("Začátek") {
                    DatePicker("Začátek", selection: $draft.start, displayedComponents: .hourAndMinute).labelsHidden()
                        .accessibilityIdentifier("block.time")
                }
                FormField("Délka (min)") {
                    NumberField(value: $draft.durationMin, in: 5...720, step: 5).accessibilityIdentifier("block.duration")
                }
            }
            if draft.original == nil {
                FormField("Opakovat každý týden", hint: "Vytvoří stejný blok i v dalších týdnech.") {
                    Picker("Opakovat", selection: $draft.repeatWeeks) {
                        ForEach(PlanBlockDraft.repeatChoices, id: \.self) { n in Text(n == 1 ? "Neopakovat" : "\(n) týdnů").tag(n) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            FormField("Poznámka") { TextArea(text: $draft.note) }
        } footer: {
            if let block = current {
                Button("Smazat") { delete(block) }.buttonStyle(.denik(.danger))
            }
            Spacer()
            if let block = current {
                if !block.done && timer.state.canSwitch {
                    Button { start(block) } label: { Label("Spustit", systemImage: "play.fill") }
                        .buttonStyle(.denik(.normal))
                        .accessibilityIdentifier("block.start")
                }
                Button { toggleDone(block) } label: { Label(block.done ? "Nehotovo" : "Hotovo", systemImage: "checkmark") }
                    .buttonStyle(.denik(.normal))
                    .accessibilityIdentifier("block.done")
            } else {
                Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            }
            Button("Uložit", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("block.save")
        }
    }

    /// Upravovaný blok, jak je teď v datech (synchronizace ho mohla mezitím změnit).
    private var current: PlanBlock? {
        draft.original.map { store.document.record(PlanBlock.self, id: $0.id) ?? $0 }
    }

    private func save() {
        guard draft.canSave else { return }
        var d = draft
        d.original = current
        let blocks = d.records(clock: store.clock)
        store.upsert(blocks)
        if blocks.count > 1 { toasts.showAfterSheet("Přidáno \(blocks.count) bloků") }
        dismiss()
    }

    private func start(_ block: PlanBlock) {
        timer.setup(TimerSetup(subjectId: block.subjectId, topic: blockTopics(block.title).first ?? "", planBlockId: block.id))
        openTimer()
        dismiss()
    }

    /// Hotovo bez zapsaného času nabídne zápis, aby se blok započítal do přehledu
    /// (jde vypnout v Nastavení → Funkce, `blockDoneLogs`).
    private func toggleDone(_ block: PlanBlock) {
        let doc = store.document
        if !block.done && doc.settings.blockDoneLogs && !PlanMatch.hasSession(doc.records(Session.self), for: block) {
            logging = SessionDraft(fromBlock: block, now: store.nowMs, clock: store.clock)
            return
        }
        var b = block
        b.done.toggle()
        store.upsert(b)
        dismiss()
    }

    private func delete(_ block: PlanBlock) {
        store.remove(.planBlocks, id: block.id)
        toasts.showAfterSheet("Blok smazán") { [store] in store.restore(.planBlocks, id: block.id) }
        dismiss()
    }
}

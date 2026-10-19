import AppModel
import Core
import DesignSystem
import SwiftUI

/// Výběr předmětu s tlačítkem pro nový předmět (`SubjectSelect` na webu). Archivované předměty
/// se nenabízejí – kromě právě vybraného.
struct SubjectPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String
    var identifier = "subject.picker"
    @State private var newSubject: SubjectDraft?

    var body: some View {
        let subjects = store.document.alive(Subject.self).filter { !$0.archived || $0.id == selection }
        HStack(spacing: 8) {
            Picker("Předmět", selection: $selection) {
                Text("Vyber předmět…").tag("")
                ForEach(subjects) { s in Text(s.name).tag(s.id) }
            }
            .labelsHidden()
            .accessibilityIdentifier(identifier)
            Button { newSubject = SubjectDraft(newIn: store.document) } label: { Image(systemName: "plus") }
                .buttonStyle(.study(.normal, size: .small))
                .help("Nový předmět")
                .accessibilityLabel("Nový předmět")
        }
        .sheet(item: $newSubject) { draft in
            SubjectEditor(draft: draft) { selection = $0 }
        }
    }
}

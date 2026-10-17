import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Okno po bloku (`AfterBlockModal` na webu): co si pamatuješ, soustředění a poznámka.
/// Bez hodnocení vybavení tématu – opakování na Macu není.
public struct AfterBlockSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let sessionId: String
    @State private var focus: Int?
    @State private var recall = ""
    @State private var note = ""

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    private var dirty: Bool {
        focus != nil || !recall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        let settings = store.document.settings
        let session = store.document.record(Session.self, id: sessionId)
        VStack(alignment: .leading, spacing: 18) {
            Text("Blok dokončen").font(Typo.sectionTitle)
            if let session {
                let subject = store.document.record(Subject.self, id: session.subjectId)
                HStack {
                    SubjectTag(name: subject?.name ?? "Smazaný předmět", color: subject?.color ?? "#837d73")
                    if !session.topic.isEmpty { Text("· \(session.topic)").foregroundStyle(Palette.text3) }
                    Spacer()
                    Text(Format.duration(session.durationSec)).monospacedDigit().foregroundStyle(Palette.text2)
                }
                .font(Typo.small)
            }
            if settings.askRecall {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Co si pamatuješ? Bez koukání do materiálů.").fontWeight(.semibold)
                    TextArea("Napiš 2–3 hlavní myšlenky vlastními slovy…", text: $recall, minHeight: 92)
                        .accessibilityIdentifier("rating.recall")
                }
            }
            if settings.askFocusRating {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOUSTŘEDĚNÍ").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Palette.text3)
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { n in
                            Button { focus = n } label: {
                                VStack(spacing: 3) {
                                    Text("\(n)").font(Typo.serifNumber(18))
                                    Text(Format.focusLabels[n]).font(.system(size: 10.5)).foregroundStyle(Palette.text2).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(focus == n ? Palette.panel3 : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == n ? Palette.text2 : Palette.line))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("rating.focus.\(n)")
                            .accessibilityAddTraits(focus == n ? .isSelected : [])
                        }
                    }
                }
            }
            TextField("Poznámka (volitelné)", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rating.note")
            HStack {
                Spacer()
                Button("Přeskočit") { timer.skipRating() }
                    .buttonStyle(.denik(.ghost))
                    .accessibilityIdentifier("rating.skip")
                Button("Uložit") { save() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty)
                    .accessibilityIdentifier("rating.save")
            }
        }
        .padding(24)
        .frame(width: 520)
        // Esc nesmí zahodit rozepsaný text – uloží se. Zahodit jde jen tlačítkem Přeskočit.
        .onExitCommand { dirty ? save() : timer.skipRating() }
        .interactiveDismissDisabled()
    }

    private func save() {
        timer.saveRating(focus: focus, recall: recall, note: note)
    }
}

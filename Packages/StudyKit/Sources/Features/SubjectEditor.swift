import AppKit
import AppModel
import Core
import DesignSystem
import SwiftUI
import Sync

/// Rozpracovaný předmět v editoru – stejná pravidla jako `SubjectModal` na webu.
public struct SubjectDraft: Equatable, Sendable {
    /// Paleta barev předmětů (`SUBJECT_COLORS` na webu).
    public static let palette = ["#7d9cc0", "#8fae8b", "#d4a35a", "#c98b8b", "#a495c2", "#6fb0a8", "#d08a64", "#b4a46a", "#c79bb8", "#9aa3ad"]

    public var original: Subject?
    public var name: String
    public var color: String
    /// Týdenní cíl v hodinách (0 = bez cíle).
    public var goalHours: Double

    /// Nový předmět: první barva z palety, kterou zatím žádný předmět nemá.
    public init(newIn doc: AppDocument) {
        let used = Set(doc.alive(Subject.self).map(\.color))
        original = nil
        name = ""
        color = Self.palette.first { !used.contains($0) } ?? Self.palette[0]
        goalHours = 0
    }

    public init(editing subject: Subject) {
        original = subject
        name = subject.name
        color = subject.color
        goalHours = Double(subject.weeklyGoalMin) / 60
    }

    /// Předmět se stejným názvem už existuje – druhý by rozdělil statistiky na dvě půlky.
    public func duplicate(in doc: AppDocument) -> Subject? {
        let key = Self.key(name)
        return doc.alive(Subject.self).first { $0.id != original?.id && Self.key($0.name) == key }
    }

    public func canSave(in doc: AppDocument) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && duplicate(in: doc) == nil
    }

    /// Záznam k uložení: úprava zachová ostatní pole, nový má pořadí klíčů jako na webu.
    public func record() -> Subject {
        var s = original ?? Subject(raw: ["id": .string(Subject.newID()), "archived": false])
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.color = color
        s.weeklyGoalMin = Int((max(0, goalHours) * 60).rounded(.toNearestOrAwayFromZero))
        return s
    }

    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "cs_CZ"))
    }
}

/// Okno pro nový nebo upravovaný předmět.
struct SubjectEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubjectDraft

    var body: some View {
        let duplicate = draft.duplicate(in: store.document)
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.original == nil ? "Nový předmět" : "Upravit předmět").font(Typo.sectionTitle)
            VStack(alignment: .leading, spacing: 6) {
                Text("Název").foregroundStyle(Palette.text2)
                TextField("Název", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("subject.name")
                    .onSubmit(save)
                if let duplicate {
                    Text("Předmět „\(duplicate.name)“ už existuje\(duplicate.archived ? " (v archivu)" : "").")
                        .font(Typo.small).foregroundStyle(Palette.danger)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Barva").foregroundStyle(Palette.text2)
                HStack(spacing: 8) {
                    ForEach(SubjectDraft.palette, id: \.self) { hex in
                        Button { draft.color = hex } label: {
                            RoundedRectangle(cornerRadius: 9).fill(Palette.subject(hex)).frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(draft.color == hex ? Palette.text : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex)
                    }
                    ColorPicker("Vlastní barva", selection: Binding(
                        get: { Palette.subject(draft.color) },
                        set: { draft.color = NSColor($0).hexString ?? draft.color }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Vlastní barva")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Týdenní cíl (hodiny)").foregroundStyle(Palette.text2)
                HStack {
                    TextField("Týdenní cíl", value: $draft.goalHours, format: .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "cs_CZ")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .labelsHidden()
                        .accessibilityIdentifier("subject.goal")
                    Stepper("", value: $draft.goalHours, in: 0...100, step: 0.5).labelsHidden()
                }
                Text("0 = bez cíle. Zobrazí se na přehledu.").font(Typo.small).foregroundStyle(Palette.text3)
            }
            HStack {
                Spacer()
                Button("Zrušit", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uložit", action: save)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave(in: store.document))
                    .accessibilityIdentifier("subject.save")
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        guard draft.canSave(in: store.document) else { return }
        store.upsert(draft.record())
        dismiss()
    }
}

extension NSColor {
    /// `#rrggbb` malými písmeny (jako `<input type="color">` na webu).
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> String {
            let n = Int((min(1, max(0, v)) * 255).rounded())
            return String(format: "%02x", n)
        }
        return "#" + byte(c.redComponent) + byte(c.greenComponent) + byte(c.blueComponent)
    }
}

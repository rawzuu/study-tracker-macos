import Core
import Testing
@testable import Features

@Suite("Úprava předmětu")
struct SubjectDraftTests {
    private func doc() -> AppDocument {
        var d = AppDocument.empty
        d.upsert([
            Subject(raw: ["id": "a", "name": "Čeština", "color": "#7d9cc0", "weeklyGoalMin": 60, "zBudoucnosti": 1]),
            Subject(raw: ["id": "b", "name": "Biologie", "color": "#8fae8b", "archived": true]),
        ], now: 1)
        return d
    }

    @Test("Nový předmět dostane první volnou barvu a klíče v pořadí jako na webu")
    func newSubject() {
        var draft = SubjectDraft(newIn: doc())
        #expect(draft.color == "#d4a35a")
        draft.name = "  Anatomie "
        draft.goalHours = 1.5
        let s = draft.record()
        #expect(Array(s.raw.keys) == ["id", "archived", "name", "color", "weeklyGoalMin"])
        #expect(s.name == "Anatomie" && s.weeklyGoalMin == 90 && !s.archived)
        #expect(s.id.count == 36)
    }

    @Test("Stejný název nejde (bez ohledu na velikost písmen, i v archivu)")
    func duplicates() {
        var draft = SubjectDraft(newIn: doc())
        draft.name = "ČEŠTINA "
        #expect(draft.duplicate(in: doc())?.id == "a")
        #expect(!draft.canSave(in: doc()))
        draft.name = "biologie"
        #expect(draft.duplicate(in: doc())?.archived == true)
        draft.name = ""
        #expect(!draft.canSave(in: doc()))
        // Úprava vlastního názvu není duplicita.
        var edit = SubjectDraft(editing: doc().record(Subject.self, id: "a")!)
        edit.name = "čeština"
        #expect(edit.canSave(in: doc()))
    }

    @Test("Úprava zachová ostatní pole")
    func editKeepsFields() {
        var draft = SubjectDraft(editing: doc().record(Subject.self, id: "a")!)
        #expect(draft.goalHours == 1)
        draft.color = "#c98b8b"
        let s = draft.record()
        #expect(s.raw["zBudoucnosti"] == 1)
        #expect(s.color == "#c98b8b" && s.weeklyGoalMin == 60 && s.id == "a")
    }
}

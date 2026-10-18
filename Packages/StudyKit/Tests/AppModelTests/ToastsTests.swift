import Testing
@testable import AppModel

@MainActor
@Suite("Hlášky")
struct ToastsTests {
    @Test("Vrátit provede akci a hlášku zavře; starší hlášku nezavře odpočet novější")
    func undo() {
        let toasts = Toasts()
        var undone = false
        toasts.show("Blok smazán") { undone = true }
        let first = toasts.current!.id
        toasts.undo()
        #expect(undone && toasts.current == nil)
        toasts.show("A")
        toasts.show("B")
        toasts.dismiss(first)
        #expect(toasts.current?.text == "B")
    }

    @Test("Hláška z okna formuláře se ukáže až po jeho zavření")
    func afterSheet() {
        let toasts = Toasts()
        toasts.showAfterSheet("Zkouška smazána") {}
        #expect(toasts.current == nil)
        toasts.presentAfterSheet()
        #expect(toasts.current?.text == "Zkouška smazána" && toasts.current?.undo != nil)
        toasts.presentAfterSheet()
        #expect(toasts.current?.text == "Zkouška smazána") // čekající hláška se ukáže jen jednou
    }
}

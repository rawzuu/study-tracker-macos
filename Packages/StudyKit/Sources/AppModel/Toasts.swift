import Foundation
import Observation

/// Krátká hláška dole v okně, případně s tlačítkem „Vrátit“ (`useToast` na webu). Vždy jen jedna –
/// nová nahradí předchozí.
@MainActor
@Observable
public final class Toasts {
    public struct Toast: Identifiable {
        public let id = UUID()
        public let text: String
        /// Vrátí akci, o které hláška informuje (`nil` = hláška bez tlačítka).
        public let undo: (@MainActor () -> Void)?
    }

    public private(set) var current: Toast?
    /// Hláška z otevřeného okna formuláře, která čeká na jeho zavření.
    @ObservationIgnored private var afterSheet: Toast?

    public init() {}

    public func show(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        current = Toast(text: text, undo: undo)
    }

    /// Hláška z okna formuláře (sheet) – ukáže se až po jeho zavření (`presentAfterSheet()` v `onDismiss`),
    /// kdy už jde na „Vrátit“ kliknout.
    public func showAfterSheet(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        afterSheet = Toast(text: text, undo: undo)
    }

    /// Okno formuláře se zavřelo – ukázat hlášku, která na to čekala.
    public func presentAfterSheet() {
        guard let toast = afterSheet else { return }
        afterSheet = nil
        current = toast
    }

    /// „Vrátit“: vrátí akci a hlášku zavře.
    public func undo() {
        let undo = current?.undo
        current = nil
        undo?()
    }

    /// Zavře hlášku `id` – pokud ji mezitím nenahradila novější.
    public func dismiss(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}

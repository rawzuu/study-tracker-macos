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

    public init() {}

    public func show(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        current = Toast(text: text, undo: undo)
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

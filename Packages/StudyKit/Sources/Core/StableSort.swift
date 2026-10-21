import Foundation

extension Array {
    /// Stabilní řazení jako `Array.prototype.sort` v JS: při shodě zůstává původní pořadí.
    /// Bez ternárních výrazů v porovnání – starší kompilátor v CI je jinak nestihne typově zkontrolovat.
    public func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        var indexed: [(offset: Int, element: Element)] = enumerated().map { ($0.offset, $0.element) }
        indexed.sort { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }
        return indexed.map(\.element)
    }
}

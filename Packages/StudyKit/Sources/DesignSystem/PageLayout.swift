import SwiftUI

/// Jak široká je stránka (oblast vedle postranního panelu): podle toho se mění počet sloupců a okraje.
/// Okno na notebooku (~1200–1500 bodů) je `regular`, okno přes celý monitor 2560 × 1440 `wide`.
public struct PageMetrics: Sendable, Equatable {
    public enum Size: Int, Sendable, Comparable {
        case compact, regular, wide

        public static func < (a: Size, b: Size) -> Bool { a.rawValue < b.rawValue }
    }

    public let width: CGFloat
    public let size: Size

    public init(width: CGFloat) {
        self.width = width
        size = width >= 1900 ? .wide : width >= 1100 ? .regular : .compact
    }

    /// Vodorovný okraj stránky – na velkém monitoru o něco větší, ať obsah nelepí na hrany.
    public var padding: CGFloat {
        switch size {
        case .compact: 32
        case .regular: 48
        case .wide: 64
        }
    }

    /// Šířka obsahu bez okrajů.
    public var contentWidth: CGFloat { max(0, width - 2 * padding) }

    /// Kolik sloupců karet se vejde (přehled, nastavení).
    public var columns: Int {
        switch size {
        case .compact: 1
        case .regular: 2
        case .wide: 3
        }
    }
}

/// Části stránky ve sloupcích popořadě: první do prvního sloupce, druhá do druhého… a po posledním sloupci
/// zase do prvního. Každý sloupec skládá své části těsně pod sebe, takže krátká karta nenechá díru vedle
/// vysoké (jako sloupce novin). Pořadí je pevné – části mezi sloupci neskáčou, když se změní jejich obsah.
public struct ColumnsLayout: Layout {
    let columns: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat

    public init(columns: Int, spacing: CGFloat = 56, rowSpacing: CGFloat = 40) {
        self.columns = max(1, columns)
        self.spacing = spacing
        self.rowSpacing = rowSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (index, frame) in arranged.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return widest * CGFloat(columns) + spacing * CGFloat(columns - 1)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var tops = Array(repeating: CGFloat(0), count: columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var slot = 0
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            // Prázdná část (podmínka bez obsahu) nezabere místo ani mezeru.
            guard height > 0 else {
                frames.append(.zero)
                continue
            }
            let column = slot % columns
            slot += 1
            let y = tops[column] == 0 ? 0 : tops[column] + rowSpacing
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            tops[column] = y + height
        }
        return (frames, tops.max() ?? 0)
    }
}

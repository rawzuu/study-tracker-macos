import AppKit
import SwiftUI

/// Pohyb v aplikaci: krátký, plynulý a bez zákmitu – jen tam, kde pomáhá pochopit změnu
/// (stisk, zaškrtnutí, nový obsah). S „Omezit pohyb“ v Zpřístupnění se vše mění okamžitě.
public enum Motion {
    /// Hover, stisk, zaškrtnutí.
    public static let quick = Animation.smooth(duration: 0.16)
    /// Změna obsahu: stránka, rozbalení, přibývající řádek.
    public static let standard = Animation.smooth(duration: 0.24)
    /// Stisk tlačítka – pružina bez odrazu.
    public static let press = Animation.spring(duration: 0.2, bounce: 0)

    /// Nový obsah se jen jemně objeví (mírný posun nahoru a průhlednost).
    public static var appear: AnyTransition { .opacity.combined(with: .offset(y: 4)) }

    @MainActor public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// `withAnimation`, které respektuje „Omezit pohyb“.
@MainActor
public func withMotion<Result>(_ animation: Animation = Motion.standard, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.reduced ? nil : animation, body)
}

extension View {
    /// `.animation(_:value:)`, které respektuje „Omezit pohyb“.
    public func motion(_ animation: Animation, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduce ? nil : animation, value: value)
    }
}

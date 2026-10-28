import AppKit
import DesignSystem
import SwiftUI

/// Blokovací obrazovka přes celou obrazovku: klidná, tmavá, co je zablokované a kolikátý je to dnes pokus.
@MainActor
public final class ShieldWindow: ShieldControl {
    private var window: NSWindow?
    private let model = ShieldModel()
    /// „Zpět k učení“ – otevře Study Tracker.
    private let backToStudy: @MainActor () -> Void

    public init(backToStudy: @escaping @MainActor () -> Void) {
        self.backToStudy = backToStudy
    }

    public var isShown: Bool { window?.isVisible ?? false }

    public func show(_ info: ShieldInfo) {
        model.info = info
        let window = self.window ?? makeWindow()
        self.window = window
        if let screen = NSScreen.main ?? NSScreen.screens.first { window.setFrame(screen.frame, display: true) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = ShieldPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.onEscape = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: ShieldView(model: model, close: { [weak self] in self?.close() },
                                                                back: { [weak self] in
                                                                    self?.close()
                                                                    self?.backToStudy()
                                                                }))
        return window
    }
}

/// Okno bez rámečku, které přijímá klávesnici (Esc zavře).
private final class ShieldPanel: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor @Observable
final class ShieldModel {
    var info = ShieldInfo(name: "", isSite: false, lists: [], attempt: 1, until: nil, locked: false)
}

struct ShieldView: View {
    let model: ShieldModel
    let close: () -> Void
    let back: () -> Void

    var body: some View {
        let info = model.info
        ZStack {
            Palette.bg.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: info.isSite ? "globe" : "app.dashed")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Palette.text3)
                VStack(spacing: 6) {
                    Text("\(info.name) je teď zablokovan\(info.isSite ? "ý" : "á")")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.center)
                    Text(detail(info))
                        .font(Typo.body)
                        .foregroundStyle(Palette.text2)
                        .multilineTextAlignment(.center)
                }
                Text("Dnes už \(info.attempt). pokus")
                    .font(Typo.number(15))
                    .foregroundStyle(info.attempt >= 5 ? Palette.danger : Palette.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.panel2, in: Capsule())
                HStack(spacing: 10) {
                    Button("Zavřít", action: close)
                        .buttonStyle(.study(.ghost))
                        .keyboardShortcut(.cancelAction)
                    Button("Zpět k učení", action: back)
                        .buttonStyle(.study(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 520)
            .padding(40)
        }
        .preferredColorScheme(.dark)
    }

    private func detail(_ info: ShieldInfo) -> String {
        var parts = [info.lists.joined(separator: ", ")].filter { !$0.isEmpty }
        if let until = info.until {
            let f = DateFormatter()
            f.locale = Locale(identifier: "cs_CZ")
            f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: Double(until) / 1000)) ? "H:mm" : "d. M. H:mm"
            parts.append("do \(f.string(from: Date(timeIntervalSince1970: Double(until) / 1000)))")
        } else {
            parts.append("do konce bloku")
        }
        if info.locked { parts.append("přísný zámek – do konce nejde zrušit") }
        return parts.joined(separator: " · ")
    }
}

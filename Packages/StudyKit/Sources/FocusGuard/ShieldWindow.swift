import AppKit
import DesignSystem
import Focus
import SwiftUI

/// Blokovací obrazovka přes celou obrazovku: velký odpočet do konce bloku, co je zablokované, kolikátý
/// je to dnes pokus, krátká věta k učení a odemykání podle přísnosti seznamu.
@MainActor
public final class ShieldWindow: ShieldControl {
    private var window: NSWindow?
    /// Tmavé pozadí na dalších monitorech (blokovací obrazovka je na hlavním).
    private var covers: [NSWindow] = []
    private let model = ShieldModel()
    public weak var actions: (any ShieldActions)?
    /// „Zpět k učení“ – otevře Study Tracker.
    private let backToStudy: @MainActor () -> Void

    public init(backToStudy: @escaping @MainActor () -> Void) {
        self.backToStudy = backToStudy
    }

    public var isShown: Bool { window?.isVisible ?? false }

    public func show(_ info: ShieldInfo) {
        let fresh = !isShown || model.info.name != info.name
        model.info = info
        if fresh {
            model.typed = ""
            model.password = ""
        }
        let window = self.window ?? makeWindow()
        self.window = window
        let main = NSScreen.main ?? NSScreen.screens.first
        if let main { window.setFrame(main.frame, display: true) }
        // Zmrazení zakryje i další monitory; běžné blokování jen hlavní (na ostatních jde dál pracovat).
        if info.frozenApps != nil { coverOtherScreens(except: main) } else { for cover in covers { cover.orderOut(nil) } }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func close() {
        window?.orderOut(nil)
        for cover in covers { cover.orderOut(nil) }
    }

    private func coverOtherScreens(except main: NSScreen?) {
        let others = NSScreen.screens.filter { $0 != main }
        while covers.count < others.count {
            let cover = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.level = .floating
            cover.isReleasedWhenClosed = false
            cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            cover.appearance = NSAppearance(named: .darkAqua)
            cover.backgroundColor = NSColor(Palette.bg)
            covers.append(cover)
        }
        for (cover, screen) in zip(covers, others) {
            cover.setFrame(screen.frame, display: true)
            cover.orderFront(nil)
        }
        for cover in covers.dropFirst(others.count) { cover.orderOut(nil) }
    }

    private func makeWindow() -> NSWindow {
        let window = ShieldPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Vždy tmavá (barvy Palette se řídí vzhledem okna, ne jen prostředím SwiftUI).
        window.appearance = NSAppearance(named: .darkAqua)
        // Zmrazení Esc nezavře – ven vede jen povolená aplikace, Study Tracker nebo odemknutí.
        window.onEscape = { [weak self] in if self?.model.info.frozenApps == nil { self?.close() } }
        let view = ShieldView(model: model, actions: ShieldView.Actions(
            close: { [weak self] in self?.close() },
            back: { [weak self] in
                self?.close()
                self?.backToStudy()
            },
            unlock: { [weak self] in self?.actions?.shieldRequestUnlock() },
            typed: { [weak self] in self?.actions?.shieldSubmit(typed: $0) },
            password: { [weak self] in self?.actions?.shieldSubmit(password: $0) },
            open: { [weak self] in self?.actions?.shieldOpen(bundleId: $0) }))
        window.contentView = NSHostingView(rootView: view)
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
    var typed = ""
    var password = ""
    var showsUnlock = false
}

extension ShieldView {
    /// Při zmrazení: co zůstalo povolené – jedním kliknutím otevřít.
    func allowedApps(_ apps: [FocusApp]) -> some View {
        VStack(spacing: 8) {
            Text(apps.isEmpty ? "Povolený je jen Study Tracker." : "Povolené zůstaly:").font(Typo.small).foregroundStyle(Palette.text3)
            HStack(spacing: 8) {
                ForEach(apps.prefix(6), id: \.bundleId) { app in
                    Button(app.name) { actions.open(app.bundleId) }.buttonStyle(.study(.normal, size: .small))
                }
            }
        }
    }
}

struct ShieldView: View {
    struct Actions {
        var close: () -> Void
        var back: () -> Void
        var unlock: () -> Void
        var typed: (String) -> Void
        var password: (String) -> Void
        var open: (String) -> Void = { _ in }
    }

    @Bindable var model: ShieldModel
    let actions: Actions

    var body: some View {
        let info = model.info
        ZStack {
            Palette.bg.opacity(0.985).ignoresSafeArea()
            VStack(spacing: 0) {
                Text("Study Tracker · Soustředění")
                    .font(Typo.small).foregroundStyle(Palette.text3)
                    .padding(.top, 40)
                Spacer(minLength: 24)
                VStack(spacing: 22) {
                    countdown(info)
                    VStack(spacing: 8) {
                        Text(info.frozenApps == nil ? "Zablokováno" : "Mac je zmrazený").font(Typo.body).foregroundStyle(Palette.text3)
                        Text(info.name)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Palette.text)
                        Text(ShieldText.detail(info))
                            .font(Typo.body).foregroundStyle(Palette.text2)
                    }
                    .multilineTextAlignment(.center)
                    if let apps = info.frozenApps { allowedApps(apps) }
                    Text("Dnes už \(info.attempt). pokus")
                        .font(Typo.number(14))
                        .foregroundStyle(info.attempt >= 5 ? Palette.danger : Palette.text2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Palette.panel2, in: Capsule())
                    Text(ShieldText.quote(info))
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    HStack(spacing: 10) {
                        if info.frozenApps == nil {
                            Button("Zavřít", action: actions.close)
                                .buttonStyle(.study(.ghost))
                                .keyboardShortcut(.cancelAction)
                        }
                        Button("Zpět k učení", action: actions.back)
                            .buttonStyle(.study(.primary))
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 640)
                Spacer(minLength: 24)
                unlockArea(info)
                    .frame(maxWidth: 560)
                    .padding(.bottom, 48)
            }
            .padding(.horizontal, 40)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Velký odpočet do konce bloku (bez známého konce: „do konce bloku“).
    @ViewBuilder
    private func countdown(_ info: ShieldInfo) -> some View {
        if let until = info.until {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, until - Int(context.date.timeIntervalSince1970 * 1000))
                VStack(spacing: 4) {
                    Text(ShieldText.clock(left))
                        .font(.system(size: 88, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                    Text("zbývá do konce").font(Typo.small).foregroundStyle(Palette.text3)
                }
            }
        } else {
            Image(systemName: info.isSite ? "globe" : "app.dashed")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.text3)
        }
    }

    // MARK: - Odemykání

    @ViewBuilder
    private func unlockArea(_ info: ShieldInfo) -> some View {
        VStack(spacing: 10) {
            switch info.unlock {
            case let .unavailable(reason):
                if !reason.isEmpty { note(reason, icon: "lock") }
            case let .request(summary):
                Button("Odemknout…", action: actions.unlock).buttonStyle(.study(.ghost, size: .small))
                Text(summary).font(Typo.small).foregroundStyle(Palette.text3).multilineTextAlignment(.center)
            case .restart:
                note("Žádost platí – odemknout půjde po restartu Macu.", icon: "arrow.clockwise")
            case let .wait(until):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = until - Int(context.date.timeIntervalSince1970 * 1000)
                    if left > 0 {
                        note("Odemknout půjde za \(ShieldText.clock(left)). Mezitím se můžeš vrátit k učení.", icon: "hourglass")
                    } else {
                        Button("Pokračovat v odemykání", action: actions.unlock).buttonStyle(.study(.normal, size: .small))
                    }
                }
            case let .type(text):
                Text("Opiš text (vložení nefunguje):").font(Typo.small).foregroundStyle(Palette.text2)
                Text(text)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.disabled)
                HStack(spacing: 8) {
                    TextField("Opiš text", text: $model.typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .monospaced))
                        .autocorrectionDisabled()
                        .onChange(of: model.typed) { old, new in
                            // Ručně, ne vložením: najednou nejvýš pár znaků.
                            if new.count - old.count > 2 { model.typed = old }
                        }
                        .onSubmit { actions.typed(model.typed) }
                    Button("Odemknout") { actions.typed(model.typed) }.buttonStyle(.study(.normal, size: .small))
                }
            case .password:
                HStack(spacing: 8) {
                    SecureField("Heslo", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { actions.password(model.password) }
                    Button("Odemknout") { actions.password(model.password) }.buttonStyle(.study(.normal, size: .small))
                }
                Text("Heslo zná ten, komu jsi ho svěřil.").font(Typo.small).foregroundStyle(Palette.text3)
            case .ready:
                EmptyView()
            }
            if let error = info.error {
                Text(error).font(Typo.small).foregroundStyle(Palette.danger)
            }
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(Typo.small).foregroundStyle(Palette.text3).multilineTextAlignment(.center)
    }
}

enum ShieldText {
    /// „1:23:45“ / „23:45“
    static func clock(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(pad(m)):\(pad(sec))" : "\(m):\(pad(sec))"
    }

    static func detail(_ info: ShieldInfo) -> String {
        var parts = [info.lists.joined(separator: ", ")].filter { !$0.isEmpty }
        if let until = info.until {
            parts.append(FocusFormat.until(until))
        } else {
            parts.append("do konce bloku")
        }
        if info.locked { parts.append("přísný zámek") }
        return parts.joined(separator: " · ")
    }

    static let quotes = [
        "Za deset minut ti tohle chybět nebude. Učení ano.",
        "Rozptýlení počká. Zkouška ne.",
        "Teď je čas na učení. Na tohle dojde potom – bez výčitek.",
        "Každý odolaný pokus je malá výhra.",
        "Soustředění je dovednost. Právě ji trénuješ.",
        "Dokonči blok. Pak si to užiješ.",
        "Malý krok teď ušetří velký stres před zkouškou.",
        "Mozek chce odměnu hned. Ty víš, co chceš doopravdy.",
    ]

    /// Věta podle pokusu – při dalším pokusu jiná.
    static func quote(_ info: ShieldInfo) -> String {
        quotes[(info.attempt + info.name.count) % quotes.count]
    }
}

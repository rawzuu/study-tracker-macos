import AppKit
import AppModel
import DesignSystem
import SwiftUI

// Nastavení jen pro tento Mac (web je nemá): automatická pauza, zkratky při bloku, klávesové zkratky
// a pondělní souhrn. Ukládá se do UserDefaults, nesynchronizuje se.

struct AwaySettings: View {
    @Environment(MacPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        PageSection("Automatická pauza") {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("Pozastavit po nečinnosti",
                           detail: "Když na Mac nesáhneš, blok se pozastaví k poslední aktivitě. Učíš se z knihy? Nastav delší dobu – po návratu jde čas jedním kliknutím započítat.") {
                    Picker("Pozastavit po nečinnosti", selection: $prefs.awayMinutes) {
                        ForEach(MacPreferences.awayChoices, id: \.self) { Text($0 == 0 ? "nikdy" : "po \($0) min").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.away")
                }
                SettingSwitch("Při zamčení nebo uspání Macu hned", detail: "Zamčená obrazovka (⌃⌘Q) nebo uspání blok pozastaví okamžitě.",
                              isOn: $prefs.awayOnLock)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

struct BlockShortcutSettings: View {
    @Environment(MacPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        PageSection("Zkratky při bloku") {
            VStack(alignment: .leading, spacing: 14) {
                SettingSwitch("Spouštět zkratky na začátku a konci bloku",
                              detail: "Třeba zapnout Nerušit, pustit hudbu nebo zavřít chat. Pozastavení bloku zkratku nespustí.",
                              isOn: $prefs.shortcutsEnabled, id: "settings.shortcuts")
                if prefs.shortcutsEnabled {
                    shortcutField("Na začátku bloku", text: $prefs.startShortcut, prompt: "Nerušit zapnout")
                    shortcutField("Na konci bloku", text: $prefs.endShortcut, prompt: "Nerušit vypnout")
                    HStack(spacing: 8) {
                        Button { BlockAutomation.openShortcutsApp() } label: { Label("Otevřít Zkratky", systemImage: "square.2.layers.3d") }
                            .buttonStyle(.study(.normal, size: .small))
                        Text("V aplikaci Zkratky vytvoř zkratku (třeba s akcí „Nastavit režim soustředění“) a sem napiš její přesný název.")
                            .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func shortcutField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        SettingRow(title) {
            HStack(spacing: 6) {
                TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).frame(width: 200).labelsHidden()
                Button("Vyzkoušet") { BlockAutomation.runShortcut(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.study(.ghost, size: .small))
                    .fixedSize()
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct HotKeySettings: View {
    @Environment(MacPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        PageSection("Klávesové zkratky") {
            VStack(alignment: .leading, spacing: 16) {
                row("Spustit / pozastavit blok", detail: "Odkudkoli: spustí doporučený blok, pozastaví ho nebo pokračuje.",
                    key: $prefs.toggleHotKey, action: .toggle, id: "settings.hotkey.toggle")
                row("Otevřít Study Tracker", detail: "Přenese okno aplikace dopředu.", key: $prefs.showHotKey, action: .show, id: "settings.hotkey.show")
                Text("Klikni na zkratku a stiskni novou kombinaci s ⌘, ⌥ nebo ⌃. Esc nahrávání zruší.")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func row(_ title: String, detail: String, key: Binding<HotKey?>, action: HotKeyCenter.Action, id: String) -> some View {
        SettingRow(title, detail: prefs.hotKeyConflicts.contains(action) ? "Tuhle zkratku už používá jiná aplikace – zvol jinou." : detail) {
            HotKeyRecorder(key: key).accessibilityIdentifier(id)
        }
    }
}

struct WeeklySummarySettings: View {
    @Environment(MacPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        PageSection("Souhrn týdne") {
            SettingSwitch("Pondělní souhrn v oznámení",
                          detail: "V pondělí ráno: kolik ses minulý týden učil proti cíli, nejlepší den, změna a blížící se zkouška.",
                          isOn: $prefs.weeklySummary, id: "settings.weekly")
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// Nahrání klávesové zkratky: klik, pak stisk kombinace (aspoň jeden z ⌘ ⌥ ⌃). Esc zruší, křížek zkratku vypne.
struct HotKeyRecorder: View {
    @Binding var key: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Stiskni zkratku…" : key?.display ?? "Nastavit") { recording ? stop() : record() }
                .buttonStyle(.study(recording ? .primary : .normal, size: .small))
                .monospaced(!recording && key != nil)
                .frame(minWidth: 96)
            if key != nil, !recording {
                Button { key = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.study(.ghost, size: .small))
                    .help("Zkratku vypnout")
                    .accessibilityLabel("Zkratku vypnout")
            }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            key = HotKey(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(flags), key: Self.label(event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= HotKey.command }
        if flags.contains(.option) { m |= HotKey.option }
        if flags.contains(.control) { m |= HotKey.control }
        if flags.contains(.shift) { m |= HotKey.shift }
        return m
    }

    private static let special: [UInt16: String] = [
        49: "Mezera", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func label(_ event: NSEvent) -> String {
        if let name = special[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

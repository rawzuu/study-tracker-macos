import Foundation
import Observation

/// Klávesová zkratka pro celý systém: kód klávesy a modifikátory v hodnotách Carbonu (`RegisterEventHotKey`).
public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Popisek klávesy („P“, „Mezera“) – jak ji ukazuje nahrávání.
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    // Carbon: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// „⌃⌥P“ – pořadí symbolů jako v nabídkách macOS.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + key
    }

    /// ⌃⌥P – v aplikacích skoro nepoužívaná kombinace.
    public static let defaultToggle = HotKey(keyCode: 35, modifiers: control | option, key: "P")
}

/// Nastavení jen pro tento Mac (web je nezná): automatická pauza, zkratky při bloku, klávesové zkratky
/// a pondělní souhrn. Ukládá se do UserDefaults, nesynchronizuje se.
@MainActor
@Observable
public final class MacPreferences {
    /// Po kolika minutách nečinnosti se blok sám pozastaví (0 = nikdy).
    public var awayMinutes: Int { didSet { save(awayMinutes, "awayMinutes") } }
    /// Zamčení obrazovky nebo uspání Macu blok pozastaví hned.
    public var awayOnLock: Bool { didSet { save(awayOnLock, "awayOnLock") } }
    /// Zkratky ze Zkratek na začátku a konci bloku (třeba zapnout a vypnout Nerušit).
    public var shortcutsEnabled: Bool { didSet { save(shortcutsEnabled, "shortcuts") } }
    public var startShortcut: String { didSet { save(startShortcut, "shortcut.start") } }
    public var endShortcut: String { didSet { save(endShortcut, "shortcut.end") } }
    /// Spustit / pozastavit blok odkudkoli.
    public var toggleHotKey: HotKey? { didSet { saveHotKey(toggleHotKey, "hotkey.toggle") } }
    /// Otevřít okno aplikace odkudkoli.
    public var showHotKey: HotKey? { didSet { saveHotKey(showHotKey, "hotkey.show") } }
    /// V pondělí souhrn minulého týdne do oznámení.
    public var weeklySummary: Bool { didSet { save(weeklySummary, "weekly") } }

    /// Zkratky, které systém nepřijal (drží je jiná aplikace) – nastavuje `HotKeyCenter`, neukládá se.
    public var hotKeyConflicts: Set<HotKeyCenter.Action> = []

    public static let awayChoices = [0, 2, 5, 10, 15, 30]

    @ObservationIgnored private let defaults: UserDefaults
    private static let prefix = "st.mac."

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let d = { (key: String) in defaults.object(forKey: Self.prefix + key) }
        awayMinutes = d("awayMinutes") as? Int ?? 10
        awayOnLock = d("awayOnLock") as? Bool ?? true
        shortcutsEnabled = d("shortcuts") as? Bool ?? false
        startShortcut = d("shortcut.start") as? String ?? ""
        endShortcut = d("shortcut.end") as? String ?? ""
        weeklySummary = d("weekly") as? Bool ?? true
        toggleHotKey = Self.hotKey(defaults, "hotkey.toggle", fallback: .defaultToggle)
        showHotKey = Self.hotKey(defaults, "hotkey.show", fallback: nil)
    }

    private func save(_ value: some Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    /// Bez zkratky se uloží prázdná data – „vypnuto“ se tak odliší od „ještě nenastaveno“ (výchozí).
    private func saveHotKey(_ key: HotKey?, _ name: String) {
        defaults.set(key.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: Self.prefix + name)
    }

    private static func hotKey(_ defaults: UserDefaults, _ name: String, fallback: HotKey?) -> HotKey? {
        guard let data = defaults.data(forKey: prefix + name) else { return fallback }
        return try? JSONDecoder().decode(HotKey.self, from: data)
    }
}

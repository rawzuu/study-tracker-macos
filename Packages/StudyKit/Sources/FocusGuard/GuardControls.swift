import AppKit
import CoreServices
import Darwin
import Focus

/// Kdy Mac naposledy nastartoval (ms od 1970) – `kern.boottime`.
public func systemBootTime() -> Int {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return Int(tv.tv_sec) * 1000 + Int(tv.tv_usec) / 1000
}

/// Spuštěná aplikace, jak ji vidí Strážce.
public struct RunningApp: Sendable, Equatable {
    public var pid: pid_t
    public var bundleId: String
    public var name: String

    public init(pid: pid_t, bundleId: String, name: String) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
    }
}

/// Ovládání ostatních aplikací (v testech náhrada).
@MainActor
public protocol AppControl: AnyObject {
    func frontmost() -> RunningApp?
    /// Aplikace s oknem v Docku (ne pomocníci na pozadí).
    func running() -> [RunningApp]
    func hide(_ app: RunningApp)
    func quit(_ app: RunningApp)
    /// Po odemknutí: otevřít (vrátit dopředu) aplikaci.
    func open(bundleId: String)
}

/// Adresa aktivní záložky Safari přes Apple Events.
@MainActor
public protocol SafariControl: AnyObject {
    var isRunning: Bool { get }
    var isFrontmost: Bool { get }
    /// Souhlas v Soukromí → Automatizace. `ask` = zeptat se uživatele (jednou).
    func permission(ask: Bool) async -> GuardReport.SafariWatch
    func currentURL() -> URL?
    /// Odejít ze zablokované stránky (když ji rozšíření nezastavilo).
    func leaveBlockedPage()
    /// Po odemknutí webu: otevřít původní adresu.
    func open(_ url: URL)
    /// Všechny otevřené záložky (i na pozadí a v soukromých oknech).
    func tabs() -> [SafariTab]
    /// Zablokované záložky na pozadí zavřít obsahem (adresa → about:blank).
    func blank(_ tabs: [SafariTab])
}

/// Záložka Safari: okno podle id (pořadí oken se mění), záložka podle pořadí v okně.
public struct SafariTab: Equatable, Sendable {
    public var window: Int
    public var index: Int
    public var isCurrent: Bool
    public var url: URL

    public init(window: Int, index: Int, isCurrent: Bool, url: URL) {
        self.window = window
        self.index = index
        self.isCurrent = isCurrent
        self.url = url
    }
}

/// Blokovací obrazovka.
@MainActor
public protocol ShieldControl: AnyObject {
    var isShown: Bool { get }
    func show(_ info: ShieldInfo)
    func close()
}

/// Co ukázat na blokovací obrazovce.
public struct ShieldInfo: Sendable, Equatable {
    /// Název aplikace nebo doména.
    public var name: String
    public var isSite: Bool
    public var lists: [String]
    /// Kolikátý pokus dnes (včetně tohoto).
    public var attempt: Int
    public var until: Int?
    public var locked: Bool
    /// Kde je uživatel v odemykání.
    public var unlock: UnlockStep
    /// Špatně opsaný text, špatné heslo.
    public var error: String?

    public init(name: String, isSite: Bool, lists: [String], attempt: Int, until: Int?, locked: Bool,
                unlock: UnlockStep = .unavailable(""), error: String? = nil) {
        self.name = name
        self.isSite = isSite
        self.lists = lists
        self.attempt = attempt
        self.until = until
        self.locked = locked
        self.unlock = unlock
        self.error = error
    }
}

/// Tlačítka blokovací obrazovky → Strážce.
@MainActor
public protocol ShieldActions: AnyObject {
    func shieldRequestUnlock()
    func shieldSubmit(typed: String)
    func shieldSubmit(password: String)
}

// MARK: - Systém

public final class SystemApps: AppControl {
    public init() {}

    public func frontmost() -> RunningApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(Self.info)
    }

    public func running() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(Self.info)
    }

    public func hide(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.hide()
    }

    public func open(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Slušné ukončení (aplikace se může zeptat na uložení). Když odmítne, zůstane schovaná.
    public func quit(_ app: RunningApp) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        running.hide()
        running.terminate()
    }

    nonisolated static func info(_ app: NSRunningApplication) -> RunningApp? {
        guard let id = app.bundleIdentifier else { return nil }
        return RunningApp(pid: app.processIdentifier, bundleId: id, name: app.localizedName ?? id)
    }
}

public final class SystemSafari: SafariControl {
    public nonisolated static let bundleId = "com.apple.Safari"

    public init() {}

    public var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty }
    public var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleId }

    public func permission(ask: Bool) async -> GuardReport.SafariWatch {
        guard isRunning else { return .needsPermission }
        // Dotaz na souhlas blokuje, dokud uživatel neodpoví – mimo hlavní vlákno.
        let status = await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleId)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        }.value
        return status == noErr ? .on : .needsPermission
    }

    public func currentURL() -> URL? {
        // Jen když Safari běží – `tell application` by ho jinak spustil.
        guard isRunning else { return nil }
        let source = """
            with timeout of 1 second
                tell application "Safari" to if (count of windows) > 0 then return URL of current tab of front window
            end timeout
            """
        return run(source)?.stringValue.flatMap(URL.init(string:))
    }

    public func leaveBlockedPage() {
        guard isRunning else { return }
        _ = run("""
            with timeout of 1 second
                tell application "Safari" to if (count of windows) > 0 then set URL of current tab of front window to "about:blank"
            end timeout
            """)
    }

    public func open(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: URL(filePath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    public func tabs() -> [SafariTab] {
        guard isRunning else { return [] }
        let source = """
            with timeout of 2 seconds
                tell application "Safari"
                    set out to {}
                    repeat with w in windows
                        try
                            set end of out to {id of w, index of current tab of w, URL of every tab of w}
                        end try
                    end repeat
                    return out
                end tell
            end timeout
            """
        guard let list = run(source), list.numberOfItems > 0 else { return [] }
        var out: [SafariTab] = []
        for i in 1...list.numberOfItems {
            guard let w = list.atIndex(i), w.numberOfItems == 3, let urls = w.atIndex(3), urls.numberOfItems > 0 else { continue }
            let window = Int(w.atIndex(1)?.int32Value ?? 0)
            let current = Int(w.atIndex(2)?.int32Value ?? 0)
            for t in 1...urls.numberOfItems {
                guard let url = urls.atIndex(t)?.stringValue.flatMap(URL.init(string:)) else { continue }
                out.append(SafariTab(window: window, index: t, isCurrent: t == current, url: url))
            }
        }
        return out
    }

    public func blank(_ tabs: [SafariTab]) {
        guard isRunning, !tabs.isEmpty else { return }
        let lines = tabs.map { "try\n set URL of tab \($0.index) of window id \($0.window) to \"about:blank\"\nend try" }.joined(separator: "\n")
        _ = run("""
            with timeout of 2 seconds
                tell application "Safari"
            \(lines)
                end tell
            end timeout
            """)
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

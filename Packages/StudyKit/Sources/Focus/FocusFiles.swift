import Foundation
import notify
import WidgetData

/// Soubory Soustředění ve sdíleném kontejneru (app group), který mají aplikace i Strážce:
/// nastavení (zapisuje aplikace) a databáze měření a pokusů (zapisuje Strážce).
public struct FocusFiles: Sendable {
    public let directory: URL
    public let group: String

    public init(directory: URL, group: String) {
        self.directory = directory
        self.group = group
    }

    /// Sdílený kontejner podle Info.plist (stejný klíč jako widgety); `nil` bez kontejneru (nepodepsaný build).
    public static func shared(bundle: Bundle = .main) -> FocusFiles? {
        guard let group = bundle.object(forInfoDictionaryKey: WidgetFiles.groupKey) as? String, !group.isEmpty, !group.hasPrefix("$"),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return FocusFiles(directory: url.appendingPathComponent("Focus", isDirectory: true), group: group)
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var databaseURL: URL { directory.appendingPathComponent("focus.sqlite") }
    public var reportURL: URL { directory.appendingPathComponent("state.json") }
    /// Kdy se naposledy ozvalo rozšíření Safari.
    public var extensionURL: URL { directory.appendingPathComponent("extension.json") }
    private var inboxURL: URL { directory.appendingPathComponent("inbox", isDirectory: true) }

    // MARK: - Nastavení

    public func readConfig() -> FocusConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(FocusConfig.self, from: data)
    }

    /// Zapíše nastavení celé najednou a dá Strážci vědět.
    public func write(_ config: FocusConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        notify_post(Self.configChanged(group))
    }

    // MARK: - Stav Strážce

    public func readReport() -> GuardReport? {
        guard let data = try? Data(contentsOf: reportURL),
              let r = try? JSONDecoder().decode(GuardReport.self, from: data), r.version == GuardReport.currentVersion else { return nil }
        return r
    }

    public func write(_ report: GuardReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
        postDataChanged()
    }

    // MARK: - Rozšíření Safari

    /// Rozšíření: „jsem tu“ (aplikace i Strážce poznají, že je zapnuté).
    public func markExtensionSeen(at t: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(["seenAt": t]).write(to: extensionURL, options: .atomic)
    }

    public func extensionSeenAt() -> Int? {
        guard let data = try? Data(contentsOf: extensionURL) else { return nil }
        return (try? JSONDecoder().decode([String: Int].self, from: data))?["seenAt"]
    }

    /// Rozšíření: pokus o zablokovaný web (každý vlastní soubor) a oznámení Strážci.
    public func send(_ attempt: SafariAttempt) throws {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(attempt).write(to: inboxURL.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
        notify_post(Self.inbox(group))
    }

    /// Strážce: pokusy od rozšíření v pořadí; přečtené soubory smaže.
    public func takeAttempts() -> [SafariAttempt] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        var out: [SafariAttempt] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let a = try? JSONDecoder().decode(SafariAttempt.self, from: data) { out.append(a) }
            try? FileManager.default.removeItem(at: file)
        }
        return out.sorted { $0.at < $1.at }
    }

    // MARK: - Oznámení mezi procesy (Darwin)

    /// Aplikace změnila nastavení.
    public static func configChanged(_ group: String) -> String { "\(group).focus-config" }
    /// Strážce zapsal nová data (pokus, odemknutí, měření).
    public static func dataChanged(_ group: String) -> String { "\(group).focus-data" }

    /// Aplikace žádá Strážce o nové spuštění (po aktualizaci běží starší kód).
    public static func restart(_ group: String) -> String { "\(group).focus-restart" }

    public func postRestart() { notify_post(Self.restart(group)) }

    /// Rozšíření Safari poslalo pokus.
    public static func inbox(_ group: String) -> String { "\(group).focus-inbox" }

    public func postDataChanged() { notify_post(Self.dataChanged(group)) }

    /// Zavolá `handler` na hlavním vlákně po každém oznámení `name`. Vrací token pro `notify_cancel`.
    @discardableResult
    public static func observe(_ name: String, _ handler: @escaping @MainActor @Sendable () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return token
    }
}

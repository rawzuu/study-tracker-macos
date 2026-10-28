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

    // MARK: - Oznámení mezi procesy (Darwin)

    /// Aplikace změnila nastavení.
    public static func configChanged(_ group: String) -> String { "\(group).focus-config" }
    /// Strážce zapsal nová data (pokus, odemknutí, měření).
    public static func dataChanged(_ group: String) -> String { "\(group).focus-data" }

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

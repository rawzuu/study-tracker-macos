import Foundation
import notify

/// Příkaz z tlačítka ve widgetu pro aplikaci (pozastavit, hotovo…). Widget ho uloží jako soubor
/// do sdíleného kontejneru a dá aplikaci vědět; aplikace ho provede se skutečným časovačem.
public struct WidgetCommand: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        case pause, resume, finish, stop
        /// Další blok (po pauze) nebo blok, který čeká.
        case next
        /// Doporučení „Co teď?“ (`subjectId`, `topic`, `modeId`).
        case start
    }

    public var id: UUID
    public var action: Action
    public var subjectId: String?
    public var topic: String?
    public var modeId: String?
    /// Kdy uživatel tlačítko stiskl (starší příkazy se po spuštění aplikace zahodí).
    public var at: Int

    public init(id: UUID = UUID(), action: Action, subjectId: String? = nil, topic: String? = nil, modeId: String? = nil, at: Int) {
        self.id = id
        self.action = action
        self.subjectId = subjectId
        self.topic = topic
        self.modeId = modeId
        self.at = at
    }

    /// Jak dlouho příkaz platí – když aplikace neběžela, starší stisk už nedává smysl.
    public static let lifetimeMs = 2 * 60_000

    /// Odkaz, který aplikaci otevře a příkaz provede (tlačítko ve widgetu, když aplikace neběží):
    /// `studytracker://widget?akce=start&predmet=…&tema=…&rezim=…`
    public var url: URL {
        var c = URLComponents()
        c.scheme = "studytracker"
        c.host = "widget"
        c.queryItems = [URLQueryItem(name: "akce", value: action.rawValue)]
            + [("predmet", subjectId), ("tema", topic), ("rezim", modeId)].compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        return c.url!
    }

    public init?(url: URL, at: Int) {
        guard url.scheme?.lowercased() == "studytracker", url.host == "widget",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let action = items.first(where: { $0.name == "akce" })?.value.flatMap(Action.init(rawValue:)) else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(action: action, subjectId: value("predmet"), topic: value("tema"), modeId: value("rezim"), at: at)
    }
}

/// Soubory widgetů ve sdíleném kontejneru aplikace (app group): souhrn od aplikace a příkazy od widgetu.
public struct WidgetFiles: Sendable {
    public let directory: URL
    public let group: String

    /// Klíč v Info.plist aplikace i widgetu s identifikátorem sdíleného kontejneru.
    public static let groupKey = "STAppGroup"
    /// Druhy widgetů (`WidgetCenter.reloadTimelines(ofKind:)`).
    public static let kinds = ["cz.rawzuu.studytracker.today", "cz.rawzuu.studytracker.timer", "cz.rawzuu.studytracker.plan",
                               "cz.rawzuu.studytracker.exams", "cz.rawzuu.studytracker.overview"]

    public init(directory: URL, group: String) {
        self.directory = directory
        self.group = group
    }

    /// Sdílený kontejner podle Info.plist; `nil`, když aplikace kontejner nemá (nepodepsaný build).
    public static func shared(bundle: Bundle = .main) -> WidgetFiles? {
        guard let group = bundle.object(forInfoDictionaryKey: groupKey) as? String, !group.isEmpty, !group.hasPrefix("$"),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetFiles(directory: url.appendingPathComponent("Widgets", isDirectory: true), group: group)
    }

    private var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    private var commandsURL: URL { directory.appendingPathComponent("commands", isDirectory: true) }

    // MARK: - Souhrn

    public func readSnapshot() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data), s.version == WidgetSnapshot.currentVersion else { return nil }
        return s
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        notify_post(Self.snapshotNotification(group))
    }

    // MARK: - Příkazy

    /// Widget: příkaz do sdíleného kontejneru (každý vlastní soubor – zápis ani čtení se nepřetahují).
    public func send(_ command: WidgetCommand) throws {
        try FileManager.default.createDirectory(at: commandsURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(command).write(to: commandsURL.appendingPathComponent("\(command.id.uuidString).json"), options: .atomic)
        notify_post(Self.commandNotification(group))
    }

    /// Aplikace: platné příkazy v pořadí stisku; přečtené soubory smaže.
    public func takeCommands(now: Int) -> [WidgetCommand] {
        let files = (try? FileManager.default.contentsOfDirectory(at: commandsURL, includingPropertiesForKeys: nil)) ?? []
        var out: [WidgetCommand] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(WidgetCommand.self, from: data),
               now - c.at <= WidgetCommand.lifetimeMs, c.at <= now + 60_000 {
                out.append(c)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Widget: počká, až aplikace po příkazu zapíše nový souhrn (běží-li). `true` = zapsala.
    public func waitForSnapshot(newerThan t: Int, timeout: Duration = .milliseconds(1500)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let s = readSnapshot(), s.generatedAt >= t { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Darwin oznámení „aplikace zapsala nový souhrn“ (Strážce Soustředění pozná začátek a konec bloku hned).
    public static func snapshotNotification(_ group: String) -> String { "\(group).widget-snapshot" }

    /// Darwin oznámení „widget poslal příkaz“ (jméno začíná identifikátorem kontejneru).
    public static func commandNotification(_ group: String) -> String { "\(group).widget-command" }

    /// Aplikace: zavolá `handler` na hlavním vlákně po každém příkazu z widgetu. Vrací token pro zrušení.
    @discardableResult
    public func observeCommands(_ handler: @escaping @MainActor @Sendable () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(Self.commandNotification(group), &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return token
    }
}

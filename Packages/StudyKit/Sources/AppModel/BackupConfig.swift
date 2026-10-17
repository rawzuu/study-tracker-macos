import Engine
import Foundation
import Networking
import Sync

/// Nastavení zálohy na GitHub na tomto Macu (bez tokenu – ten je v Klíčence).
public struct BackupConfig: Codable, Sendable, Hashable {
    public var location: RepoLocation
    /// `YYYY-MM-DD` – konec platnosti tokenu (nepovinné; GitHub ho aplikaci neprozradí).
    public var expires: String?

    public init(location: RepoLocation, expires: String? = nil) {
        self.location = location
        self.expires = expires
    }

    /// Kolik dní zbývá do konce platnosti tokenu (`tokenDaysLeft` na webu), `nil` = neznámo.
    public func tokenDaysLeft(now: Int, clock: StudyClock) -> Int? {
        guard let expires, expires.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, let end = clock.parseDayKey(expires) else { return nil }
        return Int((Double(end - clock.startOfDay(now)) / Double(StudyClock.day)).rounded())
    }
}

/// Přístup ke GitHubu pro připojení zálohy – v aplikaci skutečné API, v testech podvrh.
public protocol BackupService: Sendable {
    /// GitHub jméno majitele tokenu.
    func login(token: String) async throws(GitHubError) -> String
    func remote(token: String, location: RepoLocation) -> any RemoteDataFile
}

public struct GitHubBackupService: BackupService {
    public init() {}

    public func login(token: String) async throws(GitHubError) -> String {
        try await GitHubClient(token: token).login()
    }

    public func remote(token: String, location: RepoLocation) -> any RemoteDataFile {
        GitHubDataFile(client: GitHubClient(token: token), location: location)
    }
}

/// Uložení nastavení zálohy a režimu synchronizace (UserDefaults – jen pro tento Mac).
struct ConfigStore {
    let defaults: UserDefaults
    private static let backupKey = "st.github"
    private static let modeKey = "st.syncMode"

    var backup: BackupConfig? {
        get { defaults.data(forKey: Self.backupKey).flatMap { try? JSONDecoder().decode(BackupConfig.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.backupKey)
            } else {
                defaults.removeObject(forKey: Self.backupKey)
            }
        }
    }

    /// Dokud uživatel neověří, že data na Macu sedí s webem, Mac jen čte (#9).
    var syncMode: SyncMode {
        get { defaults.string(forKey: Self.modeKey) == "readWrite" ? .readWrite : .readOnly }
        nonmutating set { defaults.set(newValue == .readWrite ? "readWrite" : "readOnly", forKey: Self.modeKey) }
    }
}

import Core
import Engine
import Foundation
import Network
import Networking
import Persistence
import Sync

/// Závislosti aplikace na jednom místě (dependency injection). Aplikace používá `live`,
/// testy a UI testy vlastní sadu – nikdy nesahají na skutečná data, Klíčenku ani síť.
@MainActor
public struct AppEnvironment {
    public var openStore: () throws -> LocalStore
    public var secrets: any SecretStore
    public var defaults: UserDefaults
    public var backupService: any BackupService
    public var timing: SyncEngine.Timing
    public var clock: StudyClock
    /// Sledování dostupnosti sítě (`true` = připojeno).
    public var network: () -> AsyncStream<Bool>
    /// Dokument, který se před startem uloží jako lokální data (UI testy, náhledy).
    public var seed: AppDocument?

    public init(
        openStore: @escaping () throws -> LocalStore,
        secrets: any SecretStore,
        defaults: UserDefaults,
        backupService: any BackupService,
        timing: SyncEngine.Timing = .standard,
        clock: StudyClock = .current,
        network: @escaping () -> AsyncStream<Bool> = NetworkMonitor.availability,
        seed: AppDocument? = nil
    ) {
        self.openStore = openStore
        self.secrets = secrets
        self.defaults = defaults
        self.backupService = backupService
        self.timing = timing
        self.clock = clock
        self.network = network
        self.seed = seed
    }

    public static func live() -> AppEnvironment {
        AppEnvironment(
            openStore: { try LocalStore(at: LocalStore.defaultURL) },
            secrets: KeychainStore(),
            defaults: .standard,
            backupService: GitHubBackupService()
        )
    }

    /// Pro UI testy: vše v paměti, ukázková data, bez sítě.
    public static func uiTesting(now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> AppEnvironment {
        let suite = "cz.rawzuu.studytracker.uitests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppEnvironment(
            openStore: { try LocalStore.inMemory() },
            secrets: InMemorySecretStore(),
            defaults: defaults,
            backupService: OfflineBackupService(),
            network: { AsyncStream { $0.finish() } },
            seed: DemoData.document(now: now, clock: .current)
        )
    }
}

/// Bez sítě – připojení zálohy v UI testech skončí chybou sítě.
struct OfflineBackupService: BackupService {
    func login(token: String) async throws(GitHubError) -> String {
        throw .network(code: URLError.Code.notConnectedToInternet.rawValue)
    }

    func remote(token: String, location: RepoLocation) -> any RemoteDataFile {
        OfflineRemote()
    }

    private struct OfflineRemote: RemoteDataFile {
        func fetch() async throws(GitHubError) -> RemoteFile? {
            throw .network(code: URLError.Code.notConnectedToInternet.rawValue)
        }

        func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String {
            throw .network(code: URLError.Code.notConnectedToInternet.rawValue)
        }
    }
}

public enum NetworkMonitor {
    /// Proud změn dostupnosti sítě; první hodnota je aktuální stav.
    public static func availability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "cz.rawzuu.studytracker.network", qos: .utility))
        }
    }
}

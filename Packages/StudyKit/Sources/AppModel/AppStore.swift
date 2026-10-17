import Core
import Engine
import Foundation
import Networking
import Observation
import Persistence
import Sync

/// Stav aplikace pro všechna okna: aktuální data, stav synchronizace a připojení zálohy.
///
/// Drží neměnný `AppDocument`; pohledy z něj počítají, co potřebují. Úpravy jdou přes
/// `update(_:)` do `SyncEngine`, který je uloží na Mac a odešle na GitHub.
@MainActor
@Observable
public final class AppStore {
    public enum Phase: Equatable {
        case loading
        case ready
        /// Data na Macu se nepodařilo otevřít – nic se nemaže, aplikace jen ukáže chybu.
        case failed(String)
    }

    public private(set) var document: AppDocument = .empty
    public private(set) var sync = SyncState(status: .off, mode: .readOnly, dirty: false, lastSyncedAt: nil)
    public private(set) var backup: BackupConfig?
    public private(set) var phase: Phase = .loading

    public let clock: StudyClock

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var edits: AsyncStream<AppDocument>.Continuation?
    /// Úpravy odeslané enginu, které ještě nedošly – do té doby se data ze synchronizace slučují.
    @ObservationIgnored private var pendingEdits = 0
    @ObservationIgnored private var isActive = false

    static let tokenAccount = "github"

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.config = ConfigStore(defaults: environment.defaults)
        self.clock = environment.clock
    }

    public var isConnected: Bool { backup != nil }

    /// Nastavení jen pro tento Mac (stav časovače, připojení zálohy).
    var defaults: UserDefaults { environment.defaults }

    // MARK: - Start a životní cyklus

    public func start() async {
        guard phase == .loading, engine == nil else { return }
        do {
            let store = try environment.openStore()
            if let seed = environment.seed {
                try await store.save(StoredDocument(document: seed, dirty: false, remoteSha: nil))
            }
            backup = config.backup
            // Instalace z doby před v0.2.0: data patří k připojenému repu.
            if config.dataLocation == nil, let backup { config.dataLocation = backup.location }
            let engine = try await SyncEngine.open(store: store, remote: currentRemote(), mode: config.syncMode, timing: environment.timing)
            self.engine = engine
            document = await engine.document
            sync = await engine.state
            phase = .ready
            listen(to: engine)
            // Jedna synchronizace po startu; aktivní okno k ní přidá pravidelnou kontrolu.
            if isActive { await engine.setActive(true) } else { await engine.syncNow() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Okno je aktivní → synchronizovat hned a pak pravidelně; neaktivní → pravidelná kontrola stojí.
    public func setActive(_ active: Bool) async {
        isActive = active
        await engine?.setActive(active)
    }

    public func syncNow() async {
        await engine?.syncNow()
    }

    /// Před ukončením: uložit a odeslat neodeslané změny.
    public func prepareForTermination() async {
        await engine?.prepareForTermination()
    }

    // MARK: - Úpravy dat

    /// Upraví data. V režimu jen čtení zůstanou změny jen na Macu.
    public func update(_ change: (inout AppDocument) -> Void) {
        guard phase == .ready else { return }
        var next = document
        change(&next)
        guard next != document else { return }
        document = next
        pendingEdits += 1
        edits?.yield(next)
    }

    // MARK: - Připojení zálohy

    public enum ConnectError: Error, LocalizedError, Equatable {
        case emptyToken
        case github(GitHubError, owner: String, repo: String)
        case keychain(String)

        public var errorDescription: String? {
            switch self {
            case .emptyToken: "Vlož token."
            case .github(.notFound, let owner, let repo): "Repo \(owner)/\(repo) se nenašlo, nebo k němu token nemá přístup."
            case .github(let e, _, _): e.localizedDescription
            case .keychain(let detail): "Token se nepodařilo uložit do Klíčenky: \(detail)"
            }
        }
    }

    /// Ověří token a přístup k repu (jméno se zjistí z tokenu, pokud chybí), uloží token
    /// do Klíčenky a spustí synchronizaci. Jako „Připojit a synchronizovat“ na webu.
    public func connect(token rawToken: String, location: RepoLocation, expires: String? = nil) async throws(ConnectError) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw .emptyToken }
        var location = location
        do {
            if location.owner.isEmpty { location.owner = try await environment.backupService.login(token: token) }
            _ = try await environment.backupService.remote(token: token, location: location).fetch()
        } catch {
            throw .github(error, owner: location.owner, repo: location.repo)
        }
        do {
            try environment.secrets.setSecret(token, for: Self.tokenAccount)
        } catch {
            throw .keychain(error.localizedDescription)
        }
        let config = BackupConfig(location: location, expires: expires?.isEmpty == true ? nil : expires)
        // Jiné repo než to, ke kterému patří data na Macu → začít od jeho dat (stará se zálohují na Macu).
        let otherRepo = self.config.dataLocation.map { !$0.sameFile(as: location) } ?? false
        self.config.backup = config
        self.config.dataLocation = location
        backup = config
        await engine?.configure(remote: environment.backupService.remote(token: token, location: location), mode: self.config.syncMode, resetLocal: otherRepo)
    }

    /// Odpojí zálohu. Data na GitHubu i na Macu zůstanou, jen se přestanou synchronizovat.
    public func disconnect() async {
        try? environment.secrets.setSecret(nil, for: Self.tokenAccount)
        config.backup = nil
        backup = nil
        await engine?.configure(remote: nil, mode: config.syncMode)
    }

    public func setTokenExpiry(_ day: String?) {
        guard var b = backup else { return }
        b.expires = day?.isEmpty == true ? nil : day
        config.backup = b
        backup = b
    }

    public var syncMode: SyncMode { sync.mode }

    /// Přepne „jen čtení“ (Mac nic nezapisuje) a zpět.
    public func setSyncMode(_ mode: SyncMode) async {
        config.syncMode = mode
        await engine?.configure(remote: currentRemote(), mode: mode)
    }

    /// Okamžik pro razítka `updatedAt` (ms).
    public var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Vloží nebo upraví záznam (razítka `createdAt`/`updatedAt` jako na webu).
    public func upsert<R: EntityRecord>(_ item: R) {
        let now = nowMs
        update { $0.upsert(item, now: now) }
    }

    // MARK: - Interní

    private func currentRemote() -> (any RemoteDataFile)? {
        guard let backup, let token = try? environment.secrets.secret(for: Self.tokenAccount), !token.isEmpty else { return nil }
        return environment.backupService.remote(token: token, location: backup.location)
    }

    private func listen(to engine: SyncEngine) {
        let (stream, continuation) = AsyncStream.makeStream(of: AppDocument.self)
        edits = continuation
        // Úpravy jdou do enginu v pořadí, v jakém vznikly.
        tasks.append(Task { [weak self] in
            for await doc in stream {
                await engine.localDidChange(doc)
                self?.pendingEdits -= 1
            }
        })
        tasks.append(Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .document(let incoming): receive(incoming)
                case .state(let state): sync = state
                }
            }
        })
        let network = environment.network()
        tasks.append(Task {
            var wasAvailable: Bool?
            for await available in network {
                if available, wasAvailable == false { await engine.networkAvailabilityChanged(true) }
                wasAvailable = available
            }
        })
    }

    private func receive(_ incoming: AppDocument) {
        // Bez rozpracovaných úprav platí stav enginu; jinak se sloučí, aby se úprava neztratila.
        document = pendingEdits == 0 ? incoming : Merge.mergeData(local: document, remote: incoming)
    }
}

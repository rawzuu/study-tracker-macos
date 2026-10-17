import Core
import Engine
import Foundation
import Networking
import Persistence
import Sync
import Synchronization
import Testing
@testable import AppModel

/// Podvržený GitHub pro připojení zálohy.
private final class FakeBackup: BackupService, @unchecked Sendable {
    let login: Result<String, GitHubError>
    let remote: FakeRemote

    init(login: Result<String, GitHubError> = .success("rawzuu"), remote: FakeRemote) {
        self.login = login
        self.remote = remote
    }

    func login(token: String) async throws(GitHubError) -> String { try login.get() }
    func remote(token: String, location: RepoLocation) -> any RemoteDataFile {
        remote.lastToken.withLock { $0 = token }
        remote.lastLocation.withLock { $0 = location }
        return remote
    }
}

private final class FakeRemote: RemoteDataFile, @unchecked Sendable {
    let text: Mutex<String?>
    let error: GitHubError?
    let pushes = Mutex(0)
    let lastToken = Mutex<String?>(nil)
    let lastLocation = Mutex<RepoLocation?>(nil)

    init(document: AppDocument? = nil, error: GitHubError? = nil) {
        text = Mutex(document.map(Merge.serialize))
        self.error = error
    }

    func fetch() async throws(GitHubError) -> RemoteFile? {
        if let error { throw error }
        return text.withLock { $0 }.map { RemoteFile(content: Data($0.utf8), sha: "v1") }
    }

    func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String {
        pushes.withLock { $0 += 1 }
        text.withLock { $0 = String(decoding: content, as: UTF8.self) }
        return "v2"
    }
}

private func remoteDocument() -> AppDocument {
    var d = AppDocument.empty
    d.upsert(Subject(raw: ["id": "s1", "name": "Anatomie"]), now: 1_000)
    return d
}

@MainActor
private func makeStore(
    backup: FakeBackup,
    local: LocalStore? = nil,
    secrets: InMemorySecretStore = InMemorySecretStore(),
    defaults: UserDefaults? = nil,
    seed: AppDocument? = nil
) throws -> AppStore {
    let local = try local ?? LocalStore.inMemory()
    let defaults = defaults ?? UserDefaults(suiteName: "st-tests-\(UUID().uuidString)")!
    return AppStore(environment: AppEnvironment(
        openStore: { local },
        secrets: secrets,
        defaults: defaults,
        backupService: backup,
        timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
        network: { AsyncStream { $0.finish() } },
        seed: seed
    ))
}

/// Počká, až podmínka platí (aktualizace z enginu přicházejí asynchronně).
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
@Suite("Stav aplikace")
struct AppStoreTests {
    @Test("Start bez zálohy: lokální data, synchronizace vypnutá")
    func startOffline() async throws {
        let seed = remoteDocument()
        let store = try makeStore(backup: FakeBackup(remote: FakeRemote()), seed: seed)
        await store.start()
        #expect(store.phase == .ready)
        #expect(store.document == seed)
        #expect(store.sync.status == .off)
        #expect(!store.isConnected)
    }

    @Test("Připojení: jméno z tokenu, token v Klíčence, data z GitHubu, bez zbytečného commitu")
    func connect() async throws {
        let remote = FakeRemote(document: remoteDocument())
        let secrets = InMemorySecretStore()
        let store = try makeStore(backup: FakeBackup(remote: remote), secrets: secrets)
        await store.start()
        try await store.connect(token: "  github_pat_X \n", location: RepoLocation(owner: ""), expires: "2027-10-17")

        #expect(try secrets.secret(for: "github") == "github_pat_X")
        #expect(store.backup == BackupConfig(location: RepoLocation(owner: "rawzuu"), expires: "2027-10-17"))
        #expect(remote.lastLocation.withLock { $0 } == RepoLocation(owner: "rawzuu"))
        #expect(await eventually { store.document.alive(Subject.self).map(\.name) == ["Anatomie"] })
        #expect(store.sync.mode == .readWrite)
        // Stejná data jako na GitHubu → žádný commit.
        #expect(remote.pushes.withLock { $0 } == 0)
    }

    @Test("Neplatný token: hláška jako na webu, nic se neuloží")
    func wrongToken() async throws {
        let secrets = InMemorySecretStore()
        let store = try makeStore(backup: FakeBackup(login: .failure(.unauthorized), remote: FakeRemote()), secrets: secrets)
        await store.start()
        await #expect(throws: AppStore.ConnectError.github(.unauthorized, owner: "", repo: "study-tracker-data")) {
            try await store.connect(token: "bad", location: RepoLocation(owner: ""))
        }
        #expect(AppStore.ConnectError.github(.unauthorized, owner: "", repo: "x").localizedDescription == "Neplatný token.")
        #expect(try secrets.secret(for: "github") == nil)
        #expect(store.backup == nil)
    }

    @Test("Repo bez přístupu: srozumitelná hláška s názvem repa")
    func missingRepo() async throws {
        let store = try makeStore(backup: FakeBackup(remote: FakeRemote(error: .notFound)))
        await store.start()
        do {
            try await store.connect(token: "t", location: RepoLocation(owner: ""))
            Issue.record("mělo selhat")
        } catch {
            #expect(error.localizedDescription == "Repo rawzuu/study-tracker-data se nenašlo, nebo k němu token nemá přístup.")
        }
        #expect(store.backup == nil)
    }

    @Test("Prázdný token")
    func emptyToken() async throws {
        let store = try makeStore(backup: FakeBackup(remote: FakeRemote()))
        await store.start()
        await #expect(throws: AppStore.ConnectError.emptyToken) { try await store.connect(token: "  ", location: RepoLocation(owner: "")) }
    }

    @Test("Po restartu zůstane připojeno a data jsou hned k dispozici")
    func restart() async throws {
        let local = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        let defaults = UserDefaults(suiteName: "st-tests-\(UUID().uuidString)")!
        let remote = FakeRemote(document: remoteDocument())
        let first = try makeStore(backup: FakeBackup(remote: remote), local: local, secrets: secrets, defaults: defaults)
        await first.start()
        try await first.connect(token: "t", location: RepoLocation(owner: ""))
        #expect(await eventually { !first.document.alive(Subject.self).isEmpty })
        await first.prepareForTermination()

        let second = try makeStore(backup: FakeBackup(remote: remote), local: local, secrets: secrets, defaults: defaults)
        await second.start()
        #expect(second.isConnected)
        #expect(second.document.alive(Subject.self).map(\.name) == ["Anatomie"])
    }

    @Test("Odpojení smaže token, data zůstanou")
    func disconnect() async throws {
        let secrets = InMemorySecretStore()
        let store = try makeStore(backup: FakeBackup(remote: FakeRemote(document: remoteDocument())), secrets: secrets)
        await store.start()
        try await store.connect(token: "t", location: RepoLocation(owner: ""))
        #expect(await eventually { !store.document.alive(Subject.self).isEmpty })
        await store.disconnect()
        #expect(try secrets.secret(for: "github") == nil)
        #expect(store.backup == nil)
        #expect(await eventually { store.sync.status == .off })
        #expect(store.document.alive(Subject.self).count == 1)
    }

    @Test("Zápis: úprava z Macu se odešle, v režimu jen čtení ne")
    func writes() async throws {
        let remote = FakeRemote(document: remoteDocument())
        let store = try makeStore(backup: FakeBackup(remote: remote))
        await store.start()
        try await store.connect(token: "t", location: RepoLocation(owner: ""))
        #expect(await eventually { !store.document.alive(Subject.self).isEmpty })
        #expect(store.sync.mode == .readWrite)

        var s = store.document.alive(Subject.self)[0]
        s.weeklyGoalMin = 120
        store.upsert(s)
        #expect(await eventually { remote.pushes.withLock { $0 } == 1 })
        #expect(remote.text.withLock { $0 }?.contains("\"weeklyGoalMin\": 120") == true)

        await store.setSyncMode(.readOnly)
        s.weeklyGoalMin = 30
        store.upsert(s)
        try await Task.sleep(for: .milliseconds(80))
        await store.syncNow()
        #expect(remote.pushes.withLock { $0 } == 1)
        #expect(store.sync.mode == .readOnly)
    }

    @Test("Připojení k jinému repu nesloučí data z předchozího")
    func otherRepo() async throws {
        let remote = FakeRemote(document: remoteDocument())
        let store = try makeStore(backup: FakeBackup(remote: remote))
        await store.start()
        try await store.connect(token: "t", location: RepoLocation(owner: ""))
        #expect(await eventually { !store.document.alive(Subject.self).isEmpty })
        await store.disconnect()

        var other = AppDocument.empty
        other.upsert(Subject(raw: ["id": "x", "name": "Jiné repo"]), now: 5)
        remote.text.withLock { $0 = Merge.serialize(other) }
        try await store.connect(token: "t", location: RepoLocation(owner: "rawzuu", repo: "jine-repo"))
        #expect(await eventually { store.document.alive(Subject.self).map(\.name) == ["Jiné repo"] })
        #expect(remote.pushes.withLock { $0 } == 0)
    }

    @Test("Platnost tokenu: zbývající dny")
    func tokenDays() {
        let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
        let now = clock.parseDayKey("2026-10-17")! + 15 * 3_600_000
        #expect(BackupConfig(location: RepoLocation(owner: "a"), expires: "2026-10-24").tokenDaysLeft(now: now, clock: clock) == 7)
        #expect(BackupConfig(location: RepoLocation(owner: "a"), expires: "2026-10-17").tokenDaysLeft(now: now, clock: clock) == 0)
        #expect(BackupConfig(location: RepoLocation(owner: "a"), expires: "zítra").tokenDaysLeft(now: now, clock: clock) == nil)
        #expect(BackupConfig(location: RepoLocation(owner: "a")).tokenDaysLeft(now: now, clock: clock) == nil)
    }
}

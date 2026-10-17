import Core
import Engine
import Foundation
import Networking
import Persistence
import Sync
import Synchronization
import Testing
@testable import AppModel

/// Podvržený GitHub: záloha s daty a gisty, které si zapisují, co se publikovalo.
private final class FeedBackup: BackupService, @unchecked Sendable {
    let gists = FakeGists()

    func login(token: String) async throws(GitHubError) -> String { "rawzuu" }
    func remote(token: String, location: RepoLocation) -> any RemoteDataFile { EmptyRemote() }
    func gists(token: String) -> any GistPublisher { gists }

    private struct EmptyRemote: RemoteDataFile {
        func fetch() async throws(GitHubError) -> RemoteFile? { nil }
        func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String { "v1" }
    }
}

private final class FakeGists: GistPublisher, @unchecked Sendable {
    let created = Mutex<[String]>([])
    let updated = Mutex<[String]>([])
    let error = Mutex<GitHubError?>(nil)

    func createGist(file: String, content: String, description: String) async throws(GitHubError) -> CreatedGist {
        if let e = error.withLock({ $0 }) { throw e }
        created.withLock { $0.append(content) }
        return CreatedGist(id: "gist1", owner: "rawzuu")
    }

    func updateGist(id: String, file: String, content: String) async throws(GitHubError) {
        if let e = error.withLock({ $0 }) { throw e }
        updated.withLock { $0.append(content) }
    }

    var updates: Int { updated.withLock { $0.count } }
}

@MainActor
private func connectedStore(_ backup: FeedBackup) async throws -> AppStore {
    let local = try LocalStore.inMemory()
    let store = AppStore(environment: AppEnvironment(
        openStore: { local },
        secrets: InMemorySecretStore(),
        defaults: UserDefaults(suiteName: "st-feed-\(UUID().uuidString)")!,
        backupService: backup,
        timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
        network: { AsyncStream { $0.finish() } }
    ))
    await store.start()
    try await store.connect(token: "github_pat_X", location: RepoLocation(owner: ""))
    return store
}

@MainActor
private func addBlock(_ store: AppStore, _ id: String) {
    store.upsert(PlanBlock(raw: ["id": .string(id), "subjectId": "a", "title": "", "start": .number(Double(store.nowMs + 3_600_000)),
                                 "durationMin": 45, "done": false, "note": ""]))
}

@MainActor
@Suite("Odebíraný kalendář")
struct CalendarFeedSyncTests {
    @Test("Zapnutí: tajný gist s plánem, odkaz v nastavení jako na webu, bez zbytečné druhé aktualizace")
    func enable() async throws {
        let backup = FeedBackup()
        let store = try await connectedStore(backup)
        addBlock(store, "b1")
        let feed = CalendarFeedSync(app: store)
        try await feed.enable(includeExams: true, alarmMin: nil)

        let created = backup.gists.created.withLock { $0 }
        #expect(created.count == 1 && created[0].contains("UID:b1@study-tracker"))
        let settings = try #require(store.document.settings.calendarFeed)
        #expect(Array(settings.raw.keys) == ["gistId", "owner", "includeExams", "alarmMin"])
        #expect(settings.gistId == "gist1" && settings.owner == "rawzuu" && settings.alarmMin == nil && settings.raw["alarmMin"] == .null)
        #expect(feed.status?.error == nil)
        // Obsah se nezměnil → nic se znovu nenahrává.
        #expect(await feed.publish(force: false) == false)
        #expect(backup.gists.updates == 0)
    }

    @Test("Změna plánu se nahraje jednou; stejný obsah podruhé ne; „Aktualizovat teď“ vždy")
    func publishOnChange() async throws {
        let backup = FeedBackup()
        let store = try await connectedStore(backup)
        let feed = CalendarFeedSync(app: store)
        try await feed.enable(includeExams: false, alarmMin: 10)
        addBlock(store, "b2")
        #expect(await feed.publish(force: false))
        #expect(await feed.publish(force: false) == false)
        #expect(backup.gists.updated.withLock { $0.last }?.contains("TRIGGER:-PT10M") == true)
        await feed.publishNow()
        #expect(backup.gists.updates == 2)
    }

    @Test("Rychlé úpravy za sebou se nahrají najednou (prodleva po poslední změně)")
    func debounce() async throws {
        let backup = FeedBackup()
        let store = try await connectedStore(backup)
        let feed = CalendarFeedSync(app: store, delay: .milliseconds(60))
        try await feed.enable(includeExams: true, alarmMin: nil)
        feed.start()
        addBlock(store, "c1")
        try await Task.sleep(for: .milliseconds(20))
        addBlock(store, "c2")
        try await Task.sleep(for: .milliseconds(300))
        #expect(backup.gists.updates == 1)
        #expect(backup.gists.updated.withLock { $0.last }?.contains("UID:c2@study-tracker") == true)
    }

    @Test("Jen čtení: Mac nic nezapisuje, ani do gistu")
    func readOnly() async throws {
        let backup = FeedBackup()
        let store = try await connectedStore(backup)
        let feed = CalendarFeedSync(app: store)
        try await feed.enable(includeExams: true, alarmMin: nil)
        await store.setSyncMode(.readOnly)
        addBlock(store, "r1")
        #expect(await feed.publish(force: true) == false)
        #expect(backup.gists.updates == 0)
    }

    @Test("Token bez oprávnění ke gistům: srozumitelná chyba ve stavu")
    func permissionError() async throws {
        let backup = FeedBackup()
        let store = try await connectedStore(backup)
        let feed = CalendarFeedSync(app: store)
        try await feed.enable(includeExams: true, alarmMin: nil)
        backup.gists.error.withLock { $0 = .notFound }
        addBlock(store, "e1")
        #expect(await feed.publish(force: false) == false)
        #expect(feed.status?.error == "Token nemá oprávnění „Gists: Read and write“.")
        await #expect(throws: FeedError.github(.notFound)) { try await feed.enable(includeExams: true, alarmMin: nil) }
    }

    @Test("Vypnutí smaže odkaz z nastavení (gist zůstane)")
    func disable() async throws {
        let store = try await connectedStore(FeedBackup())
        let feed = CalendarFeedSync(app: store)
        try await feed.enable(includeExams: true, alarmMin: nil)
        feed.setAlarm(15)
        #expect(store.document.settings.calendarFeed?.alarmMin == 15)
        feed.disable()
        #expect(store.document.settings.calendarFeed == nil)
        #expect(store.document.settings.raw["calendarFeed"] == .null)
    }
}

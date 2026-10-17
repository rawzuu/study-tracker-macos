import Core
import Foundation
import Networking
import Persistence

/// Synchronizace dat s GitHubem – stejný postup jako `syncNow()` ve `store.tsx` na webu:
/// stáhnout (+`sha`) → normalizovat → sloučit s lokálními daty → nahrát se `sha`,
/// při konfliktu (409/422) znovu, nejvýš 4×.
///
/// Drží aktuální dokument, ukládá ho na Mac (`LocalStore`) a změny ze synchronizace posílá
/// aplikaci přes `updates`. Bezpečnostní pravidla:
///  - v režimu `.readOnly` nikdy nic nezapisuje na GitHub,
///  - data z novější verze schématu ani nečitelný soubor nikdy nepřepíše,
///  - lokální změny se při chybě neztratí – zůstanou uložené a odešlou se příště.
public actor SyncEngine {
    public struct Timing: Sendable {
        /// Odklad synchronizace po změně (na webu 3 s).
        public var debounce: Duration
        /// Pravidelná kontrola, jen když je aplikace aktivní (na webu 5 min).
        public var interval: Duration
        /// Odklad uložení na Mac po změně (sloučí rychlé po sobě jdoucí změny).
        public var persistDelay: Duration

        public init(debounce: Duration, interval: Duration, persistDelay: Duration) {
            self.debounce = debounce
            self.interval = interval
            self.persistDelay = persistDelay
        }

        public static let standard = Timing(debounce: .seconds(3), interval: .seconds(300), persistDelay: .milliseconds(300))
    }

    static let maxAttempts = 4

    public private(set) var document: AppDocument
    public private(set) var state: SyncState
    public nonisolated let updates: AsyncStream<SyncUpdate>

    private let store: LocalStore
    private var remote: (any RemoteDataFile)?
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let continuation: AsyncStream<SyncUpdate>.Continuation

    private var remoteSha: String?
    /// Čerstvá instalace bez vlastních dat: první stažená data se převezmou celá, aby výchozí
    /// nastavení Macu (`updatedAt: 0`) nepřebilo nastavení z GitHubu.
    private var adoptRemote: Bool
    private var syncing = false
    private var syncAgain = false
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    /// Ukládání na Mac jde přísně za sebou, aby starší stav nikdy nepřepsal novější.
    private var saveChain: Task<Void, any Error>?

    public init(
        store: LocalStore,
        stored: StoredDocument?,
        remote: (any RemoteDataFile)?,
        mode: SyncMode,
        timing: Timing = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.remote = remote
        self.timing = timing
        self.now = now
        self.document = stored?.document ?? .empty
        self.remoteSha = stored?.remoteSha
        self.adoptRemote = stored == nil
        self.state = SyncState(status: remote == nil ? .off : .idle, mode: mode, dirty: stored?.dirty ?? false, lastSyncedAt: nil)
        (updates, continuation) = AsyncStream.makeStream(of: SyncUpdate.self)
    }

    /// Načte uložený dokument z Macu a vytvoří engine.
    public static func open(
        store: LocalStore,
        remote: (any RemoteDataFile)?,
        mode: SyncMode,
        timing: Timing = .standard
    ) async throws -> SyncEngine {
        SyncEngine(store: store, stored: try await store.load(), remote: remote, mode: mode, timing: timing)
    }

    // MARK: - Ovládání

    /// Nový token / repo / režim. `nil` = synchronizace vypnutá (data zůstanou na Macu).
    ///
    /// `resetLocal`: data na Macu patří k jinému repu – uloží se do zálohy na Macu a začne se
    /// od dat nového repa, aby se do něj nesloučila cizí data.
    public func configure(remote: (any RemoteDataFile)?, mode: SyncMode, resetLocal: Bool = false) async {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        if resetLocal {
            do {
                try await store.snapshot(document, reason: "před přepojením na jiné repo")
            } catch {
                // Bez zálohy se lokální data nezahodí.
                setStatus(.failed(.storage(error.localizedDescription), at: now()))
                return
            }
            document = .empty
            remoteSha = nil
            adoptRemote = true
            state.dirty = false
            continuation.yield(.document(document))
            await persistNow()
        }
        self.remote = remote
        state.mode = mode
        state.status = remote == nil ? .off : .idle
        emitState()
        if remote != nil { await syncNow() }
    }

    /// Aplikace změnila data. Sloučí se s aktuálním stavem (na pořadí doručení nezáleží –
    /// rozhoduje `updatedAt`), uloží se a za chvíli se odešlou.
    public func localDidChange(_ incoming: AppDocument) {
        let merged = Merge.mergeData(local: incoming, remote: document)
        guard merged != document else { return }
        document = merged
        adoptRemote = false
        if merged != incoming { continuation.yield(.document(merged)) }
        if !state.dirty {
            state.dirty = true
            emitState()
        }
        schedulePersist()
        if remote != nil, state.mode == .readWrite { scheduleSync(after: timing.debounce) }
    }

    /// Okno aplikace je aktivní: hned synchronizuje a pak pravidelně. Neaktivní: pravidelná kontrola stojí.
    public func setActive(_ active: Bool) async {
        intervalTask?.cancel()
        intervalTask = nil
        guard active, remote != nil else { return }
        let interval = timing.interval
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                // Vlastní úloha: zastavení pravidelné kontroly nepřeruší rozběhnutou synchronizaci.
                await Task { await self?.syncNow() }.value
            }
        }
        await syncNow()
    }

    /// Síť je zase dostupná.
    public func networkAvailabilityChanged(_ available: Bool) async {
        if available, remote != nil { await syncNow() }
    }

    /// Před ukončením aplikace: uloží data a odešle neodeslané změny.
    public func prepareForTermination() async {
        debounceTask?.cancel()
        debounceTask = nil
        intervalTask?.cancel()
        intervalTask = nil
        await persistNow()
        if remote != nil, state.mode == .readWrite, state.dirty { await syncNow() }
    }

    // MARK: - Synchronizace

    public func syncNow() async {
        guard remote != nil else { return setStatus(.off) }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        repeat {
            syncAgain = false
            if let remote { await run(remote, generation: generation) }
        } while syncAgain
        syncing = false
    }

    private func run(_ remote: any RemoteDataFile, generation started: Int) async {
        setStatus(.syncing)
        do {
            for attempt in 0..<Self.maxAttempts {
                let file = try await remote.fetch()
                guard started == generation else { return }
                let remoteDoc = try file.map { try Self.parse($0.content) }
                let remoteText = remoteDoc.map(Merge.serialize)

                let local = document
                let merged: AppDocument
                if let remoteDoc {
                    merged = adoptRemote ? remoteDoc : Merge.mergeData(local: local, remote: remoteDoc)
                } else {
                    merged = local
                }
                adoptRemote = false
                if merged != local {
                    document = merged
                    continuation.yield(.document(merged))
                    schedulePersist()
                }
                let text = Merge.serialize(merged)

                if remoteText == text || state.mode == .readOnly {
                    try await finish(sha: file?.sha, syncedText: remoteText)
                    return
                }
                do {
                    let sha = try await remote.push(Data(text.utf8), sha: file?.sha, message: Self.commitMessage(at: now()))
                    guard started == generation else { return }
                    try await finish(sha: sha, syncedText: text)
                    return
                } catch let error as GitHubError where error.isConflict && attempt < Self.maxAttempts - 1 {
                    continue  // mezitím zapsalo jiné zařízení – stáhnout, sloučit a zkusit znovu
                }
            }
        } catch let error as GitHubError {
            fail(error == .cancelled ? nil : .github(error), generation: started)
        } catch let error as SyncFailure {
            fail(error, generation: started)
        } catch let error as SchemaError {
            if case .tooNew(let v) = error { fail(.schemaTooNew(version: v), generation: started) } else { fail(.unreadableRemote, generation: started) }
        } catch {
            fail(.storage(error.localizedDescription), generation: started)
        }
    }

    /// Úspěch: zapamatuje si verzi na GitHubu a uloží dokument.
    /// `syncedText` = obsah GitHubu po synchronizaci; pokud se dokument mezitím změnil, zůstává `dirty`.
    private func finish(sha: String?, syncedText: String?) async throws {
        remoteSha = sha
        let at = now()
        state.dirty = syncedText.map { $0 != Merge.serialize(document) } ?? (document != .empty)
        state.lastSyncedAt = at
        state.status = .synced(at: at)
        emitState()
        do {
            try await save(StoredDocument(document: document, dirty: state.dirty, remoteSha: remoteSha, savedAt: at))
        } catch {
            throw SyncFailure.storage(error.localizedDescription)
        }
    }

    private func fail(_ failure: SyncFailure?, generation started: Int) {
        guard started == generation else { return }
        setStatus(failure.map { .failed($0, at: now()) } ?? .idle)
    }

    private static func parse(_ content: Data) throws -> AppDocument {
        let value: JSONValue
        do { value = try JSONValue.parse(content) } catch { throw SyncFailure.unreadableRemote }
        return try AppDocument(normalizing: value)
    }

    /// `Sync dat (Mac) · 17. 10. 2026 19:16:58` – jako na webu (`toLocaleString('cs-CZ')`), jen s označením Macu.
    static func commitMessage(at date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.day, .month, .year, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { n.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "00" }
        return "Sync dat (Mac) · \(c.day ?? 0). \(c.month ?? 0). \(c.year ?? 0) \(c.hour ?? 0):\(two(c.minute)):\(two(c.second))"
    }

    // MARK: - Plánování a ukládání

    private func scheduleSync(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.fireDebouncedSync()
        }
    }

    private func fireDebouncedSync() async {
        debounceTask = nil
        await syncNow()
    }

    /// Naplánuje uložení. Jedno naplánované uložení stačí – uloží stav platný v okamžiku zápisu.
    private func schedulePersist() {
        guard persistTask == nil else { return }
        let delay = timing.persistDelay
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.persistScheduled()
        }
    }

    private func persistScheduled() async {
        persistTask = nil
        await persistNow()
    }

    private func persistNow() async {
        do {
            try await save(StoredDocument(document: document, dirty: state.dirty, remoteSha: remoteSha, savedAt: now()))
        } catch {
            setStatus(.failed(.storage(error.localizedDescription), at: now()))
        }
    }

    /// Uloží na Mac. Zápisy jdou v pořadí, v jakém vznikly, a zrušení volajícího je nepřeruší.
    private func save(_ stored: StoredDocument) async throws {
        let previous = saveChain
        let store = store
        let task = Task {
            _ = await previous?.result
            try await store.save(stored)
        }
        saveChain = task
        try await task.value
    }

    private func setStatus(_ status: SyncStatus) {
        guard state.status != status else { return }
        state.status = status
        emitState()
    }

    private func emitState() {
        continuation.yield(.state(state))
    }

    /// Počká, až doběhnou naplánované i běžící synchronizace a uložení (pro testy).
    func settle() async {
        while true {
            if let task = debounceTask {
                await task.value
                if debounceTask == task { debounceTask = nil }
            } else if syncing {
                try? await Task.sleep(for: .milliseconds(1))
            } else if let task = persistTask {
                await task.value
                if persistTask == task { persistTask = nil }
            } else if let task = saveChain {
                _ = await task.result
                if saveChain == task { saveChain = nil }
            } else {
                return
            }
        }
    }
}

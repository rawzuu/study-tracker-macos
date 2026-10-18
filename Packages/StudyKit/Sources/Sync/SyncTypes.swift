import Core
import Foundation
import Networking
import Synchronization

/// Vzdálený soubor s daty. V aplikaci `data.json` na GitHubu, v testech podvržený GitHub.
public protocol RemoteDataFile: Sendable {
    /// `nil` = soubor zatím neexistuje.
    func fetch() async throws(GitHubError) -> RemoteFile?
    /// Stáhne soubor, jen když už nemá verzi `sha` (synchronizace, kde se nic nezměnilo, nic nestahuje).
    func fetch(ifChangedFrom sha: String) async throws(GitHubError) -> RemoteFetch
    /// Zapíše obsah proti verzi `sha` (`nil` = nový soubor) a vrátí nový `sha`.
    func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String
}

/// Odpověď na „změnil se soubor od verze, kterou známe?“.
public enum RemoteFetch: Sendable {
    case unchanged
    /// Jiná verze, nebo soubor zmizel (`nil`).
    case changed(RemoteFile?)
}

extension RemoteDataFile {
    /// Bez podmíněných dotazů: stáhne soubor a porovná verzi.
    public func fetch(ifChangedFrom sha: String) async throws(GitHubError) -> RemoteFetch {
        let file = try await fetch()
        return file?.sha == sha ? .unchanged : .changed(file)
    }
}

/// `data.json` v repu na GitHubu.
public struct GitHubDataFile: RemoteDataFile {
    public let client: GitHubClient
    public let location: RepoLocation
    private let tags = ETagMemory()

    public init(client: GitHubClient, location: RepoLocation) {
        self.client = client
        self.location = location
    }

    public func fetch() async throws(GitHubError) -> RemoteFile? {
        try await client.fetchFile(at: location)
    }

    public func fetch(ifChangedFrom sha: String) async throws(GitHubError) -> RemoteFetch {
        // Značka se posílá jen k verzi, ke které patří – 304 pak opravdu znamená „pořád `sha`“.
        let known = tags.etag(for: sha)
        switch try await client.fetchFile(at: location, ifChangedFrom: sha, etag: known) {
        case .unchanged(let etag):
            tags.remember(etag ?? known, sha: sha)
            return .unchanged
        case .changed(let file, let etag):
            tags.remember(etag, sha: file?.sha)
            return .changed(file)
        }
    }

    public func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String {
        try await client.putFile(content, at: location, sha: sha, message: message)
    }
}

/// Značka (ETag) poslední odpovědi GitHubu a verze souboru, ke které patří.
final class ETagMemory: Sendable {
    private let value = Mutex<(etag: String, sha: String)?>(nil)

    func etag(for sha: String) -> String? {
        value.withLock { $0?.sha == sha ? $0?.etag : nil }
    }

    func remember(_ etag: String?, sha: String?) {
        value.withLock { $0 = etag.flatMap { e in sha.map { (e, $0) } } }
    }
}

public enum SyncMode: Sendable, Hashable {
    /// Změny z GitHubu se načtou, na GitHub se nic nezapisuje.
    case readOnly
    case readWrite
}

public enum SyncStatus: Sendable, Hashable {
    /// Synchronizace není nastavená (chybí token).
    case off
    case idle
    case syncing
    case synced(at: Date)
    case failed(SyncFailure, at: Date)
}

public struct SyncState: Sendable, Hashable {
    public var status: SyncStatus
    public var mode: SyncMode
    /// Na Macu jsou změny, které ještě nejsou na GitHubu.
    public var dirty: Bool
    public var lastSyncedAt: Date?

    public init(status: SyncStatus, mode: SyncMode, dirty: Bool, lastSyncedAt: Date?) {
        self.status = status
        self.mode = mode
        self.dirty = dirty
        self.lastSyncedAt = lastSyncedAt
    }
}

public enum SyncUpdate: Sendable {
    /// Dokument se změnil synchronizací (přišla data z jiného zařízení).
    case document(AppDocument)
    case state(SyncState)
}

public enum SyncFailure: Error, Sendable, Hashable {
    case github(GitHubError)
    /// Data na GitHubu jsou z novější verze – nic se nezapisuje, dokud se aplikace neaktualizuje.
    case schemaTooNew(version: Int)
    /// `data.json` na GitHubu se nedá přečíst (neplatný JSON) – nikdy se nepřepíše.
    case unreadableRemote
    /// Nepodařilo se uložit data na Macu.
    case storage(String)

    public var isTransient: Bool {
        if case .github(let e) = self { e.isTransient } else { false }
    }
}

extension SyncFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .github(let e):
            e.localizedDescription
        case .schemaTooNew(let v):
            "Data na GitHubu jsou z novější verze Study Trackeru (verze dat \(v)). Aktualizuj aplikaci pro Mac – do té doby nic nesynchronizuje ani nezapisuje."
        case .unreadableRemote:
            "Soubor s daty na GitHubu se nedá přečíst. Nic jsem nepřepsal – obnov ho z historie změn na GitHubu."
        case .storage(let detail):
            "Data se nepodařilo uložit na Mac: \(detail)"
        }
    }
}

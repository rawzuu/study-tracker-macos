import Core
import Foundation
import Networking

/// Vzdálený soubor s daty. V aplikaci `data.json` na GitHubu, v testech podvržený GitHub.
public protocol RemoteDataFile: Sendable {
    /// `nil` = soubor zatím neexistuje.
    func fetch() async throws(GitHubError) -> RemoteFile?
    /// Zapíše obsah proti verzi `sha` (`nil` = nový soubor) a vrátí nový `sha`.
    func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String
}

/// `data.json` v repu na GitHubu.
public struct GitHubDataFile: RemoteDataFile {
    public let client: GitHubClient
    public let location: RepoLocation

    public init(client: GitHubClient, location: RepoLocation) {
        self.client = client
        self.location = location
    }

    public func fetch() async throws(GitHubError) -> RemoteFile? {
        try await client.fetchFile(at: location)
    }

    public func push(_ content: Data, sha: String?, message: String) async throws(GitHubError) -> String {
        try await client.putFile(content, at: location, sha: sha, message: message)
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

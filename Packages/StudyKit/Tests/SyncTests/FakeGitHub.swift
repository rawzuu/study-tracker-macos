import Core
import Foundation
import Networking
@testable import Sync

/// Podvržený `data.json` na GitHubu se `sha` a historií commitů – chová se jako Contents API:
/// zápis se starým `sha` skončí konfliktem.
actor FakeGitHub: RemoteDataFile {
    struct Commit: Sendable {
        let message: String
        let text: String
    }

    private(set) var text: String?
    private(set) var version = 0
    private(set) var commits: [Commit] = []
    private(set) var fetchCount = 0
    private var fetchErrors: [GitHubError] = []
    private var pushErrors: [GitHubError] = []
    /// Zápisy „webu“, které proběhnou těsně před dalšími zápisy z Macu (souběh dvou zařízení).
    private var webWritesBeforePush: [String] = []

    init(text: String? = nil) {
        self.text = text
        if text != nil { version = 1 }
    }

    init(document: AppDocument) {
        self.init(text: Merge.serialize(document))
    }

    var sha: String { "v\(version)" }

    func failNextFetches(_ errors: GitHubError...) { fetchErrors += errors }
    func failNextPushes(_ errors: GitHubError...) { pushErrors += errors }
    func webWritesBeforeNextPush(_ texts: String...) { webWritesBeforePush += texts }

    /// Zápis z webu (jiné zařízení).
    func webWrite(_ text: String) {
        self.text = text
        version += 1
    }

    func fetch() async throws(GitHubError) -> RemoteFile? {
        fetchCount += 1
        if !fetchErrors.isEmpty { throw fetchErrors.removeFirst() }
        return text.map { RemoteFile(content: Data($0.utf8), sha: sha) }
    }

    func push(_ content: Data, sha expected: String?, message: String) async throws(GitHubError) -> String {
        if !webWritesBeforePush.isEmpty { webWrite(webWritesBeforePush.removeFirst()) }
        if !pushErrors.isEmpty { throw pushErrors.removeFirst() }
        if text != nil {
            guard let expected else { throw .conflict(status: 422) }  // chybí sha existujícího souboru
            guard expected == sha else { throw .conflict(status: 409) }
        } else if expected != nil {
            throw .conflict(status: 422)
        }
        let new = String(decoding: content, as: UTF8.self)
        text = new
        version += 1
        commits.append(Commit(message: message, text: new))
        return sha
    }

    var document: AppDocument? {
        get throws { try text.map { try AppDocument(parsing: Data($0.utf8)) } }
    }
}

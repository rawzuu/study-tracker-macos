import Foundation

/// Kde leží data: soubor `path` na větvi `branch` v repu `owner/repo`.
/// Odpovídá `GithubConfig` na webu bez tokenu – token je zvlášť v Klíčence.
public struct RepoLocation: Sendable, Hashable, Codable {
    public var owner: String
    public var repo: String
    public var branch: String
    public var path: String

    /// Výchozí hodnoty jako `NEW_GITHUB` na webu – uživatel vloží jen token, jméno se zjistí z něj.
    public static let defaultRepo = "study-tracker-data"
    public static let defaultBranch = "main"
    public static let defaultPath = "data.json"

    public init(owner: String, repo: String = defaultRepo, branch: String = defaultBranch, path: String = defaultPath) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.path = path
    }

    /// Odkaz na historii změn dat na GitHubu.
    public var commitsURL: URL? {
        URL(string: "https://github.com/\(URLPath.component(owner))/\(URLPath.component(repo))/commits/\(URLPath.component(branch))")
    }
}

/// Kódování částí adresy stejně jako `encodeURIComponent` v JavaScriptu.
enum URLPath {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func component(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Cesta k souboru: každá část zvlášť, lomítka zůstanou (`c.path.split('/').map(encodeURIComponent)`).
    static func filePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { component(String($0)) }.joined(separator: "/")
    }
}

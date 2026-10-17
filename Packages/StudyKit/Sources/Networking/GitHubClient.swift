import Foundation

/// Obsah souboru v repu a jeho verze (`sha`), proti které se pak zapisuje.
public struct RemoteFile: Sendable, Hashable {
    public var content: Data
    public var sha: String

    public init(content: Data, sha: String) {
        self.content = content
        self.sha = sha
    }
}

/// Přístup ke GitHub Contents API – stejné požadavky jako `github.ts` na webu.
///
/// Nemá žádný měnitelný stav (token a adresa jsou neměnné, `URLSession` je bezpečná pro souběh),
/// proto stačí `Sendable` struktura a není potřeba actor.
public struct GitHubClient: Sendable {
    private let token: String
    private let session: URLSession
    private let baseURL: URL

    public init(token: String, session: URLSession = .gitHub, baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token
        self.session = session
        self.baseURL = baseURL
    }

    /// GitHub jméno majitele tokenu (`fetchLogin`) – stačí tak vložit jen token.
    public func login() async throws(GitHubError) -> String {
        let (data, http) = try await send(request("/user"))
        try check(http)
        return try decode(UserResponse.self, from: data).login
    }

    /// Stáhne soubor (`fetchRemote`). `nil` = soubor ještě neexistuje, repo ale ano.
    public func fetchFile(at location: RepoLocation) async throws(GitHubError) -> RemoteFile? {
        let ref = "ref=\(URLPath.component(location.branch))"
        let (data, http) = try await send(request(contentsPath(location), query: ref))
        if http.statusCode == 404 {
            // Rozliší „soubor neexistuje“ od „repo neexistuje / bez přístupu“.
            let (_, repo) = try await send(request(repoPath(location)))
            try check(repo)
            return nil
        }
        try check(http)
        let body = try decode(ContentsResponse.self, from: data)
        if let content = body.content, !content.isEmpty, body.encoding == "base64" {
            guard let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw .invalidResponse }
            return RemoteFile(content: bytes, sha: body.sha)
        }
        // Soubory nad 1 MB API v `content` nevrací – stáhnou se jako raw.
        let (raw, rawHTTP) = try await send(request(contentsPath(location), query: ref, accept: "application/vnd.github.raw+json"))
        try check(rawHTTP)
        return RemoteFile(content: raw, sha: body.sha)
    }

    /// Zapíše soubor jedním commitem (`pushRemote`). `sha` = verze, kterou přepisujeme (`nil` pro nový soubor).
    /// Vrací nový `sha` souboru.
    @discardableResult
    public func putFile(_ content: Data, at location: RepoLocation, sha: String?, message: String) async throws(GitHubError) -> String {
        var put = request(contentsPath(location))
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = PutRequest(message: message, content: content.base64EncodedString(), branch: location.branch, sha: sha)
        do { put.httpBody = try JSONEncoder().encode(body) } catch { throw .invalidResponse }
        let (data, http) = try await send(put)
        try check(http)
        return try decode(PutResponse.self, from: data).content.sha
    }

    // MARK: - Požadavky

    private func contentsPath(_ l: RepoLocation) -> String {
        repoPath(l) + "/contents/" + URLPath.filePath(l.path)
    }

    private func repoPath(_ l: RepoLocation) -> String {
        "/repos/\(URLPath.component(l.owner))/\(URLPath.component(l.repo))"
    }

    private func request(_ path: String, query: String? = nil, accept: String = "application/vnd.github+json") -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = components.percentEncodedPath + path
        components.percentEncodedQuery = query
        var r = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("StudyTracker-macOS", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func send(_ request: URLRequest) async throws(GitHubError) -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .network(code: error.code.rawValue)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(code: URLError.Code.unknown.rawValue)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw .invalidResponse }
        return (result.0, http)
    }

    private func check(_ http: HTTPURLResponse) throws(GitHubError) {
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.from(status: http.statusCode, headers: http.allHeaderFields)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(GitHubError) -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw .invalidResponse }
    }
}

extension GitHubClient: CustomStringConvertible, CustomReflectable {
    // Token se nikdy nesmí objevit ve výpisu ani v logu.
    public var description: String { "GitHubClient(\(baseURL.host() ?? ""))" }
    public var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }
}

extension URLSession {
    /// Sezení bez mezipaměti a cookies – data se vždy čtou čerstvá (`cache: 'no-store'` na webu).
    public static let gitHub: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
}

// MARK: - Tvar odpovědí

private struct UserResponse: Decodable {
    let login: String
}

private struct ContentsResponse: Decodable {
    let sha: String
    let content: String?
    let encoding: String?
}

private struct PutRequest: Encodable {
    let message: String
    let content: String
    let branch: String
    let sha: String?
}

private struct PutResponse: Decodable {
    struct Content: Decodable { let sha: String }
    let content: Content
}

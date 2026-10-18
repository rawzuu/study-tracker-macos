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

/// Výsledek podmíněného stažení (`fetchFile(at:ifChangedFrom:etag:)`).
public enum FileChange: Sendable, Hashable {
    /// Soubor má pořád známou verzi; `etag` = značka odpovědi pro příští dotaz.
    case unchanged(etag: String?)
    /// Jiná verze, nebo soubor zmizel (`nil`), a značka odpovědi.
    case changed(RemoteFile?, etag: String?)
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
        try await fetch(location, ifChangedFrom: nil, etag: nil).file
    }

    /// Stáhne soubor, jen když už nemá verzi `sha`. `etag` je značka odpovědi, která k `sha` patří:
    /// GitHub na ni odpoví 304 bez obsahu (a takový dotaz nečerpá limit API). Bez značky se porovná
    /// verze z první odpovědi – obsah (a velký soubor zvlášť) se pak stahuje jen při změně.
    public func fetchFile(at location: RepoLocation, ifChangedFrom sha: String, etag: String?) async throws(GitHubError) -> FileChange {
        let fetched = try await fetch(location, ifChangedFrom: sha, etag: etag)
        return fetched.unchanged ? .unchanged(etag: fetched.etag) : .changed(fetched.file, etag: fetched.etag)
    }

    private struct Fetched {
        var file: RemoteFile?
        var etag: String?
        var unchanged = false
    }

    private func fetch(_ location: RepoLocation, ifChangedFrom sha: String?, etag: String?) async throws(GitHubError) -> Fetched {
        let ref = "ref=\(URLPath.component(location.branch))"
        var first = request(contentsPath(location), query: ref)
        if let etag { first.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await send(first)
        if http.statusCode == 304 { return Fetched(file: nil, etag: etag, unchanged: true) }
        if http.statusCode == 404 {
            // Rozliší „soubor neexistuje“ od „repo neexistuje / bez přístupu“.
            let (_, repo) = try await send(request(repoPath(location)))
            try check(repo)
            return Fetched(file: nil, etag: nil)
        }
        try check(http)
        let body = try decode(ContentsResponse.self, from: data)
        let tag = http.value(forHTTPHeaderField: "ETag")
        if let sha, body.sha == sha { return Fetched(file: nil, etag: tag, unchanged: true) }
        if let content = body.content, !content.isEmpty, body.encoding == "base64" {
            guard let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw .invalidResponse }
            return Fetched(file: RemoteFile(content: bytes, sha: body.sha), etag: tag)
        }
        // Soubory nad 1 MB API v `content` nevrací – stáhnou se jako raw.
        let (raw, rawHTTP) = try await send(request(contentsPath(location), query: ref, accept: "application/vnd.github.raw+json"))
        try check(rawHTTP)
        return Fetched(file: RemoteFile(content: raw, sha: body.sha), etag: tag)
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

    /// Požadavek s tělem JSON (`POST`, `PATCH`).
    func jsonRequest(_ path: String, method: String, body: some Encodable) throws(GitHubError) -> URLRequest {
        var r = request(path)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { r.httpBody = try JSONEncoder().encode(body) } catch { throw .invalidResponse }
        return r
    }

    private func contentsPath(_ l: RepoLocation) -> String {
        repoPath(l) + "/contents/" + URLPath.filePath(l.path)
    }

    private func repoPath(_ l: RepoLocation) -> String {
        "/repos/\(URLPath.component(l.owner))/\(URLPath.component(l.repo))"
    }

    func request(_ path: String, query: String? = nil, accept: String = "application/vnd.github+json") -> URLRequest {
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

    func send(_ request: URLRequest) async throws(GitHubError) -> (Data, HTTPURLResponse) {
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

    func check(_ http: HTTPURLResponse) throws(GitHubError) {
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.from(status: http.statusCode, headers: http.allHeaderFields)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(GitHubError) -> T {
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

import Foundation
import Testing
@testable import Networking

private let location = RepoLocation(owner: "rawzuu")
private let contentsPath = "/repos/rawzuu/study-tracker-data/contents/data.json"

/// GitHub vrací base64 zalomené po 60 znacích.
private func githubBase64(_ text: String) -> String {
    let b64 = Data(text.utf8).base64EncodedString()
    return stride(from: 0, to: b64.count, by: 60).map { i in
        let start = b64.index(b64.startIndex, offsetBy: i)
        return String(b64[start..<(b64.index(start, offsetBy: 60, limitedBy: b64.endIndex) ?? b64.endIndex)])
    }.joined(separator: "\n") + "\n"
}

@Suite("GitHub API")
struct GitHubClientTests {
    @Test("Login z tokenu a hlavičky jako na webu")
    func login() async throws {
        let server = StubServer { _ in .json(200, ["login": "rawzuu", "id": 1]) }
        let login = try await server.client(token: "github_pat_ABC").login()
        #expect(login == "rawzuu")
        let r = try #require(server.requests.first)
        #expect(r.method == "GET" && r.path == "/user")
        #expect(r.header("Authorization") == "Bearer github_pat_ABC")
        #expect(r.header("X-GitHub-Api-Version") == "2022-11-28")
        #expect(r.header("Accept") == "application/vnd.github+json")
    }

    @Test("Stažení souboru: base64 se zalomením, sha, větev v ref")
    func fetchSmallFile() async throws {
        let text = #"{"schemaVersion":1,"note":"Příliš žluťoučký kůň"}"# + "\n"
        let server = StubServer { _ in
            .json(200, ["sha": "abc123", "encoding": "base64", "content": githubBase64(text), "size": text.utf8.count])
        }
        let file = try #require(try await server.client().fetchFile(at: location))
        #expect(file.sha == "abc123")
        #expect(String(decoding: file.content, as: UTF8.self) == text)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].path == contentsPath)
        #expect(server.requests[0].query == "ref=main")
    }

    @Test("Cesta a větev se kódují jako encodeURIComponent")
    func encodesPath() async throws {
        let server = StubServer { _ in .json(200, ["sha": "s", "encoding": "base64", "content": githubBase64("{}")]) }
        let odd = RepoLocation(owner: "rawzuu", repo: "data", branch: "feature/č 1", path: "složka/data (1).json")
        _ = try await server.client().fetchFile(at: odd)
        #expect(server.requests[0].path == "/repos/rawzuu/data/contents/slo%C5%BEka/data%20(1).json")
        #expect(server.requests[0].query == "ref=feature%2F%C4%8D%201")
    }

    @Test("Soubor nad 1 MB se stáhne jako raw se sha z první odpovědi")
    func fetchLargeFile() async throws {
        let big = String(repeating: "x", count: 1_200_000)
        let server = StubServer { r in
            if r.header("Accept") == "application/vnd.github.raw+json" {
                return .http(200, body: Data(big.utf8))
            }
            return .json(200, ["sha": "big-sha", "encoding": "none", "content": ""])
        }
        let file = try #require(try await server.client().fetchFile(at: location))
        #expect(file.sha == "big-sha")
        #expect(file.content.count == big.utf8.count)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].path == contentsPath && server.requests[1].query == "ref=main")
    }

    @Test("Chybějící soubor v existujícím repu = nil")
    func fetchMissingFile() async throws {
        let server = StubServer { r in
            r.path == contentsPath ? .json(404, ["message": "Not Found"]) : .json(200, ["full_name": "rawzuu/study-tracker-data"])
        }
        let file = try await server.client().fetchFile(at: location)
        #expect(file == nil)
        #expect(server.requests.map(\.path) == [contentsPath, "/repos/rawzuu/study-tracker-data"])
    }

    @Test("Chybějící repo nebo bez přístupu = notFound")
    func fetchMissingRepo() async throws {
        let server = StubServer { _ in .json(404, ["message": "Not Found"]) }
        await #expect(throws: GitHubError.notFound) { try await server.client().fetchFile(at: location) }
    }

    @Test("Chyby oprávnění a serveru", arguments: [
        (401, GitHubError.unauthorized),
        (403, GitHubError.forbidden),
        (500, GitHubError.http(status: 500)),
        (502, GitHubError.http(status: 502)),
    ])
    func httpErrors(status: Int, expected: GitHubError) async throws {
        let server = StubServer { _ in .json(status, ["message": "x"]) }
        await #expect(throws: expected) { try await server.client().fetchFile(at: location) }
        await #expect(throws: expected) { try await server.client().login() }
    }

    @Test("Vyčerpaný limit požadavků se pozná podle hlaviček")
    func rateLimit() async throws {
        let reset = 1_900_000_000
        let server = StubServer { _ in
            .json(403, ["message": "API rate limit exceeded"], headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"])
        }
        let error = await #expect(throws: GitHubError.self) { try await server.client().fetchFile(at: location) }
        #expect(error == .rateLimited(retryAt: Date(timeIntervalSince1970: TimeInterval(reset))))
        #expect(error?.isTransient == true)
    }

    @Test("Výpadek sítě")
    func offline() async throws {
        let server = StubServer { _ in .failure(.notConnectedToInternet) }
        let error = await #expect(throws: GitHubError.self) { try await server.client().fetchFile(at: location) }
        #expect(error == .network(code: URLError.Code.notConnectedToInternet.rawValue))
        #expect(error?.isTransient == true)
    }

    @Test("Zápis nového souboru: bez sha, obsah v base64, větev a zpráva")
    func putNewFile() async throws {
        let text = "{\n \"schemaVersion\": 1\n}\n"
        let server = StubServer { _ in .json(201, ["content": ["sha": "new-sha"], "commit": ["sha": "c1"]]) }
        let sha = try await server.client().putFile(Data(text.utf8), at: location, sha: nil, message: "Sync dat (Mac) · 17. 10. 2026 19:00:00")
        #expect(sha == "new-sha")
        let r = try #require(server.requests.first)
        #expect(r.method == "PUT" && r.path == contentsPath && r.query == nil)
        #expect(r.header("Content-Type") == "application/json")
        let body = try #require(r.json)
        #expect(body["sha"] == nil)
        #expect(body["branch"] as? String == "main")
        #expect(body["message"] as? String == "Sync dat (Mac) · 17. 10. 2026 19:00:00")
        let content = try #require(body["content"] as? String)
        #expect(Data(base64Encoded: content) == Data(text.utf8))
    }

    @Test("Zápis existujícího souboru posílá sha")
    func putWithSha() async throws {
        let server = StubServer { _ in .json(200, ["content": ["sha": "next"]]) }
        let sha = try await server.client().putFile(Data("{}".utf8), at: location, sha: "prev", message: "m")
        #expect(sha == "next")
        #expect(server.requests[0].json?["sha"] as? String == "prev")
    }

    @Test("Konflikt verzí při zápisu", arguments: [409, 422])
    func putConflict(status: Int) async throws {
        let server = StubServer { _ in .json(status, ["message": "does not match"]) }
        let error = await #expect(throws: GitHubError.self) {
            try await server.client().putFile(Data("{}".utf8), at: location, sha: "old", message: "m")
        }
        #expect(error == .conflict(status: status))
        #expect(error?.isConflict == true)
    }

    @Test("Neočekávaná odpověď")
    func invalidResponse() async throws {
        let server = StubServer { _ in .http(200, body: Data("<html>".utf8)) }
        await #expect(throws: GitHubError.invalidResponse) { try await server.client().fetchFile(at: location) }
    }

    @Test("Hlášky jsou stejné jako na webu")
    func messages() {
        #expect(GitHubError.unauthorized.localizedDescription == "Neplatný token.")
        #expect(GitHubError.forbidden.localizedDescription == "Token nemá oprávnění (potřebuje Contents: Read and write).")
        #expect(GitHubError.notFound.localizedDescription == "Repo nebo větev nenalezena (nebo k nim token nemá přístup).")
        #expect(GitHubError.conflict(status: 409).localizedDescription == "Konflikt verzí.")
        #expect(GitHubError.http(status: 500).localizedDescription == "GitHub vrátil chybu 500.")
    }

    @Test("Token se neobjeví ve výpisu klienta")
    func tokenIsRedacted() {
        let client = GitHubClient(token: "github_pat_SECRET")
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!String(describing: client).contains("SECRET"))
        #expect(!String(reflecting: client).contains("SECRET"))
        #expect(!dumped.contains("SECRET"))
    }

    @Test("Odkaz na historii změn")
    func commitsURL() {
        #expect(location.commitsURL?.absoluteString == "https://github.com/rawzuu/study-tracker-data/commits/main")
    }
}

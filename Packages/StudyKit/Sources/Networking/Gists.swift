import Foundation

/// Tajný gist s jedním souborem – odebíraný kalendář (`createGist` / `updateGist` v `github.ts` na webu).
public protocol GistPublisher: Sendable {
    /// Vytvoří tajný (neveřejný) gist a vrátí jeho id a GitHub jméno majitele.
    func createGist(file: String, content: String, description: String) async throws(GitHubError) -> CreatedGist
    /// Přepíše obsah souboru v gistu.
    func updateGist(id: String, file: String, content: String) async throws(GitHubError)
}

public struct CreatedGist: Sendable, Hashable {
    public let id: String
    public let owner: String

    public init(id: String, owner: String) {
        self.id = id
        self.owner = owner
    }
}

extension GitHubClient: GistPublisher {
    public func createGist(file: String, content: String, description: String) async throws(GitHubError) -> CreatedGist {
        let body = GistRequest(description: description, isPublic: false, files: [file: .init(content: content)])
        let (data, http) = try await send(jsonRequest("/gists", method: "POST", body: body))
        try check(http)
        let gist = try decode(GistResponse.self, from: data)
        return CreatedGist(id: gist.id, owner: gist.owner.login)
    }

    public func updateGist(id: String, file: String, content: String) async throws(GitHubError) {
        let body = GistRequest(description: nil, isPublic: nil, files: [file: .init(content: content)])
        let (_, http) = try await send(jsonRequest("/gists/\(URLPath.component(id))", method: "PATCH", body: body))
        try check(http)
    }
}

private struct GistRequest: Encodable {
    struct File: Encodable { let content: String }
    let description: String?
    let isPublic: Bool?
    let files: [String: File]

    enum CodingKeys: String, CodingKey {
        case description, isPublic = "public", files
    }
}

private struct GistResponse: Decodable {
    struct Owner: Decodable { let login: String }
    let id: String
    let owner: Owner
}

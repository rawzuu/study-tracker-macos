import Foundation
import Testing
@testable import Networking

@Suite("Gist pro odebíraný kalendář")
struct GistTests {
    @Test("Nový gist je tajný a má jeden soubor; vrátí id a majitele")
    func create() async throws {
        let server = StubServer { _ in .json(201, ["id": "abc123", "owner": ["login": "rawzuu"], "public": false]) }
        let gist = try await server.client().createGist(file: "studijni-plan.ics", content: "BEGIN:VCALENDAR\r\n", description: "Study Tracker – studijní plán (kalendář)")
        #expect(gist == CreatedGist(id: "abc123", owner: "rawzuu"))
        let r = try #require(server.requests.first)
        #expect(r.method == "POST" && r.path == "/gists")
        #expect(r.header("Content-Type") == "application/json" && r.header("Authorization") == "Bearer github_pat_TEST")
        let body = try #require(r.json)
        #expect(body["public"] as? Bool == false)
        #expect(body["description"] as? String == "Study Tracker – studijní plán (kalendář)")
        #expect((body["files"] as? [String: [String: String]])?["studijni-plan.ics"]?["content"] == "BEGIN:VCALENDAR\r\n")
    }

    @Test("Aktualizace přepíše jen obsah souboru")
    func update() async throws {
        let server = StubServer { _ in .json(200, ["id": "abc123"]) }
        try await server.client().updateGist(id: "abc/123", file: "studijni-plan.ics", content: "X")
        let r = try #require(server.requests.first)
        #expect(r.method == "PATCH" && r.path == "/gists/abc%2F123")
        let body = try #require(r.json)
        #expect(Set(body.keys) == ["files"])
    }

    @Test("Bez oprávnění ke gistům: 404 / 403 jako chyba, ne tichý úspěch")
    func errors() async {
        let server = StubServer { _ in .json(404, ["message": "Not Found"]) }
        await #expect(throws: GitHubError.notFound) {
            try await server.client().updateGist(id: "x", file: "f", content: "c")
        }
    }
}

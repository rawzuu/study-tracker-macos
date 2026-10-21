import Foundation
import Testing
@testable import Networking

/// Podvržená Anki (AnkiConnect) na smyšleném hostu – testy nikdy nesahají na skutečnou Anki (127.0.0.1:8765).
private func anki(reviewedToday: Int = 12, permission: String = "granted", reviews: [String: [[Double]]] = [:]) -> StubServer {
    StubServer { r in
        let action = r.json?["action"] as? String ?? ""
        let params = r.json?["params"] as? [String: Any] ?? [:]
        switch action {
        case "requestPermission": return .json(200, ["result": ["permission": permission], "error": NSNull()])
        case "deckNames": return .json(200, ["result": ["Default", "Medicína::Anatomie", "Medicína::Fyziologie", "Latina"], "error": NSNull()])
        case "getDeckStats":
            return .json(200, ["result": [
                "1": ["deck_id": 1, "name": "Default", "new_count": 0, "learn_count": 0, "review_count": 0, "total_in_deck": 0],
                "20": ["deck_id": 20, "name": "Latina", "new_count": 5, "learn_count": 0, "review_count": 10, "total_in_deck": 80],
                "3": ["deck_id": 3, "name": "Medicína", "new_count": 10, "learn_count": 2, "review_count": 3, "total_in_deck": 900],
            ], "error": NSNull()])
        case "getNumCardsReviewedToday": return .json(200, ["result": reviewedToday, "error": NSNull()])
        case "cardReviews": return .json(200, ["result": reviews[params["deck"] as? String ?? ""] ?? [], "error": NSNull()])
        default: return .json(200, ["result": NSNull(), "error": "unsupported action"])
        }
    }
}

private func client(_ server: StubServer) -> AnkiConnectClient {
    AnkiConnectClient(endpoint: server.baseURL, session: StubProtocol.session)
}

@Suite("AnkiConnect")
struct AnkiConnectTests {
    @Test("Balíčky nejvyšší úrovně: jen neprázdné, podle počtu k opakování (při shodě podle id); historie ze všech podbalíčků")
    func fetch() async throws {
        let server = anki(reviews: [
            "Medicína::Anatomie": [[1_000_500, 1, 0, 3, 1, 0, 2500, 4000, 1]],
            "Latina": [[1_000_100, 2, 0, 3, 1, 0, 2500, 2000, 1], [1_000_900, 3, 0, 3, 1, 0, 2500, 3000, 1]],
        ])
        let result = try await client(server).fetch(since: 999_999, knownReviewedToday: nil)
        // Obě mají 15 karet – jako `Object.values` na webu vyhraje menší id (3 < 20); prázdný Default vypadne.
        #expect(result.decks.map(\.name) == ["Medicína", "Latina"])
        #expect(result.reviewsFetched && result.reviewedToday == 12)
        #expect(result.reviews == [
            .init(deck: "Latina", time: 1_000_100, durationMs: 2000), .init(deck: "Medicína", time: 1_000_500, durationMs: 4000),
            .init(deck: "Latina", time: 1_000_900, durationMs: 3000),
        ])
        let body = try #require(server.requests.first { $0.json?["action"] as? String == "cardReviews" }?.json)
        #expect(body["version"] as? Int == 6 && (body["params"] as? [String: Any])?["startID"] as? Int == 999_999)
        #expect(server.requests.filter { $0.json?["action"] as? String == "cardReviews" }.count == 4, "každý balíček zvlášť")
    }

    @Test("AnkiConnect 2026: balíček bez počtů (skrytý Default) shodí celý dotaz – načte se po jednom")
    func deckWithoutCounts() async throws {
        let server = StubServer { r in
            let stats: [String: [String: Any]] = [
                "Latina": ["deck_id": 20, "name": "Latina", "new_count": 5, "learn_count": 0, "review_count": 10, "total_in_deck": 80],
                "Medicína": ["deck_id": 3, "name": "Medicína", "new_count": 10, "learn_count": 2, "review_count": 3, "total_in_deck": 900],
            ]
            let action = r.json?["action"] as? String ?? ""
            let decks = (r.json?["params"] as? [String: Any])?["decks"] as? [String] ?? []
            switch action {
            case "requestPermission": return .json(200, ["result": ["permission": "granted"], "error": NSNull()])
            case "deckNames": return .json(200, ["result": ["Default", "Medicína::Anatomie", "Latina"], "error": NSNull()])
            case "getDeckStats":
                // Jako nová verze doplňku: neznámé počty u kteréhokoli balíčku = chyba celého dotazu
                guard decks.allSatisfy({ stats[$0] != nil }) else { return .json(200, ["result": NSNull(), "error": "Deck counts unavailable."]) }
                var out: [String: Any] = [:]
                for d in decks { out[String(stats[d]!["deck_id"] as! Int)] = stats[d] }
                return .json(200, ["result": out, "error": NSNull()])
            case "getNumCardsReviewedToday": return .json(200, ["result": 3, "error": NSNull()])
            case "cardReviews": return .json(200, ["result": [], "error": NSNull()])
            default: return .json(200, ["result": NSNull(), "error": "unsupported action"])
            }
        }
        let result = try await client(server).fetch(since: 0, knownReviewedToday: nil)
        #expect(result.decks.map(\.name) == ["Medicína", "Latina"])
        #expect(result.reviewedToday == 3)
    }

    @Test("Bez nového opakování se historie nestahuje")
    func known() async throws {
        let server = anki(reviewedToday: 7)
        let result = try await client(server).fetch(since: 0, knownReviewedToday: 7)
        #expect(!result.reviewsFetched && result.reviews.isEmpty)
        #expect(!server.requests.contains { $0.json?["action"] as? String == "cardReviews" })
    }

    @Test("Chyby: Anki neběží, připojení zamítnuto, chyba AnkiConnect")
    func errors() async {
        let offline = StubServer { _ in .failure(.cannotConnectToHost) }
        await #expect(throws: AnkiConnectError.offline) { try await client(offline).fetch(since: 0, knownReviewedToday: nil) }
        await #expect(throws: AnkiConnectError.denied) { try await client(anki(permission: "denied")).fetch(since: 0, knownReviewedToday: nil) }
        let forbidden = StubServer { _ in .http(403) }
        await #expect(throws: AnkiConnectError.denied) { try await client(forbidden).fetch(since: 0, knownReviewedToday: nil) }
        let failing = StubServer { _ in .json(200, ["result": NSNull(), "error": "collection is not available"]) }
        await #expect(throws: AnkiConnectError.failed("collection is not available")) { try await client(failing).fetch(since: 0, knownReviewedToday: nil) }
    }
}

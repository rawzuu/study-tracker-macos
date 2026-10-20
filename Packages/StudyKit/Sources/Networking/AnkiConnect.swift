import Foundation

/// Balíček nejvyšší úrovně a jeho dnešní počty (`DeckStat` v `anki.ts` na webu).
public struct AnkiConnectDeck: Sendable, Hashable {
    public let name: String
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let total: Int

    public init(name: String, newCount: Int, learnCount: Int, reviewCount: Int, total: Int) {
        self.name = name
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.total = total
    }

    var due: Int { newCount + learnCount + reviewCount }
}

/// Jedno zodpovězení karty: balíček nejvyšší úrovně, kdy (ms) a jak dlouho.
public struct AnkiConnectReview: Sendable, Hashable {
    public let deck: String
    public let time: Int
    public let durationMs: Int

    public init(deck: String, time: Int, durationMs: Int) {
        self.deck = deck
        self.time = time
        self.durationMs = durationMs
    }
}

/// Výsledek načtení (`AnkiFetch` na webu). `reviewsFetched == false` = historie se nestahovala,
/// protože od minula nepřibylo žádné opakování.
public struct AnkiConnectResult: Sendable, Hashable {
    public let decks: [AnkiConnectDeck]
    public let reviewedToday: Int
    public let reviews: [AnkiConnectReview]
    public let reviewsFetched: Bool

    public init(decks: [AnkiConnectDeck], reviewedToday: Int, reviews: [AnkiConnectReview], reviewsFetched: Bool) {
        self.decks = decks
        self.reviewedToday = reviewedToday
        self.reviews = reviews
        self.reviewsFetched = reviewsFetched
    }
}

public enum AnkiConnectError: Error, Equatable, Sendable, LocalizedError {
    /// Anki neběží nebo nemá doplněk AnkiConnect.
    case offline
    /// AnkiConnect připojení zamítl.
    case denied
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .offline: "Anki neběží, nebo v ní chybí doplněk AnkiConnect (kód 2055492159)."
        case .denied: "V Anki bylo připojení zamítnuto. Povol ho v nastavení doplňku AnkiConnect."
        case .failed(let message): message
        }
    }
}

/// Načtení stavu Anki – v aplikaci AnkiConnect, v testech podvrh (nikdy skutečná Anki).
public protocol AnkiConnecting: Sendable {
    /// Počty k opakování a historie opakování od `since` (ms). `knownReviewedToday` = kolik karet bylo
    /// dnes hotovo při minulém načtení – když se nezměnilo, historie se nestahuje znovu.
    func fetch(since: Int, knownReviewedToday: Int?) async throws(AnkiConnectError) -> AnkiConnectResult
}

/// Klient doplňku AnkiConnect v desktopové Anki (`anki.ts` na webu): stejné dotazy a stejné zpracování.
/// Anki musí běžet na tomto Macu; API poslouchá jen na 127.0.0.1:8765. Na rozdíl od prohlížeče
/// tu není omezení Safari ani CORS – požadavky bez hlavičky Origin AnkiConnect povoluje.
public struct AnkiConnectClient: AnkiConnecting {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8765")!

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = Self.defaultEndpoint, session: URLSession = .anki) {
        self.endpoint = endpoint
        self.session = session
    }

    public func fetch(since: Int, knownReviewedToday: Int?) async throws(AnkiConnectError) -> AnkiConnectResult {
        try await requestPermission()
        let names: [String] = try await invoke("deckNames")
        var tops: [String] = []
        for name in names.map(Self.topLevel) where !tops.contains(name) { tops.append(name) }
        let stats: [String: DeckStats] = try await invoke("getDeckStats", ["decks": tops])
        let decks = Self.sorted(stats)
        let reviewedToday: Int = try await invoke("getNumCardsReviewedToday")
        if let knownReviewedToday, knownReviewedToday == reviewedToday {
            return AnkiConnectResult(decks: decks, reviewedToday: reviewedToday, reviews: [], reviewsFetched: false)
        }
        // cardReviews vrací jen karty přímo v balíčku (ne v podbalíčcích) – ptáme se na všechny.
        var reviews: [AnkiConnectReview] = []
        for name in names {
            let rows: [[Double]] = try await invoke("cardReviews", ["deck": name, "startID": since])
            for r in rows where r.count > 7 {
                reviews.append(AnkiConnectReview(deck: Self.topLevel(name), time: Int(r[0]), durationMs: Int(r[7])))
            }
        }
        // `reviews.sort((a, b) => a.time - b.time)` – stabilní, při shodě v pořadí balíčků
        let ordered = reviews.enumerated().sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
        return AnkiConnectResult(decks: decks, reviewedToday: reviewedToday, reviews: ordered.map(\.element), reviewsFetched: true)
    }

    /// „Medicína::Anatomie“ → „Medicína“
    static func topLevel(_ name: String) -> String {
        String(name.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// Jako na webu: `Object.values` (číselné klíče = id balíčků vzestupně), jen neprázdné, podle počtu
    /// karet k opakování sestupně (stabilně).
    static func sorted(_ stats: [String: DeckStats]) -> [AnkiConnectDeck] {
        let byKey = stats.sorted { a, b in
            switch (Int(a.key), Int(b.key)) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.key < b.key
            }
        }
        let decks = byKey.map {
            AnkiConnectDeck(name: $0.value.name, newCount: $0.value.new_count, learnCount: $0.value.learn_count,
                            reviewCount: $0.value.review_count, total: $0.value.total_in_deck)
        }
        .filter { $0.total > 0 }
        return decks.enumerated().sorted { $0.element.due != $1.element.due ? $0.element.due > $1.element.due : $0.offset < $1.offset }.map(\.element)
    }

    struct DeckStats: Decodable {
        let name: String
        let new_count: Int
        let learn_count: Int
        let review_count: Int
        let total_in_deck: Int
    }

    private func requestPermission() async throws(AnkiConnectError) {
        struct Permission: Decodable { let permission: String }
        let result: Permission = try await invoke("requestPermission", timeout: 60)
        guard result.permission == "granted" else { throw .denied }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    private func invoke<T: Decodable>(_ action: String, _ params: [String: any Sendable] = [:], timeout: TimeInterval = 5) async throws(AnkiConnectError) -> T {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["action": action, "version": 6, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw .failed("Neplatný dotaz pro Anki.") }
        request.httpBody = data
        let response: (Data, URLResponse)
        do {
            response = try await session.data(for: request)
        } catch {
            throw .offline
        }
        if (response.1 as? HTTPURLResponse)?.statusCode == 403 { throw .denied }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: response.0) else {
            throw .failed("Anki odpověděla nečekaně (\(action)).")
        }
        if let error = envelope.error { throw .failed(error) }
        guard let result = envelope.result else { throw .failed("Anki odpověděla nečekaně (\(action)).") }
        return result
    }
}

extension URLSession {
    /// Pro Anki: bez mezipaměti a cookies, krátké čekání (Anki je na tomto Macu).
    public static let anki: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

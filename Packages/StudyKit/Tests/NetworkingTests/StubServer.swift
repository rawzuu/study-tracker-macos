import Foundation
import Synchronization
@testable import Networking

/// Podvržený GitHub: odpovědi vrací `URLProtocol`, nic neodchází do sítě.
/// Každý test má vlastní smyšlený host, takže testy můžou běžet souběžně.
final class StubServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    enum Response: Sendable {
        case http(Int, body: Data = Data(), headers: [String: String] = [:])
        case failure(URLError.Code)

        static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Response {
            .http(status, body: try! JSONSerialization.data(withJSONObject: object), headers: headers)
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    let handler: Handler
    private let log = Mutex<[Request]>([])

    /// Server zůstane zaregistrovaný do konce běhu testů – je malý a host se neopakuje.
    init(_ handler: @escaping Handler) {
        self.handler = handler
        StubProtocol.servers.withLock { $0[host] = self }
    }

    var baseURL: URL { URL(string: "https://\(host)")! }
    var requests: [Request] { log.withLock { $0 } }

    func client(token: String = "github_pat_TEST") -> GitHubClient {
        GitHubClient(token: token, session: StubProtocol.session, baseURL: baseURL)
    }

    fileprivate func respond(to request: URLRequest) -> Response {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            path: components.percentEncodedPath,
            query: components.percentEncodedQuery,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        log.withLock { $0.append(recorded) }
        return handler(recorded)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: StubServer]>([:])

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let server = Self.servers.withLock { $0[request.url?.host() ?? ""] }
        guard let server else { return client!.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
        switch server.respond(to: request) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

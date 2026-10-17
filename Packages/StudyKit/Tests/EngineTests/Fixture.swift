import Foundation

/// Kontrolní data vygenerovaná z kódu webové aplikace (Tools/parity/generate.ts).
enum Fixture {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = try require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.fileNoSuchFile) }
    return value
}

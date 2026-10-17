import Foundation
import Testing
@testable import Core

/// Paritní testy: výstup musí být bajtově shodný s webovou aplikací (verze v Fixtures/meta.json).
@Suite("Parita s webem") struct ParityTests {
    struct NumberCase: Decodable { let bits: String; let js: String }
    struct StringCase: Decodable { let codePoints: [UInt32]; let js: String }
    struct DocumentCase: Decodable { let text: String; let compact: String; let pretty: String }
    struct MergeCase: Decodable {
        let local: String
        let remote: String
        let normalizedLocal: String?
        let normalizedRemote: String?
        let merged: String
        let mergedReversed: String
        let hasNewerLocalRemote: Bool
        let hasNewerRemoteLocal: Bool
    }
    struct ErrorCase: Decodable { let text: String; let error: String }

    @Test("Čísla jako Number::toString") func numbers() throws {
        let cases = try Fixture.load("numbers", as: [NumberCase].self)
        #expect(cases.count > 1000)
        for c in cases {
            let value = Double(bitPattern: UInt64(c.bits, radix: 16)!)
            let swift = JSONValue.number(value).serialized()
            #expect(swift == c.js, "číslo \(value) (\(c.bits))")
        }
    }

    @Test("Escapování řetězců jako JSON.stringify") func strings() throws {
        for c in try Fixture.load("strings", as: [StringCase].self) {
            var s = ""
            s.unicodeScalars.append(contentsOf: c.codePoints.map { Unicode.Scalar($0)! })
            #expect(JSONValue.string(s).serialized() == c.js)
        }
    }

    @Test("Čtení a zápis dokumentů (pořadí klíčů, escape sekvence, čísla)") func documents() throws {
        for c in try Fixture.load("documents", as: [DocumentCase].self) {
            let value = try JSONValue.parse(c.text)
            #expect(value.serialized() == c.compact, "kompaktně: \(c.text)")
            #expect(value.serialized(indent: 1) == c.pretty, "odsazeně: \(c.text)")
        }
    }

    @Test("Migrace, slučování a hasNewer") func merges() throws {
        let cases = try Fixture.load("merges", as: [MergeCase].self)
        for (i, c) in cases.enumerated() {
            let local = try AppDocument(normalizing: JSONValue.parse(c.local))
            let remote = try AppDocument(normalizing: JSONValue.parse(c.remote))
            if let expected = c.normalizedLocal { #expect(Merge.serialize(local) == expected, "normalizace local #\(i)") }
            if let expected = c.normalizedRemote { #expect(Merge.serialize(remote) == expected, "normalizace remote #\(i)") }
            #expect(Merge.serialize(Merge.mergeData(local: local, remote: remote)) == c.merged, "merge #\(i)")
            #expect(Merge.serialize(Merge.mergeData(local: remote, remote: local)) == c.mergedReversed, "merge obráceně #\(i)")
            #expect(Merge.hasNewer(local: local, incoming: remote) == c.hasNewerLocalRemote, "hasNewer #\(i)")
            #expect(Merge.hasNewer(local: remote, incoming: local) == c.hasNewerRemoteLocal, "hasNewer obráceně #\(i)")
        }
    }

    @Test("Novější nebo neznámá verze dat se odmítne") func schemaErrors() throws {
        for c in try Fixture.load("migrate-errors", as: [ErrorCase].self) {
            #expect {
                try AppDocument(normalizing: JSONValue.parse(c.text))
            } throws: { error in
                switch error as? SchemaError {
                case .tooNew: c.error == "tooNew"
                case .missingMigration: c.error == "missingMigration"
                case nil: false
                }
            }
        }
    }

    @Test("Prázdná data jako emptyData()") func empty() throws {
        struct Empty: Decodable { let serialized: String }
        let expected = try Fixture.load("empty", as: Empty.self).serialized
        #expect(Merge.serialize(.empty) == expected)
        #expect(Merge.serialize(try AppDocument(normalizing: .object([:]))) == expected)
    }
}

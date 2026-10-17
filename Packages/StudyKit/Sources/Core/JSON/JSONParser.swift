import Foundation

public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "Neplatný JSON na pozici \(offset): \(reason)" }
}

extension JSONValue {
    /// Přečte JSON stejně jako `JSON.parse` (striktní gramatika, duplicitní klíč – vyhrává poslední).
    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        var text = text
        return try JSONParser.run { try text.withUTF8 { try JSONParser($0).parseDocument() } }
    }

    public static func parse(_ data: Data) throws(JSONParseError) -> JSONValue {
        try JSONParser.run { try data.withUnsafeBytes { try JSONParser($0.bindMemory(to: UInt8.self)).parseDocument() } }
    }
}

struct JSONParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var pos = 0
    private var depth = 0
    private static let maxDepth = 512

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    /// `withUTF8`/`withUnsafeBytes` jsou `rethrows`, takže typ chyby ztratí – tady ho vrátíme.
    static func run(_ body: () throws -> JSONValue) throws(JSONParseError) -> JSONValue {
        do {
            return try body()
        } catch let error as JSONParseError {
            throw error
        } catch {
            throw JSONParseError(offset: 0, reason: "\(error)")
        }
    }

    consuming func parseDocument() throws(JSONParseError) -> JSONValue {
        // UTF-8 BOM tolerujeme (JSON.parse by na něm spadl, ale data tím nic neztratí).
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard pos == bytes.count else { throw fail("nečekaný znak za koncem dokumentu") }
        return value
    }

    private func fail(_ reason: String) -> JSONParseError { JSONParseError(offset: pos, reason: reason) }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D: pos += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws(JSONParseError) -> JSONValue {
        guard pos < bytes.count else { throw fail("neočekávaný konec") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw fail("neočekávaný znak")
        }
    }

    private mutating func expect(_ literal: StaticString) throws(JSONParseError) {
        let count = literal.utf8CodeUnitCount
        guard pos + count <= bytes.count else { throw fail("neočekávaný konec") }
        let start = literal.utf8Start
        for i in 0..<count where bytes[pos + i] != start[i] {
            throw fail("neplatný literál")
        }
        pos += count
    }

    private mutating func enter() throws(JSONParseError) {
        depth += 1
        if depth > Self.maxDepth { throw fail("příliš hluboké zanoření") }
    }

    private mutating func parseObject() throws(JSONParseError) -> JSONObject {
        try enter()
        defer { depth -= 1 }
        pos += 1
        var object = JSONObject()
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
            pos += 1
            return object
        }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("očekáván klíč") }
            let key = try parseString()
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("očekávána dvojtečka") }
            pos += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard pos < bytes.count else { throw fail("neočekávaný konec") }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
            } else if bytes[pos] == UInt8(ascii: "}") {
                pos += 1
                return object
            } else {
                throw fail("očekávána čárka nebo }")
            }
        }
    }

    private mutating func parseArray() throws(JSONParseError) -> [JSONValue] {
        try enter()
        defer { depth -= 1 }
        pos += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
            pos += 1
            return array
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard pos < bytes.count else { throw fail("neočekávaný konec") }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
            } else if bytes[pos] == UInt8(ascii: "]") {
                pos += 1
                return array
            } else {
                throw fail("očekávána čárka nebo ]")
            }
        }
    }

    private mutating func parseString() throws(JSONParseError) -> String {
        pos += 1
        let start = pos
        // Rychlá cesta: řetězec bez escape sekvencí se jen dekóduje z UTF-8.
        while pos < bytes.count {
            let byte = bytes[pos]
            if byte == UInt8(ascii: "\"") {
                let slice = UnsafeBufferPointer(rebasing: bytes[start..<pos])
                pos += 1
                return String(decoding: slice, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw fail("řídicí znak v řetězci") }
            pos += 1
        }
        var out = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<pos]))
        while pos < bytes.count {
            let byte = bytes[pos]
            switch byte {
            case UInt8(ascii: "\""):
                pos += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                pos += 1
                guard pos < bytes.count else { throw fail("neočekávaný konec") }
                let esc = bytes[pos]
                pos += 1
                switch esc {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): appendScalar(try parseUnicodeEscape(), to: &out)
                default: throw fail("neplatná escape sekvence")
                }
            default:
                if byte < 0x20 { throw fail("řídicí znak v řetězci") }
                out.append(byte)
                pos += 1
            }
        }
        throw fail("neukončený řetězec")
    }

    /// `\uXXXX`, případně dvojice náhradních znaků. Osamocený náhradní znak se nahradí U+FFFD
    /// (Swift ho v řetězci neumí uložit; v datech aplikace se nevyskytuje).
    private mutating func parseUnicodeEscape() throws(JSONParseError) -> Unicode.Scalar {
        let high = try parseHex4()
        if (0xD800...0xDBFF).contains(high) {
            if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                let save = pos
                pos += 2
                let low = try parseHex4()
                if (0xDC00...0xDFFF).contains(low) {
                    return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))!
                }
                pos = save
            }
            return "\u{FFFD}"
        }
        if (0xDC00...0xDFFF).contains(high) { return "\u{FFFD}" }
        return Unicode.Scalar(high)!
    }

    private mutating func parseHex4() throws(JSONParseError) -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail("neočekávaný konec") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[pos]
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            default: throw fail("neplatná hexadecimální číslice")
            }
            value = value << 4 | UInt32(digit)
            pos += 1
        }
        return value
    }

    private func appendScalar(_ scalar: Unicode.Scalar, to out: inout [UInt8]) {
        out.append(contentsOf: UTF8.encode(scalar)!)
    }

    private mutating func parseNumber() throws(JSONParseError) -> Double {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        guard pos < bytes.count else { throw fail("neúplné číslo") }
        if bytes[pos] == UInt8(ascii: "0") {
            pos += 1
        } else if isDigit(bytes[pos]) {
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        } else {
            throw fail("neúplné číslo")
        }
        var simple = true
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            simple = false
            pos += 1
            guard pos < bytes.count, isDigit(bytes[pos]) else { throw fail("neúplné desetinné číslo") }
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            simple = false
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard pos < bytes.count, isDigit(bytes[pos]) else { throw fail("neúplný exponent") }
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<pos])
        // Rychlá cesta pro celá čísla do 15 číslic (časy v ms, počty) – převod je přesný.
        if simple, slice.count <= 16 {
            var negative = false
            var value: Int64 = 0
            for byte in slice {
                if byte == UInt8(ascii: "-") { negative = true } else { value = value * 10 + Int64(byte - 0x30) }
            }
            if value == 0 && negative { return -0.0 }
            return Double(negative ? -value : value)
        }
        guard let value = Double(String(decoding: slice, as: UTF8.self)) else { throw fail("neplatné číslo") }
        return value
    }

    @inline(__always) private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
}

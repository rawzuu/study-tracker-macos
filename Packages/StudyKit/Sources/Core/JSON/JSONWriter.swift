import Foundation

extension JSONValue {
    /// Zapíše hodnotu stejně jako `JSON.stringify(value, null, indent)` v JavaScriptu – bajt po bajtu.
    /// `indent: nil` = kompaktní zápis.
    public func serialized(indent: Int? = nil) -> String {
        var writer = JSONWriter(gap: indent.map { String(repeating: " ", count: min($0, 10)) } ?? "")
        writer.write(self, indentation: "")
        return String(decoding: writer.out, as: UTF8.self)
    }
}

struct JSONWriter {
    private(set) var out: [UInt8] = []
    private let gap: [UInt8]

    init(gap: String) {
        self.gap = Array(gap.utf8)
        out.reserveCapacity(64 * 1024)
    }

    mutating func write(_ value: JSONValue, indentation: [UInt8]) {
        switch value {
        case .null: append("null")
        case .bool(let b): append(b ? "true" : "false")
        case .number(let n): out.append(contentsOf: JSNumber.format(n).utf8)
        case .string(let s): writeString(s)
        case .array(let items):
            guard !items.isEmpty else { return append("[]") }
            let inner = indentation + gap
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(inner)
                write(item, indentation: inner)
            }
            newline(indentation)
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            guard !object.isEmpty else { return append("{}") }
            let inner = indentation + gap
            out.append(UInt8(ascii: "{"))
            for (i, (key, item)) in object.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(inner)
                writeString(key)
                out.append(UInt8(ascii: ":"))
                if !gap.isEmpty { out.append(UInt8(ascii: " ")) }
                write(item, indentation: inner)
            }
            newline(indentation)
            out.append(UInt8(ascii: "}"))
        }
    }

    mutating func write(_ value: JSONValue, indentation: String) {
        write(value, indentation: Array(indentation.utf8))
    }

    private mutating func newline(_ indentation: [UInt8]) {
        guard !gap.isEmpty else { return }
        out.append(0x0A)
        out.append(contentsOf: indentation)
    }

    private mutating func append(_ s: StaticString) {
        out.append(contentsOf: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    /// Escapuje jen to, co JS: uvozovky, zpětné lomítko a řídicí znaky. Lomítko `/` ani diakritiku ne.
    private mutating func writeString(_ s: String) {
        out.append(UInt8(ascii: "\""))
        for byte in s.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Převod čísla na text podle ECMAScript `Number::toString` (to používá `JSON.stringify`).
public enum JSNumber {
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }  // i −0
        // Rychlá cesta: celá čísla do 2⁵³ (časy, počty) jsou přesná.
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        let (digits, n) = shortestDigits(abs(value))
        let sign = value < 0 ? "-" : ""
        let k = digits.count
        if k <= n && n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            return sign + digits[..<i] + "." + digits[i...]
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let e = n - 1
        let exp = e < 0 ? "e-\(-e)" : "e+\(e)"
        if k == 1 { return sign + digits + exp }
        return sign + digits.prefix(1) + "." + digits.dropFirst() + exp
    }

    /// Nejkratší číslice, které jednoznačně určují `value`, a exponent `n` tak, že value = 0,d₁d₂… × 10ⁿ.
    /// Swift `description` dává nejkratší přesný zápis (stejné pravidlo jako JS), jen v jiném tvaru.
    static func shortestDigits(_ value: Double) -> (String, Int) {
        let text = value.description
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...])!
        }
        var digits = ""
        var pointPos: Int?
        for ch in mantissa {
            if ch == "." { pointPos = digits.count } else { digits.append(ch) }
        }
        var n = (pointPos ?? digits.count) + exponent
        while digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        return (digits, n)
    }
}

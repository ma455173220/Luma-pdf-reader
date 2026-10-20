import Foundation

/// Why the append writer would not touch a file.
///
/// The writer's rule is "when in doubt, refuse": a file it does not fully understand is left
/// exactly as it is, and the reader is told it cannot be annotated.
public enum PDFAppendError: Error, Equatable, CustomStringConvertible {
    /// The file is understood, and deliberately left alone (password, signature, size…).
    case refused(String)
    /// One of the changes asked for is deliberately not made (its place in the list given, and
    /// why); nothing is written. The rest could be saved without it.
    case refusedChange(Int, String)
    /// The file's structure is not strictly valid. Readers open such files by repairing them
    /// on the fly; appending to one could stop that repair from happening.
    case damaged(String)
    /// The writer's own output failed its read-back check. Always a bug in the writer.
    case selfCheckFailed(String)

    public var description: String {
        switch self {
        case .refused(let why): return "refused: \(why)"
        case .refusedChange(let position, let why): return "refused: \(why) (change \(position))"
        case .damaged(let why): return "damaged: \(why)"
        case .selfCheckFailed(let why): return "self-check failed: \(why)"
        }
    }
}

indirect enum PDFNode {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    case string
    case array([PDFValue])
    case dict([PDFDictEntry])
    case ref(Int, Int)
}

struct PDFDictEntry {
    /// The key with `#xx` escapes decoded, for comparing.
    let key: String
    /// The key exactly as written in the file, for copying out unchanged.
    let rawKey: ArraySlice<UInt8>
    let value: PDFValue
}

/// A parsed value plus the exact source bytes it came from, so it can be copied out unchanged.
struct PDFValue {
    let node: PDFNode
    let raw: ArraySlice<UInt8>

    static let null = PDFValue(node: .null, raw: [])

    var isNull: Bool { if case .null = node { return true }; return false }
    var int: Int? { if case .int(let v) = node { return v }; return nil }
    /// Any number, whole or not.
    var number: Double? {
        switch node {
        case .int(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }
    var name: String? { if case .name(let v) = node { return v }; return nil }
    var array: [PDFValue]? { if case .array(let v) = node { return v }; return nil }
    var entries: [PDFDictEntry]? { if case .dict(let v) = node { return v }; return nil }
    var reference: (number: Int, generation: Int)? { if case .ref(let n, let g) = node { return (n, g) }; return nil }

    subscript(key: String) -> PDFValue? { entries?.first { $0.key == key }?.value }
}

struct PDFParser {
    let bytes: [UInt8]
    var index: Int
    /// How many lists and dictionaries deep the parser currently is. Capped so that a file made of
    /// thousands of nested brackets is refused instead of exhausting the stack.
    private var depth = 0
    static let maximumDepth = 64

    init(_ bytes: [UInt8], at index: Int) {
        self.bytes = bytes
        self.index = min(max(index, 0), bytes.count)
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    func matches(_ keyword: String) -> Bool {
        let k = Array(keyword.utf8)
        guard index + k.count <= bytes.count else { return false }
        for j in 0..<k.count where bytes[index + j] != k[j] { return false }
        return true
    }

    mutating func skipSpace() {
        while index < bytes.count {
            let c = bytes[index]
            if PDFParser.isSpace(c) {
                index += 1
            } else if c == 0x25 {
                while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 { index += 1 }
            } else {
                break
            }
        }
    }

    /// The next run of ordinary characters, or an empty string at a delimiter or the end.
    mutating func token() -> String {
        skipSpace()
        let start = index
        while index < bytes.count && !PDFParser.isSpace(bytes[index]) && !PDFParser.isDelimiter(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// A whole number written with digits only; anything else is nil.
    mutating func unsignedInteger() -> Int? {
        let word = token()
        guard !word.isEmpty, word.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(word)
    }

    private static func decodeName(_ raw: ArraySlice<UInt8>) -> String {
        var decoded: [UInt8] = []
        var i = raw.startIndex
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < raw.endIndex {
            if raw[i] == 0x23, i + 2 < raw.endIndex, let high = hex(raw[i + 1]), let low = hex(raw[i + 2]) {
                decoded.append(high << 4 | low)
                i += 3
            } else {
                decoded.append(raw[i])
                i += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    mutating func value() throws -> PDFValue {
        skipSpace()
        guard index < bytes.count else { throw PDFAppendError.damaged("data ends in the middle of an object") }
        let start = index
        switch bytes[index] {
        case 0x2F:  // name
            index += 1
            let nameStart = index
            while index < bytes.count && !PDFParser.isSpace(bytes[index]) && !PDFParser.isDelimiter(bytes[index]) { index += 1 }
            return PDFValue(node: .name(PDFParser.decodeName(bytes[nameStart..<index])), raw: bytes[start..<index])
        case 0x28:  // literal string
            var depth = 0
            var closed = false
            while index < bytes.count {
                let c = bytes[index]
                if c == 0x5C { index += 2; continue }
                if c == 0x28 { depth += 1 }
                if c == 0x29 {
                    depth -= 1
                    if depth == 0 { index += 1; closed = true; break }
                }
                index += 1
            }
            guard closed, index <= bytes.count else { throw PDFAppendError.damaged("text string never closes") }
            return PDFValue(node: .string, raw: bytes[start..<index])
        case 0x3C:
            if index + 1 < bytes.count && bytes[index + 1] == 0x3C {  // dictionary
                depth += 1
                defer { depth -= 1 }
                guard depth <= PDFParser.maximumDepth else { throw PDFAppendError.damaged("objects are nested too deeply") }
                index += 2
                var entries: [PDFDictEntry] = []
                while true {
                    skipSpace()
                    guard index < bytes.count else { throw PDFAppendError.damaged("dictionary never closes") }
                    if bytes[index] == 0x3E && index + 1 < bytes.count && bytes[index + 1] == 0x3E { index += 2; break }
                    let key = try value()
                    guard let keyName = key.name else { throw PDFAppendError.damaged("dictionary key is not a name") }
                    entries.append(PDFDictEntry(key: keyName, rawKey: key.raw, value: try value()))
                }
                return PDFValue(node: .dict(entries), raw: bytes[start..<index])
            }
            while index < bytes.count && bytes[index] != 0x3E { index += 1 }  // hex string
            guard index < bytes.count else { throw PDFAppendError.damaged("hex string never closes") }
            index += 1
            return PDFValue(node: .string, raw: bytes[start..<index])
        case 0x5B:  // array
            depth += 1
            defer { depth -= 1 }
            guard depth <= PDFParser.maximumDepth else { throw PDFAppendError.damaged("objects are nested too deeply") }
            index += 1
            var items: [PDFValue] = []
            while true {
                skipSpace()
                guard index < bytes.count else { throw PDFAppendError.damaged("list never closes") }
                if bytes[index] == 0x5D { index += 1; break }
                items.append(try value())
            }
            return PDFValue(node: .array(items), raw: bytes[start..<index])
        default:
            let word = token()
            let end = index
            guard !word.isEmpty else { throw PDFAppendError.damaged("unexpected character in an object") }
            if word == "true" { return PDFValue(node: .bool(true), raw: bytes[start..<end]) }
            if word == "false" { return PDFValue(node: .bool(false), raw: bytes[start..<end]) }
            if word == "null" { return PDFValue(node: .null, raw: bytes[start..<end]) }
            if let number = Int(word) {
                // "12 0 R" is a reference; a lone "12" is a number.
                if number >= 0, let generation = unsignedInteger() {
                    skipSpace()
                    if index < bytes.count && bytes[index] == 0x52
                        && (index + 1 >= bytes.count || PDFParser.isSpace(bytes[index + 1]) || PDFParser.isDelimiter(bytes[index + 1])) {
                        index += 1
                        return PDFValue(node: .ref(number, generation), raw: bytes[start..<index])
                    }
                }
                index = end
                return PDFValue(node: .int(number), raw: bytes[start..<end])
            }
            if let number = Double(word), number.isFinite { return PDFValue(node: .real(number), raw: bytes[start..<end]) }
            throw PDFAppendError.damaged("unrecognised word in an object")
        }
    }
}

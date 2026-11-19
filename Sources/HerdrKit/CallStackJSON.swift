import Foundation

/// An iterative JSON tokenizer for MetricKit's call-stack trees. In
/// `MXCallStackTree.jsonRepresentation()` each frame nests its callers in `subFrames`, two
/// levels of JSON per frame, so a 300-frame stack is 600 levels deep. `JSONSerialization`
/// refuses input nested more than 512 levels on Linux and on Apple platforms, and a stack
/// overflow's tree is thousands of frames deep. This reads any depth with no recursion.
struct JSONTokens {
    enum Token: Equatable {
        case objectStart, objectEnd, arrayStart, arrayEnd
        /// An object member's name.
        case key(String)
        case string(String)
        /// An integer that fits `Int`, or a whole `Double`; nil for any other number.
        case number(Int?)
        case bool(Bool)
        case null
    }

    private let bytes: [UInt8]
    private(set) var position = 0
    /// One entry per open container: true for an object.
    private var open: [Bool] = []
    /// In an object, whether the next string is a member name.
    private var expectKey = false
    private(set) var failed = false

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var depth: Int { open.count }

    /// The next token, or nil at the end of the input or on malformed input (`failed`).
    mutating func next() -> Token? {
        while !failed {
            skipSpace()
            guard position < bytes.count else {
                if !open.isEmpty { failed = true }
                return nil
            }
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "{"):
                position += 1
                open.append(true)
                expectKey = true
                return .objectStart
            case UInt8(ascii: "["):
                position += 1
                open.append(false)
                expectKey = false
                return .arrayStart
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                let isObject = byte == UInt8(ascii: "}")
                guard open.last == isObject else { return fail() }
                position += 1
                open.removeLast()
                expectKey = false
                return isObject ? .objectEnd : .arrayEnd
            case UInt8(ascii: ","):
                guard !open.isEmpty else { return fail() }
                position += 1
                expectKey = open.last == true
            case UInt8(ascii: ":"):
                position += 1
            case UInt8(ascii: "\""):
                guard let text = string() else { return fail() }
                if expectKey {
                    expectKey = false
                    return .key(text)
                }
                return .string(text)
            case UInt8(ascii: "t"):
                return literal("true", .bool(true))
            case UInt8(ascii: "f"):
                return literal("false", .bool(false))
            case UInt8(ascii: "n"):
                return literal("null", .null)
            default:
                guard let value = number() else { return fail() }
                return .number(value)
            }
        }
        return nil
    }

    /// Skips the value whose first token was just read (`first`), however deep.
    mutating func skip(after first: Token) {
        guard first == .objectStart || first == .arrayStart else { return }
        let target = depth - 1
        while depth > target, next() != nil {}
    }

    private mutating func fail() -> Token? {
        failed = true
        return nil
    }

    private mutating func skipSpace() {
        while position < bytes.count,
              [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(bytes[position]) {
            position += 1
        }
    }

    private mutating func literal(_ word: String, _ token: Token) -> Token? {
        let utf8 = Array(word.utf8)
        guard position + utf8.count <= bytes.count, Array(bytes[position..<position + utf8.count]) == utf8 else {
            return fail()
        }
        position += utf8.count
        return token
    }

    private mutating func number() -> Int?? {
        let start = position
        while position < bytes.count, "+-0123456789.eE".utf8.contains(bytes[position]) { position += 1 }
        guard position > start else { return nil }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        if let int = Int(text) { return .some(int) }
        guard let double = Double(text) else { return nil }
        return .some(double.rounded() == double ? Int(exactly: double) : nil)
    }

    /// The string at `position` (its opening quote), unescaped.
    private mutating func string() -> String? {
        position += 1
        var scalars = String.UnicodeScalarView()
        var run = position
        func flush(_ end: Int) {
            scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars)
        }
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                flush(position)
                position += 1
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                position += 1
                continue
            }
            flush(position)
            guard position + 1 < bytes.count else { return nil }
            let escaped = bytes[position + 1]
            position += 2
            switch escaped {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): scalars.append(Unicode.Scalar(escaped))
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                guard position + 4 <= bytes.count,
                      let code = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
                else { return nil }
                position += 4
                // Surrogates (never in what a report keeps, which is ASCII) become U+FFFD.
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                return nil
            }
            run = position
        }
        return nil
    }
}

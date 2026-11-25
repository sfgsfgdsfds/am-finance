import CryptoKit
import Foundation

/// A JSON value kept as an AST. The `data` payloads on the sync wire are
/// backup-v5 DTOs whose types live in the app target — this package only
/// needs to carry them verbatim, embed them in requests, and hash them
/// canonically.
public enum SyncJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// Integer literals that fit `Int64` — VND amounts and seqs are always
    /// integers, and `Int64` keeps them exact where `Double` would not.
    case int(Int64)
    /// Literals with a fraction/exponent (and integers too big for
    /// `Int64`).
    case double(Double)
    case string(String)
    case array([SyncJSONValue])
    /// Key order is not preserved (irrelevant on the wire); a duplicate
    /// key keeps its last value, like every other JSON reader.
    case object([String: SyncJSONValue])
}

extension SyncJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SyncJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Failures of the strict JSON reader.
public enum SyncJSONError: Error, Equatable, Sendable {
    /// Input is not a single well-formed JSON document.
    case malformedJSON
}

/// A JSON scalar as the sync DTO encoder emits it — every field type the
/// backup-v5 DTOs carry, tagged so the canonical writer needs no AST to
/// know which normalizations apply. `SyncContentHasher.hash(fields:)`
/// renders these byte-identically to `SyncJSONValue.canonicalData()` on
/// the equivalent document — the same digest, without the
/// encode → parse → canonicalize round trip.
public enum SyncCanonicalScalar: Sendable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    /// A timestamp — emits `YYYY-MM-DDTHH:MM:SS.sssZ`, rounded to the
    /// nearest millisecond like the wire's ISO-8601 rendering (and the
    /// server's stored form).
    case date(Date)
    /// A UUID — emits its lowercase string.
    case uuid(UUID)
    /// A plain string — `SyncCanonical.content` normalization still
    /// applies: a user string that merely LOOKS like a UUID or an
    /// ISO-8601 timestamp is canonicalized exactly as the parse-then-
    /// canonicalize pipeline would.
    case string(String)
}

extension SyncJSONValue {
    /// Strict JSON per RFC 8259: no comments, no trailing data, numbers
    /// must be finite. This is the exact shape the sync wire carries.
    public init(jsonData: Data) throws {
        var parser = SyncJSONParser(Array(jsonData))
        self = try parser.parseDocument()
    }

    public init(jsonString: String) throws {
        try self.init(jsonData: Data(jsonString.utf8))
    }
}

/// The canonical byte encoding used for content hashing: object keys
/// sorted, insignificant whitespace gone, numbers in shortest form
/// (`12` never `12.0`), string contents with UUIDs lowercased and
/// ISO-8601 timestamps normalized to `…T…sssZ` (UTC, milliseconds —
/// what the server stores and returns). Two byte-different encodings of
/// the same record — the app's backup encoder and the server's ledger
/// writer — hash identically.
extension SyncJSONValue {
    public func canonicalData() -> Data {
        var bytes: [UInt8] = []
        appendCanonical(to: &bytes)
        return Data(bytes)
    }

    private func appendCanonical(to bytes: inout [UInt8]) {
        switch self {
        case .null:
            bytes.append(contentsOf: [UInt8]("null".utf8))
        case .bool(let value):
            bytes.append(contentsOf: [UInt8]((value ? "true" : "false").utf8))
        case .int(let value):
            bytes.append(contentsOf: [UInt8](String(value).utf8))
        case .double(let value):
            bytes.append(contentsOf: [UInt8](SyncCanonical.number(value).utf8))
        case .string(let value):
            SyncCanonical.appendString(SyncCanonical.content(value), to: &bytes)
        case .array(let values):
            bytes.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                value.appendCanonical(to: &bytes)
            }
            bytes.append(UInt8(ascii: "]"))
        case .object(let members):
            bytes.append(UInt8(ascii: "{"))
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                SyncCanonical.appendString(key, to: &bytes)
                bytes.append(UInt8(ascii: ":"))
                members[key]?.appendCanonical(to: &bytes)
            }
            bytes.append(UInt8(ascii: "}"))
        }
    }
}

enum SyncCanonical {
    /// Canonical number form: integral values inside ±2^53 print as
    /// integers (matching the server's shortest-form `12`, not `12.0`),
    /// `-0` collapses to `0`, everything else keeps Swift's shortest
    /// round-trip rendering.
    static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value == value.rounded(.towardZero), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(describing: value)
    }

    /// Content normalization for string values: UUIDs lowercase and
    /// ISO-8601 timestamps emit `YYYY-MM-DDTHH:MM:SS.sssZ`. Anything that
    /// does not match those shapes passes through unchanged.
    static func content(_ string: String) -> String {
        if isUUIDShape(string) { return string.lowercased() }
        if let timestamp = normalizeTimestamp(string) { return timestamp }
        return string
    }

    /// `"…"` with only the escapes JSON requires: `"` `\` and control
    /// characters below 0x20 (named escapes where one exists, `\u00XX`
    /// otherwise). `/` is never escaped and non-ASCII bytes pass through.
    static func appendString(_ string: String, to bytes: inout [UInt8]) {
        bytes.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": bytes.append(contentsOf: [UInt8](#""\"""#.utf8))
            case "\\": bytes.append(contentsOf: [UInt8](#"\\"#.utf8))
            case "\n": bytes.append(contentsOf: [UInt8](#"\n"#.utf8))
            case "\r": bytes.append(contentsOf: [UInt8](#"\r"#.utf8))
            case "\t": bytes.append(contentsOf: [UInt8](#"\t"#.utf8))
            case "\u{08}": bytes.append(contentsOf: [UInt8](#"\b"#.utf8))
            case "\u{0C}": bytes.append(contentsOf: [UInt8](#"\f"#.utf8))
            default:
                if scalar.value < 0x20 {
                    let hex = String(format: "\\u%04x", scalar.value)
                    bytes.append(contentsOf: [UInt8](hex.utf8))
                } else {
                    bytes.append(contentsOf: [UInt8](String(scalar).utf8))
                }
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, hex digits either case.
    static func isUUIDShape(_ string: String) -> Bool {
        let chars = Array(string.utf8)
        guard chars.count == 36 else { return false }
        for (index, char) in chars.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard char == UInt8(ascii: "-") else { return false }
            default:
                let isHex = (char >= UInt8(ascii: "0") && char <= UInt8(ascii: "9"))
                    || (char >= UInt8(ascii: "a") && char <= UInt8(ascii: "f"))
                    || (char >= UInt8(ascii: "A") && char <= UInt8(ascii: "F"))
                guard isHex else { return false }
            }
        }
        return true
    }

    /// If `string` parses as an ISO-8601 date-time (`Z` or numeric
    /// offset, fractional seconds optional), returns its canonical
    /// `…T…sssZ` form — truncated to milliseconds like the server.
    private static func normalizeTimestamp(_ string: String) -> String? {
        let chars = Array(string.utf8)
        guard chars.count >= 20,
              chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-"),
              chars[10] == UInt8(ascii: "T") || chars[10] == UInt8(ascii: "t"),
              chars[13] == UInt8(ascii: ":"), chars[16] == UInt8(ascii: ":"),
              isDigit(chars[0]), isDigit(chars[1]), isDigit(chars[2]), isDigit(chars[3]),
              isDigit(chars[5]), isDigit(chars[6]),
              isDigit(chars[8]), isDigit(chars[9]),
              isDigit(chars[11]), isDigit(chars[12]),
              isDigit(chars[14]), isDigit(chars[15]),
              isDigit(chars[17]), isDigit(chars[18])
        else { return nil }

        var date: Date?
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(string) {
            date = parsed
        } else if let parsed = try? Date.ISO8601FormatStyle().parse(string) {
            date = parsed
        }
        guard let date else { return nil }

        // The server truncates to milliseconds — hash the same value it
        // will store, so a pulled record matches its pushed twin.
        return render(epochMs: Int64(
            (date.timeIntervalSince1970 * 1000).rounded(.towardZero)))
    }

    /// `YYYY-MM-DDTHH:MM:SS.sssZ` for a `Date` — the rendering both the
    /// string normalizer above and `SyncCanonicalScalar.date` share, so
    /// the direct DTO hash is byte-identical to the canonicalized JSON.
    /// `rounding` picks the ms reduction: `.towardZero` for parsed
    /// timestamps (the server truncates), `.toNearestOrAwayFromZero` for
    /// live dates (the wire's ISO-8601 writer rounds).
    static func timestamp(
        _ date: Date, rounding: FloatingPointRoundingRule
    ) -> String {
        render(epochMs: Int64(
            (date.timeIntervalSince1970 * 1000).rounded(rounding)))
            ?? "1970-01-01T00:00:00.000Z"
    }

    /// `%04d-…-.%03dZ` of `epochMs` — including the negative-ms quirk
    /// (`epochMs % 1000`) pre-1970 instants produce, kept so both paths
    /// agree byte-for-byte.
    private static func render(epochMs: Int64) -> String? {
        let truncated = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: truncated)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second
        else { return nil }
        let ms = Int(epochMs % 1000)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            year, month, day, hour, minute, second, ms)
    }

    private static func isDigit(_ char: UInt8) -> Bool {
        char >= UInt8(ascii: "0") && char <= UInt8(ascii: "9")
    }
}

extension SyncCanonical {
    /// Canonical `{"k":v,…}` bytes built straight from typed DTO fields:
    /// keys sorted, each scalar rendered exactly as `SyncJSONValue`'s
    /// canonicalizer renders the equivalent AST node. Nil optionals are
    /// simply absent from `fields`, like the JSON they stand for.
    static func objectData(_ fields: [(String, SyncCanonicalScalar)]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(fields.count * 24)
        bytes.append(UInt8(ascii: "{"))
        for (index, field) in fields.sorted(by: { $0.0 < $1.0 }).enumerated() {
            if index > 0 { bytes.append(UInt8(ascii: ",")) }
            appendString(field.0, to: &bytes)
            bytes.append(UInt8(ascii: ":"))
            appendScalar(field.1, to: &bytes)
        }
        bytes.append(UInt8(ascii: "}"))
        return Data(bytes)
    }

    /// One scalar in canonical form — see each case's doc on
    /// `SyncCanonicalScalar` for which normalization applies.
    private static func appendScalar(
        _ scalar: SyncCanonicalScalar, to bytes: inout [UInt8]
    ) {
        switch scalar {
        case .bool(let value):
            bytes.append(contentsOf: [UInt8]((value ? "true" : "false").utf8))
        case .int(let value):
            bytes.append(contentsOf: [UInt8](String(value).utf8))
        case .double(let value):
            bytes.append(contentsOf: [UInt8](number(value).utf8))
        case .string(let value):
            appendString(content(value), to: &bytes)
        case .uuid(let value):
            appendString(value.uuidString.lowercased(), to: &bytes)
        case .date(let value):
            appendString(timestamp(value, rounding: .toNearestOrAwayFromZero), to: &bytes)
        }
    }
}

/// SHA-256 of the canonical JSON encoding — the content hash the sync
/// engine compares against the shadow copy to detect local edits.
///
/// THE single hash for both sync directions: a local row's DTO fields go
/// through `hash(fields:)`; a pulled server record is decoded to the same
/// DTO and hashed the same way. `hash(_:)`/`hash(jsonData:)` remain for
/// already-parsed wire values (the replayed push body) — they produce the
/// same digest for the same record.
public enum SyncContentHasher {
    /// Hash of a parsed JSON value.
    public static func hash(_ value: SyncJSONValue) -> String {
        hex(SHA256.hash(data: value.canonicalData()))
    }

    /// Hash of a raw JSON document — a freshly encoded DTO or the `data`
    /// of a pulled record. Both forms of the same record hash equal.
    public static func hash(jsonData: Data) throws -> String {
        try hash(SyncJSONValue(jsonData: jsonData))
    }

    /// Hash of a DTO's canonical field list — byte-identical to hashing
    /// the equivalent document's canonicalData, without building or
    /// parsing any JSON. The hot path: this is what the diff feeds on
    /// for every row, every cycle.
    public static func hash(fields: [(String, SyncCanonicalScalar)]) -> String {
        hash(canonicalData: SyncCanonical.objectData(fields))
    }

    /// Canonical bytes of `fields` — sorted keys, `.sssZ` dates, the
    /// `wireBytes` size estimate batching needs alongside the hash.
    public static func canonicalData(
        fields: [(String, SyncCanonicalScalar)]
    ) -> Data {
        SyncCanonical.objectData(fields)
    }

    /// Hash of bytes already in canonical form — pairs with
    /// `canonicalData(fields:)` so a row's digest and byte size come
    /// from a single encoding pass.
    public static func hash(canonicalData: Data) -> String {
        hex(SHA256.hash(data: canonicalData))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Strict recursive-descent JSON reader over UTF-8 bytes. Numbers keep
/// their `Int64`/`Double` distinction — `JSONSerialization`'s `NSNumber`
/// would round large Int64s to doubles.
private struct SyncJSONParser {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> SyncJSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw SyncJSONError.malformedJSON }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"),
                 UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                index += 1
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws -> SyncJSONValue {
        guard index < bytes.count else { throw SyncJSONError.malformedJSON }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", as: .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", as: .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", as: .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw SyncJSONError.malformedJSON
        }
    }

    private mutating func parseLiteral(
        _ literal: String, as value: SyncJSONValue
    ) throws -> SyncJSONValue {
        for expected in literal.utf8 {
            guard index < bytes.count, bytes[index] == expected else {
                throw SyncJSONError.malformedJSON
            }
            index += 1
        }
        return value
    }

    private mutating func parseObject() throws -> SyncJSONValue {
        index += 1 // '{'
        var members: [String: SyncJSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw SyncJSONError.malformedJSON
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw SyncJSONError.malformedJSON
            }
            index += 1
            skipWhitespace()
            members[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw SyncJSONError.malformedJSON }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            } else {
                throw SyncJSONError.malformedJSON
            }
        }
    }

    private mutating func parseArray() throws -> SyncJSONValue {
        index += 1 // '['
        var values: [SyncJSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw SyncJSONError.malformedJSON }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            } else {
                throw SyncJSONError.malformedJSON
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // '"'
        var utf8: [UInt8] = []
        while index < bytes.count {
            let char = bytes[index]
            index += 1
            switch char {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try parseEscape(into: &utf8)
            case 0x00...0x1F:
                throw SyncJSONError.malformedJSON
            default:
                utf8.append(char)
            }
        }
        throw SyncJSONError.malformedJSON
    }

    private mutating func parseEscape(into utf8: inout [UInt8]) throws {
        guard index < bytes.count else { throw SyncJSONError.malformedJSON }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""): utf8.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): utf8.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): utf8.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            let codeUnit = try parseHexQuad()
            let scalar: Unicode.Scalar
            if (0xD800...0xDBFF).contains(codeUnit) {
                guard index + 1 < bytes.count,
                      bytes[index] == UInt8(ascii: "\\"),
                      bytes[index + 1] == UInt8(ascii: "u")
                else { throw SyncJSONError.malformedJSON }
                index += 2
                let low = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(low),
                      let composed = Unicode.Scalar(
                          0x10000 + ((UInt32(codeUnit) - 0xD800) << 10)
                          + (UInt32(low) - 0xDC00))
                else { throw SyncJSONError.malformedJSON }
                scalar = composed
            } else if (0xDC00...0xDFFF).contains(codeUnit) {
                throw SyncJSONError.malformedJSON
            } else {
                guard let decoded = Unicode.Scalar(UInt32(codeUnit)) else {
                    throw SyncJSONError.malformedJSON
                }
                scalar = decoded
            }
            utf8.append(contentsOf: [UInt8](String(scalar).utf8))
        default:
            throw SyncJSONError.malformedJSON
        }
    }

    private mutating func parseHexQuad() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw SyncJSONError.malformedJSON }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let char = bytes[index]
            index += 1
            let digit: UInt16
            switch char {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digit = UInt16(char - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                digit = UInt16(char - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                digit = UInt16(char - UInt8(ascii: "A")) + 10
            default:
                throw SyncJSONError.malformedJSON
            }
            value = value << 4 | digit
        }
        return value
    }

    private mutating func parseNumber() throws -> SyncJSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw SyncJSONError.malformedJSON }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        } else {
            throw SyncJSONError.malformedJSON
        }
        var isFractional = false
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isFractional = true
            index += 1
            guard index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
            else { throw SyncJSONError.malformedJSON }
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        }
        if index < bytes.count,
           bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isFractional = true
            index += 1
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
            else { throw SyncJSONError.malformedJSON }
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        if !isFractional, let int = Int64(literal) {
            return .int(int)
        }
        guard let double = Double(literal), double.isFinite else {
            throw SyncJSONError.malformedJSON
        }
        return .double(double)
    }
}

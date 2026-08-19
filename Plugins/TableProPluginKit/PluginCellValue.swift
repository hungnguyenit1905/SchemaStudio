import Foundation

/// A single cell crossing the plugin boundary.
///
/// Deliberately **not** `@frozen`. Freezing it is what forced the v20 PluginKit
/// break: a frozen enum's layout is part of the ABI, so every value case ever
/// added would cost another coordinated 16-plugin re-release. Non-frozen makes
/// every future addition additive, at the price of `@unknown default:` in
/// client-module switches.
///
/// A driver that cannot handle a case natively routes it through
/// ``textFallback``, which renders it to the exact string the pre-v20 text path
/// would have carried. That is what lets a driver adopt the typed path on its
/// own schedule instead of all at once.
public enum PluginCellValue: Sendable, Hashable {
    case null
    case text(String)
    case bytes(Data)
    case int(Int64)
    case double(Double)
    /// Arbitrary-precision numerics cross as text. `Foundation.Decimal` has no
    /// portable mapping across driver value types and PostgreSQL `numeric` has
    /// no lossless `Double` path, while every driver already parses numeric
    /// literals.
    case decimalText(String)
    case bool(Bool)
    /// A calendar date with no instant and no timezone. `Foundation.Date` is an
    /// absolute instant, so using it for a plain `date` column shifts the day at
    /// timezone boundaries.
    case date(year: Int, month: Int, day: Int)
    /// A time of day with no date and no timezone.
    case time(seconds: Int32, nanoseconds: Int32)
    /// An absolute instant, UTC at the boundary by definition.
    case timestamp(Date)
    case uuid(UUID)
    indirect case array([PluginCellValue])
}

extension PluginCellValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

extension PluginCellValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

public extension PluginCellValue {
    static func fromOptional(_ string: String?) -> PluginCellValue {
        string.map(PluginCellValue.text) ?? .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var asText: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var asBytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    var asAny: Any? {
        switch self {
        case .null: nil
        case .text(let value): value
        case .bytes(let value): value
        case .int(let value): value
        case .double(let value): value
        case .decimalText(let value): value
        case .bool(let value): value
        case .date, .time, .array: textFallback
        case .timestamp(let value): value
        case .uuid(let value): value
        }
    }

    /// String representation suitable for sorting and equality comparison.
    /// Binary cells are rendered as uppercase hex without prefix so byte-wise
    /// lexicographic order matches a stable sort across runs.
    ///
    /// Kept separate from ``textFallback`` on purpose: the two agree today, but
    /// rerouting one through the other would tie sort behavior to a rendering
    /// contract that exists for drivers, and v20 claims no behavior change.
    var sortKey: String {
        switch self {
        case .null: return ""
        case .text(let value): return value
        case .bytes(let value): return Self.hex(value)
        case .int, .double, .decimalText, .bool, .date, .time, .timestamp, .uuid, .array:
            return textFallback
        }
    }

    /// Renders any case into the string a pre-v20 driver would have received.
    ///
    /// This is the safety property for every driver that has not adopted the
    /// typed path: it keeps their behavior byte-identical to v19. The three v19
    /// cases render exactly as ``sortKey`` does, so nothing that already goes
    /// through text changes.
    var textFallback: String {
        switch self {
        case .null:
            return ""
        case .text(let value):
            return value
        case .bytes(let value):
            return Self.hex(value)
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .decimalText(let value):
            return value
        case .bool(let value):
            return value ? "1" : "0"
        case .date(let year, let month, let day):
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .time(let seconds, let nanoseconds):
            return Self.renderTime(seconds: seconds, nanoseconds: nanoseconds)
        case .timestamp(let value):
            return Self.iso8601.string(from: value)
        case .uuid(let value):
            return value.uuidString.lowercased()
        case .array(let values):
            return "{" + values.map(\.textFallback).joined(separator: ",") + "}"
        }
    }

    private static func hex(_ data: Data) -> String {
        var hex = ""
        hex.reserveCapacity(data.count * 2)
        for byte in data {
            hex += String(format: "%02X", byte)
        }
        return hex
    }

    private static func renderTime(seconds: Int32, nanoseconds: Int32) -> String {
        let total = Int(seconds)
        let base = String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        guard nanoseconds != 0 else { return base }
        return base + String(format: ".%06d", Int(nanoseconds) / 1_000)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

extension PluginCellValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum DateKeys: String, CodingKey {
        case year
        case month
        case day
    }

    private enum TimeKeys: String, CodingKey {
        case seconds
        case nanoseconds
    }

    // Wire tags are ABI-stable: never rename one, never reuse one for a
    // different case. `null`, `text` and `bytes` are the v19 tags.
    private enum Kind: String, Codable {
        case null
        case text
        case bytes
        case int
        case double
        case decimalText
        case bool
        case date
        case time
        case timestamp
        case uuid
        case array
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .null:
            self = .null
        case .text:
            self = try .text(container.decode(String.self, forKey: .value))
        case .bytes:
            self = try .bytes(container.decode(Data.self, forKey: .value))
        case .int:
            self = try .int(container.decode(Int64.self, forKey: .value))
        case .double:
            self = try .double(container.decode(Double.self, forKey: .value))
        case .decimalText:
            self = try .decimalText(container.decode(String.self, forKey: .value))
        case .bool:
            self = try .bool(container.decode(Bool.self, forKey: .value))
        case .date:
            let nested = try container.nestedContainer(keyedBy: DateKeys.self, forKey: .value)
            self = try .date(
                year: nested.decode(Int.self, forKey: .year),
                month: nested.decode(Int.self, forKey: .month),
                day: nested.decode(Int.self, forKey: .day)
            )
        case .time:
            let nested = try container.nestedContainer(keyedBy: TimeKeys.self, forKey: .value)
            self = try .time(
                seconds: nested.decode(Int32.self, forKey: .seconds),
                nanoseconds: nested.decode(Int32.self, forKey: .nanoseconds)
            )
        case .timestamp:
            self = try .timestamp(container.decode(Date.self, forKey: .value))
        case .uuid:
            self = try .uuid(container.decode(UUID.self, forKey: .value))
        case .array:
            self = try .array(container.decode([PluginCellValue].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bytes(let value):
            try container.encode(Kind.bytes, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .decimalText(let value):
            try container.encode(Kind.decimalText, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .date(let year, let month, let day):
            try container.encode(Kind.date, forKey: .kind)
            var nested = container.nestedContainer(keyedBy: DateKeys.self, forKey: .value)
            try nested.encode(year, forKey: .year)
            try nested.encode(month, forKey: .month)
            try nested.encode(day, forKey: .day)
        case .time(let seconds, let nanoseconds):
            try container.encode(Kind.time, forKey: .kind)
            var nested = container.nestedContainer(keyedBy: TimeKeys.self, forKey: .value)
            try nested.encode(seconds, forKey: .seconds)
            try nested.encode(nanoseconds, forKey: .nanoseconds)
        case .timestamp(let value):
            try container.encode(Kind.timestamp, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .uuid(let value):
            try container.encode(Kind.uuid, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .array(let values):
            try container.encode(Kind.array, forKey: .kind)
            try container.encode(values, forKey: .value)
        }
    }
}

public extension PluginCellValue {
    /// `YYYY-MM-DD HH:MM:SS[.ffffff]` in UTC: the timestamp form every SQL
    /// engine parses.
    ///
    /// Deliberately not ``textFallback``, which keeps the ISO 8601 `T`/`Z`
    /// form. That rendering is the v19 wire format a non-adopting driver still
    /// receives, so changing it would change behavior this release promises to
    /// leave alone. A literal inlined into a statement has no such constraint
    /// and a `T` separator is what Oracle and SQL Server reject.
    static func portableTimestampLiteral(_ instant: Date) -> String {
        portableTimestampFormatter.string(from: instant)
    }

    private static let portableTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter
    }()
}

public extension PluginCellValue {
    /// Reduces this value to the pre-v20 case set (`null`, `text`, `bytes`).
    ///
    /// The contract on ``PluginCapabilities/typedCellValues`` is that a driver
    /// which does not declare it receives exactly the cases it received in v19.
    /// Callers crossing into such a driver route every value through here, so a
    /// driver that reads a cell with `asText` keeps working instead of silently
    /// reading nil.
    var downgradedToLegacyCases: PluginCellValue {
        switch self {
        case .null, .text, .bytes:
            return self
        case .int, .double, .decimalText, .bool, .date, .time, .timestamp, .uuid, .array:
            return .text(textFallback)
        }
    }
}

public extension Array where Element == PluginCellValue {
    var downgradedToLegacyCases: [PluginCellValue] {
        map(\.downgradedToLegacyCases)
    }
}

public extension Array where Element == [PluginCellValue] {
    var downgradedToLegacyCases: [[PluginCellValue]] {
        map { $0.downgradedToLegacyCases }
    }
}

//
//  NativeTypeParser.swift
//  TablePro
//

import Foundation

protocol NativeTypeParsing: Sendable {
    func parse(_ native: String, allowedValues: [String]?) -> TransferColumnType
    func render(_ type: TransferColumnType) -> String?
}

/// The SQL dialect families the transfer engine can translate between. Resolved
/// from a static table rather than `DatabaseType.pluginTypeId`, which reads the
/// runtime plugin registry and would make type mapping depend on plugin loading.
enum TransferVendor: String, Sendable, Hashable, CaseIterable {
    case mysql
    case postgresql
    case sqlite
    case mssql

    init?(_ databaseType: DatabaseType) {
        switch databaseType {
        case .mysql, .mariadb:
            self = .mysql
        case .postgresql, .redshift, .cockroachdb, .pglite:
            self = .postgresql
        case .sqlite, .libsql, .turso, .cloudflareD1:
            self = .sqlite
        case .mssql:
            self = .mssql
        default:
            return nil
        }
    }

    var hasNativeBool: Bool {
        switch self {
        case .postgresql, .mssql: return true
        case .mysql, .sqlite: return false
        }
    }
}

/// `DatabaseType` is an open struct, so a vendor without a parser resolves to
/// `nil` and the caller keeps the source type verbatim.
enum NativeTypeParserRegistry {
    static func parser(for databaseType: DatabaseType) -> NativeTypeParsing? {
        guard let vendor = TransferVendor(databaseType) else { return nil }
        return parser(for: vendor)
    }

    static func parser(for vendor: TransferVendor) -> NativeTypeParsing {
        switch vendor {
        case .mysql: return MySqlNativeTypeParser()
        case .postgresql: return PostgreSqlNativeTypeParser()
        case .sqlite: return SqliteNativeTypeParser()
        case .mssql: return MssqlNativeTypeParser()
        }
    }
}

/// The lexical split every vendor parser starts from: `head(arguments) tail`,
/// with a trailing `[]` recorded separately.
struct NativeTypeSyntax: Sendable, Hashable {
    let head: String
    let arguments: [String]
    let tail: String
    let isArray: Bool

    var length: Int? {
        guard let first = arguments.first else { return nil }
        return Int(first)
    }

    var precision: Int? { length }

    var scale: Int? {
        guard arguments.count > 1 else { return nil }
        return Int(arguments[1])
    }

    /// `nvarchar(max)` and `varbinary(max)` declare an unbounded column.
    var isMaxLength: Bool {
        arguments.first?.lowercased() == "max"
    }

    var quotedArguments: [String] {
        arguments.map { argument in
            var value = argument
            for quote in ["'", "\""] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
    }

    func containsWord(_ word: String) -> Bool {
        head.contains(word) || tail.contains(word)
    }

    /// Removes modifier words from `head` so the remainder is the bare type
    /// name. `int unsigned` yields `int`, `timestamp without time zone` yields
    /// `timestamp`.
    func name(removing modifiers: Set<String>) -> String {
        let words = head.split(separator: " ").map(String.init)
        let kept = words.filter { !modifiers.contains($0) }
        return kept.joined(separator: " ")
    }

    static func parse(_ native: String) -> NativeTypeSyntax {
        var working = native.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var isArray = false
        while working.hasSuffix("[]") {
            isArray = true
            working = String(working.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }

        guard let open = working.firstIndex(of: "("), let close = working.lastIndex(of: ")"), open < close else {
            return NativeTypeSyntax(
                head: collapseWhitespace(working),
                arguments: [],
                tail: "",
                isArray: isArray
            )
        }

        let head = collapseWhitespace(String(working[working.startIndex..<open]))
        let inner = String(working[working.index(after: open)..<close])
        let tail = collapseWhitespace(String(working[working.index(after: close)...]))

        return NativeTypeSyntax(
            head: head,
            arguments: splitArguments(inner),
            tail: tail,
            isArray: isArray
        )
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Splits on commas that sit outside quotes so `enum('a,b','c')` keeps its
    /// first member intact.
    private static func splitArguments(_ inner: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?

        for character in inner {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case ",":
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }

        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !arguments.isEmpty { arguments.append(last) }
        return arguments.filter { !$0.isEmpty }
    }
}

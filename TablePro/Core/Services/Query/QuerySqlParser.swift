import Foundation
import TableProPluginKit

struct SingleTableWriteStatement: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case update
        case delete
    }

    let kind: Kind
    let table: String
    let whereClause: String?
}

enum QuerySqlParser {
    private static let tableReferencePattern =
        #"(?:\[[^\]]+\]|`[^`]+`|"[^"]+"|[\w$]+)(?:\s*\.\s*(?:\[[^\]]+\]|`[^`]+`|"[^"]+"|[\w$]+))?"#

    private static let whereKeywordRegex = try? NSRegularExpression(
        pattern: #"(?i)\bWHERE\b"#,
        options: []
    )

    private static let disqualifyingKeywordRegex = try? NSRegularExpression(
        pattern: #"(?is)\b(?:SELECT|JOIN|USING|WITH|UNION|MERGE)\b"#,
        options: []
    )

    private static let leadingDeleteRegex = try? NSRegularExpression(
        pattern: #"(?is)^\s*DELETE\b"#,
        options: []
    )

    private static let leadingUpdateRegex = try? NSRegularExpression(
        pattern: #"(?is)^\s*UPDATE\b"#,
        options: []
    )

    private static let deleteHeadRegex = try? NSRegularExpression(
        pattern: #"(?is)^\s*DELETE\s+FROM\s+(\#(tableReferencePattern))\s*$"#,
        options: []
    )

    private static let updateHeadRegex = try? NSRegularExpression(
        pattern: #"(?is)^\s*UPDATE\s+(\#(tableReferencePattern))\s+SET\s+\S(?:.|\n)*$"#,
        options: []
    )

    private static let tableNameRegex = try? NSRegularExpression(
        pattern: #"(?i)^\s*SELECT\s+.+?\s+FROM\s+(?:\[([^\]]+)\]|[`"]([^`"]+)[`"]|([\w$]+))\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|OFFSET|FETCH|$|;)"#,
        options: []
    )

    private static let mongoCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.(\w+)\."#,
        options: []
    )

    private static let mongoBracketCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\["([^"]+)"\]"#,
        options: []
    )

    static func extractTableName(from sql: String) -> String? {
        let nsRange = NSRange(sql.startIndex..., in: sql)

        if let regex = tableNameRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange) {
            for group in 1 ... 3 {
                let r = match.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: sql) {
                    return String(sql[range])
                }
            }
        }

        if let regex = mongoBracketCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        if let regex = mongoCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        return nil
    }

    static func leadingWriteKind(from sql: String) -> SingleTableWriteStatement.Kind? {
        let masked = maskQuotedRegions(in: sql.trimmingCharacters(in: .whitespacesAndNewlines))
        if !matches(of: leadingDeleteRegex, in: masked).isEmpty { return .delete }
        if !matches(of: leadingUpdateRegex, in: masked).isEmpty { return .update }
        return nil
    }

    static func parseSingleTableWrite(from sql: String) -> SingleTableWriteStatement? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let masked = maskQuotedRegions(in: trimmed)
        guard let statementEnd = soleStatementEnd(in: masked) else { return nil }

        let body = String(trimmed.prefix(upTo: index(trimmed, offset: statementEnd)))
        let maskedBody = String(masked.prefix(upTo: index(masked, offset: statementEnd)))
        guard !containsDisqualifyingKeyword(maskedBody) else { return nil }

        let whereMatches = matches(of: whereKeywordRegex, in: maskedBody)
        guard whereMatches.count <= 1 else { return nil }

        guard let whereMatch = whereMatches.first else {
            return parseHead(body, maskedHead: maskedBody, whereClause: nil)
        }

        let head = String(body.prefix(upTo: index(body, offset: whereMatch.location)))
        let maskedHead = String(maskedBody.prefix(upTo: index(maskedBody, offset: whereMatch.location)))
        let predicate = String(body.suffix(from: index(body, offset: whereMatch.location + whereMatch.length)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty else { return nil }

        return parseHead(head, maskedHead: maskedHead, whereClause: predicate)
    }

    private static func parseHead(
        _ head: String,
        maskedHead: String,
        whereClause: String?
    ) -> SingleTableWriteStatement? {
        if let range = firstCaptureRange(of: deleteHeadRegex, in: maskedHead) {
            return SingleTableWriteStatement(
                kind: .delete,
                table: String(head[range(head)]),
                whereClause: whereClause
            )
        }
        if let range = firstCaptureRange(of: updateHeadRegex, in: maskedHead) {
            return SingleTableWriteStatement(
                kind: .update,
                table: String(head[range(head)]),
                whereClause: whereClause
            )
        }
        return nil
    }

    private static func containsDisqualifyingKeyword(_ maskedSql: String) -> Bool {
        disqualifyingKeywordRegex.map { !matches(of: $0, in: maskedSql).isEmpty } ?? true
    }

    private static func soleStatementEnd(in masked: String) -> Int? {
        let units = Array(masked.utf16)
        let semicolon = UInt16(UInt8(ascii: ";"))
        guard let first = units.firstIndex(of: semicolon) else { return units.count }
        let remainder = units[(first + 1)...]
        guard remainder.allSatisfy(isWhitespaceUnit) else { return nil }
        return first
    }

    private static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func index(_ string: String, offset: Int) -> String.Index {
        String.Index(utf16Offset: offset, in: string)
    }

    private static func matches(of regex: NSRegularExpression?, in string: String) -> [NSRange] {
        guard let regex else { return [] }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.matches(in: string, options: [], range: range).map(\.range)
    }

    private static func firstCaptureRange(
        of regex: NSRegularExpression?,
        in string: String
    ) -> ((String) -> Range<String.Index>)? {
        guard let regex else { return nil }
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard let match = regex.firstMatch(in: string, options: [], range: range) else { return nil }
        let captured = match.range(at: 1)
        guard captured.location != NSNotFound else { return nil }
        return { target in
            index(target, offset: captured.location) ..< index(target, offset: captured.location + captured.length)
        }
    }

    private static func maskQuotedRegions(in sql: String) -> String {
        var units = Array(sql.utf16)
        let placeholder = UInt16(UInt8(ascii: "x"))
        let blankPlaceholder = UInt16(UInt8(ascii: " "))
        var index = 0

        while index < units.count {
            let unit = units[index]

            if unit == asciiUnit("'") || unit == asciiUnit("\"") || unit == asciiUnit("`") {
                index = maskDelimited(&units, from: index, closing: unit, placeholder: placeholder)
                continue
            }
            if unit == asciiUnit("[") {
                index = maskDelimited(&units, from: index, closing: asciiUnit("]"), placeholder: placeholder)
                continue
            }
            if unit == asciiUnit("-"), index + 1 < units.count, units[index + 1] == asciiUnit("-") {
                index = maskLineComment(&units, from: index, placeholder: blankPlaceholder)
                continue
            }
            if unit == asciiUnit("/"), index + 1 < units.count, units[index + 1] == asciiUnit("*") {
                index = maskBlockComment(&units, from: index, placeholder: blankPlaceholder)
                continue
            }

            index += 1
        }

        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func maskDelimited(
        _ units: inout [UInt16],
        from start: Int,
        closing: UInt16,
        placeholder: UInt16
    ) -> Int {
        var cursor = start + 1
        while cursor < units.count {
            if units[cursor] == closing {
                if cursor + 1 < units.count, units[cursor + 1] == closing {
                    units[cursor] = placeholder
                    units[cursor + 1] = placeholder
                    cursor += 2
                    continue
                }
                return cursor + 1
            }
            units[cursor] = placeholder
            cursor += 1
        }
        return cursor
    }

    private static func maskLineComment(_ units: inout [UInt16], from start: Int, placeholder: UInt16) -> Int {
        var cursor = start
        while cursor < units.count, units[cursor] != asciiUnit("\n") {
            units[cursor] = placeholder
            cursor += 1
        }
        return cursor
    }

    private static func maskBlockComment(_ units: inout [UInt16], from start: Int, placeholder: UInt16) -> Int {
        var cursor = start
        while cursor < units.count {
            if units[cursor] == asciiUnit("*"), cursor + 1 < units.count, units[cursor + 1] == asciiUnit("/") {
                units[cursor] = placeholder
                units[cursor + 1] = placeholder
                return cursor + 2
            }
            units[cursor] = placeholder
            cursor += 1
        }
        return cursor
    }

    private static func asciiUnit(_ character: Unicode.Scalar) -> UInt16 {
        UInt16(character.value)
    }

    static func stripTrailingOrderBy(from sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsString = trimmed as NSString
        let pattern = "\\s+ORDER\\s+BY\\s+(?![^(]*\\))[^)]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return trimmed
        }
        let range = NSRange(location: 0, length: nsString.length)
        return regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseSQLiteCheckConstraintValues(createSQL: String, columnName: String) -> [String]? {
        let escapedName = NSRegularExpression.escapedPattern(for: columnName)
        let pattern = "CHECK\\s*\\(\\s*\"?\(escapedName)\"?\\s+IN\\s*\\(([^)]+)\\)\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsString = createSQL as NSString
        guard let match = regex.firstMatch(
            in: createSQL,
            range: NSRange(location: 0, length: nsString.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        let valuesString = nsString.substring(with: match.range(at: 1))
        return EnumValueParser.parseMySQLEnumOrSet(from: "ENUM(\(valuesString))")
    }
}

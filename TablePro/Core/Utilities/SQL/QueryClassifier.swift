//
//  QueryClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum QueryTier {
    case safe
    case write
    case destructive
}

enum QueryClassifier {
    private static let writeQueryKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE",
        "DROP", "TRUNCATE", "ALTER", "CREATE",
        "RENAME", "GRANT", "REVOKE",
        "MERGE", "UPSERT", "CALL", "EXEC", "EXECUTE", "LOAD",
    ]

    private static let redisWriteCommands: Set<String> = [
        "SET", "DEL", "HSET", "HDEL", "HMSET", "LPUSH", "RPUSH", "LPOP", "RPOP",
        "SADD", "SREM", "ZADD", "ZREM", "EXPIRE", "PERSIST", "RENAME",
        "FLUSHDB", "FLUSHALL", "MSET", "APPEND", "INCR", "DECR", "INCRBY",
        "DECRBY", "SETEX", "PSETEX", "SETNX", "GETSET", "GETDEL",
        "XADD", "XTRIM", "XDEL",
    ]

    private static let redisDangerousCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "DEBUG", "SHUTDOWN",
    ]

    private static let explainPrefixes: [String] = ["EXPLAIN", "ANALYZE"]

    private static let sqlLengthCap = 10_000

    private static let rawWhereTokenRegex = try? NSRegularExpression(pattern: #"(?i)\bWHERE\b"#, options: [])

    static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return redisWriteCommands.contains(firstToken)
        }

        let keyword = leadingKeyword(of: trimmed)
        if writeQueryKeywords.contains(keyword) {
            return true
        }

        if keyword == "WITH" {
            let uppercased = trimmed.uppercased()
            let dmlKeywords = ["INSERT ", "UPDATE ", "DELETE ", "MERGE "]
            for dmlKeyword in dmlKeywords where uppercased.contains(dmlKeyword) {
                return true
            }
        }

        return false
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return redisDangerousCommands.contains(firstToken)
        }

        return statements(in: trimmed, databaseType: databaseType).contains(where: isDangerousStatement)
    }

    /// Broader than `isDangerousQuery`: also flags `UPDATE` with no `WHERE`. Feeds
    /// `needsConfirmation`, never `capabilityDenial`, so MCP `execute_query` for an
    /// unbounded `UPDATE` keeps behaving as it does today.
    static func isUnboundedWrite(_ sql: String, databaseType: DatabaseType) -> Bool {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            return false
        }

        return statements(in: trimmed, databaseType: databaseType).contains(where: isUnboundedWriteStatement)
    }

    private static func statements(in sql: String, databaseType: DatabaseType) -> [String] {
        let dialect = SqlDialect.from(databaseTypeId: databaseType.rawValue)
        let split = SQLStatementScanner.allStatements(in: sql, dialect: dialect)
        return split.isEmpty ? [sql] : split
    }

    private static func isDangerousStatement(_ statement: String) -> Bool {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = leadingKeyword(of: trimmed)

        if keyword == "DROP" || keyword == "TRUNCATE" {
            return true
        }
        if keyword == "DELETE" {
            return !hasWhereToken(in: trimmed)
        }
        return false
    }

    private static func isUnboundedWriteStatement(_ statement: String) -> Bool {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = leadingKeyword(of: trimmed)
        guard keyword == "UPDATE" || keyword == "DELETE" else { return false }
        return !hasWhereToken(in: trimmed)
    }

    private static func hasWhereToken(in statement: String) -> Bool {
        guard statement.utf16.count <= sqlLengthCap else {
            return matchesRawWhereToken(statement)
        }
        return QuerySqlParser.containsUnmaskedKeyword("WHERE", in: statement)
    }

    private static func matchesRawWhereToken(_ sql: String) -> Bool {
        guard let regex = rawWhereTokenRegex else { return true }
        let range = NSRange(sql.startIndex..., in: sql)
        return regex.firstMatch(in: sql, options: [], range: range) != nil
    }

    static func classifyTier(_ sql: String, databaseType: DatabaseType) -> QueryTier {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "FLUSHDB" || firstToken == "FLUSHALL" {
                return .destructive
            }
        } else {
            let keyword = leadingKeyword(of: trimmed)
            if keyword == "DROP" || keyword == "TRUNCATE" {
                return .destructive
            }
            if keyword == "ALTER", trimmed.uppercased().range(of: " DROP ", options: .literal) != nil {
                return .destructive
            }

            if keyword == "WITH" {
                let uppercased = trimmed.uppercased()
                let destructiveKeywords = ["DROP ", "TRUNCATE "]
                for destructiveKeyword in destructiveKeywords where uppercased.contains(destructiveKeyword) {
                    return .destructive
                }
                let writeKeywords = ["INSERT ", "UPDATE ", "DELETE ", "MERGE "]
                for writeKeyword in writeKeywords where uppercased.contains(writeKeyword) {
                    return .write
                }
            }
        }

        if isWriteQuery(sql, databaseType: databaseType) {
            return .write
        }

        return .safe
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        SQLStatementScanner.allStatements(
            in: sql,
            dialect: SqlDialect.from(databaseTypeId: databaseType.rawValue)
        ).count > 1
    }

    static func isExplainStatement(_ sql: String) -> Bool {
        let upper = strippingLeadingComments(sql).uppercased()
        return explainPrefixes.contains { prefix in
            guard upper.hasPrefix(prefix), let boundary = upper.dropFirst(prefix.count).first else {
                return false
            }
            return boundary == "(" || boundary.isWhitespace
        }
    }

    static func leadingKeyword(of sql: String) -> String {
        let stripped = strippingLeadingComments(sql)
        return stripped.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }

    static func strippingLeadingComments(_ sql: String) -> String {
        var remaining = sql[...]
        while true {
            let trimmed = remaining.drop { $0.isWhitespace }
            if trimmed.hasPrefix("--") {
                guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
                remaining = trimmed[trimmed.index(after: newline)...]
            } else if trimmed.hasPrefix("/*") {
                guard let close = trimmed.range(of: "*/") else { return "" }
                remaining = trimmed[close.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }
}

//
//  TransferIdentifierPolicy.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferCaseFolding: Sendable, Hashable {
    /// The target keeps the name exactly as written, because every identifier
    /// reaches it quoted.
    case preserve
    case lowercase
}

/// The naming rules of one target vendor.
///
/// Table and column names are never rewritten: the target always uses the
/// source name, so a rewrite here would desynchronise the DDL from the INSERT
/// statements the row copy generates. Only generated names, index and
/// constraint names, are shortened, because they are built by joining column
/// names and overrun a limit long before a table name does.
struct TransferIdentifierPolicy: Sendable, Hashable {
    let maxLengthBytes: Int
    let caseFolding: TransferCaseFolding

    static func policy(for vendor: TransferVendor?) -> TransferIdentifierPolicy {
        switch vendor {
        case .postgresql:
            return TransferIdentifierPolicy(maxLengthBytes: 63, caseFolding: .preserve)
        case .mysql:
            return TransferIdentifierPolicy(maxLengthBytes: 64, caseFolding: .preserve)
        case .mssql:
            return TransferIdentifierPolicy(maxLengthBytes: 128, caseFolding: .preserve)
        case .sqlite, .none:
            return TransferIdentifierPolicy(maxLengthBytes: .max, caseFolding: .preserve)
        }
    }

    func fits(_ identifier: String) -> Bool {
        identifier.utf8.count <= maxLengthBytes
    }

    /// Shortens on a character boundary so a multi-byte scalar is never cut in
    /// half, then appends a hash of the whole original. The hash is what keeps
    /// two names that share a long prefix apart after the shortening.
    func shorten(_ identifier: String) -> String {
        guard !fits(identifier) else { return identifier }

        let suffix = "_" + Self.stableHash(identifier)
        let budget = maxLengthBytes - suffix.utf8.count
        guard budget > 0 else { return String(suffix.dropFirst()) }

        var prefix = ""
        var used = 0
        for character in identifier {
            let width = String(character).utf8.count
            if used + width > budget { break }
            prefix.append(character)
            used += width
        }
        return prefix + suffix
    }

    /// FNV-1a. `Hasher` is seeded per process, so it would hand the same name a
    /// different short form on every run and a re-run would build indexes the
    /// previous run's foreign keys no longer match.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    func fold(_ identifier: String) -> String {
        switch caseFolding {
        case .preserve:
            return identifier
        case .lowercase:
            return identifier.lowercased()
        }
    }
}

/// One run's resolved names.
///
/// Built once over the whole name set rather than per name: two names only
/// collide relative to each other, so a per-name call could never see it. The
/// resolved form is then read back from the table instead of recomputed, which
/// is what guarantees a foreign key and the index it points at agree.
struct TransferIdentifierMap: Sendable {
    private let resolved: [String: String]
    let warnings: [TransferStructureWarning]

    init(names: [String], policy: TransferIdentifierPolicy) {
        var resolved: [String: String] = [:]
        var warnings: [TransferStructureWarning] = []
        var taken: [String: String] = [:]

        for name in names where resolved[name] == nil {
            let shortened = policy.shorten(name)
            if shortened != name {
                warnings.append(.identifierShortened(original: name, mapped: shortened))
            }

            let key = policy.fold(shortened).lowercased()
            if let existing = taken[key], existing != name {
                warnings.append(.identifierCollision(first: existing, second: name, mapped: shortened))
            } else {
                taken[key] = name
            }
            resolved[name] = shortened
        }

        self.resolved = resolved
        self.warnings = warnings
    }

    func resolve(_ name: String) -> String {
        resolved[name] ?? name
    }
}

extension PluginIndexDefinition {
    func renamed(to name: String) -> PluginIndexDefinition {
        guard name != self.name else { return self }
        return PluginIndexDefinition(
            name: name,
            columns: columns,
            isUnique: isUnique,
            indexType: indexType,
            columnPrefixes: columnPrefixes,
            whereClause: whereClause,
            descendingColumns: descendingColumns
        )
    }

    func withDescendingColumns(_ columns: Set<String>) -> PluginIndexDefinition {
        guard columns != descendingColumns else { return self }
        return PluginIndexDefinition(
            name: name,
            columns: self.columns,
            isUnique: isUnique,
            indexType: indexType,
            columnPrefixes: columnPrefixes,
            whereClause: whereClause,
            descendingColumns: columns
        )
    }
}

extension PluginForeignKeyDefinition {
    func renamed(to name: String) -> PluginForeignKeyDefinition {
        guard name != self.name else { return self }
        return PluginForeignKeyDefinition(
            name: name,
            columns: columns,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            onDelete: onDelete,
            onUpdate: onUpdate,
            referencedSchema: referencedSchema
        )
    }
}

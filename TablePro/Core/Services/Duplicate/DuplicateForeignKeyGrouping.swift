//
//  DuplicateForeignKeyGrouping.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct DuplicateGroupedForeignKey: Sendable, Hashable {
    let name: String
    let localColumns: [String]
    let referencedSchema: String?
    let referencedTable: String
    let referencedColumns: [String]
    let onDelete: String?
    let onUpdate: String?
}

/// `PluginForeignKeyInfo` carries the whole column list on every row for drivers that populate
/// `localColumns`, but older rows describe one column each. Grouping by constraint name handles
/// both shapes without asking the caller which one it got.
enum DuplicateForeignKeyGrouping {
    struct Result: Sendable {
        let keys: [DuplicateGroupedForeignKey]
        let warnings: [DuplicateWarning]
    }

    static func grouped(_ keys: [PluginForeignKeyInfo]) -> Result {
        var order: [String] = []
        var rows: [String: [PluginForeignKeyInfo]] = [:]
        for key in keys {
            if rows[key.name] == nil { order.append(key.name) }
            rows[key.name, default: []].append(key)
        }

        var grouped: [DuplicateGroupedForeignKey] = []
        var warnings: [DuplicateWarning] = []
        for name in order {
            guard let group = rows[name], let first = group.first else { continue }
            let locals = group.count > 1 ? group.map(\.column) : first.localColumns
            let referenced = group.count > 1 ? group.map(\.referencedColumn) : first.referencedColumns
            guard !locals.isEmpty, locals.count == referenced.count else {
                warnings.append(.foreignKeyNotCarried(name))
                continue
            }
            grouped.append(
                DuplicateGroupedForeignKey(
                    name: name,
                    localColumns: locals,
                    referencedSchema: first.referencedSchema,
                    referencedTable: first.referencedTable,
                    referencedColumns: referenced,
                    onDelete: meaningfulAction(first.onDelete),
                    onUpdate: meaningfulAction(first.onUpdate)
                )
            )
        }
        return Result(keys: grouped, warnings: warnings)
    }

    /// A self-referencing key must point at the copy, not the original, or the new table stays
    /// tied to the table it was duplicated from.
    static func isSelfReferencing(_ key: DuplicateGroupedForeignKey, source: DuplicateTableRef) -> Bool {
        guard key.referencedTable == source.name else { return false }
        guard let keySchema = key.referencedSchema, let sourceSchema = source.schema else { return true }
        return keySchema == sourceSchema
    }

    /// `NO ACTION` is the server default, so emitting it adds noise to every generated statement
    /// and to every test expectation.
    private static func meaningfulAction(_ action: String) -> String? {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.uppercased() != "NO ACTION" else { return nil }
        return trimmed
    }
}

//
//  TransferTypeMapper+Index.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension TransferTypeMapper {
    private static let postgresOnlyIndexTypes: Set<String> = ["gin", "gist", "spgist", "brin", "hash"]

    func plan(for index: PluginIndexDefinition, table: String) -> TransferIndexPlan {
        if isSameDialect { return TransferIndexPlan(index: index, warnings: []) }

        guard let target = targetVendor else {
            return TransferIndexPlan(
                index: index,
                warnings: [
                    .indexNotMapped(
                        table: table,
                        index: index.name,
                        reason: String(localized: "The target engine is not supported for index translation.")
                    )
                ]
            )
        }

        var warnings: [TransferStructureWarning] = []
        let kind = index.indexType?.lowercased()

        if kind == "fulltext" || kind == "spatial", target != .mysql {
            return TransferIndexPlan(
                index: nil,
                warnings: [
                    .indexNotMapped(
                        table: table,
                        index: index.name,
                        reason: String(localized: "The target has no equivalent full-text index, so the index is skipped.")
                    )
                ]
            )
        }

        var columnPrefixes = index.columnPrefixes
        if let prefixes = columnPrefixes, !prefixes.isEmpty, target != .mysql {
            columnPrefixes = nil
            warnings.append(
                .indexNotMapped(
                    table: table,
                    index: index.name,
                    reason: String(localized: "The target cannot index a prefix of a column, so the whole column is indexed.")
                )
            )
        }

        var whereClause = index.whereClause
        if let clause = whereClause, !clause.isEmpty, target != .postgresql, target != .sqlite {
            whereClause = nil
            warnings.append(
                .indexNotMapped(
                    table: table,
                    index: index.name,
                    reason: String(localized: "The target has no partial index, so the index covers every row.")
                )
            )
        }

        var indexType = index.indexType
        if let kind, Self.postgresOnlyIndexTypes.contains(kind), target != .postgresql {
            indexType = nil
            warnings.append(
                .indexNotMapped(
                    table: table,
                    index: index.name,
                    reason: String(localized: "The target has no equivalent index method, so a B-tree index is created.")
                )
            )
        }

        return TransferIndexPlan(
            index: PluginIndexDefinition(
                name: index.name,
                columns: index.columns,
                isUnique: index.isUnique,
                indexType: indexType,
                columnPrefixes: columnPrefixes,
                whereClause: whereClause
            ),
            warnings: warnings
        )
    }
}

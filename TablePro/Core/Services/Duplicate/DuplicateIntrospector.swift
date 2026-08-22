//
//  DuplicateIntrospector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Reads everything the builder needs about the source table.
///
/// Structured reads reuse the plugin driver, which is the same for every vendor. Everything the
/// driver protocol does not expose comes from the vendor's catalog, so this type holds no SQL of
/// its own and adding a vendor never touches it.
struct DuplicateIntrospector: Sendable {
    let driver: any DuplicateDriving
    let catalog: any DuplicateVendorCatalog

    func introspect(_ source: DuplicateTableRef) async throws -> DuplicateTableIntrospection {
        let columns = try await driver.fetchColumns(table: source.name, schema: source.schema)
        let indexes = try await driver.fetchIndexes(table: source.name, schema: source.schema)
        let foreignKeys = try await driver.fetchForeignKeys(table: source.name, schema: source.schema)
        let rowCount = try await driver.fetchApproximateRowCount(table: source.name, schema: source.schema)

        let facts = try await catalog.facts(source, driver: driver)
        let sequences = try await catalog.sequenceAttributes(source, driver: driver)

        return DuplicateTableIntrospection(
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            sequencesByColumn: sequences,
            tableComment: facts.comment,
            estimatedRowCount: rowCount.map(Int64.init),
            hasRowLevelSecurity: facts.hasRowLevelSecurity,
            isOwner: facts.isOwner,
            isPartitioned: facts.isPartitioned,
            hasExpressionIndex: facts.hasExpressionIndex
        )
    }
}

//
//  TableOperationSQLBuilder.swift
//  TablePro
//

import Foundation

@MainActor
struct TableOperationSQLBuilder {
    let connectionId: UUID
    let databaseType: DatabaseType
    let adapterProvider: () -> PluginDriverAdapter?

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        adapterProvider: @escaping () -> PluginDriverAdapter?
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.adapterProvider = adapterProvider
    }

    func generate(
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []

        let needsDisableFK = includeFKHandling && truncates.union(deletes).contains { ref in
            options[ref]?.ignoreForeignKeys == true
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyDisableStatements())
        }

        for ref in truncates.sorted(by: Self.executionOrder) {
            statements.append(contentsOf: truncateStatements(ref, options: options[ref] ?? TableOperationOptions()))
        }

        for ref in deletes.sorted(by: Self.executionOrder) {
            let stmt = dropObjectStatement(ref, options: options[ref] ?? TableOperationOptions())
            if !stmt.isEmpty {
                statements.append(stmt)
            }
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyEnableStatements())
        }

        return statements
    }

    private static func executionOrder(_ lhs: DatabaseTreeTableRef, _ rhs: DatabaseTreeTableRef) -> Bool {
        (lhs.table.name, lhs.id) < (rhs.table.name, rhs.id)
    }

    private static func schema(of ref: DatabaseTreeTableRef) -> String? {
        let schema = ref.schema ?? ref.table.schema
        return schema.flatMap { $0.isEmpty ? nil : $0 }
    }

    func foreignKeyDisableStatements() -> [String] {
        adapterProvider()?.foreignKeyDisableStatements() ?? []
    }

    func foreignKeyEnableStatements() -> [String] {
        adapterProvider()?.foreignKeyEnableStatements() ?? []
    }

    private func truncateStatements(_ ref: DatabaseTreeTableRef, options: TableOperationOptions) -> [String] {
        guard let adapter = adapterProvider() else { return [] }
        return adapter.truncateTableStatements(
            table: ref.table.name, schema: Self.schema(of: ref), cascade: options.cascade
        )
    }

    private func dropObjectStatement(_ ref: DatabaseTreeTableRef, options: TableOperationOptions) -> String {
        guard let adapter = adapterProvider() else { return "" }
        return adapter.dropObjectStatement(
            name: ref.table.name,
            objectType: Self.dropKeyword(for: ref.table.type),
            schema: Self.schema(of: ref),
            cascade: options.cascade
        )
    }

    private static func dropKeyword(for type: TableInfo.TableType) -> String {
        switch type {
        case .view:
            return "VIEW"
        case .materializedView:
            return "MATERIALIZED VIEW"
        case .foreignTable:
            return "FOREIGN TABLE"
        case .table, .systemTable, .partitionedTable, .externalTable:
            return "TABLE"
        }
    }
}

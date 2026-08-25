//
//  DuplicateSheetEnvironmentLive.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DuplicateSheetEnvironment {
    /// Wires the sheet to the app: quoting and the schema capability come from the connection's
    /// driver, the reads go through the metadata pool, and the run goes through the service with
    /// the execution gate and the query history attached.
    ///
    /// Returns `nil` when the connection has no live plugin-backed driver, because every
    /// structured read this feature makes exists only on the plugin protocol.
    @MainActor
    static func live(
        scope: DatabaseScope,
        databaseType: DatabaseType,
        source: DuplicateTableRef,
        partialCopyPrompt: DuplicatePartialCopyPrompt
    ) -> DuplicateSheetEnvironment? {
        guard let driver = DatabaseManager.shared.driver(for: scope.connectionId),
              let adapter = DatabaseDriverDuplicateAdapter(driver: driver) else { return nil }

        let session = DatabaseManagerDuplicateSession(scope: scope)
        let service = DuplicateTableService(
            databaseType: databaseType,
            session: session,
            hooks: hooks(
                scope: scope,
                databaseType: databaseType,
                source: source,
                partialCopyPrompt: partialCopyPrompt
            )
        )

        return DuplicateSheetEnvironment(
            quoting: adapter.quoting,
            supportsSchemas: (driver as? PluginDriverAdapter)?.schemaPluginDriver.supportsSchemas ?? false,
            runsOnSharedConnection: session.runsOnSharedConnection,
            loadSchemas: {
                try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchSchemas()
                }
            },
            loadTakenNames: { schema in
                let target = DatabaseScope(
                    connectionId: scope.connectionId,
                    database: scope.database,
                    schema: schema
                )
                let listed = try await DatabaseManager.shared.withMetadataDriver(scope: target) { driver in
                    try await driver.fetchTables(schema: schema)
                }
                return Set(listed.map(\.name))
            },
            introspect: {
                guard let catalog = DuplicateVendorCatalogRegistry.catalog(for: databaseType) else {
                    throw DuplicateError.unsupportedDatabase(databaseType.rawValue)
                }
                return try await session.withDriver(tracksCancellation: false) { driver in
                    try await DuplicateIntrospector(driver: driver, catalog: catalog).introspect(source)
                }
            },
            run: { request, token, onProgress in
                try await service.run(request, token: token, onProgress: onProgress)
            }
        )
    }

    private static func hooks(
        scope: DatabaseScope,
        databaseType: DatabaseType,
        source: DuplicateTableRef,
        partialCopyPrompt: DuplicatePartialCopyPrompt
    ) -> DuplicateServiceHooks {
        var hooks = DuplicateServiceHooks()
        hooks.authorize = {
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: scope.connectionId,
                    databaseType: databaseType,
                    sql: nil,
                    kind: .schemaMutation,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(
                        format: String(localized: "Duplicate table '%@'"),
                        source.name
                    )
                )
            )
            guard case .authorized = decision else {
                throw ExecutionGateError.denied(
                    decision.deniedReason ?? String(localized: "Operation not permitted")
                )
            }
        }
        hooks.recordHistory = { stage, sql, succeeded, error in
            QueryHistoryManager.shared.recordQuery(
                query: sql.isEmpty ? "-- \(stage): \(source.name)" : sql,
                connectionId: scope.connectionId,
                databaseName: scope.database,
                executionTime: 0,
                rowCount: 0,
                wasSuccessful: succeeded,
                errorMessage: error
            )
        }
        hooks.confirmDropPartialCopy = { copiedRows in
            await partialCopyPrompt.ask(copiedRows: copiedRows)
        }
        hooks.confirmDropReferencedTarget = { target, referencing in
            await confirmDropReferencedTarget(target: target, referencing: referencing)
        }
        return hooks
    }

    /// The second dialog of the `Drop and recreate` policy. It names the owning table next to
    /// every constraint, because dropping one changes a table the user did not ask about.
    ///
    /// This is an app-level confirmation, not an execution gate: the run still goes through
    /// `ExecutionGateProvider` afterwards. When per-connection blocking of destructive operations
    /// lands, this path has to be blocked outright rather than confirmed.
    @MainActor
    private static func confirmDropReferencedTarget(
        target: DuplicateTableRef,
        referencing: [ReferencingForeignKey]
    ) async -> Bool {
        let listed = referencing.map { "• \($0.describedForDialog)" }.joined(separator: "\n")
        return await AlertHelper.confirmDestructive(
            title: String(
                format: String(localized: "Replace '%@'?"),
                target.name
            ),
            message: String(
                format: String(
                    localized: """
                    These foreign keys point at it and are deleted with it:

                    %@
                    """
                ),
                listed
            ),
            confirmButton: String(
                format: String(localized: "Drop with CASCADE (will delete %lld foreign key constraints)"),
                Int64(referencing.count)
            )
        )
    }
}

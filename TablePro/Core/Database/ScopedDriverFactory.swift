//
//  ScopedDriverFactory.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
enum ScopedDriverFactory {
    static func openDriver(scope: DatabaseScope, timeoutSeconds: Double) async throws -> DatabaseDriver {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        var connection = session.effectiveConnection ?? session.connection
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: connection.database,
            targetDatabase: scope.database,
            authenticationIsDatabaseScoped: connection.type.authenticationIsDatabaseScoped
        )
        connection.database = plan.connectDatabase

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )
        do {
            try await MetadataConnectionPool.connect(driver, database: plan.connectDatabase, timeoutSeconds: timeoutSeconds)
            try? await driver.applyQueryTimeout(AppSettingsManager.shared.general.queryTimeoutSeconds)
            await DatabaseManager.shared.executeStartupCommands(
                session.connection.startupCommands, on: driver, connectionName: session.connection.name
            )
            if let database = plan.switchDatabase {
                try await MetadataConnectionPool.switchDatabase(driver, to: database, timeoutSeconds: timeoutSeconds)
            }
            if let schema = scope.schema {
                try await MetadataConnectionPool.switchSchema(driver, to: schema, timeoutSeconds: timeoutSeconds)
            }
        } catch {
            driver.disconnect()
            throw error
        }
        return driver
    }
}

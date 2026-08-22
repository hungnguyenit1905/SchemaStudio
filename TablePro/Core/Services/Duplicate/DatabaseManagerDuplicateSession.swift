//
//  DatabaseManagerDuplicateSession.swift
//  TablePro
//

import Foundation

/// Wires the service to the app's connection management.
///
/// The route is resolved once, up front, so the sheet can tell the user before they start whether
/// the copy will run beside their other tabs or block them. A duplicate is a long background bulk
/// operation, closer to Data Transfer than to a query tab, so it asks for a pooled connection with
/// the `.bulk` workload. `DatabaseManager.metadataRoute(for:)` answers `.pooled` when the
/// connection type supports it and `.sessionDriver` when it does not, and this feature accepts the
/// second answer rather than refusing to run: it says so in the UI and goes ahead.
struct DatabaseManagerDuplicateSession: DuplicateSessionProviding {
    let scope: DatabaseScope
    let route: ScopedDriverRoute

    @MainActor
    init(scope: DatabaseScope) {
        self.scope = scope
        route = DatabaseManager.shared.metadataRoute(for: scope)
    }

    var runsOnSharedConnection: Bool {
        route == .sessionDriver
    }

    func withDriver<T: Sendable>(
        tracksCancellation: Bool,
        _ body: @Sendable @escaping (any DuplicateDriving) async throws -> T
    ) async throws -> T {
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            workload: .bulk,
            tracksCancellation: tracksCancellation
        ) { driver in
            guard let adapter = DatabaseDriverDuplicateAdapter(driver: driver) else {
                throw DuplicateError.unsupportedDatabase(scope.database)
            }
            return try await body(adapter)
        }
    }
}

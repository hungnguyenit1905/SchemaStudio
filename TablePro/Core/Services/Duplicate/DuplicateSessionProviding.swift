//
//  DuplicateSessionProviding.swift
//  TablePro
//

import Foundation

/// Hands the service a driver for the length of one step.
///
/// `runsOnSharedConnection` is the honest answer to a question the connection type decides, not
/// the feature: a duplicate wants a pooled connection so a long copy leaves the user's other tabs
/// responsive, but `DatabaseManager.canPool` is false for types without pooling support and for
/// types that pick their database from a connection field. On those, the work runs on the session
/// driver and does block the connection, and the sheet says so rather than pretending otherwise.
protocol DuplicateSessionProviding: Sendable {
    var runsOnSharedConnection: Bool { get }

    func withDriver<T: Sendable>(
        tracksCancellation: Bool,
        _ body: @Sendable @escaping (any DuplicateDriving) async throws -> T
    ) async throws -> T
}

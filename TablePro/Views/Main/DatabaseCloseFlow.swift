//
//  DatabaseCloseFlow.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
enum DatabaseCloseFlow {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "DatabaseCloseFlow")

    struct Impact: Equatable {
        var windowCount = 0
        var unsavedWindowCount = 0
        var pendingOperationCount = 0
        var runningQueryCount = 0

        var needsConfirmation: Bool {
            unsavedWindowCount > 0 || pendingOperationCount > 0 || runningQueryCount > 0
        }
    }

    @discardableResult
    static func closeDatabase(_ database: String, connectionId: UUID, anchor: NSWindow?) async -> Bool {
        let manager = DatabaseManager.shared
        guard !manager.isDefaultDatabase(database, for: connectionId) else { return false }
        let coordinators = connectionCoordinators(connectionId)
        let owning = coordinators.filter { databaseNames(of: $0).contains(database) }
        let pending = pendingRefs(connectionId: connectionId) { $0.database == database }
        var impact = impact(of: owning, pending: pending)
        if manager.isDatabaseSessionBusy(database, for: connectionId) {
            impact.runningQueryCount = max(impact.runningQueryCount, 1)
        }

        if impact.needsConfirmation {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Close %@?"), database),
                message: message(for: impact),
                confirmButton: String(localized: "Close"),
                window: anchor
            )
            guard confirmed else { return false }
        }

        let plan = TabBatchClosePlanner.planCloseForDatabase(
            targets: targets(owning),
            database: database,
            currentWindowId: anchor.map(ObjectIdentifier.init)
        )
        stopQueries(in: owning, connectionId: connectionId, database: database)
        discardPending(connectionId: connectionId) { $0.database == database }
        close(plan, among: owning)

        do {
            try await manager.closeDatabase(database, for: connectionId, force: true)
            return true
        } catch {
            logger.error("Closing \(database, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(format: String(localized: "Could not close %@"), database),
                message: error.localizedDescription,
                window: anchor
            )
            return false
        }
    }

    static func closeConnection(_ connectionId: UUID, anchor: NSWindow?) async -> Bool {
        let coordinators = connectionCoordinators(connectionId)
        let pending = pendingRefs(connectionId: connectionId) { _ in true }
        let impact = impact(of: coordinators, pending: pending)

        if impact.needsConfirmation {
            let name = DatabaseManager.shared.session(for: connectionId)?.connection.name ?? ""
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Close %@?"), name),
                message: message(for: impact),
                confirmButton: String(localized: "Close"),
                window: anchor
            )
            guard confirmed else { return false }
        }

        let plan = TabBatchClosePlanner.planCloseForConnection(
            targets: targets(coordinators),
            currentWindowId: anchor.map(ObjectIdentifier.init)
        )
        for coordinator in coordinators {
            coordinator.cancelInFlightQueryTask()
        }
        discardPending(connectionId: connectionId) { _ in true }
        close(plan, among: coordinators)
        await DatabaseManager.shared.disconnectSession(connectionId)
        return true
    }

    static func impact(
        of coordinators: [MainContentCoordinator],
        pending: [DatabaseTreeTableRef]
    ) -> Impact {
        Impact(
            windowCount: coordinators.count,
            unsavedWindowCount: coordinators.filter { $0.hasAnyUnsavedWork() }.count,
            pendingOperationCount: pending.count,
            runningQueryCount: coordinators.filter { $0.currentQueryTask != nil }.count
        )
    }

    static func message(for impact: Impact) -> String {
        var lines: [String] = []
        if impact.windowCount > 0 {
            lines.append(String(format: String(localized: "%d open tabs will close."), impact.windowCount))
        }
        if impact.unsavedWindowCount > 0 {
            lines.append(
                String(format: String(localized: "%d tabs have unsaved changes that will be lost."), impact.unsavedWindowCount)
            )
        }
        if impact.pendingOperationCount > 0 {
            lines.append(
                String(
                    format: String(localized: "%d pending truncate or delete operations will be discarded."),
                    impact.pendingOperationCount
                )
            )
        }
        if impact.runningQueryCount > 0 {
            lines.append(String(localized: "Running queries will be stopped and open transactions rolled back."))
        }
        return lines.joined(separator: "\n")
    }

    private static func connectionCoordinators(_ connectionId: UUID) -> [MainContentCoordinator] {
        MainContentCoordinator.allActiveCoordinators().filter { $0.connectionId == connectionId }
    }

    private static func databaseNames(of coordinator: MainContentCoordinator) -> Set<String> {
        Set(coordinator.tabManager.tabs.compactMap { coordinator.scope(for: $0)?.database })
    }

    private static func targets(_ coordinators: [MainContentCoordinator]) -> [TabBatchCloseTarget] {
        coordinators.compactMap { coordinator in
            guard let window = coordinator.contentWindow else { return nil }
            return TabBatchCloseTarget(windowId: ObjectIdentifier(window), databaseNames: databaseNames(of: coordinator))
        }
    }

    private static func pendingRefs(
        connectionId: UUID,
        where matches: (DatabaseTreeTableRef) -> Bool
    ) -> [DatabaseTreeTableRef] {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return [] }
        return session.pendingTruncates.union(session.pendingDeletes).filter(matches)
    }

    private static func discardPending(connectionId: UUID, where matches: @escaping (DatabaseTreeTableRef) -> Bool) {
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.pendingTruncates = session.pendingTruncates.filter { !matches($0) }
            session.pendingDeletes = session.pendingDeletes.filter { !matches($0) }
            session.tableOperationOptions = session.tableOperationOptions.filter { !matches($0.key) }
        }
    }

    private static func stopQueries(in coordinators: [MainContentCoordinator], connectionId: UUID, database: String) {
        for coordinator in coordinators {
            coordinator.cancelInFlightQueryTask()
        }
        guard DatabaseManager.shared.isDatabaseSessionBusy(database, for: connectionId),
              let driver = DatabaseManager.shared.databaseDriver(for: database, connectionId: connectionId) else { return }
        do {
            try driver.cancelQuery()
        } catch {
            logger.warning("Stopping the query on \(database, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func close(_ plan: TabBatchClosePlanner.Plan, among coordinators: [MainContentCoordinator]) {
        let byWindow: [ObjectIdentifier: MainContentCoordinator] = coordinators.reduce(into: [:]) { result, coordinator in
            guard let window = coordinator.contentWindow else { return }
            result[ObjectIdentifier(window)] = coordinator
        }
        for windowId in plan.windowsToCloseOutright {
            byWindow[windowId]?.commandActions?.closeWindowDiscarding(asBatchSurvivor: false)
        }
        if let survivor = plan.survivorWindowId {
            byWindow[survivor]?.commandActions?.closeWindowDiscarding(asBatchSurvivor: true)
        }
    }
}

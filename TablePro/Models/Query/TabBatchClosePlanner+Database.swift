//
//  TabBatchClosePlanner+Database.swift
//  TablePro
//

import Foundation

extension TabBatchClosePlanner {
    static func planCloseForDatabase(
        targets: [TabBatchCloseTarget],
        database: String,
        currentWindowId: ObjectIdentifier?
    ) -> Plan {
        guard !database.isEmpty else { return .empty }
        let owning = targets.filter { $0.databaseNames.contains(database) }.map(\.windowId)
        guard let currentWindowId, owning.contains(currentWindowId) else {
            return Plan(windowsToCloseOutright: owning, survivorWindowId: nil)
        }
        return Plan(
            windowsToCloseOutright: owning.filter { $0 != currentWindowId },
            survivorWindowId: currentWindowId
        )
    }

    static func planCloseForConnection(
        targets: [TabBatchCloseTarget],
        currentWindowId: ObjectIdentifier?
    ) -> Plan {
        let windows = targets.map(\.windowId)
        guard let currentWindowId, windows.contains(currentWindowId) else {
            return Plan(windowsToCloseOutright: windows, survivorWindowId: nil)
        }
        return Plan(
            windowsToCloseOutright: windows.filter { $0 != currentWindowId },
            survivorWindowId: currentWindowId
        )
    }
}

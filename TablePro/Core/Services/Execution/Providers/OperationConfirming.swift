//
//  OperationConfirming.swift
//  TablePro
//

import AppKit

internal protocol OperationConfirming: Sendable {
    @MainActor
    func confirm(sql: String, operationDescription: String, connectionId: UUID, isDestructive: Bool) async -> Bool

    @MainActor
    func confirm(
        sql: String,
        operationDescription: String,
        connectionId: UUID,
        isDestructive: Bool,
        affectedRows: AffectedRowEstimate
    ) async -> Bool
}

internal extension OperationConfirming {
    @MainActor
    func confirm(
        sql: String,
        operationDescription: String,
        connectionId: UUID,
        isDestructive: Bool,
        affectedRows: AffectedRowEstimate
    ) async -> Bool {
        await confirm(
            sql: sql,
            operationDescription: operationDescription,
            connectionId: connectionId,
            isDestructive: isDestructive
        )
    }
}

internal struct AlertOperationConfirming: OperationConfirming {
    @MainActor
    func confirm(sql: String, operationDescription: String, connectionId: UUID, isDestructive: Bool) async -> Bool {
        await confirm(
            sql: sql,
            operationDescription: operationDescription,
            connectionId: connectionId,
            isDestructive: isDestructive,
            affectedRows: .undetermined(.notACountableStatement)
        )
    }

    @MainActor
    func confirm(
        sql: String,
        operationDescription: String,
        connectionId: UUID,
        isDestructive: Bool,
        affectedRows: AffectedRowEstimate
    ) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let window = WindowLifecycleMonitor.shared.activeWindow(for: connectionId, preferring: NSApp.keyWindow)
        let preview = Self.affectedRowsPreamble(affectedRows) + Self.preview(of: sql)

        if isDestructive {
            return await AlertHelper.confirmCritical(
                title: operationDescription,
                message: String(
                    format: String(
                        localized: "This query may permanently modify or delete data and cannot be undone.\n\n%@"
                    ),
                    preview
                ),
                confirmButton: String(localized: "Execute"),
                cancelButton: String(localized: "Cancel"),
                window: window
            )
        }

        return await AlertHelper.confirmDestructive(
            title: operationDescription,
            message: String(
                format: String(localized: "Are you sure you want to execute this query?\n\n%@"),
                preview
            ),
            confirmButton: String(localized: "Execute"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

    static func affectedRowsPreamble(_ estimate: AffectedRowEstimate) -> String {
        switch estimate {
        case .exact(let count):
            return String(
                format: String(localized: "%d rows currently match this statement's WHERE clause.\n\n"),
                count
            )
        case .wholeTable(let count):
            guard let count else {
                return String(localized: "This statement has no WHERE clause and affects every row in the table.\n\n")
            }
            return String(
                format: String(
                    localized: "This statement has no WHERE clause and affects every row in the table, %d in total.\n\n"
                ),
                count
            )
        case .undetermined(.couldNotDetermine):
            return String(
                localized: "SchemaStudio could not work out how many rows this statement affects.\n\n"
            )
        case .undetermined(.notACountableStatement):
            return ""
        }
    }

    private static func preview(of sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed as NSString).length > 200 {
            return String(trimmed.prefix(200)) + "..."
        }
        return trimmed
    }
}

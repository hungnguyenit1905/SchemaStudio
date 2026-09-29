//
//  MainWindowToolbar+Validation.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension MainWindowToolbar: NSToolbarItemValidation {
    struct ValidationContext {
        let connected: Bool
        let isTableTab: Bool
        let hasPendingChanges: Bool
        let hasDataPendingChanges: Bool
        let blocksAllWrites: Bool
        let supportsImport: Bool
        let supportsServerDashboard: Bool
    }

    static func isEnabled(itemIdentifier: NSToolbarItem.Identifier, context: ValidationContext) -> Bool {
        switch itemIdentifier {
        case history:
            return true
        case refresh, quickSwitcher, newTab, exportTables:
            return context.connected
        case saveChanges:
            return context.hasPendingChanges && context.connected && !context.blocksAllWrites
        case previewSQL:
            return context.hasDataPendingChanges && context.connected
        case results:
            return context.connected && !context.isTableTab
        case dashboard:
            return context.connected && context.supportsServerDashboard
        case importTables:
            return context.connected && !context.blocksAllWrites && context.supportsImport
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let state = coordinator?.toolbarState else { return false }
        let context = ValidationContext(
            connected: state.connectionState == .connected,
            isTableTab: state.isTableTab,
            hasPendingChanges: state.hasPendingChanges,
            hasDataPendingChanges: state.hasDataPendingChanges,
            blocksAllWrites: state.safeModeLevel.blocksAllWrites,
            supportsImport: PluginManager.shared.supportsImport(for: state.databaseType),
            supportsServerDashboard: coordinator?.commandActions?.supportsServerDashboard ?? false
        )
        return Self.isEnabled(itemIdentifier: item.itemIdentifier, context: context)
    }
}

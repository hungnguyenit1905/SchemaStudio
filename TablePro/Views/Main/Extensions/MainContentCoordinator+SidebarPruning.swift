//
//  MainContentCoordinator+SidebarPruning.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func pruneStaleSidebarState() {
        guard case .loaded = services.schemaService.state(for: connectionId) else { return }
        let tables = services.schemaService.allLoadedTables(for: connectionId)
        guard let vm = sidebarViewModel else { return }
        let validNames = Set(tables.map(\.name))
        let browseDatabase = browseDatabaseName
        let staleSelections = vm.selectedTables.filter {
            $0.connectionId == connectionId && $0.database == browseDatabase && !validNames.contains($0.table.name)
        }
        if !staleSelections.isEmpty {
            vm.selectedTables.subtract(staleSelections)
        }
        let stalePendingDeletes = vm.pendingDeletes.subtracting(existingTables(vm.pendingDeletes))
        if !stalePendingDeletes.isEmpty {
            vm.pendingDeletes.subtract(stalePendingDeletes)
            for ref in stalePendingDeletes {
                vm.tableOperationOptions.removeValue(forKey: ref)
            }
        }
        let stalePendingTruncates = vm.pendingTruncates.subtracting(existingTables(vm.pendingTruncates))
        if !stalePendingTruncates.isEmpty {
            vm.pendingTruncates.subtract(stalePendingTruncates)
            for ref in stalePendingTruncates {
                vm.tableOperationOptions.removeValue(forKey: ref)
            }
        }
    }
}

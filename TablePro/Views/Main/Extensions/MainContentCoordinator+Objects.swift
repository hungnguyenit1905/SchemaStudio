//
//  MainContentCoordinator+Objects.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    func showObjects() {
        let tabGroup = contentWindow?.tabbedWindows ?? contentWindow.map { [$0] } ?? []
        for window in tabGroup {
            guard let owner = Self.coordinator(forWindow: window),
                  let objectsTab = owner.tabManager.tabs.first(where: { $0.tabType == .objects }) else { continue }
            owner.tabManager.selectedTabId = objectsTab.id
            window.makeKeyAndOrderFront(nil)
            return
        }

        let scope = windowSidebarState.selectedScope ?? SidebarScope(connectionId: connectionId)
        if scope.connectionId == connectionId, tabManager.tabs.isEmpty {
            tabManager.addObjectsTab(databaseName: scope.database ?? "", schemaName: scope.schema)
            return
        }
        openTabInCurrentWindow(EditorTabPayload(
            connectionId: scope.connectionId,
            tabType: .objects,
            databaseName: scope.database,
            schemaName: scope.schema
        ))
    }
}

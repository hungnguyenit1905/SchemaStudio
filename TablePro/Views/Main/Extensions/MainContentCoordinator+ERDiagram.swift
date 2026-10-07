import AppKit
import Foundation

extension MainContentCoordinator {
    func showERDiagram(scope: DatabaseScope) {
        let schemaKey = "\(scope.database).\(scope.schema ?? "default")"

        if let existing = Self.coordinator(forConnection: scope.connectionId, tabMatching: {
            $0.tabType == .erDiagram && $0.display.erDiagramSchemaKey == schemaKey
        }) {
            existing.contentWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if scope.connectionId == connectionId, tabManager.tabs.isEmpty {
            tabManager.addERDiagramTab(schemaKey: schemaKey, databaseName: scope.database)
            return
        }

        let payload = EditorTabPayload(
            connectionId: scope.connectionId,
            tabType: .erDiagram,
            databaseName: scope.database,
            schemaName: scope.schema,
            erDiagramSchemaKey: schemaKey
        )
        openTabInCurrentWindow(payload)
    }
}

//
//  PreferenceKeys.swift
//  TablePro
//

import Foundation

enum PreferenceKeys {
    static let linkedFolders = DefaultsKey<[LinkedFolder]>("com.SchemaStudio.linkedFolders")
    static let linkedSQLFolders = DefaultsKey<[LinkedSQLFolder]>("com.SchemaStudio.linkedSQLFolders")
    static let selectedSettingsPane = DefaultsKey<String>("com.SchemaStudio.settings.selectedPane")
    static let rowInspectorJsonFieldHeight = DefaultsKey<Double>("com.SchemaStudio.rightSidebar.jsonFieldHeight")

    static let registeredKeyNames: [String] = [
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorJsonFieldHeight.name,
    ]

    static func columnDisplayFormats(_ scope: TableScope) -> DefaultsKey<[String: ValueDisplayFormat]> {
        DefaultsKey("com.SchemaStudio.columns.displayFormat." + scope.storageComponent)
    }

    static func recentTables(connectionId: UUID) -> DefaultsKey<[RecentTableEntry]> {
        DefaultsKey("com.SchemaStudio.recentTables." + connectionId.uuidString)
    }
}

//
//  PluginManifest.swift
//  TablePro
//

import Foundation

internal struct PluginManifest {
    let bundleId: String
    let providedDatabaseTypeIds: [String]
    let providedExportFormatIds: [String]
    let providedImportFormatIds: [String]
    let providedInspectorIds: [String]
    let providedInspectorFileExtensions: [String]
    let providedInspectorUTIs: [String]

    var supportsLazyLoad: Bool {
        !providedDatabaseTypeIds.isEmpty
            || !providedExportFormatIds.isEmpty
            || !providedImportFormatIds.isEmpty
            || !providedInspectorIds.isEmpty
    }

    init?(bundle: Bundle) {
        guard let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        bundleId = id
        providedDatabaseTypeIds = info["SchemaStudioProvidesDatabaseTypeIds"] as? [String] ?? []
        providedExportFormatIds = info["SchemaStudioProvidesExportFormatIds"] as? [String] ?? []
        providedImportFormatIds = info["SchemaStudioProvidesImportFormatIds"] as? [String] ?? []
        providedInspectorIds = info["SchemaStudioProvidesInspectorIds"] as? [String] ?? []
        providedInspectorFileExtensions = info["SchemaStudioInspectorFileExtensions"] as? [String] ?? []
        providedInspectorUTIs = info["SchemaStudioInspectorUTIs"] as? [String] ?? []
    }
}

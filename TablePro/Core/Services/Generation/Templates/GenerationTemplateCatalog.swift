//
//  GenerationTemplateCatalog.swift
//  TablePro
//

import Foundation
import os

/// The templates that ship with the app, read from bundled JSON. Authoring a
/// template is adding a JSON file and its identifier here: no Swift changes and
/// no generator knowledge in this type.
enum GenerationTemplateCatalog {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "GenerationTemplateCatalog")

    static let builtinIdentifiers = ["ecommerce", "crm"]

    static func builtin(bundle: Bundle = .main) -> [GenerationTemplate] {
        builtinIdentifiers.compactMap { load(identifier: $0, bundle: bundle) }
    }

    static func load(identifier: String, bundle: Bundle = .main) -> GenerationTemplate? {
        guard let url = bundle.url(forResource: resourceName(identifier), withExtension: "json") else {
            logger.error("Built-in template \(identifier, privacy: .public) is not in the bundle")
            return nil
        }
        do {
            return try GenerationTemplate.decode(from: Data(contentsOf: url))
        } catch {
            logger.error(
                "Built-in template \(identifier, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func resourceName(_ identifier: String) -> String {
        "generation-template-\(identifier)"
    }
}

extension GenerationTemplate {
    static func decode(from data: Data) throws -> GenerationTemplate {
        try JSONDecoder().decode(GenerationTemplate.self, from: data)
    }
}

import Foundation

enum DatabaseTreeVisibility {
    static func visible(
        databases: [DatabaseMetadata],
        selected: Set<String>,
        alwaysShown: String?,
        showsHiddenItems: Bool = false
    ) -> [DatabaseMetadata] {
        let pinned = alwaysShown.flatMap { $0.isEmpty ? nil : $0 }
        return databases.filter { database in
            if database.name == pinned { return true }
            if database.isSystemDatabase, !showsHiddenItems { return false }
            return selected.isEmpty || selected.contains(database.name)
        }
    }

    static func isFiltering(selected: Set<String>) -> Bool {
        !selected.isEmpty
    }
}

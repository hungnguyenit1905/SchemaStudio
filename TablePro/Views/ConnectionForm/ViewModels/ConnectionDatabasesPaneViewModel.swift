//
//  ConnectionDatabasesPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class ConnectionDatabasesPaneViewModel {
    struct Row: Identifiable, Hashable {
        let name: String
        var isShown: Bool
        var opensAutomatically: Bool

        var id: String { name }
    }

    var useCustomList = false
    var rows: [Row] = []
    var newDatabaseName = ""
    var selection: Set<String> = []
    var coordinator: WeakCoordinatorRef?

    func load(from connection: DatabaseConnection, liveDatabases: [String] = []) {
        let settings = connection.databaseListSettings ?? .empty
        useCustomList = settings.useCustomList
        let names = settings.shown.union(settings.autoOpen).union(liveDatabases)
        rows = names.sorted().map { name in
            Row(
                name: name,
                isShown: !settings.useCustomList || settings.shown.contains(name),
                opensAutomatically: settings.autoOpen.contains(name)
            )
        }
    }

    func mergeLiveDatabases(_ names: [String]) {
        let known = Set(rows.map(\.name))
        let added = names.filter { !known.contains($0) }.map {
            Row(name: $0, isShown: !useCustomList, opensAutomatically: false)
        }
        rows = (rows + added).sorted { $0.name < $1.name }
    }

    func addDatabase() {
        let name = newDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rows.contains(where: { $0.name == name }) else { return }
        rows.append(Row(name: name, isShown: true, opensAutomatically: false))
        rows.sort { $0.name < $1.name }
        newDatabaseName = ""
    }

    func removeSelected() {
        rows.removeAll { selection.contains($0.name) }
        selection = []
    }

    func settings(for databaseType: DatabaseType) -> DatabaseListSettings? {
        guard DatabaseLevel.live.hasDatabaseLevel(databaseType) else { return nil }
        let settings = DatabaseListSettings(
            useCustomList: useCustomList,
            shown: useCustomList ? Set(rows.filter(\.isShown).map(\.name)) : [],
            autoOpen: Set(rows.filter(\.opensAutomatically).map(\.name))
        )
        return settings.isEmpty ? nil : settings
    }
}

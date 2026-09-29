@testable import SchemaStudio
import Testing

@Suite("DatabaseTreeVisibility")
struct DatabaseTreeVisibilityTests {
    private let databases: [DatabaseMetadata] = [
        .minimal(name: "analytics"),
        .minimal(name: "billing"),
        .minimal(name: "legacy_2019"),
        .minimal(name: "mysql", isSystem: true),
        .minimal(name: "information_schema", isSystem: true)
    ]

    @Test("Empty selection shows all non-system databases")
    func emptyShowsAll() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], alwaysShown: nil)
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("Non-empty selection shows only the selected non-system databases")
    func selectionShowsSubset() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["billing", "legacy_2019"],
            alwaysShown: nil
        )
        #expect(visible.map(\.name) == ["billing", "legacy_2019"])
    }

    @Test("System databases are hidden even when selected")
    func systemHiddenWhenSelected() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["mysql", "analytics"],
            alwaysShown: nil
        )
        #expect(visible.map(\.name) == ["analytics"])
    }

    @Test("Selecting a database that no longer exists yields an empty result")
    func staleSelectionEmpty() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["dropped_db"],
            alwaysShown: nil
        )
        #expect(visible.isEmpty)
    }

    @Test("The default database stays visible even when it is a system database")
    func defaultSystemDatabaseStaysVisible() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], alwaysShown: "mysql")
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019", "mysql"])
    }

    @Test("The default database stays visible when the filter excludes it")
    func defaultDatabaseSurvivesFilter() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["billing"],
            alwaysShown: "analytics"
        )
        #expect(visible.map(\.name) == ["analytics", "billing"])
    }

    @Test("The default database keeps its position in the list")
    func defaultDatabaseKeepsPosition() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: [],
            alwaysShown: "information_schema"
        )
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019", "information_schema"])
    }

    @Test("An empty default database name is treated as absent")
    func emptyDefaultDatabaseIgnored() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], alwaysShown: "")
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("Show Hidden Items reveals system databases")
    func showHiddenItemsRevealsSystemDatabases() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: [],
            alwaysShown: nil,
            showsHiddenItems: true
        )
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019", "mysql", "information_schema"])
    }

    @Test("Show Hidden Items still respects the custom list")
    func showHiddenItemsRespectsSelection() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["mysql"],
            alwaysShown: nil,
            showsHiddenItems: true
        )
        #expect(visible.map(\.name) == ["mysql"])
    }

    @Test("isFiltering reflects whether a selection is active")
    func isFiltering() {
        #expect(DatabaseTreeVisibility.isFiltering(selected: []) == false)
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["analytics"]))
    }
}

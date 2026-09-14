//
//  GenerationPlanCompilerTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("ColumnDependencySorter")
struct ColumnDependencySorterTests {
    @Test("A copy chain is ordered source before reader")
    func copyChainOrders() throws {
        let sorted = try ColumnDependencySorter.sort(
            columns: ["slug", "title", "legacy_slug"],
            dependencies: ["slug": ["title"], "legacy_slug": ["slug"]],
            table: "posts"
        )
        #expect(sorted == ["title", "slug", "legacy_slug"])
    }

    @Test("Columns with no dependencies keep their declared order")
    func independentColumnsKeepOrder() throws {
        let sorted = try ColumnDependencySorter.sort(
            columns: ["c", "a", "b"],
            dependencies: [:],
            table: "t"
        )
        #expect(sorted == ["c", "a", "b"])
    }

    @Test("A dependency on a column outside the table is ignored")
    func externalDependencyIgnored() throws {
        let sorted = try ColumnDependencySorter.sort(
            columns: ["a"],
            dependencies: ["a": ["not_here"]],
            table: "t"
        )
        #expect(sorted == ["a"])
    }

    @Test("A two-column loop is a configuration error naming both columns")
    func twoColumnCycle() {
        #expect(throws: GenerationError.columnDependencyCycle(table: "t", columns: ["a", "b"])) {
            _ = try ColumnDependencySorter.sort(
                columns: ["a", "b"],
                dependencies: ["a": ["b"], "b": ["a"]],
                table: "t"
            )
        }
    }

    @Test("A column that copies itself is a loop")
    func selfCycle() {
        #expect(throws: GenerationError.columnDependencyCycle(table: "t", columns: ["a"])) {
            _ = try ColumnDependencySorter.sort(columns: ["a"], dependencies: ["a": ["a"]], table: "t")
        }
    }

    @Test("A column named twice does not trap building the in-degree map")
    func duplicateColumnDoesNotTrap() throws {
        let sorted = try ColumnDependencySorter.sort(
            columns: ["a", "b", "a"],
            dependencies: [:],
            table: "t"
        )
        #expect(sorted == ["a", "b"])
    }
}

@Suite("GenerationPlanCompiler")
struct GenerationPlanCompilerTests {
    private typealias Fixtures = GenerationPlanningFixtures

    @Test("Tables are planned parent first")
    func tablesAreOrdered() throws {
        let schema = Fixtures.shopSchema
        let plan = try GenerationPlanCompiler().compile(
            profile: Fixtures.autoProfile(for: schema),
            schema: schema
        )
        #expect(plan.tables.map(\.reference.table) == ["customers", "orders", "order_items"])
        #expect(plan.totalRowCount == 30)
        #expect(!plan.requiresConstraintDisable)
    }

    @Test("A server-assigned column is left out of the insert")
    func identityColumnExcluded() throws {
        let schema = Fixtures.shopSchema
        let plan = try GenerationPlanCompiler().compile(
            profile: Fixtures.autoProfile(for: schema),
            schema: schema
        )
        let customers = try #require(plan.tables.first { $0.reference.table == "customers" })
        #expect(customers.insertColumns == ["email"])
        #expect(customers.columns.map(\.name) == ["id", "email"])
        #expect(try #require(customers.columns.first).excludedFromInsert)
        #expect(!customers.usesDefaultValues)
    }

    @Test("A table with nothing but server-assigned columns takes the default-values shape")
    func defaultValuesShape() throws {
        let schema = [Fixtures.table("ticks", columns: [Fixtures.identityColumn()])]
        let plan = try GenerationPlanCompiler().compile(
            profile: Fixtures.autoProfile(for: schema),
            schema: schema
        )
        let ticks = try #require(plan.tables.first)
        #expect(ticks.insertColumns.isEmpty)
        #expect(ticks.usesDefaultValues)
    }

    @Test("Columns are planned in row-dependency order")
    func columnsAreSorted() throws {
        let schema = [Fixtures.table("posts", columns: [
            PluginColumnInfo(name: "slug", dataType: "text"),
            PluginColumnInfo(name: "title", dataType: "text")
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("posts", columns: [
                GenerationColumnProfile(
                    column: "slug",
                    generator: "Copy",
                    params: .object(["sourceColumn": .string("title")])
                ),
                GenerationColumnProfile(column: "title", generator: "LoremWords")
            ])
        ])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        let posts = try #require(plan.tables.first)
        #expect(posts.columns.map(\.name) == ["title", "slug"])
        #expect(posts.columns.last?.dependencies == ["title"])
    }

    @Test("A self-referencing foreign key is recorded for the second pass")
    func selfReferenceIsDeferred() throws {
        let schema = [Fixtures.table(
            "employees",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "manager_id", dataType: "bigint", isNullable: true)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "manager_id", to: "employees")]
        )]
        let plan = try GenerationPlanCompiler().compile(
            profile: Fixtures.autoProfile(for: schema),
            schema: schema
        )
        let employees = try #require(plan.tables.first)
        #expect(employees.deferredColumns == ["manager_id"])
    }

    @Test("A cycle refuses to compile rather than producing a broken plan")
    func cycleRefusesToCompile() {
        let left = Fixtures.table(
            "left",
            columns: [PluginColumnInfo(name: "right_id", dataType: "bigint", isNullable: false)],
            foreignKeys: [Fixtures.foreignKey(from: "right_id", to: "right")]
        )
        let right = Fixtures.table(
            "right",
            columns: [PluginColumnInfo(name: "left_id", dataType: "bigint", isNullable: false)],
            foreignKeys: [Fixtures.foreignKey(from: "left_id", to: "left")]
        )
        let schema = [left, right]
        #expect(throws: GenerationError.self) {
            _ = try GenerationPlanCompiler().compile(
                profile: Fixtures.autoProfile(for: schema),
                schema: schema
            )
        }
    }

    @Test("The plan carries the profile's seed and row counts")
    func planCarriesSeedAndCounts() throws {
        let schema = [Fixtures.table("t", columns: [PluginColumnInfo(name: "a", dataType: "text")])]
        var profile = Fixtures.autoProfile(for: schema, rowCount: 250)
        profile.seed = 4_242
        profile.tables[0].emptyFirst = true
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        #expect(plan.seed == 4_242)
        #expect(plan.tables.first?.rowCount == 250)
        #expect(plan.tables.first?.emptyFirst == true)
    }

    @Test("A table named twice in the profile compiles without trapping")
    func duplicateTableDoesNotTrap() throws {
        let schema = [Fixtures.table("t", columns: [PluginColumnInfo(name: "a", dataType: "text")])]
        var profile = Fixtures.autoProfile(for: schema)
        profile.tables.append(profile.tables[0])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        #expect(plan.tables.map(\.reference.table) == ["t"])
    }

    @Test("A table in the profile that the schema no longer has is dropped from the plan")
    func missingTableIsDropped() throws {
        let schema = [Fixtures.table("t", columns: [PluginColumnInfo(name: "a", dataType: "text")])]
        var profile = Fixtures.autoProfile(for: schema)
        profile.tables.append(
            Fixtures.tableProfile("gone", columns: [
                GenerationColumnProfile(column: "x", generator: "LoremWords")
            ])
        )
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        #expect(plan.tables.map(\.reference.table) == ["t"])
    }
}

@Suite("TypeFallbackGeneratorResolver")
struct TypeFallbackGeneratorResolverTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func resolve(_ column: PluginColumnInfo, databaseType: DatabaseType = .postgresql) -> String {
        let table = Fixtures.table("t", columns: [column], databaseType: databaseType)
        guard let resolved = table.column(named: column.name) else { return "" }
        return TypeFallbackGeneratorResolver.resolve(resolved).identifier
    }

    @Test("Each base type resolves to the generator that can fill it")
    func typesResolve() {
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "boolean")) == "Boolean")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "integer")) == "Integer")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "numeric(10,2)")) == "Decimal")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "double precision")) == "Double")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "uuid")) == "UUID")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "date")) == "Date")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "timestamp")) == "DateTime")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "bytea")) == "RandomBytes")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "varchar(8)")) == "RandomString")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "varchar(40)")) == "LoremWords")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "text")) == "LoremWords")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "jsonb")) == "Fixed")
    }

    @Test("A server-assigned column resolves to the server's own value")
    func serverAssignedResolvesToDefault() {
        #expect(resolve(Fixtures.identityColumn()) == "Default")
        #expect(resolve(PluginColumnInfo(name: "a", dataType: "integer", isGenerated: true)) == "Default")
    }

    @Test("An enum column resolves to its own value list")
    func enumResolvesToList() {
        let table = Fixtures.table(
            "t",
            columns: [
                PluginColumnInfo(
                    name: "status",
                    dataType: "enum('new','paid')",
                    allowedValues: ["new", "paid"]
                )
            ],
            databaseType: .mysql
        )
        guard let column = table.column(named: "status") else {
            Issue.record("fixture column missing")
            return
        }
        let resolution = TypeFallbackGeneratorResolver.resolve(column)
        #expect(resolution.identifier == "List")
        #expect(resolution.params.objectValue?["values"] == .array([.string("new"), .string("paid")]))
    }

    @Test("A foreign key resolves to a reference draw")
    func foreignKeyResolvesToReference() {
        let table = Fixtures.table(
            "orders",
            columns: [PluginColumnInfo(name: "customer_id", dataType: "bigint")],
            foreignKeys: [Fixtures.foreignKey(from: "customer_id", to: "customers")]
        )
        guard let column = table.column(named: "customer_id") else {
            Issue.record("fixture column missing")
            return
        }
        #expect(TypeFallbackGeneratorResolver.resolve(column).identifier == "Reference")
    }

    @Test("Every resolution builds a working generator", arguments: [
        "boolean", "integer", "numeric(10,2)", "double precision", "uuid", "date",
        "timestamp", "bytea", "varchar(40)", "varchar(8)", "text", "smallint", "bigint", "jsonb"
    ])
    func everyResolutionBuilds(dataType: String) throws {
        let table = GenerationPlanningFixtures.table(
            "t",
            columns: [PluginColumnInfo(name: "a", dataType: dataType)]
        )
        let column = try #require(table.column(named: "a"))
        let resolution = TypeFallbackGeneratorResolver.resolve(column)
        let params = GenerationColumnProfile(
            column: "a",
            generator: resolution.identifier,
            params: resolution.params
        ).paramData
        let generator = try GeneratorRegistry.standard.make(
            identifier: resolution.identifier,
            params: params,
            column: column,
            seed: 1
        )
        _ = try generator.next(row: RowContext(table: "t", rowIndex: 0), index: 0)
    }
}

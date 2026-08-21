//
//  GenerationTemplateTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private typealias Fixtures = GenerationPlanningFixtures

@Suite("GenerationTemplate")
struct GenerationTemplateTests {
    private let applier = GenerationTemplateApplier()

    private var ecommerce: GenerationTemplate {
        get throws {
            try #require(GenerationTemplateCatalog.load(identifier: "ecommerce", bundle: .schemaStudio))
        }
    }

    private func usersTable(emailType: String = "varchar(255)") -> GenerationTable {
        Fixtures.table("users", columns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "email", dataType: emailType, isNullable: false),
            PluginColumnInfo(name: "first_name", dataType: "varchar(80)", isNullable: false),
            PluginColumnInfo(name: "created_at", dataType: "timestamp", isNullable: false)
        ])
    }

    /// Every column the e-commerce template names for `users`, so a full match
    /// leaves nothing unplaced.
    private var completeUsersTable: GenerationTable {
        Fixtures.table("users", columns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "email", dataType: "varchar(255)", isNullable: false),
            PluginColumnInfo(name: "username", dataType: "varchar(60)", isNullable: false),
            PluginColumnInfo(name: "first_name", dataType: "varchar(80)", isNullable: false),
            PluginColumnInfo(name: "last_name", dataType: "varchar(80)", isNullable: false),
            PluginColumnInfo(name: "full_name", dataType: "varchar(160)", isNullable: false),
            PluginColumnInfo(name: "phone", dataType: "varchar(40)", isNullable: true),
            PluginColumnInfo(name: "city", dataType: "varchar(80)", isNullable: true),
            PluginColumnInfo(name: "country", dataType: "varchar(80)", isNullable: true),
            PluginColumnInfo(name: "postal_code", dataType: "varchar(20)", isNullable: true),
            PluginColumnInfo(name: "created_at", dataType: "timestamp", isNullable: false)
        ])
    }

    private var productsTable: GenerationTable {
        Fixtures.table("products", columns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "name", dataType: "varchar(120)", isNullable: false),
            PluginColumnInfo(name: "price", dataType: "numeric(10,2)", isNullable: false)
        ])
    }

    // MARK: - Catalog

    @Test("Both built-in templates load from the bundle", arguments: GenerationTemplateCatalog.builtinIdentifiers)
    func builtinTemplatesLoad(identifier: String) throws {
        let template = try #require(GenerationTemplateCatalog.load(identifier: identifier, bundle: .schemaStudio))
        #expect(template.id == identifier)
        #expect(!template.name.isEmpty)
        #expect(!template.tables.isEmpty)
    }

    @Test("Every generator a built-in template names is registered")
    func builtinGeneratorsExist() throws {
        for identifier in GenerationTemplateCatalog.builtinIdentifiers {
            let template = try #require(GenerationTemplateCatalog.load(identifier: identifier, bundle: .schemaStudio))
            for table in template.tables {
                for column in table.columns {
                    #expect(
                        GeneratorRegistry.standard.contains(column.generator),
                        "\(identifier).\(table.table).\(column.column) names an unknown generator"
                    )
                }
            }
        }
    }

    // MARK: - Applying

    @Test("A table carrying every column the template names is filled by the template")
    func matchingSchemaIsFilled() throws {
        let application = try applier.apply(try ecommerce, to: [completeUsersTable], seed: 7)

        #expect(application.matchedTables == ["users"])
        #expect(application.unmatchedColumns.isEmpty)
        #expect(application.profile.seed == 7)

        let users = try #require(application.profile.table(named: "users", schema: "public"))
        #expect(users.column(named: "email")?.generator == "Email")
        #expect(users.column(named: "first_name")?.generator == "FirstName")
        #expect(users.column(named: "created_at")?.generator == "DateTime")
        #expect(users.column(named: "postal_code")?.generator == "PostalCode")
        #expect(users.column(named: "id")?.generator == "Default")
    }

    @Test("A column the template never names still gets a generator")
    func unnamedColumnsAreAutoMapped() throws {
        let extended = Fixtures.table("products", columns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "name", dataType: "varchar(120)", isNullable: false),
            PluginColumnInfo(name: "internal_note", dataType: "text", isNullable: true)
        ])
        let application = try applier.apply(try ecommerce, to: [extended], seed: 1)

        let products = try #require(application.profile.table(named: "products", schema: "public"))
        #expect(products.columns.count == extended.columns.count)
        #expect(products.column(named: "internal_note")?.generator.isEmpty == false)
    }

    @Test("A partial schema fills what it can and reports the tables it could not place")
    func partialSchemaReportsTheRest() throws {
        let application = try applier.apply(try ecommerce, to: [usersTable()], seed: 1)

        #expect(application.matchedTables == ["users"])
        #expect(application.unmatchedTables.contains("products"))
        #expect(application.unmatchedTables.contains("orders"))
        #expect(!application.isComplete)
    }

    @Test("A column whose generator will not build falls back to the auto-mapper and says so")
    func unusableColumnIsReported() throws {
        let template = GenerationTemplate(
            id: "broken",
            name: "Broken",
            summary: "",
            tables: [
                GenerationTemplateTable(
                    table: "users",
                    rowCount: 10,
                    columns: [
                        GenerationTemplateColumn(column: "first_name", generator: "FirstName"),
                        GenerationTemplateColumn(
                            column: "email",
                            generator: "List",
                            params: .object(["values": .array([])])
                        )
                    ]
                )
            ]
        )
        let application = try applier.apply(template, to: [usersTable()], seed: 1)

        #expect(application.unmatchedColumns == ["users.email"])
        let users = try #require(application.profile.table(named: "users", schema: "public"))
        #expect(users.column(named: "email")?.generator == "Email")
        #expect(users.column(named: "first_name")?.generator == "FirstName")
    }

    @Test("An unrelated schema is refused instead of half-applied")
    func unrelatedSchemaIsRefused() throws {
        let unrelated = [
            Fixtures.table("audit_log", columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "payload", dataType: "text", isNullable: true)
            ])
        ]
        #expect(throws: GenerationError.templateDidNotMatch(template: try ecommerce.name)) {
            try applier.apply(try ecommerce, to: unrelated, seed: 1)
        }
    }

    @Test("Table names match without regard to case")
    func tableMatchIgnoresCase() throws {
        let upper = Fixtures.table("USERS", columns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "EMAIL", dataType: "varchar(255)", isNullable: false)
        ])
        let application = try applier.apply(try ecommerce, to: [upper], seed: 1)

        #expect(application.matchedTables == ["USERS"])
        let users = try #require(application.profile.table(named: "USERS", schema: "public"))
        #expect(users.column(named: "EMAIL")?.generator == "Email")
    }

    @Test("The applied profile carries the scope it was given")
    func scopeIsCarried() throws {
        let scope = GenerationProfileScope(connectionName: "Local", database: "shop", schema: "public")
        let application = try applier.apply(try ecommerce, to: [usersTable()], seed: 1, scope: scope)
        #expect(application.profile.scope == scope)
    }
}

private extension Bundle {
    /// A hosted test run reads the templates out of the app bundle. Falling back to
    /// the test bundle keeps the suite honest if the host ever goes away.
    static var schemaStudio: Bundle {
        let probe = GenerationTemplateCatalog.resourceName(GenerationTemplateCatalog.builtinIdentifiers[0])
        if Bundle.main.url(forResource: probe, withExtension: "json") != nil { return .main }
        return Bundle(for: BundleToken.self)
    }
}

private final class BundleToken {}

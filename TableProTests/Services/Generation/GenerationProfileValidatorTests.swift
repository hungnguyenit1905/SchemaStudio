//
//  GenerationProfileValidatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("GenerationProfileValidator")
struct GenerationProfileValidatorTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func validate(
        profile: GenerationProfile,
        schema: [GenerationTable],
        existingRowCount: @escaping GenerationProfileValidator.RowCountLookup = { _ in nil }
    ) -> [GenerationError] {
        GenerationProfileValidator(existingRowCount: existingRowCount)
            .validate(profile: profile, schema: schema)
    }

    @Test("A required column set to the Null generator is refused")
    func nullGeneratorOnRequiredColumn() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "name", dataType: "text", isNullable: false)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(column: "name", generator: "Null")
            ])
        ])
        #expect(
            validate(profile: profile, schema: schema)
                .contains(.nullGeneratorOnRequiredColumn(table: "public.t", column: "name"))
        )
    }

    @Test("A required column with a null percentage is refused")
    func nullPercentOnRequiredColumn() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "name", dataType: "text", isNullable: false)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(
                    column: "name",
                    generator: "LoremWords",
                    common: CommonParams(nullPercent: 5)
                )
            ])
        ])
        #expect(
            validate(profile: profile, schema: schema)
                .contains(.nullPercentOnRequiredColumn(table: "public.t", column: "name", percent: 5))
        )
    }

    @Test("A nullable column may produce nulls")
    func nullableColumnAcceptsNulls() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "note", dataType: "text", isNullable: true)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(
                    column: "note",
                    generator: "LoremWords",
                    common: CommonParams(nullPercent: 40)
                )
            ])
        ])
        #expect(validate(profile: profile, schema: schema).isEmpty)
    }

    @Test("A unique column whose generator cannot fill the row count is refused before any write")
    func uniqueDomainTooSmall() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "code", dataType: "integer", isNullable: false)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", rowCount: 1_000, columns: [
                GenerationColumnProfile(
                    column: "code",
                    generator: "Integer",
                    params: .object(["min": .int(1), "max": .int(100)]),
                    common: CommonParams(unique: true)
                )
            ])
        ])
        #expect(
            validate(profile: profile, schema: schema).contains(
                .uniqueDomainTooSmall(table: "public.t", column: "code", distinctValues: 100, rowCount: 1_000)
            )
        )
    }

    @Test("A unique column with room to spare passes")
    func uniqueDomainLargeEnough() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "code", dataType: "integer", isNullable: false)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", rowCount: 100, columns: [
                GenerationColumnProfile(
                    column: "code",
                    generator: "Integer",
                    params: .object(["min": .int(1), "max": .int(1_000)]),
                    common: CommonParams(unique: true)
                )
            ])
        ])
        #expect(validate(profile: profile, schema: schema).isEmpty)
    }

    @Test("A column the schema declares unique is checked even without the Unique setting")
    func schemaUniquenessIsEnough() {
        let schema = [Fixtures.table(
            "t",
            columns: [
                PluginColumnInfo(
                    name: "code",
                    dataType: "integer",
                    isNullable: false,
                    checkExpressions: [],
                    uniqueConstraints: ["t_code_key"]
                )
            ],
            indexes: [PluginIndexInfo(name: "t_code_key", columns: ["code"], isUnique: true)]
        )]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", rowCount: 500, columns: [
                GenerationColumnProfile(
                    column: "code",
                    generator: "Integer",
                    params: .object(["min": .int(1), "max": .int(10)])
                )
            ])
        ])
        #expect(validate(profile: profile, schema: schema).contains {
            if case .uniqueDomainTooSmall = $0 { return true } else { return false }
        })
    }

    @Test("A generator with no computable domain skips the cardinality check")
    func uncomputableDomainIsSkipped() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "blurb", dataType: "text", isNullable: false)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", rowCount: 1_000_000, columns: [
                GenerationColumnProfile(
                    column: "blurb",
                    generator: "LoremWords",
                    common: CommonParams(unique: true)
                )
            ])
        ])
        #expect(validate(profile: profile, schema: schema).isEmpty)
    }

    @Test("A required foreign key to an empty table outside the run is refused, naming both tables")
    func emptyParentTable() {
        let schema = [Fixtures.table(
            "orders",
            columns: [
                PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "customer_id", to: "customers")]
        )]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("orders", columns: [
                GenerationColumnProfile(column: "customer_id", generator: "Reference")
            ])
        ])
        let errors = validate(profile: profile, schema: schema, existingRowCount: { _ in 0 })
        #expect(errors.contains(.emptyParentTable(
            table: "public.orders",
            column: "customer_id",
            parentTable: "public.customers"
        )))
    }

    @Test("A parent that already has rows is accepted")
    func populatedParentTable() {
        let schema = [Fixtures.table(
            "orders",
            columns: [PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: false)],
            foreignKeys: [Fixtures.foreignKey(from: "customer_id", to: "customers")]
        )]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("orders", columns: [
                GenerationColumnProfile(column: "customer_id", generator: "Reference")
            ])
        ])
        #expect(validate(profile: profile, schema: schema, existingRowCount: { _ in 25 }).isEmpty)
    }

    @Test("A parent inside the run is accepted even when it is empty now")
    func parentInsideTheRun() {
        let profile = Fixtures.autoProfile(for: Fixtures.shopSchema)
        #expect(validate(profile: profile, schema: Fixtures.shopSchema, existingRowCount: { _ in 0 }).isEmpty)
    }

    @Test("A generated column is not validated as if the user could fill it")
    func generatedColumnIsSkipped() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "total", dataType: "numeric(10,2)", isNullable: false, isGenerated: true)
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(column: "total", generator: "Null")
            ])
        ])
        #expect(validate(profile: profile, schema: schema).isEmpty)
    }

    @Test("Malformed generator settings are reported against the column")
    func malformedParamsAreReported() {
        let schema = [Fixtures.table("t", columns: [
            PluginColumnInfo(name: "tier", dataType: "text")
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(column: "tier", generator: "List", params: .object(["values": .array([])]))
            ])
        ])
        #expect(validate(profile: profile, schema: schema).contains {
            if case .invalidParameters = $0 { return true } else { return false }
        })
    }

    @Test("A column the table no longer has is reported")
    func unknownColumnIsReported() {
        let schema = [Fixtures.table("t", columns: [PluginColumnInfo(name: "a", dataType: "text")])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("t", columns: [
                GenerationColumnProfile(column: "gone", generator: "LoremWords")
            ])
        ])
        #expect(validate(profile: profile, schema: schema) == [.unknownColumn(table: "public.t", column: "gone")])
    }

    @Test("Every error explains itself and says how to fix it", arguments: GenerationErrorSamples.all)
    func everyErrorCarriesRecovery(error: GenerationError) {
        let description = error.errorDescription ?? ""
        let recovery = error.recoverySuggestion ?? ""
        #expect(!description.isEmpty)
        #expect(!recovery.isEmpty)
        #expect(recovery != description)
    }

    @Test("A cycle error names the tables in the cycle")
    func cycleErrorNamesTables() {
        let error = GenerationError.tableDependencyCycle(tables: ["public.left", "public.right"])
        let description = error.errorDescription ?? ""
        #expect(description.contains("public.left"))
        #expect(description.contains("public.right"))
    }

    @Test("The cardinality error names the column, the domain and the row count")
    func cardinalityErrorIsSpecific() {
        let error = GenerationError.uniqueDomainTooSmall(
            table: "public.t",
            column: "code",
            distinctValues: 100,
            rowCount: 1_000
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("code"))
        #expect(description.contains("100"))
        #expect(description.contains("1"))
        #expect(error.recoverySuggestion?.contains("code") == true)
    }
}

enum GenerationErrorSamples {
    static let all: [GenerationError] = [
        .unknownGenerator(identifier: "Nope"),
        .invalidParameters(generator: "List", reason: "empty"),
        .uniqueExhausted(column: "email", attempts: 64),
        .dependencyMissing(column: "slug", dependsOn: "title"),
        .nullGeneratorOnRequiredColumn(table: "t", column: "c"),
        .nullPercentOnRequiredColumn(table: "t", column: "c", percent: 10),
        .uniqueDomainTooSmall(table: "t", column: "c", distinctValues: 5, rowCount: 50),
        .emptyParentTable(table: "t", column: "c", parentTable: "p"),
        .tableDependencyCycle(tables: ["a", "b"]),
        .columnDependencyCycle(table: "t", columns: ["a", "b"]),
        .unsupportedProfileVersion(found: 9, supported: 1),
        .unknownColumn(table: "t", column: "c")
    ]
}

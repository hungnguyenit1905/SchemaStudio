import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferIdentifierPolicy")
struct TransferIdentifierPolicyTests {
    private let postgres = TransferIdentifierPolicy.policy(for: .postgresql)
    private let mysql = TransferIdentifierPolicy.policy(for: .mysql)

    @Test("Vendor limits match what the engines accept")
    func vendorLimits() {
        #expect(postgres.maxLengthBytes == 63)
        #expect(mysql.maxLengthBytes == 64)
        #expect(TransferIdentifierPolicy.policy(for: .mssql).maxLengthBytes == 128)
    }

    @Test("A name inside the limit is untouched")
    func shortNameUnchanged() {
        #expect(postgres.shorten("idx_users_email") == "idx_users_email")
    }

    @Test("A 70 character name is shortened to fit PostgreSQL")
    func longNameShortened() {
        let name = String(repeating: "a", count: 70)
        let shortened = postgres.shorten(name)

        #expect(shortened != name)
        #expect(shortened.utf8.count <= 63)
    }

    @Test("An index name joining four columns fits after shortening")
    func compositeIndexName() {
        let name = "idx_organisation_membership_subscription_billing_account_reference_state"
        let shortened = postgres.shorten(name)

        #expect(shortened.utf8.count <= 63)
        #expect(shortened.hasPrefix("idx_organisation_membership"))
    }

    /// The limit is a byte budget, so a name well inside 63 characters can still
    /// overrun it once its scalars are encoded.
    @Test("Shortening counts bytes, not characters")
    func multiByteNameShortened() {
        let name = String(repeating: "é", count: 40)

        #expect(name.count == 40)
        #expect(name.utf8.count == 80)
        #expect(postgres.shorten(name).utf8.count <= 63)
    }

    @Test("Shortening never splits a scalar")
    func emojiNameStaysValid() {
        let name = String(repeating: "🍎", count: 30)
        let shortened = postgres.shorten(name)

        #expect(shortened.utf8.count <= 63)
        #expect(!shortened.contains("\u{FFFD}"))
    }

    /// A rerun that shortened names differently would build indexes the previous
    /// run's foreign keys no longer name.
    @Test("Shortening is stable across calls")
    func shorteningIsDeterministic() {
        let name = String(repeating: "column_name_", count: 10)

        #expect(postgres.shorten(name) == postgres.shorten(name))
        #expect(TransferIdentifierPolicy.stableHash("users") == TransferIdentifierPolicy.stableHash("users"))
    }

    @Test("Two long names sharing a prefix stay apart")
    func sharedPrefixNamesStayDistinct() {
        let prefix = String(repeating: "a", count: 60)
        let first = prefix + "_created_at"
        let second = prefix + "_updated_at"

        #expect(postgres.shorten(first) != postgres.shorten(second))
    }

    @Test("A reserved word is left alone because every identifier reaches the target quoted")
    func reservedWordUnchanged() {
        #expect(postgres.shorten("select") == "select")
        #expect(postgres.shorten("order") == "order")
    }

    @Test("The map reports a name it had to shorten")
    func mapReportsShortening() {
        let name = String(repeating: "b", count: 80)
        let map = TransferIdentifierMap(names: [name], policy: postgres)

        #expect(map.resolve(name).utf8.count <= 63)
        #expect(map.warnings.contains { warning in
            if case .identifierShortened = warning { return true }
            return false
        })
    }

    @Test("The map resolves an unknown name to itself")
    func unknownNameResolvesToItself() {
        let map = TransferIdentifierMap(names: ["idx_a"], policy: postgres)

        #expect(map.resolve("idx_b") == "idx_b")
    }

    /// Names are quoted at the target, so two that differ only in case remain
    /// two names. The map has to keep them apart rather than fold them together.
    @Test("Names differing only in case stay distinct and are reported")
    func caseOnlyNamesReported() {
        let map = TransferIdentifierMap(names: ["MyIndex", "myindex"], policy: postgres)

        #expect(map.resolve("MyIndex") == "MyIndex")
        #expect(map.resolve("myindex") == "myindex")
        #expect(map.warnings.contains { warning in
            if case .identifierCollision = warning { return true }
            return false
        })
    }

    @Test("The same name listed twice is resolved once and reported once")
    func duplicateNameNotReportedAsCollision() {
        let map = TransferIdentifierMap(names: ["idx_a", "idx_a"], policy: postgres)

        #expect(map.resolve("idx_a") == "idx_a")
        #expect(map.warnings.isEmpty)
    }

    @Test("A table or column over the limit is reported, not renamed")
    func overLongTableAndColumnReported() {
        let table = String(repeating: "t", count: 70)
        let warnings = TransferStructureBuilder.nameWarnings(
            table: table,
            columns: ["id"],
            policy: postgres
        )

        #expect(warnings.contains { warning in
            if case .identifierTooLong(let name, let limit) = warning { return name == table && limit == 63 }
            return false
        })
    }

    @Test("Two columns differing only in case are reported")
    func caseOnlyColumnClashReported() {
        let warnings = TransferStructureBuilder.nameWarnings(
            table: "users",
            columns: ["Email", "email"],
            policy: postgres
        )

        #expect(warnings.contains { warning in
            if case .caseOnlyNameClash = warning { return true }
            return false
        })
    }

    @Test("A renamed index keeps every other field")
    func renamedIndexKeepsFields() {
        let index = PluginIndexDefinition(
            name: "long_name",
            columns: ["a", "b"],
            isUnique: true,
            indexType: "BTREE",
            columnPrefixes: ["a": 10],
            whereClause: "a IS NOT NULL"
        )
        let renamed = index.renamed(to: "short")

        #expect(renamed.name == "short")
        #expect(renamed.columns == ["a", "b"])
        #expect(renamed.isUnique)
        #expect(renamed.indexType == "BTREE")
        #expect(renamed.columnPrefixes?["a"] == 10)
        #expect(renamed.whereClause == "a IS NOT NULL")
    }

    @Test("A renamed foreign key keeps every other field")
    func renamedForeignKeyKeepsFields() {
        let foreignKey = PluginForeignKeyDefinition(
            name: "long_name",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: "CASCADE",
            onUpdate: "RESTRICT",
            referencedSchema: "public"
        )
        let renamed = foreignKey.renamed(to: "short")

        #expect(renamed.name == "short")
        #expect(renamed.columns == ["user_id"])
        #expect(renamed.referencedTable == "users")
        #expect(renamed.referencedColumns == ["id"])
        #expect(renamed.onDelete == "CASCADE")
        #expect(renamed.onUpdate == "RESTRICT")
        #expect(renamed.referencedSchema == "public")
    }
}

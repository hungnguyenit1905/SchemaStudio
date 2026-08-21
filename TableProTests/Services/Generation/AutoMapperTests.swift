//
//  AutoMapperTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

enum AutoMapFixtures {
    static func column(
        _ name: String,
        _ dataType: String,
        table: String = "t",
        databaseType: DatabaseType = .postgresql,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        identityKind: IdentityKind? = nil,
        isGenerated: Bool = false,
        allowedValues: [String]? = nil,
        checkExpressions: [String] = [],
        sequenceName: String? = nil,
        collation: String? = nil,
        foreignKeys: [PluginForeignKeyInfo] = [],
        indexes: [PluginIndexInfo] = []
    ) -> GenerationColumn {
        let info = PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            collation: collation,
            identityKind: identityKind,
            isGenerated: isGenerated,
            allowedValues: allowedValues,
            checkExpressions: checkExpressions,
            sequenceName: sequenceName
        )
        let assembled = SchemaFactsAssembler(databaseType: databaseType).assemble(
            schema: "public",
            table: table,
            columns: [info],
            foreignKeys: foreignKeys,
            indexes: indexes
        )
        guard let resolved = assembled.column(named: name) else {
            fatalError("fixture column missing")
        }
        return resolved
    }

    static func resolve(
        _ name: String,
        _ dataType: String,
        table: String = "t",
        databaseType: DatabaseType = .postgresql,
        checkExpressions: [String] = [],
        referenceDate: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> AutoMapResolution {
        AutoMapper.resolve(
            column(
                name,
                dataType,
                table: table,
                databaseType: databaseType,
                checkExpressions: checkExpressions
            ),
            table: table,
            referenceDate: referenceDate
        )
    }
}

@Suite("ColumnNameNormalizer")
struct ColumnNameNormalizerTests {
    @Test("Separator spellings collapse to one form")
    func separatorsCollapse() {
        #expect(ColumnNameNormalizer.candidates(column: "created_at", table: "users").contains("createdat"))
        #expect(ColumnNameNormalizer.candidates(column: "createdAt", table: "users").contains("createdat"))
        #expect(ColumnNameNormalizer.candidates(column: "CREATED-AT", table: "users").contains("createdat"))
    }

    @Test("The tokenized form keeps the word boundary a prefix rule needs")
    func tokenizedFormKeepsBoundaries() {
        #expect(ColumnNameNormalizer.candidates(column: "is_active", table: "users").contains("is_active"))
        #expect(ColumnNameNormalizer.candidates(column: "isActive", table: "users").contains("is_active"))
        #expect(!ColumnNameNormalizer.candidates(column: "issued_count", table: "orders").contains("is_sued_count"))
    }

    @Test("The table prefix becomes an extra candidate, never a replacement")
    func tablePrefixIsAnExtraCandidate() {
        let candidates = ColumnNameNormalizer.candidates(column: "user_email", table: "users")
        #expect(candidates.contains("useremail"))
        #expect(candidates.contains("email"))
    }

    @Test("A singular table name strips too")
    func singularTablePrefix() {
        #expect(ColumnNameNormalizer.candidates(column: "order_number", table: "orders").contains("number"))
        #expect(ColumnNameNormalizer.candidates(column: "company_name", table: "companies").contains("name"))
    }

    @Test("Stripping never empties the name")
    func strippingKeepsAName() {
        let candidates = ColumnNameNormalizer.candidates(column: "user", table: "users")
        #expect(candidates == ["user"])
    }

    @Test("A field suffix is dropped without eating a real word")
    func fieldSuffixIsDropped() {
        #expect(ColumnNameNormalizer.candidates(column: "email_col", table: "t").contains("email"))
        #expect(ColumnNameNormalizer.candidates(column: "email_field", table: "t").contains("email"))
        #expect(ColumnNameNormalizer.candidates(column: "protocol", table: "t").contains("protocol"))
    }
}

@Suite("NameRules")
struct NameRuleTests {
    @Test("The regex table is compiled once")
    func tableIsCompiledOnce() throws {
        let first = try #require(NameRules.all.first)
        let again = try #require(NameRules.all.first)
        #expect(first.pattern === again.pattern)
    }

    @Test("Every rule names a generator the registry can build")
    func everyRuleIsRegistered() {
        for rule in NameRules.all {
            #expect(GeneratorRegistry.standard.contains(rule.identifier), "\(rule.identifier) is not registered")
        }
    }

    @Test("Every rule accepts at least one type")
    func everyRuleAcceptsAType() {
        for rule in NameRules.all {
            #expect(!rule.acceptedTypes.isEmpty)
        }
    }
}

@Suite("AutoMapper")
struct AutoMapperTests {
    private typealias Fixtures = AutoMapFixtures

    @Test(
        "A column maps to the generator its constraints, name and type call for",
        arguments: [
            ("users", "is_active", "boolean", "Boolean"),
            ("users", "isActive", "boolean", "Boolean"),
            ("users", "deleted", "boolean", "Boolean"),
            ("users", "has_verified_email", "boolean", "Boolean"),
            ("users", "is_admin", "smallint", "Boolean"),
            ("users", "admin", "boolean", "Boolean"),
            ("orders", "issued_count", "integer", "Integer"),
            ("users", "created_at", "timestamp", "DateTime"),
            ("users", "createdAt", "timestamptz", "DateTime"),
            ("users", "created_at", "date", "Date"),
            ("users", "registered_at", "timestamp", "DateTime"),
            ("users", "updated_at", "timestamp", "DateTime"),
            ("users", "deleted_at", "timestamp", "DateTime"),
            ("users", "birth_date", "date", "Date"),
            ("users", "dob", "date", "Date"),
            ("subscriptions", "expires_at", "timestamp", "DateTime"),
            ("events", "start_date", "date", "Date"),
            ("events", "end_date", "date", "Date"),
            ("users", "last_login_at", "timestamp", "DateTime"),
            ("users", "age", "integer", "Age"),
            ("products", "stock", "integer", "Integer"),
            ("order_items", "quantity", "integer", "Integer"),
            ("products", "rating", "smallint", "Integer"),
            ("reviews", "score", "integer", "Integer"),
            ("promos", "percent", "integer", "Integer"),
            ("promos", "percentage", "numeric(5,2)", "Decimal"),
            ("stats", "year", "integer", "Integer"),
            ("stats", "month", "smallint", "Integer"),
            ("products", "sort_order", "integer", "Integer"),
            ("stores", "latitude", "numeric(9,6)", "Latitude"),
            ("stores", "latitude", "double precision", "Latitude"),
            ("stores", "longitude", "double precision", "Longitude"),
            ("products", "price", "numeric(10,2)", "Price"),
            ("products", "price", "double precision", "Price"),
            ("products", "price", "bigint", "Price"),
            ("orders", "total_amount", "numeric(12,2)", "Price"),
            ("orders", "discount", "numeric(5,2)", "Decimal"),
            ("posts", "view_count", "integer", "Integer"),
            ("users", "email", "varchar(255)", "Email"),
            ("users", "user_email", "varchar(255)", "Email"),
            ("users", "contact_email", "varchar(255)", "Email"),
            ("users", "username", "varchar(32)", "Username"),
            ("users", "login", "varchar(32)", "Username"),
            ("users", "password_hash", "varchar(255)", "RandomString"),
            ("sessions", "token", "varchar(64)", "RandomString"),
            ("users", "phone", "varchar(20)", "PhoneNumber"),
            ("users", "mobile_number", "varchar(20)", "MobileNumber"),
            ("users", "first_name", "varchar(50)", "FirstName"),
            ("users", "last_name", "varchar(50)", "LastName"),
            ("users", "middle_name", "varchar(50)", "MiddleName"),
            ("products", "name", "varchar(120)", "LoremWords"),
            ("posts", "title", "varchar(200)", "LoremWords"),
            ("employees", "job_title", "varchar(80)", "JobTitle"),
            ("companies", "company_name", "varchar(120)", "CompanyName"),
            ("stores", "city", "varchar(80)", "City"),
            ("stores", "province", "varchar(80)", "State"),
            ("stores", "country", "varchar(60)", "Country"),
            ("stores", "country_code", "varchar(2)", "CountryCode"),
            ("stores", "address_line1", "varchar(200)", "StreetAddress"),
            ("stores", "postal_code", "varchar(10)", "PostalCode"),
            ("posts", "description", "text", "LoremParagraph"),
            ("posts", "body", "text", "LoremParagraph"),
            ("reviews", "comment", "varchar(400)", "LoremSentence"),
            ("posts", "slug", "varchar(120)", "RandomString"),
            ("products", "sku", "varchar(32)", "SKU"),
            ("orders", "order_number", "varchar(24)", "RandomString"),
            ("users", "website", "varchar(255)", "URL"),
            ("users", "avatar_url", "varchar(255)", "RandomString"),
            ("files", "filename", "varchar(120)", "FileName"),
            ("files", "mime_type", "varchar(60)", "MimeType"),
            ("users", "gender", "varchar(10)", "Gender"),
            ("orders", "currency", "varchar(3)", "CurrencyCode"),
            ("users", "locale", "varchar(10)", "List"),
            ("users", "timezone", "varchar(40)", "TimeZone"),
            ("products", "color", "varchar(20)", "Color"),
            ("orders", "status", "varchar(20)", "List"),
            ("releases", "version", "varchar(20)", "SemVer"),
            ("users", "external_id", "varchar(64)", "UUID"),
            ("users", "uuid", "uuid", "UUID"),
            ("users", "public_id", "varchar(36)", "UUID"),
            ("t", "a", "boolean", "Boolean"),
            ("t", "a", "smallint", "Integer"),
            ("t", "a", "integer", "Integer"),
            ("t", "a", "bigint", "Integer"),
            ("t", "a", "numeric(10,2)", "Decimal"),
            ("t", "a", "double precision", "Double"),
            ("t", "a", "real", "Double"),
            ("t", "a", "uuid", "UUID"),
            ("t", "a", "date", "Date"),
            ("t", "a", "timestamp", "DateTime"),
            ("t", "a", "time", "DateTime"),
            ("t", "a", "bytea", "RandomBytes"),
            ("t", "a", "jsonb", "Fixed"),
            ("t", "a", "varchar(8)", "RandomString"),
            ("t", "a", "varchar(40)", "LoremWords"),
            ("t", "a", "text", "LoremWords"),
            ("users", "email", "integer", "Integer"),
            ("users", "email", "boolean", "Boolean"),
            ("users", "created_at", "varchar(30)", "LoremWords"),
            ("users", "is_active", "varchar(20)", "LoremWords"),
            ("products", "price", "varchar(20)", "LoremWords"),
            ("users", "age", "varchar(8)", "RandomString"),
            ("stores", "latitude", "varchar(20)", "LoremWords"),
            ("users", "status", "integer", "Integer"),
            ("users", "gender", "smallint", "Integer")
        ]
    )
    func mapsColumn(table: String, column: String, dataType: String, expected: String) {
        let resolution = Fixtures.resolve(column, dataType, table: table)
        #expect(resolution.identifier == expected, "\(table).\(column) \(dataType)")
    }

    @Test("A generated column stays the server's to fill")
    func generatedColumnIsServerAssigned() {
        let column = Fixtures.column("total", "numeric(10,2)", isGenerated: true)
        #expect(AutoMapper.resolve(column, table: "orders").identifier == "Default")
    }

    @Test("An identity column stays the server's to fill")
    func identityColumnIsServerAssigned() {
        let always = Fixtures.column("id", "bigint", isPrimaryKey: true, identityKind: .always)
        let byDefault = Fixtures.column("id", "bigint", isPrimaryKey: true, identityKind: .byDefault)
        #expect(AutoMapper.resolve(always, table: "orders").identifier == "Default")
        #expect(AutoMapper.resolve(byDefault, table: "orders").identifier == "Default")
    }

    @Test("A sequence-backed column stays the server's to fill")
    func sequenceBackedColumnIsServerAssigned() {
        let column = Fixtures.column("id", "bigint", sequenceName: "orders_id_seq")
        #expect(AutoMapper.resolve(column, table: "orders").identifier == "Default")
    }

    @Test("A foreign key outranks its name and its type")
    func foreignKeyOutranksEverything() {
        let column = Fixtures.column(
            "email",
            "varchar(255)",
            table: "orders",
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_email_fk",
                    column: "email",
                    referencedTable: "customers",
                    referencedColumn: "email",
                    referencedSchema: "public"
                )
            ]
        )
        #expect(AutoMapper.resolve(column, table: "orders").identifier == "Reference")
    }

    @Test("A value list outranks the name")
    func valueListOutranksName() {
        let column = Fixtures.column(
            "status",
            "enum('new','paid')",
            databaseType: .mysql,
            allowedValues: ["new", "paid"]
        )
        let resolution = AutoMapper.resolve(column, table: "orders")
        #expect(resolution.identifier == "List")
        #expect(resolution.params.objectValue?["values"] == .array([.string("new"), .string("paid")]))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A column that has to be distinct is mapped as unique")
    func uniqueConstraintReachesCommonParams() {
        let column = Fixtures.column(
            "email",
            "varchar(255)",
            table: "users",
            indexes: [PluginIndexInfo(name: "users_email_key", columns: ["email"], isUnique: true)]
        )
        #expect(AutoMapper.resolve(column, table: "users").common.unique)
    }

    @Test("An email reads as an email")
    func emailParams() throws {
        let column = Fixtures.column("email", "varchar(255)", table: "users")
        let resolution = AutoMapper.resolve(column, table: "users")
        #expect(resolution.identifier == "Email")

        let profile = GenerationColumnProfile(
            column: "email",
            generator: resolution.identifier,
            params: resolution.params,
            common: resolution.common
        )
        let generator = try GeneratorRegistry.standard.make(
            identifier: resolution.identifier,
            params: profile.paramData,
            column: column,
            seed: 3
        )
        let value = try generator.next(row: RowContext(table: "users", rowIndex: 0), index: 0)
        #expect(value.textFallback.contains("@"))
    }

    @Test("A creation timestamp lands in the two years before the run")
    func createdAtWindow() throws {
        let reference = Date(timeIntervalSince1970: 1_760_000_000)
        let resolution = Fixtures.resolve("created_at", "timestamp", table: "users", referenceDate: reference)
        let from = try #require(resolution.params.objectValue?["from"]?.stringValue)
        let to = try #require(resolution.params.objectValue?["to"]?.stringValue)
        #expect(from == "2023-10-10 08:53:20")
        #expect(to == "2025-10-09 08:53:20")
    }

    @Test("A date column gets calendar bounds, not timestamps")
    func createdOnWindowIsCalendarOnly() throws {
        let resolution = Fixtures.resolve("created_at", "date", table: "users")
        let from = try #require(resolution.params.objectValue?["from"]?.stringValue)
        #expect(from == "2023-10-10")
    }

    @Test("A birth date lands in a plausible decade")
    func birthDateWindow() {
        let resolution = Fixtures.resolve("birth_date", "date", table: "users")
        #expect(resolution.params.objectValue?["from"] == .string("1950-01-01"))
        #expect(resolution.params.objectValue?["to"] == .string("2005-12-31"))
    }

    @Test("A flag's bias follows what the name means")
    func booleanBias() {
        #expect(Fixtures.resolve("is_active", "boolean").params.objectValue?["truePercent"] == .int(80))
        #expect(Fixtures.resolve("is_deleted", "boolean").params.objectValue?["truePercent"] == .int(10))
        #expect(Fixtures.resolve("is_admin", "boolean").params.objectValue?["truePercent"] == .int(50))
    }

    @Test("A mostly-empty timestamp is only mostly empty where nulls are allowed")
    func nullPercentNeedsANullableColumn() {
        let nullable = Fixtures.column("deleted_at", "timestamp", table: "users", isNullable: true)
        let required = Fixtures.column("deleted_at", "timestamp", table: "users", isNullable: false)
        #expect(AutoMapper.resolve(nullable, table: "users").common.nullPercent == 90)
        #expect(AutoMapper.resolve(required, table: "users").common.nullPercent == 0)
    }

    @Test("Guessed value lists say so")
    func guessedValuesWarn() {
        let resolution = Fixtures.resolve("status", "varchar(20)", table: "orders")
        #expect(resolution.warnings == [.guessedValues(column: "status")])
        #expect(!(resolution.warnings.first?.message.isEmpty ?? true))
    }

    @Test("A long text column gets paragraphs, a short one gets a fitting string")
    func textLengthDecidesTheGenerator() {
        let long = Fixtures.resolve("description", "varchar(500)", table: "posts")
        let short = Fixtures.resolve("description", "varchar(20)", table: "posts")
        #expect(long.identifier == "LoremParagraph")
        #expect(short.identifier != "LoremParagraph")
    }

    @Test("A readable range replaces the native one, except where values must differ")
    func integerRangeIsReadable() {
        let plain = Fixtures.resolve("counter", "bigint", table: "stats")
        #expect(plain.params.objectValue?["min"] == .int(0))
        #expect(plain.params.objectValue?["max"] == .int(10_000))

        let key = Fixtures.column("legacy_key", "bigint", table: "stats", isPrimaryKey: true)
        #expect(AutoMapper.resolve(key, table: "stats").params.objectValue?["max"] == nil)
    }

    @Test("Every mapping builds a generator that produces a value")
    func everyMappingBuilds() throws {
        let dataTypes = [
            "boolean", "smallint", "integer", "bigint", "numeric(10,2)", "double precision",
            "uuid", "date", "timestamp", "time", "bytea", "jsonb", "varchar(8)", "varchar(40)", "text"
        ]
        let names = [
            "email", "username", "password_hash", "phone", "first_name", "title", "city", "country",
            "status", "price", "age", "created_at", "deleted_at", "is_active", "slug", "sku",
            "latitude", "avatar_url", "currency", "uuid", "quantity", "birth_date", "counter"
        ]
        for dataType in dataTypes {
            for name in names {
                let column = AutoMapFixtures.column(name, dataType, table: "things")
                let resolution = AutoMapper.resolve(column, table: "things")
                let profile = GenerationColumnProfile(
                    column: name,
                    generator: resolution.identifier,
                    params: resolution.params,
                    common: resolution.common
                )
                let generator = try GeneratorRegistry.standard.make(
                    identifier: resolution.identifier,
                    params: profile.paramData,
                    column: column,
                    seed: 7
                )
                _ = try generator.next(row: RowContext(table: "things", rowIndex: 0), index: 0)
            }
        }
    }
}

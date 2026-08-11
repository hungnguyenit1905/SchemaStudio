import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferTypeMapper")
struct TransferTypeMapperTests {
    private func column(
        _ name: String,
        _ dataType: String,
        isNullable: Bool = true,
        allowedValues: [String]? = nil
    ) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            allowedValues: allowedValues
        )
    }

    private func mapper(
        _ source: DatabaseType,
        _ target: DatabaseType,
        options: TransferMappingOptions = TransferMappingOptions()
    ) -> TransferTypeMapper {
        TransferTypeMapper(sourceType: source, targetType: target, options: options)
    }

    private func target(
        _ source: DatabaseType,
        _ target: DatabaseType,
        _ dataType: String,
        options: TransferMappingOptions = TransferMappingOptions()
    ) -> String {
        mapper(source, target, options: options)
            .plan(for: column("value", dataType), table: "t")
            .targetType
    }

    // MARK: - Same dialect

    @Test(
        "A same-vendor transfer passes the source type through untouched",
        arguments: ["int(11)", "enum('a','b')", "some_udt", "bigint unsigned", "geometry"]
    )
    func sameVendorPassthrough(dataType: String) {
        let plan = mapper(.mysql, .mysql).plan(for: column("value", dataType), table: "t")
        #expect(plan.targetType == dataType)
        #expect(plan.conversion == nil)
        #expect(plan.warnings.isEmpty)
    }

    @Test("MariaDB and MySQL are the same dialect")
    func mariadbIsMysql() {
        #expect(mapper(.mariadb, .mysql).isSameDialect)
        #expect(mapper(.postgresql, .redshift).isSameDialect)
    }

    @Test("An unsupported vendor keeps the source type and warns")
    func unsupportedVendor() {
        let plan = mapper(.mysql, .mongodb).plan(for: column("value", "int"), table: "t")
        #expect(plan.targetType == "int")
        #expect(plan.warnings.contains { if case .typeNotMapped = $0 { return true } else { return false } })
    }

    @Test("A per-column override wins over the matrix")
    func override() {
        let options = TransferMappingOptions(
            overrides: [TransferTypeOverride(table: "t", column: "value", targetType: "citext")]
        )
        #expect(target(.mysql, .postgresql, "varchar(20)", options: options) == "citext")
    }

    // MARK: - MySQL to PostgreSQL

    @Test(
        "MySQL types map to their PostgreSQL equivalent",
        arguments: [
            ("tinyint(1)", "boolean"),
            ("tinyint", "smallint"),
            ("smallint", "smallint"),
            ("mediumint", "integer"),
            ("int", "integer"),
            ("bigint", "bigint"),
            ("year", "smallint"),
            ("decimal(10,2)", "numeric(10,2)"),
            ("double", "double precision"),
            ("float", "real"),
            ("varchar(255)", "varchar(255)"),
            ("longtext", "text"),
            ("longblob", "bytea"),
            ("date", "date"),
            ("datetime", "timestamp"),
            ("timestamp", "timestamptz"),
            ("json", "jsonb")
        ]
    )
    func mysqlToPostgres(source: String, expected: String) {
        #expect(target(.mysql, .postgresql, source) == expected)
    }

    @Test(
        "An unsigned MySQL integer widens so it cannot overflow at the target",
        arguments: [
            ("tinyint unsigned", "smallint"),
            ("smallint unsigned", "integer"),
            ("int unsigned", "bigint"),
            ("bigint unsigned", "numeric(20,0)")
        ]
    )
    func unsignedWidening(source: String, expected: String) {
        #expect(target(.mysql, .postgresql, source) == expected)
    }

    @Test("bigint unsigned needs a value conversion and warns, int unsigned does not")
    func unsignedConversion() {
        let wide = mapper(.mysql, .postgresql).plan(for: column("v", "bigint unsigned"), table: "t")
        #expect(wide.conversion == .unsignedToDecimalText)
        #expect(wide.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })

        let narrow = mapper(.mysql, .postgresql).plan(for: column("v", "int unsigned"), table: "t")
        #expect(narrow.conversion == nil)
    }

    @Test("tinyint(1) becomes a small integer when the user says it is not a boolean")
    func tinyintNotBool() {
        var options = TransferMappingOptions()
        options.tinyint1AsBool = false
        #expect(target(.mysql, .postgresql, "tinyint(1)", options: options) == "smallint")
    }

    @Test("A MySQL enum becomes a varchar wide enough for its widest member and warns")
    func enumToPostgres() {
        let plan = mapper(.mysql, .postgresql)
            .plan(for: column("status", "enum('new','archived')", allowedValues: ["new", "archived"]), table: "t")
        #expect(plan.targetType == "varchar(8)")
        #expect(plan.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })
    }

    @Test("A MySQL SET loses its membership semantics and warns")
    func setToPostgres() {
        let plan = mapper(.mysql, .postgresql).plan(for: column("tags", "set('a','b')"), table: "t")
        #expect(plan.targetType == "text")
        #expect(plan.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })
    }

    @Test("A nullable MySQL date maps its zero date to null")
    func zeroDateNullable() {
        let plan = mapper(.mysql, .postgresql).plan(for: column("d", "date", isNullable: true), table: "t")
        #expect(plan.conversion == .zeroDateToNull)
    }

    @Test("A non-null MySQL date maps its zero date to a sentinel instead")
    func zeroDateNotNull() {
        let plan = mapper(.mysql, .postgresql).plan(for: column("d", "date", isNullable: false), table: "t")
        #expect(plan.conversion == .zeroDateToSentinel("1970-01-01 00:00:00"))
    }

    // MARK: - PostgreSQL to MySQL

    @Test(
        "PostgreSQL types map to their MySQL equivalent",
        arguments: [
            ("text", "longtext"),
            ("boolean", "tinyint(1)"),
            ("uuid", "char(36)"),
            ("jsonb", "json"),
            ("smallint", "smallint"),
            ("integer", "int"),
            ("bigint", "bigint"),
            ("double precision", "double"),
            ("bytea", "longblob"),
            ("timestamp without time zone", "datetime"),
            ("timestamp with time zone", "timestamp"),
            ("numeric(8,3)", "decimal(8,3)")
        ]
    )
    func postgresToMysql(source: String, expected: String) {
        #expect(target(.postgresql, .mysql, source) == expected)
    }

    @Test("A bare numeric has to take MySQL's widest precision and warns")
    func bareNumericToMysql() {
        let plan = mapper(.postgresql, .mysql).plan(for: column("v", "numeric"), table: "t")
        #expect(plan.targetType == "decimal(65,30)")
        #expect(plan.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })
    }

    @Test("An interval becomes a count of seconds and warns")
    func intervalToMysql() {
        let plan = mapper(.postgresql, .mysql).plan(for: column("v", "interval"), table: "t")
        #expect(plan.targetType == "bigint")
        #expect(plan.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })
    }

    @Test("An array folds into JSON and carries the conversion")
    func arrayToMysql() {
        let plan = mapper(.postgresql, .mysql).plan(for: column("v", "text[]"), table: "t")
        #expect(plan.targetType == "json")
        #expect(plan.conversion == .arrayToJson)
    }

    @Test("An array into SQLite keeps the array conversion rather than a JSON check")
    func arrayToSqliteKeepsConversion() {
        let plan = mapper(.postgresql, .sqlite).plan(for: column("v", "text[]"), table: "t")
        #expect(plan.conversion == .arrayToJson)
    }

    @Test("A timestamptz into MySQL warns about the 1970 to 2038 range")
    func timestampRangeWarning() {
        let plan = mapper(.postgresql, .mysql).plan(for: column("v", "timestamptz"), table: "t")
        #expect(plan.warnings.contains { if case .typeLossy = $0 { return true } else { return false } })
    }

    // MARK: - Boolean representation

    @Test("A boolean needs a conversion only when the two engines represent it differently")
    func boolRepresentation() {
        #expect(mapper(.mysql, .postgresql).plan(for: column("b", "tinyint(1)"), table: "t").conversion == .intToBool)
        #expect(mapper(.postgresql, .mysql).plan(for: column("b", "boolean"), table: "t").conversion == .boolToInt)
        #expect(mapper(.postgresql, .mssql).plan(for: column("b", "boolean"), table: "t").conversion == nil)
        #expect(mapper(.mysql, .sqlite).plan(for: column("b", "tinyint(1)"), table: "t").conversion == nil)
    }

    // MARK: - Unmappable

    @Test("A type the target cannot express keeps the source string and warns instead of throwing")
    func unmappableFallsBack() {
        let plan = mapper(.mysql, .postgresql).plan(for: column("shape", "geometry"), table: "t")
        #expect(plan.targetType == "geometry")
        #expect(plan.warnings.contains { if case .typeNotMapped = $0 { return true } else { return false } })
    }

    @Test("An unrecognised source type keeps its native string and warns")
    func unknownSourceType() {
        let plan = mapper(.mysql, .postgresql).plan(for: column("v", "some_udt"), table: "t")
        #expect(plan.targetType == "some_udt")
        #expect(plan.warnings.contains { if case .typeNotMapped = $0 { return true } else { return false } })
    }

    // MARK: - Indexes

    private func index(
        _ name: String,
        columns: [String] = ["a"],
        type: String? = nil,
        prefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: name,
            columns: columns,
            indexType: type,
            columnPrefixes: prefixes,
            whereClause: whereClause
        )
    }

    @Test("A same-vendor index passes through untouched")
    func indexSameVendor() {
        let plan = mapper(.mysql, .mysql).plan(for: index("i", type: "FULLTEXT"), table: "t")
        #expect(plan.index?.indexType == "FULLTEXT")
        #expect(plan.warnings.isEmpty)
    }

    @Test("A full-text index is dropped rather than mistranslated")
    func indexFulltextDropped() {
        let plan = mapper(.mysql, .postgresql).plan(for: index("i", type: "FULLTEXT"), table: "t")
        #expect(plan.index == nil)
        #expect(plan.warnings.count == 1)
    }

    @Test("A prefix index becomes a whole-column index and warns")
    func indexPrefixStripped() {
        let plan = mapper(.mysql, .postgresql).plan(for: index("i", prefixes: ["a": 20]), table: "t")
        #expect(plan.index?.columnPrefixes == nil)
        #expect(plan.index?.columns == ["a"])
        #expect(plan.warnings.count == 1)
    }

    @Test("A partial index becomes a full index when the target has no partial index")
    func indexPartialStripped() {
        let plan = mapper(.postgresql, .mysql).plan(for: index("i", whereClause: "a > 0"), table: "t")
        #expect(plan.index?.whereClause == nil)
        #expect(plan.warnings.count == 1)
    }

    @Test("SQLite keeps a partial index because it supports one")
    func indexPartialKeptOnSqlite() {
        let plan = mapper(.postgresql, .sqlite).plan(for: index("i", whereClause: "a > 0"), table: "t")
        #expect(plan.index?.whereClause == "a > 0")
    }

    @Test("A GIN index falls back to the default method and warns")
    func indexGinFallsBack() {
        let plan = mapper(.postgresql, .mysql).plan(for: index("i", type: "gin"), table: "t")
        #expect(plan.index?.indexType == nil)
        #expect(plan.warnings.count == 1)
    }
}

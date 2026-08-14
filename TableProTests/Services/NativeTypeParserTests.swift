import Foundation
@testable import SchemaStudio
import Testing

@Suite("NativeTypeParser")
struct NativeTypeParserTests {
    private let mysql = MySqlNativeTypeParser()
    private let postgres = PostgreSqlNativeTypeParser()
    private let sqlite = SqliteNativeTypeParser()
    private let mssql = MssqlNativeTypeParser()

    // MARK: - Syntax

    @Test("The tokenizer splits a name, its arguments and its trailing modifiers")
    func syntaxSplit() {
        let syntax = NativeTypeSyntax.parse("BIGINT(20) UNSIGNED")
        #expect(syntax.head == "bigint")
        #expect(syntax.arguments == ["20"])
        #expect(syntax.tail == "unsigned")
        #expect(syntax.isArray == false)
    }

    @Test("A quoted comma inside an enum stays part of its member")
    func syntaxQuotedComma() {
        let syntax = NativeTypeSyntax.parse("enum('a,b','c')")
        #expect(syntax.quotedArguments == ["a,b", "c"])
    }

    @Test("A trailing bracket pair marks an array type")
    func syntaxArray() {
        let syntax = NativeTypeSyntax.parse("text[]")
        #expect(syntax.head == "text")
        #expect(syntax.isArray)
    }

    // MARK: - MySQL

    @Test(
        "MySQL native types parse to the expected base",
        arguments: [
            ("varchar(255)", TransferBaseType.string, 255 as Int?),
            ("char(10)", .string, 10),
            ("tinyint(1)", .bool, nil),
            ("tinyint", .int8, nil),
            ("smallint", .int16, nil),
            ("mediumint", .int32, nil),
            ("int", .int32, nil),
            ("bigint", .int64, nil),
            ("year", .int16, nil),
            ("float", .float32, nil),
            ("double", .float64, nil),
            ("longtext", .text, nil),
            ("longblob", .bytes, nil),
            ("date", .date, nil),
            ("time", .time, nil),
            ("datetime", .timestamp, nil),
            ("timestamp", .timestampTZ, nil),
            ("json", .json, nil),
            ("point", .geometry, nil),
            ("some_udt", .unknown, nil)
        ]
    )
    func mysqlParse(native: String, base: TransferBaseType, length: Int?) {
        let type = mysql.parse(native, allowedValues: nil)
        #expect(type.base == base)
        #expect(type.length == length)
        #expect(type.native == native)
    }

    @Test("A MySQL display width is dropped so it never renders as integer(11)")
    func mysqlDisplayWidthDropped() {
        #expect(mysql.parse("int(11)", allowedValues: nil).length == nil)
        #expect(mysql.parse("bigint(20) unsigned", allowedValues: nil).length == nil)
        #expect(mysql.parse("bigint(20) unsigned", allowedValues: nil).base == .int64)
        #expect(mysql.parse("bigint(20) unsigned", allowedValues: nil).unsigned)
    }

    @Test("MySQL decimal keeps precision and scale")
    func mysqlDecimal() {
        let type = mysql.parse("decimal(10,2)", allowedValues: nil)
        #expect(type.base == .decimal)
        #expect(type.precision == 10)
        #expect(type.scale == 2)
    }

    @Test("An enum takes its members from the column info when the driver supplies them")
    func mysqlEnumFromColumnInfo() {
        let type = mysql.parse("enum('a','b')", allowedValues: ["x", "y"])
        #expect(type.base == .enumeration)
        #expect(type.allowedValues == ["x", "y"])
    }

    @Test("An enum falls back to parsing its members from the type string")
    func mysqlEnumFromString() {
        let type = mysql.parse("enum('a','b')", allowedValues: nil)
        #expect(type.allowedValues == ["a", "b"])
    }

    // MARK: - PostgreSQL

    @Test(
        "PostgreSQL native types parse to the expected base",
        arguments: [
            ("boolean", TransferBaseType.bool),
            ("smallint", .int16),
            ("integer", .int32),
            ("bigint", .int64),
            ("serial", .int32),
            ("bigserial", .int64),
            ("real", .float32),
            ("double precision", .float64),
            ("text", .text),
            ("bytea", .bytes),
            ("date", .date),
            ("time", .time),
            ("time without time zone", .time),
            ("time with time zone", .time),
            ("interval", .interval),
            ("jsonb", .json),
            ("uuid", .uuid),
            ("timestamp without time zone", .timestamp),
            ("timestamp with time zone", .timestampTZ),
            ("timestamptz", .timestampTZ),
            ("mystery_type", .unknown)
        ]
    )
    func postgresParse(native: String, base: TransferBaseType) {
        #expect(postgres.parse(native, allowedValues: nil).base == base)
    }

    @Test("character varying without a length is unbounded text")
    func postgresUnboundedVarchar() {
        #expect(postgres.parse("character varying", allowedValues: nil).base == .text)
        #expect(postgres.parse("character varying(80)", allowedValues: nil).base == .string)
        #expect(postgres.parse("character varying(80)", allowedValues: nil).length == 80)
    }

    @Test("numeric without a precision keeps a nil precision")
    func postgresBareNumeric() {
        let type = postgres.parse("numeric", allowedValues: nil)
        #expect(type.base == .decimal)
        #expect(type.precision == nil)
    }

    @Test("An array type keeps its element base and is recognised as an array")
    func postgresArray() {
        let type = postgres.parse("text[]", allowedValues: nil)
        #expect(type.base == .text)
        #expect(type.isArray)
    }

    // MARK: - SQLite

    @Test(
        "SQLite resolves affinity from the declared string, not a type name",
        arguments: [
            ("INTEGER", TransferBaseType.int64),
            ("BIGINT", .int64),
            ("VARCHAR(20)", .text),
            ("NVARCHAR(9)", .text),
            ("CLOB", .text),
            ("TEXT", .text),
            ("BLOB", .bytes),
            ("", .bytes),
            ("REAL", .float64),
            ("DOUBLE", .float64),
            ("FLOAT", .float64),
            ("NUMERIC", .decimal),
            ("DECIMAL(10,5)", .decimal),
            ("BOOLEAN", .decimal),
            ("DATETIME", .decimal)
        ]
    )
    func sqliteAffinity(native: String, base: TransferBaseType) {
        #expect(sqlite.parse(native, allowedValues: nil).base == base)
    }

    @Test("SQLite integer affinity wins over text affinity")
    func sqliteIntegerBeatsChar() {
        #expect(sqlite.parse("INT", allowedValues: nil).base == .int64)
    }

    // MARK: - SQL Server

    @Test(
        "SQL Server native types parse to the expected base",
        arguments: [
            ("bit", TransferBaseType.bool),
            ("tinyint", .int8),
            ("smallint", .int16),
            ("int", .int32),
            ("bigint", .int64),
            ("real", .float32),
            ("float", .float64),
            ("nvarchar(max)", .text),
            ("nvarchar(50)", .string),
            ("varbinary(max)", .bytes),
            ("datetime2", .timestamp),
            ("datetimeoffset", .timestampTZ),
            ("uniqueidentifier", .uuid),
            ("sql_variant", .unknown)
        ]
    )
    func mssqlParse(native: String, base: TransferBaseType) {
        #expect(mssql.parse(native, allowedValues: nil).base == base)
    }

    // MARK: - Round trip

    @Test(
        "Every vendor renders each base it can express back to a string it can parse",
        arguments: TransferBaseType.allCases
    )
    func roundTrip(base: TransferBaseType) {
        let parsers: [any NativeTypeParsing] = [mysql, postgres, sqlite, mssql]
        let source = TransferColumnType(base: base, length: 32, precision: 10, scale: 2, native: "seed")

        for parser in parsers {
            guard let rendered = parser.render(source) else { continue }
            let reparsed = parser.parse(rendered, allowedValues: source.allowedValues)
            #expect(
                reparsed.base != .unknown,
                "\(type(of: parser)) rendered \(base) as '\(rendered)' which it cannot parse back"
            )
        }
    }
}

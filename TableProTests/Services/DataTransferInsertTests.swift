import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@MainActor
@Suite("DataTransfer insert pipeline")
struct DataTransferInsertTests {
    private let header = ["id", "name", "total"]

    @Test("A stream row becomes a dictionary keyed by the header")
    func rowDictionaryZipsHeader() {
        let row: PluginRow = [.text("7"), .text("ann"), .null]
        let values = DataTransferService.rowDictionary(row, columns: header)
        #expect(values["id"] == .text("7"))
        #expect(values["name"] == .text("ann"))
        #expect(values["total"] == .null)
    }

    @Test("A short row does not fabricate values for the missing columns")
    func rowDictionaryIgnoresMissingValues() {
        let values = DataTransferService.rowDictionary([.text("7")], columns: header)
        #expect(values.count == 1)
        #expect(values["name"] == nil)
    }

    @Test("Every non-generated column maps onto itself")
    func identityMappingCoversHeader() {
        let mapping = DataTransferService.identityColumnMapping(headerColumns: header, generatedColumns: [])
        #expect(mapping == ["id": "id", "name": "name", "total": "total"])
    }

    @Test("A generated column is left out of the mapping")
    func identityMappingSkipsGeneratedColumns() {
        let mapping = DataTransferService.identityColumnMapping(
            headerColumns: header,
            generatedColumns: ["total"]
        )
        #expect(mapping["total"] == nil)
        #expect(mapping.count == 2)
    }

    @Test("An empty mapping stops the run instead of writing nothing")
    func emptyMappingThrows() {
        #expect(throws: TransferError.emptyColumnMapping("orders")) {
            try DataTransferService.validateColumnMapping(
                table: "orders",
                headerColumns: header,
                generatedColumns: [],
                mapping: [:]
            )
        }
    }

    @Test("A mapping that misses a column stops the run")
    func partialMappingThrows() {
        #expect(throws: TransferError.columnMappingIncomplete("orders")) {
            try DataTransferService.validateColumnMapping(
                table: "orders",
                headerColumns: header,
                generatedColumns: [],
                mapping: ["id": "id"]
            )
        }
    }

    @Test("A mapping that covers every writable column passes")
    func completeMappingPasses() throws {
        let generated: Set = ["total"]
        let mapping = DataTransferService.identityColumnMapping(
            headerColumns: header,
            generatedColumns: generated
        )
        try DataTransferService.validateColumnMapping(
            table: "orders",
            headerColumns: header,
            generatedColumns: generated,
            mapping: mapping
        )
    }

    @Test("A generated column never reaches the INSERT")
    func generatedColumnIsNotInserted() throws {
        let generator = try SQLStatementGenerator(
            tableName: "orders",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: ["total"]
        )
        let statement = generator.insertStatement(
            columns: ["id", "name"],
            rows: [[.text("1"), .text("ann")]]
        )
        #expect(statement?.sql.contains("total") == false)
        #expect(statement?.parameters.count == 2)
    }

    @Test("A batch never exceeds the driver's bind parameter limit")
    func batchStaysUnderBindLimit() throws {
        let generator = try SQLStatementGenerator(
            tableName: "orders",
            columns: header,
            primaryKeyColumns: ["id"],
            databaseType: .sqlite
        )
        let chunkSize = max(1, generator.maxBindParameters / header.count)
        let rows = Array(repeating: [PluginCellValue.text("1"), .text("ann"), .text("2")], count: chunkSize)
        let statement = generator.insertStatement(columns: header, rows: rows)
        #expect((statement?.parameters.count ?? .max) <= generator.maxBindParameters)
    }

    @Test("The stream container is the schema on a schema-aware engine")
    func containerNameOnSchemaAwareEngine() {
        let endpoint = TransferEndpoint(
            connectionId: UUID(),
            databaseType: .postgresql,
            database: "shop",
            schema: "staging"
        )
        #expect(TransferDriverContext.containerName(for: endpoint, supportsSchemas: true) == "staging")
    }

    @Test("The stream container is the database everywhere else")
    func containerNameOnDatabaseEngine() {
        let endpoint = TransferEndpoint(
            connectionId: UUID(),
            databaseType: .mysql,
            database: "shop",
            schema: nil
        )
        #expect(TransferDriverContext.containerName(for: endpoint, supportsSchemas: false) == "shop")
    }

    @Test("A schema-aware endpoint with no schema falls back to the driver's own")
    func containerNameWithoutSchema() {
        let endpoint = TransferEndpoint(
            connectionId: UUID(),
            databaseType: .postgresql,
            database: "shop",
            schema: nil
        )
        #expect(TransferDriverContext.containerName(for: endpoint, supportsSchemas: true).isEmpty)
    }
}

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferRowConverter")
struct TransferRowConverterTests {
    private let columns = ["id", "name", "flag", "created_at"]

    private func converter(
        _ conversions: [String: TransferValueConversion],
        primaryKeyColumns: [String] = ["id"]
    ) -> TransferRowConverter {
        TransferRowConverter(
            table: "users",
            columns: columns,
            conversions: conversions,
            primaryKeyColumns: primaryKeyColumns
        )
    }

    private func row(_ flag: String, created: String = "2024-05-01") -> PluginRow {
        [.text("7"), .text("ada"), .text(flag), .text(created)]
    }

    @Test("A same-dialect transfer produces no conversions and is skipped whole")
    func identity() {
        #expect(converter([:]).isIdentity)
        #expect(TransferRowConverter.identity.isIdentity)
        #expect(!converter(["flag": .intToBool]).isIdentity)
    }

    @Test("Only the converted column changes")
    func convertsOneColumn() throws {
        let converted = try converter(["flag": .intToBool]).convert(row("1"))
        #expect(converted == [.text("7"), .text("ada"), .text("true"), .text("2024-05-01")])
    }

    @Test("A short row is left alone rather than crashing on a missing column")
    func shortRow() throws {
        let converted = try converter(["created_at": .zeroDateToNull]).convert([.text("7"), .text("ada")])
        #expect(converted == [.text("7"), .text("ada")])
    }

    @Test("A failure names the table, the column and the primary key of the row")
    func failureCarriesContext() {
        do {
            _ = try converter(["created_at": .zeroDateReject]).convert(row("1", created: "0000-00-00"))
            Issue.record("Expected the zero date to fail")
        } catch let error as TransferValueError {
            #expect(error == .zeroDateInNotNull(table: "users", column: "created_at", primaryKey: "id=7"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A composite key names every one of its columns")
    func compositeKey() {
        let converter = converter(["created_at": .zeroDateReject], primaryKeyColumns: ["id", "name"])
        do {
            _ = try converter.convert(row("1", created: "0000-00-00"))
            Issue.record("Expected the zero date to fail")
        } catch let error as TransferValueError {
            #expect(error == .zeroDateInNotNull(table: "users", column: "created_at", primaryKey: "id=7, name=ada"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A table with no primary key says so instead of quoting other columns")
    func noPrimaryKey() {
        let converter = converter(["created_at": .zeroDateReject], primaryKeyColumns: [])
        do {
            _ = try converter.convert(row("1", created: "0000-00-00"))
            Issue.record("Expected the zero date to fail")
        } catch let error as TransferValueError {
            guard case .zeroDateInNotNull(_, _, let primaryKey) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(!primaryKey.contains("ada"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("The error message never quotes the value that failed")
    func messageHidesTheValue() {
        let error = TransferValueError.outOfRange(table: "users", column: "created_at", primaryKey: "id=7")
        let message = error.errorDescription ?? ""
        #expect(message.contains("users"))
        #expect(message.contains("created_at"))
        #expect(message.contains("id=7"))
    }
}

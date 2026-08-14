import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferValueConverter")
struct TransferValueConverterTests {
    private func text(
        _ value: String,
        _ conversion: TransferValueConversion
    ) throws -> PluginCellValue {
        try TransferValueConverter.convert(.text(value), using: conversion).value
    }

    private func fault(
        _ value: String,
        _ conversion: TransferValueConversion
    ) -> TransferValueFault? {
        do {
            _ = try TransferValueConverter.convert(.text(value), using: conversion)
            return nil
        } catch let fault as TransferValueFault {
            return fault
        } catch {
            return nil
        }
    }

    // MARK: - Null

    @Test(
        "Null passes through every conversion unchanged",
        arguments: [
            TransferValueConversion.boolToInt,
            .intToBool,
            .zeroDateToNull,
            .zeroDateToSentinel("1970-01-01"),
            .zeroDateReject,
            .unsignedToDecimalText,
            .arrayToJson,
            .jsonValidate,
            .mysqlTimestampRange,
            .decimalFit(precision: 10, scale: 2),
            .decimalRound(precision: 10, scale: 2)
        ]
    )
    func nullPassesThrough(conversion: TransferValueConversion) throws {
        let outcome = try TransferValueConverter.convert(.null, using: conversion)
        #expect(outcome.value == .null)
        #expect(!outcome.lostPrecision)
    }

    @Test(
        "Bytes pass through conversions that only understand text",
        arguments: [TransferValueConversion.jsonValidate, .mysqlTimestampRange, .zeroDateReject]
    )
    func bytesPassThrough(conversion: TransferValueConversion) throws {
        let data = Data([0x00, 0xFF, 0x10])
        let outcome = try TransferValueConverter.convert(.bytes(data), using: conversion)
        #expect(outcome.value == .bytes(data))
    }

    // MARK: - Boolean

    @Test(
        "A boolean crossing into an integer column becomes 0 or 1",
        arguments: [("t", "1"), ("true", "1"), ("f", "0"), ("false", "0"), ("1", "1"), ("0", "0"), ("2", "1")]
    )
    func boolToInt(input: String, expected: String) throws {
        #expect(try text(input, .boolToInt) == .text(expected))
    }

    @Test(
        "An integer crossing into a boolean column becomes true or false",
        arguments: [("0", "false"), ("1", "true"), ("7", "true"), ("t", "true"), ("FALSE", "false")]
    )
    func intToBool(input: String, expected: String) throws {
        #expect(try text(input, .intToBool) == .text(expected))
    }

    @Test("A value that is not a boolean fails instead of defaulting to false")
    func invalidBoolean() {
        #expect(fault("maybe", .intToBool) == .invalidBoolean)
        #expect(fault("maybe", .boolToInt) == .invalidBoolean)
    }

    // MARK: - Zero date

    @Test(
        "A zero date becomes null, a sentinel, or a failure",
        arguments: ["0000-00-00", "0000-00-00 00:00:00"]
    )
    func zeroDate(input: String) throws {
        #expect(try text(input, .zeroDateToNull) == .null)
        #expect(try text(input, .zeroDateToSentinel("1970-01-01")) == .text("1970-01-01"))
        #expect(fault(input, .zeroDateReject) == .zeroDateInNotNull)
    }

    @Test("A real date is left alone by every zero date conversion")
    func realDate() throws {
        #expect(try text("2024-05-01", .zeroDateToNull) == .text("2024-05-01"))
        #expect(try text("2024-05-01", .zeroDateToSentinel("1970-01-01")) == .text("2024-05-01"))
        #expect(try text("2024-05-01", .zeroDateReject) == .text("2024-05-01"))
    }

    // MARK: - Unsigned

    @Test("The largest bigint unsigned survives as an exact decimal")
    func unsignedMaximum() throws {
        #expect(try text("18446744073709551615", .unsignedToDecimalText) == .text("18446744073709551615"))
    }

    @Test(
        "An unsigned value is normalised without going through Int64",
        arguments: [("0", "0"), ("+42", "42"), ("007", "7"), ("42.000", "42"), ("-0", "0")]
    )
    func unsignedNormalisation(input: String, expected: String) throws {
        #expect(try text(input, .unsignedToDecimalText) == .text(expected))
    }

    @Test("A negative value in an unsigned column fails")
    func negativeUnsigned() {
        #expect(fault("-1", .unsignedToDecimalText) == .negativeIntoUnsigned)
    }

    @Test("A non-integer unsigned value fails rather than being truncated")
    func fractionalUnsigned() {
        #expect(fault("42.5", .unsignedToDecimalText) == .outOfRange)
        #expect(fault("abc", .unsignedToDecimalText) == .outOfRange)
    }

    // MARK: - JSON

    @Test("Valid JSON passes validation untouched")
    func validJson() throws {
        #expect(try text("{\"a\":1}", .jsonValidate) == .text("{\"a\":1}"))
        #expect(try text("[1,2]", .jsonValidate) == .text("[1,2]"))
        #expect(try text("\"plain\"", .jsonValidate) == .text("\"plain\""))
    }

    @Test("Broken JSON fails at the client, where the column name is known")
    func brokenJson() {
        #expect(fault("{not json", .jsonValidate) == .invalidJson)
    }

    @Test(
        "A PostgreSQL array literal becomes a JSON array",
        arguments: [
            ("{}", "[]"),
            ("{a,b}", "[\"a\",\"b\"]"),
            ("{1,2,3}", "[\"1\",\"2\",\"3\"]"),
            ("{\"a,b\",c}", "[\"a,b\",\"c\"]"),
            ("{a,NULL,b}", "[\"a\",null,\"b\"]"),
            ("{\"NULL\"}", "[\"NULL\"]"),
            ("{{1,2},{3}}", "[[\"1\",\"2\"],[\"3\"]]")
        ]
    )
    func arrayToJson(input: String, expected: String) throws {
        #expect(try text(input, .arrayToJson) == .text(expected))
    }

    @Test("An escaped quote inside an array element survives")
    func arrayEscapes() throws {
        #expect(try text("{\"say \\\"hi\\\"\"}", .arrayToJson) == .text("[\"say \\\"hi\\\"\"]"))
    }

    @Test("A malformed array literal fails")
    func brokenArray() {
        #expect(fault("{a,b", .arrayToJson) == .invalidJson)
        #expect(fault("a,b}", .arrayToJson) == .invalidJson)
    }

    // MARK: - MySQL timestamp range

    @Test(
        "A timestamp inside the MySQL range passes",
        arguments: ["1970-01-01 00:00:01", "2024-05-01 12:30:00", "2038-01-19 03:14:07", "2024-05-01T12:30:00Z"]
    )
    func timestampInRange(input: String) throws {
        #expect(try text(input, .mysqlTimestampRange) == .text(input))
    }

    @Test(
        "A timestamp outside the MySQL range fails instead of being zeroed",
        arguments: ["2050-06-01 10:00:00", "1969-12-31 23:59:59", "1900-01-01 00:00:00"]
    )
    func timestampOutOfRange(input: String) {
        #expect(fault(input, .mysqlTimestampRange) == .outOfRange)
    }

    @Test("A zone offset is applied before the range is checked")
    func timestampOffset() throws {
        #expect(fault("1970-01-01 01:00:00+02", .mysqlTimestampRange) == .outOfRange)
        #expect(try text("1970-01-01 01:00:00-02", .mysqlTimestampRange) == .text("1970-01-01 01:00:00-02"))
    }

    @Test("Text that is not a timestamp is left for the server to reject")
    func timestampUnparsed() throws {
        #expect(try text("not a date", .mysqlTimestampRange) == .text("not a date"))
    }

    // MARK: - Decimal

    @Test(
        "A decimal that fits its target column is untouched",
        arguments: ["1.50", "-1.50", "0", "12345678.99"]
    )
    func decimalFits(input: String) throws {
        #expect(try text(input, .decimalFit(precision: 10, scale: 2)) == .text(input))
    }

    @Test("A decimal with too many integer digits fails, rounding or not")
    func decimalIntegerOverflow() {
        #expect(fault("123456789.00", .decimalFit(precision: 10, scale: 2)) == .precisionLoss)
        #expect(fault("123456789.00", .decimalRound(precision: 10, scale: 2)) == .precisionLoss)
    }

    @Test("Extra fractional digits fail by default")
    func decimalFractionOverflow() {
        #expect(fault("1.005", .decimalFit(precision: 10, scale: 2)) == .precisionLoss)
    }

    @Test("Extra fractional digits round when the user asked for it, and say so")
    func decimalRounds() throws {
        let outcome = try TransferValueConverter.convert(
            .text("1.005"),
            using: .decimalRound(precision: 10, scale: 2)
        )
        #expect(outcome.value == .text("1.01"))
        #expect(outcome.lostPrecision)
    }

    @Test("A value in exponent notation is left for the server")
    func decimalExponent() throws {
        #expect(try text("1e20", .decimalFit(precision: 10, scale: 2)) == .text("1e20"))
    }

    // MARK: - Epoch parsing

    @Test(
        "Timestamp text resolves to UTC epoch seconds",
        arguments: [
            ("1970-01-01 00:00:00", 0),
            ("2038-01-19 03:14:07", 2_147_483_647),
            ("2024-05-01T00:00:00Z", 1_714_521_600),
            ("2024-05-01 02:00:00+02:00", 1_714_521_600),
            ("2024-05-01", 1_714_521_600)
        ]
    )
    func epochSeconds(input: String, expected: Int) {
        #expect(TransferValueConverter.epochSeconds(input) == expected)
    }
}

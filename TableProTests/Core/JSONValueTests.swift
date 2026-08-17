//
//  JSONValueTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @Test("Nested object and array round trip to the same value")
    func nestedRoundTrip() throws {
        let json = """
        {"a":{"b":[1,"two",true,null,{"c":1.5}]},"d":[]}
        """
        let value = try decode(json)
        let reencoded = try encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(again == value)
    }

    @Test("An integer stays an integer and a fractional number stays a double")
    func integerAndDoubleStayDistinct() throws {
        let value = try decode(#"{"i":1,"d":1.5}"#)
        #expect(value.objectValue?["i"] == .int(1))
        #expect(value.objectValue?["d"] == .double(1.5))
        #expect(JSONValue.int(1) != JSONValue.double(1.0))
    }

    @Test("An integer re-encodes without a decimal point")
    func integerEncodesWithoutFraction() throws {
        let encoded = try encode(.object(["i": .int(7)]))
        #expect(String(bytes: encoded, encoding: .utf8) == #"{"i":7}"#)
    }

    @Test("Every key survives a decode and re-encode")
    func keySetPreserved() throws {
        let value = try decode(#"{"z":1,"a":2,"m":{"n":3}}"#)
        #expect(Set(value.objectValue?.keys ?? [:].keys) == ["z", "a", "m"])
        let again = try JSONDecoder().decode(JSONValue.self, from: try encode(value))
        #expect(again == value)
    }

    @Test("Booleans decode as booleans, not as numbers")
    func booleansStayBooleans() throws {
        let value = try decode(#"{"t":true,"f":false,"one":1}"#)
        #expect(value.objectValue?["t"] == .bool(true))
        #expect(value.objectValue?["f"] == .bool(false))
        #expect(value.objectValue?["one"] == .int(1))
    }

    @Test("Null decodes as null and re-encodes as null")
    func nullRoundTrips() throws {
        let value = try decode(#"{"n":null}"#)
        #expect(value.objectValue?["n"] == JSONValue.null)
        #expect(String(bytes: try encode(value), encoding: .utf8) == #"{"n":null}"#)
    }

    @Test("A top-level array decodes with its element order intact")
    func topLevelArrayOrder() throws {
        let value = try decode("[3,1,2]")
        #expect(value == .array([.int(3), .int(1), .int(2)]))
    }

    @Test("A negative integer beyond Int32 round trips exactly")
    func largeNegativeInteger() throws {
        let value = try decode(#"{"n":-9007199254740993}"#)
        #expect(value.objectValue?["n"] == .int(-9_007_199_254_740_993))
    }
}

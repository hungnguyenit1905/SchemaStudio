//
//  AddressConsistencyTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The point of the address group: every address column in one row must describe
/// the same real place. A row that pairs a ward in Ho Chi Minh City with the
/// province of Ha Noi is worse than obviously fake data, because it looks real
/// enough to be trusted.
@Suite("Address consistency")
struct AddressConsistencyTests {
    private static let registry = GeneratorRegistry.standard

    private func bound(
        _ identifiers: [String],
        locale: GenerationLocale,
        tableSeed: UInt64 = 4_242
    ) throws -> [String: any ValueGenerator] {
        let source = LocalityRowSource(locale: locale, seed: tableSeed)
        var made: [String: any ValueGenerator] = [:]
        for identifier in identifiers {
            let generator = try Self.registry.make(
                identifier: identifier,
                params: Data(#"{"locale":"\#(locale.rawValue)"}"#.utf8),
                column: GeneratorTestFixtures.column(dataType: "varchar(200)"),
                seed: UInt64(identifier.hashValue.magnitude % 100_000)
            )
            if let consumer = generator as? LocalityConsuming {
                consumer.bind(localities: source)
            }
            made[identifier] = generator
        }
        return made
    }

    private func text(_ generator: any ValueGenerator, row: Int) throws -> String {
        let value = try generator.next(row: RowContext(table: "t", rowIndex: row), index: row)
        guard case let .text(text) = value else { return "" }
        return text
    }

    @Test("City, state and postal code in one row come from one record", arguments: GenerationLocale.allCases)
    func oneRowDescribesOnePlace(locale: GenerationLocale) throws {
        let generators = try bound(
            [CityField.identifier, StateField.identifier, PostalCodeField.identifier, TimeZoneField.identifier],
            locale: locale
        )
        let records = LocaleDataStore.shared.localityRecords(locale: locale)
        #expect(!records.isEmpty)

        for row in 0..<500 {
            let city = try text(#require(generators[CityField.identifier]), row: row)
            let state = try text(#require(generators[StateField.identifier]), row: row)
            let postal = try text(#require(generators[PostalCodeField.identifier]), row: row)
            let zone = try text(#require(generators[TimeZoneField.identifier]), row: row)
            let matching = records.filter {
                $0.city == city && $0.state == state && $0.postalCode == postal && $0.timeZone == zone
            }
            #expect(
                !matching.isEmpty,
                "row \(row) of \(locale.rawValue) produced \(city) / \(state) / \(postal) / \(zone), which is no real record"
            )
        }
    }

    @Test("Coordinates belong to the same record as the city", arguments: GenerationLocale.allCases)
    func coordinatesMatchTheCity(locale: GenerationLocale) throws {
        let generators = try bound(
            [CityField.identifier, LatitudeField.identifier, LongitudeField.identifier],
            locale: locale
        )
        let records = LocaleDataStore.shared.localityRecords(locale: locale)

        for row in 0..<200 {
            let city = try text(#require(generators[CityField.identifier]), row: row)
            let latitude = try #require(generators[LatitudeField.identifier])
                .next(row: RowContext(table: "t", rowIndex: row), index: row)
            let longitude = try #require(generators[LongitudeField.identifier])
                .next(row: RowContext(table: "t", rowIndex: row), index: row)
            let expected = records.filter { $0.city == city }
            #expect(expected.contains { record in
                GenerationValueMapper.value(from: .double(record.latitude), base: .string) == latitude
                    && GenerationValueMapper.value(from: .double(record.longitude), base: .string) == longitude
            })
        }
    }

    @Test("Reading a column twice in one row gives the same place")
    func rereadingARowIsStable() throws {
        let generators = try bound([CityField.identifier, StateField.identifier], locale: .viVN)
        let city = try #require(generators[CityField.identifier])
        for row in 0..<100 {
            #expect(try text(city, row: row) == (try text(city, row: row)))
        }
    }

    @Test("Column order inside a row does not change the place")
    func columnOrderDoesNotMatter() throws {
        let forwards = try bound([CityField.identifier, StateField.identifier], locale: .enUS)
        let backwards = try bound([StateField.identifier, CityField.identifier], locale: .enUS)
        for row in 0..<200 {
            let firstState = try text(#require(backwards[StateField.identifier]), row: row)
            let firstCity = try text(#require(backwards[CityField.identifier]), row: row)
            #expect(try text(#require(forwards[CityField.identifier]), row: row) == firstCity)
            #expect(try text(#require(forwards[StateField.identifier]), row: row) == firstState)
        }
    }

    @Test("A different table seed moves the row to a different place")
    func theSeedChangesTheRun() throws {
        let first = try bound([CityField.identifier], locale: .enUS, tableSeed: 1)
        let second = try bound([CityField.identifier], locale: .enUS, tableSeed: 2)
        var differences = 0
        for row in 0..<200 where
            try text(#require(first[CityField.identifier]), row: row)
            != (try text(#require(second[CityField.identifier]), row: row)) {
            differences += 1
        }
        #expect(differences > 100)
    }

    @Test("A full address names the same place as the city column", arguments: GenerationLocale.allCases)
    func fullAddressAgreesWithTheCityColumn(locale: GenerationLocale) throws {
        let generators = try bound([CityField.identifier, FullAddressGenerator.identifier], locale: locale)
        for row in 0..<200 {
            let city = try text(#require(generators[CityField.identifier]), row: row)
            let full = try text(#require(generators[FullAddressGenerator.identifier]), row: row)
            #expect(full.contains(city), "\(full) does not contain \(city)")
        }
    }

    @Test("Vietnamese addresses keep their diacritics through the pipeline")
    func vietnameseKeepsDiacritics() throws {
        let generators = try bound([CityField.identifier, StateField.identifier], locale: .viVN)
        var seen: Set<String> = []
        for row in 0..<200 {
            seen.insert(try text(#require(generators[StateField.identifier]), row: row))
        }
        #expect(seen.contains { $0.contains("ộ") || $0.contains("ẵ") || $0.contains("ả") || $0.contains("ơ") })
        #expect(seen.allSatisfy { !$0.isEmpty })
    }
}

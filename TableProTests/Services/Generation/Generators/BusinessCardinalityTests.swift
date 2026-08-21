//
//  BusinessCardinalityTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// `distinctValueCount` is what `GenerationProfileValidator` trusts when it
/// decides whether a unique column can be filled at all. Overstating it lets an
/// impossible configuration past pre-flight and fails deep inside the run, so
/// these assert the count against the values the generator really produces.
@Suite("Business generator cardinality")
struct BusinessCardinalityTests {
    private static let registry = GeneratorRegistry.standard

    private func generator(_ identifier: String, params: String, dataType: String) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(dataType: dataType),
            seed: 11
        )
    }

    private func distinctProduced(_ generator: any ValueGenerator, draws: Int) throws -> Set<String> {
        var seen: Set<String> = []
        for index in 0..<draws {
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .text(text) = value else { continue }
            seen.insert(text)
        }
        return seen
    }

    @Test("A short column never reports more values than it can produce", arguments: [
        (CompanyNameGenerator.identifier, #"{"locale":"en_US"}"#),
        (ProductNameGenerator.identifier, #"{"locale":"en_US"}"#),
        (DepartmentGenerator.identifier, #"{"locale":"en_US"}"#)
    ])
    func truncationIsNotCountedAsVariety(identifier: String, params: String) throws {
        let narrow = try generator(identifier, params: params, dataType: "varchar(6)")
        let claimed = try #require(narrow.distinctValueCount)
        let produced = try distinctProduced(narrow, draws: 20_000)
        #expect(
            claimed >= produced.count,
            "\(identifier) claims \(claimed) values but produced \(produced.count) distinct ones"
        )
    }

    /// Six characters is not narrow enough to collapse every list, so the case
    /// that proves the count actually tracks truncation uses a width where
    /// collisions are unavoidable: 95 company stems cannot stay distinct in three
    /// characters.
    @Test("A width that forces collisions lowers the reported count")
    func collidingWidthLowersTheCount() throws {
        let params = #"{"locale":"en_US","includeSuffix":false}"#
        let narrow = try generator(CompanyNameGenerator.identifier, params: params, dataType: "varchar(3)")
        let unlimited = try generator(CompanyNameGenerator.identifier, params: params, dataType: "text")
        let claimed = try #require(narrow.distinctValueCount)
        let unlimitedClaim = try #require(unlimited.distinctValueCount)
        #expect(claimed < unlimitedClaim)
        #expect(claimed >= (try distinctProduced(narrow, draws: 20_000)).count)
    }

    @Test("A column wide enough to hold every value keeps the full count")
    func awideColumnKeepsTheCrossProduct() throws {
        let wide = try generator(DepartmentGenerator.identifier, params: #"{"locale":"en_US"}"#, dataType: "varchar(200)")
        let unlimited = try generator(DepartmentGenerator.identifier, params: #"{"locale":"en_US"}"#, dataType: "text")
        #expect(wide.distinctValueCount == unlimited.distinctValueCount)
    }

    @Test("Vietnamese values are measured in characters, not bytes")
    func vietnameseCountsCharacters() throws {
        let generator = try generator(
            DepartmentGenerator.identifier,
            params: #"{"locale":"vi_VN"}"#,
            dataType: "varchar(200)"
        )
        let produced = try distinctProduced(generator, draws: 2_000)
        #expect(produced.contains { $0.contains("ò") || $0.contains("ê") || $0.contains("ả") })
    }
}

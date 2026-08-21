//
//  ClickHouseDialectTests.swift
//  TableProTests
//
//  Tests for ClickHouse dialect descriptor structure
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("ClickHouse Dialect")
struct ClickHouseDialectTests {
    @Test("SQLDialectDescriptor with ClickHouse-style config")
    func testClickHouseDialectDescriptor() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FINAL", "PREWHERE", "SAMPLE", "ENGINE"],
            functions: ["UNIQ", "ARGMIN", "TOPK"],
            dataTypes: ["UInt32", "String", "DateTime"]
        )
        let adapter = PluginDialectAdapter(descriptor: descriptor)

        #expect(adapter.identifierQuote == "`")
        #expect(adapter.keywords.contains("FINAL"))
        #expect(adapter.functions.contains("UNIQ"))
        #expect(adapter.dataTypes.contains("UInt32"))
    }

    @Test("Factory serves the registry default dialect before the plugin loads")
    @MainActor
    func testFactoryFallbackWithoutPlugin() {
        let dialect = SQLDialectFactory.createDialect(for: .clickhouse)
        #expect(dialect.identifierQuote == "`")
        #expect(dialect.keywords.contains("PREWHERE"))
        #expect(dialect.keywords.contains("FINAL"))
    }

    @Test("Factory returns the empty dialect for a type no plugin describes")
    @MainActor
    func testFactoryFallbackForUnknownType() {
        let dialect = SQLDialectFactory.createDialect(for: DatabaseType(rawValue: "NotARealEngine"))
        #expect(dialect.keywords.isEmpty)
    }
}

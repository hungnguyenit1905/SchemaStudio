//
//  GenerationSeedTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("GenerationSeed")
struct GenerationSeedTests {
    @Test("A column seed matches its reference FNV-1a constant")
    func referenceConstants() {
        #expect(
            GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "email")
                == 16_203_399_429_681_520_915
        )
        #expect(
            GenerationSeed.columnSeed(runSeed: 42, table: "public.users", column: "id")
                == 15_121_650_225_758_886_939
        )
    }

    @Test("Two columns in one table get different streams")
    func columnsWithinATableDiffer() {
        let email = GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "email")
        let name = GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "name")
        #expect(email != name)
        #expect(name == 12_425_648_384_036_410_541)
    }

    @Test("The same column name in two tables gets different streams")
    func sameColumnAcrossTablesDiffers() {
        let users = GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "email")
        let orders = GenerationSeed.columnSeed(runSeed: 0, table: "orders", column: "email")
        #expect(users != orders)
        #expect(orders == 2_478_644_597_311_646_583)
    }

    @Test("Changing the run seed changes every column")
    func runSeedChangesEverything() {
        let base = GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "email")
        let shifted = GenerationSeed.columnSeed(runSeed: 1, table: "users", column: "email")
        #expect(base != shifted)
        #expect(shifted == 13_006_592_434_791_688_618)
    }

    @Test("The table and column separator prevents name splicing collisions")
    func separatorPreventsSplicing() {
        let split = GenerationSeed.columnSeed(runSeed: 0, table: "user", column: "semail")
        let other = GenerationSeed.columnSeed(runSeed: 0, table: "users", column: "email")
        #expect(split != other)
    }

    @Test("A generator stream is reproducible from the seed alone")
    func streamIsReproducible() {
        var first = GenerationSeed.generator(runSeed: 7, table: "orders", column: "total")
        var second = GenerationSeed.generator(runSeed: 7, table: "orders", column: "total")
        let firstValues = (0..<8).map { _ in first.next() }
        let secondValues = (0..<8).map { _ in second.next() }
        #expect(firstValues == secondValues)
    }
}

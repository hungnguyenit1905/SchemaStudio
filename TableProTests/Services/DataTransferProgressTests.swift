//
//  DataTransferProgressTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("DataTransfer progress and outcomes")
struct DataTransferProgressTests {
    private func state(
        currentTableIndex: Int,
        totalTables: Int,
        processed: Int = 0,
        estimated: Int = 0
    ) -> TransferState {
        TransferState(
            currentTableIndex: currentTableIndex,
            totalTables: totalTables,
            currentTableProcessedRows: processed,
            currentTableEstimatedRows: estimated
        )
    }

    @Test("No table to copy leaves the bar indeterminate")
    func noTablesIsIndeterminate() {
        #expect(state(currentTableIndex: 0, totalTables: 0).progressFraction == nil)
    }

    @Test("A table with no row estimate contributes nothing until it completes")
    func missingEstimateContributesNothing() {
        let value = state(currentTableIndex: 1, totalTables: 4, processed: 500, estimated: 0).progressFraction
        #expect(value == 0)
    }

    @Test("The first table contributes only its own fraction")
    func firstTableFraction() {
        let value = state(currentTableIndex: 1, totalTables: 4, processed: 50, estimated: 100).progressFraction
        #expect(value == 0.125)
    }

    @Test("More rows than estimated clamps the current table at one whole table")
    func overshootClampsToOne() {
        let value = state(currentTableIndex: 1, totalTables: 4, processed: 400, estimated: 100).progressFraction
        #expect(value == 0.25)
    }

    @Test("Completed tables count in full")
    func completedTablesCountInFull() {
        let value = state(currentTableIndex: 3, totalTables: 4, processed: 0, estimated: 100).progressFraction
        #expect(value == 0.5)
    }

    @Test("The last table finishing reaches 100% and never passes it")
    func lastTableReachesOne() {
        let value = state(currentTableIndex: 4, totalTables: 4, processed: 999, estimated: 100).progressFraction
        #expect(value == 1)
    }
}

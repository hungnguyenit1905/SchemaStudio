//
//  ExportScopeAvailabilityTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Export Scope Availability")
struct ExportScopeAvailabilityTests {
    private func makeTableRows(rowCount: Int) -> TableRows {
        var tableRows = TableRows(columns: ["id"], columnTypes: [.integer(rawType: "INT")])
        tableRows.appendPage((0 ..< rowCount).map { [PluginCellValue.int(Int64($0))] }, startingAt: 0)
        return tableRows
    }

    @Test("Filtered scope is offered only when a client side filter or sort is active")
    func filteredScopeRequiresActiveRefinement() {
        let rows = makeTableRows(rowCount: 5)
        let withoutRefinement = ExportScopeAvailability.resolve(
            ExportRowSelection(tableRows: rows, displayIDs: [.existing(0), .existing(1)])
        )
        let withRefinement = ExportScopeAvailability.resolve(
            ExportRowSelection(
                tableRows: rows,
                displayIDs: [.existing(0), .existing(1)],
                hasClientSideRefinement: true
            )
        )
        #expect(withoutRefinement.option(for: .displayedRows) == nil)
        #expect(withRefinement.count(for: .displayedRows) == 2)
    }

    @Test("Selected scope is disabled for an empty resolved selection")
    func selectedScopeDisabledWhenEmpty() {
        let rows = makeTableRows(rowCount: 5)
        let empty = ExportScopeAvailability.resolve(ExportRowSelection(tableRows: rows))
        let filled = ExportScopeAvailability.resolve(
            ExportRowSelection(tableRows: rows, selectedDisplayIndices: [1, 3])
        )
        #expect(empty.isEnabled(.selectedRows) == false)
        #expect(empty.count(for: .selectedRows) == 0)
        #expect(filled.isEnabled(.selectedRows))
        #expect(filled.count(for: .selectedRows) == 2)
    }

    @Test("No scope picker is offered when the data grid does not own the selection")
    func noPickerWithoutDataGridOwnership() {
        let rows = makeTableRows(rowCount: 5)
        let availability = ExportScopeAvailability.resolve(
            ExportRowSelection(
                tableRows: rows,
                selectedDisplayIndices: [0, 1],
                hasClientSideRefinement: true,
                dataGridOwnsSelection: false
            )
        )
        #expect(availability.showsPicker == false)
        #expect(availability.options.map(\.scope) == [.allRows])
        #expect(availability.defaultScope == .allRows)
    }

    @Test("Partial load is flagged for loaded scopes and cleared when all rows re-queries the server")
    func partialLoadFlag() {
        let rows = makeTableRows(rowCount: 200)
        let streaming = ExportScopeAvailability.resolve(
            ExportRowSelection(
                tableRows: rows,
                selectedDisplayIndices: [0],
                hasClientSideRefinement: true,
                hasMoreRows: true,
                allRowsQuery: ExportAllRowsQuery(sql: "SELECT * FROM t")
            )
        )
        #expect(streaming.isPartialLoad(for: .allRows) == false)
        #expect(streaming.isPartialLoad(for: .displayedRows))
        #expect(streaming.isPartialLoad(for: .selectedRows))

        let noStreaming = ExportScopeAvailability.resolve(
            ExportRowSelection(tableRows: rows, hasMoreRows: true)
        )
        #expect(noStreaming.isPartialLoad(for: .allRows))

        let fullyLoaded = ExportScopeAvailability.resolve(ExportRowSelection(tableRows: rows))
        #expect(fullyLoaded.isPartialLoad(for: .allRows) == false)
        #expect(fullyLoaded.isPartialLoad(for: .selectedRows) == false)
    }

    @Test("All rows count uses the server estimate only when it re-queries a truncated result")
    func allRowsCountSource() {
        let rows = makeTableRows(rowCount: 200)
        let streaming = ExportScopeAvailability.resolve(
            ExportRowSelection(
                tableRows: rows,
                hasMoreRows: true,
                totalRowCountEstimate: 12431,
                allRowsQuery: ExportAllRowsQuery(sql: "SELECT * FROM t")
            )
        )
        #expect(streaming.count(for: .allRows) == 12431)
        #expect(streaming.streamsFromServer(for: .allRows))

        let inMemory = ExportScopeAvailability.resolve(
            ExportRowSelection(tableRows: rows, hasMoreRows: true, totalRowCountEstimate: 12431)
        )
        #expect(inMemory.count(for: .allRows) == 200)
        #expect(inMemory.streamsFromServer(for: .allRows) == false)
    }

    @Test("Counts exclude delete marked and unsaved inserted rows")
    func countsExcludePendingEdits() {
        var rows = makeTableRows(rowCount: 5)
        rows.appendInsertedRow(values: [.int(99)])
        let selection = ExportRowSelection(
            tableRows: rows,
            selectedDisplayIndices: [0, 1, 2, 5],
            excludedRowIDs: [.existing(1)],
            hasClientSideRefinement: true
        )
        let availability = ExportScopeAvailability.resolve(selection)
        #expect(availability.count(for: .allRows) == 4)
        #expect(availability.count(for: .displayedRows) == 4)
        #expect(availability.count(for: .selectedRows) == 2)
        #expect(selection.resolvedRows(for: .selectedRows).count == 2)
    }

    @Test("An unavailable preferred scope falls back to the default scope")
    func unavailableScopeFallsBack() {
        let rows = makeTableRows(rowCount: 5)
        let availability = ExportScopeAvailability.resolve(ExportRowSelection(tableRows: rows))
        #expect(availability.resolvedScope(preferring: .selectedRows) == .allRows)
        #expect(availability.resolvedScope(preferring: .displayedRows) == .allRows)
        #expect(availability.resolvedScope(preferring: .allRows) == .allRows)
    }
}

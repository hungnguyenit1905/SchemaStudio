//
//  ExportRowSetResolverTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Export Row Set Resolver")
struct ExportRowSetResolverTests {
    private func makeTableRows(rowCount: Int) -> TableRows {
        var tableRows = TableRows(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR")],
            columnNullable: ["id": false, "name": true],
            columnComments: ["name": "display name"]
        )
        let page = (0 ..< rowCount).map { index in
            [PluginCellValue.int(Int64(index)), PluginCellValue.text("row\(index)")]
        }
        tableRows.appendPage(page, startingAt: 0)
        return tableRows
    }

    private func names(_ tableRows: TableRows) -> [String] {
        tableRows.rows.map { row in
            if case let .text(value) = row[1] { return value }
            return ""
        }
    }

    @Test("Displayed rows follow display order with no display mapping")
    func displayedRowsWithoutMapping() {
        let tableRows = makeTableRows(rowCount: 4)
        let result = ExportRowSetResolver.resolve(
            scope: .displayedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row0", "row1", "row2", "row3"])
    }

    @Test("Displayed rows follow display order under a filtering reversed mapping")
    func displayedRowsWithMapping() {
        let tableRows = makeTableRows(rowCount: 4)
        let displayIDs: [RowID] = [.existing(3), .existing(2), .existing(1)]
        let result = ExportRowSetResolver.resolve(
            scope: .displayedRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row3", "row2", "row1"])
    }

    @Test("Selected rows resolve in display order regardless of set iteration order")
    func selectedRowsSortedIntoDisplayOrder() {
        let tableRows = makeTableRows(rowCount: 4)
        let result = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [2, 0],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row0", "row2"])
    }

    @Test("Selected rows under a diverging mapping resolve through the mapping, not by position")
    func selectedRowsUnderDivergingMapping() {
        let tableRows = makeTableRows(rowCount: 4)
        let displayIDs: [RowID] = [.existing(3), .existing(2), .existing(1)]
        let result = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [0, 2],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row3", "row1"])
    }

    @Test("Empty selection resolves to zero rows")
    func emptySelectionResolvesToNoRows() {
        let tableRows = makeTableRows(rowCount: 4)
        let result = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        #expect(result.rows.isEmpty)
    }

    @Test("Out of range display indices are dropped and the rest still resolve")
    func outOfRangeIndicesDropped() {
        let tableRows = makeTableRows(rowCount: 3)
        let result = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [-1, 1, 99],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row1"])
    }

    @Test("Stale display IDs absent from the row set are dropped")
    func staleDisplayIDsDropped() {
        let tableRows = makeTableRows(rowCount: 3)
        let displayIDs: [RowID] = [.existing(0), .existing(97), .existing(2)]
        let result = ExportRowSetResolver.resolve(
            scope: .displayedRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        #expect(names(result) == ["row0", "row2"])
    }

    @Test("Delete marked rows are excluded from every scope")
    func deleteMarkedRowsExcluded() {
        let tableRows = makeTableRows(rowCount: 4)
        let excluded: Set<RowID> = [.existing(1)]
        let all = ExportRowSetResolver.resolve(
            scope: .allRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [],
            excludedRowIDs: excluded
        )
        let displayed = ExportRowSetResolver.resolve(
            scope: .displayedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [],
            excludedRowIDs: excluded
        )
        let selected = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [0, 1, 2],
            excludedRowIDs: excluded
        )
        #expect(names(all) == ["row0", "row2", "row3"])
        #expect(names(displayed) == ["row0", "row2", "row3"])
        #expect(names(selected) == ["row0", "row2"])
    }

    @Test("Unsaved inserted rows are excluded from every scope")
    func insertedRowsExcluded() {
        var tableRows = makeTableRows(rowCount: 3)
        tableRows.insertInsertedRow(at: 1, values: [.int(99), .text("unsaved")])
        let insertedID = tableRows.rows[1].id
        let displayIDs: [RowID] = [.existing(0), insertedID, .existing(1), .existing(2)]

        let all = ExportRowSetResolver.resolve(
            scope: .allRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        let displayed = ExportRowSetResolver.resolve(
            scope: .displayedRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [],
            excludedRowIDs: []
        )
        let selected = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: [1, 2],
            excludedRowIDs: []
        )
        #expect(names(all) == ["row0", "row1", "row2"])
        #expect(names(displayed) == ["row0", "row1", "row2"])
        #expect(names(selected) == ["row1"])
    }

    @Test("Column metadata survives resolution unchanged")
    func columnMetadataPreserved() {
        let tableRows = makeTableRows(rowCount: 3)
        let result = ExportRowSetResolver.resolve(
            scope: .selectedRows,
            tableRows: tableRows,
            displayIDs: nil,
            selectedDisplayIndices: [1],
            excludedRowIDs: []
        )
        #expect(result.columns == tableRows.columns)
        #expect(result.columnTypes == tableRows.columnTypes)
        #expect(result.columnNullable == tableRows.columnNullable)
        #expect(result.columnComments == tableRows.columnComments)
    }

    @Test("Count matches the resolved row count for every scope")
    func countMatchesResolvedRows() {
        var tableRows = makeTableRows(rowCount: 5)
        tableRows.appendInsertedRow(values: [.int(9), .text("unsaved")])
        let excluded: Set<RowID> = [.existing(2)]
        for scope in ExportRowScope.allCases {
            let resolved = ExportRowSetResolver.resolve(
                scope: scope,
                tableRows: tableRows,
                displayIDs: nil,
                selectedDisplayIndices: [0, 2, 4],
                excludedRowIDs: excluded
            )
            let counted = ExportRowSetResolver.count(
                scope: scope,
                tableRows: tableRows,
                displayIDs: nil,
                selectedDisplayIndices: [0, 2, 4],
                excludedRowIDs: excluded
            )
            #expect(resolved.count == counted)
        }
    }
}

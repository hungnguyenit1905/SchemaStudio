//
//  ExportRowSelectionTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Export Row Selection")
struct ExportRowSelectionTests {
    private func makeTableRows(rowCount: Int) -> TableRows {
        var tableRows = TableRows(columns: ["id"], columnTypes: [.integer(rawType: "INT")])
        tableRows.appendPage((0 ..< rowCount).map { [PluginCellValue.int(Int64($0))] }, startingAt: 0)
        return tableRows
    }

    @Test("The snapshot copies rows, display order and selection rather than referencing them")
    func snapshotCopiesItsInputs() {
        var rows = makeTableRows(rowCount: 3)
        var displayIDs: [RowID] = [.existing(2), .existing(1), .existing(0)]
        var selected: Set<Int> = [0]

        let selection = ExportRowSelection(
            tableRows: rows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selected
        )

        rows.replace(rows: [[.int(90)], [.int(91)]])
        displayIDs = [.existing(0)]
        selected = [2]

        #expect(selection.tableRows.count == 3)
        #expect(selection.displayIDs?.count == 3)
        #expect(selection.selectedDisplayIndices == [0])
        #expect(selection.count(for: .selectedRows) == 1)
    }

    @Test("A missing delegate chain yields no display order and an empty selection, never all rows")
    func missingDelegateChainYieldsEmptySelection() {
        let selection = ExportRowSelection(tableRows: makeTableRows(rowCount: 4))
        #expect(selection.displayIDs == nil)
        #expect(selection.selectedDisplayIndices.isEmpty)
        #expect(selection.count(for: .selectedRows) == 0)
    }

    @Test("Currency is reported by the injected check")
    func stalenessIsDetected() async {
        let current = ExportRowSelection(tableRows: makeTableRows(rowCount: 2))
        let stale = ExportRowSelection(tableRows: makeTableRows(rowCount: 2), isStillCurrent: { false })
        await #expect(MainActor.run { current.isStillCurrent() })
        await #expect(MainActor.run { !stale.isStillCurrent() })
    }

    @Test("A parameterized all rows query is reported as parameterized")
    func parameterizedQueryDetection() {
        #expect(ExportAllRowsQuery(sql: "SELECT 1").isParameterized == false)
        #expect(ExportAllRowsQuery(sql: "SELECT 1", parameterValues: []).isParameterized == false)
        #expect(ExportAllRowsQuery(sql: "SELECT 1", parameterValues: ["a"]).isParameterized)
    }
}

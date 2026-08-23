//
//  ExportRowSelection.swift
//  TablePro
//

import Foundation

struct ExportAllRowsQuery: Equatable, Sendable {
    let sql: String
    let parameterValues: [String?]?

    init(sql: String, parameterValues: [String?]? = nil) {
        self.sql = sql
        self.parameterValues = parameterValues
    }

    var isParameterized: Bool {
        guard let parameterValues else { return false }
        return !parameterValues.isEmpty
    }
}

struct ExportRowSelection {
    let tableRows: TableRows
    let displayIDs: [RowID]?
    let selectedDisplayIndices: Set<Int>
    let excludedRowIDs: Set<RowID>
    let hasClientSideRefinement: Bool
    let hasMoreRows: Bool
    let dataGridOwnsSelection: Bool
    let totalRowCountEstimate: Int?
    let allRowsQuery: ExportAllRowsQuery?
    let isStillCurrent: @MainActor () -> Bool

    init(
        tableRows: TableRows,
        displayIDs: [RowID]? = nil,
        selectedDisplayIndices: Set<Int> = [],
        excludedRowIDs: Set<RowID> = [],
        hasClientSideRefinement: Bool = false,
        hasMoreRows: Bool = false,
        dataGridOwnsSelection: Bool = true,
        totalRowCountEstimate: Int? = nil,
        allRowsQuery: ExportAllRowsQuery? = nil,
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.tableRows = tableRows
        self.displayIDs = displayIDs
        self.selectedDisplayIndices = selectedDisplayIndices
        self.excludedRowIDs = excludedRowIDs
        self.hasClientSideRefinement = hasClientSideRefinement
        self.hasMoreRows = hasMoreRows
        self.dataGridOwnsSelection = dataGridOwnsSelection
        self.totalRowCountEstimate = totalRowCountEstimate
        self.allRowsQuery = allRowsQuery
        self.isStillCurrent = isStillCurrent
    }

    func resolvedRows(for scope: ExportRowScope) -> TableRows {
        ExportRowSetResolver.resolve(
            scope: scope,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            excludedRowIDs: excludedRowIDs
        )
    }

    func count(for scope: ExportRowScope) -> Int {
        ExportRowSetResolver.count(
            scope: scope,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            excludedRowIDs: excludedRowIDs
        )
    }
}

//
//  MainContentCoordinator+ExportScope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// The snapshot is taken once, at sheet presentation. `activeGridDisplayIDs` chases two weak
    /// hops and the selection is a live binding into the table view, so both are copied here
    /// rather than read again while the sheet is open.
    func makeExportRowSelection(for tab: QueryTab) -> ExportRowSelection {
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        let displayIDs = activeGridDisplayIDs
        let ownsSelection = GridSelectionOwner.resolve(
            tabType: tab.tabType,
            resultsViewMode: tab.display.resultsViewMode
        ) == .dataGrid
        let selectedDisplayIndices: Set<Int> = ownsSelection
            ? (dataTabDelegate?.tableViewCoordinator?.currentRowSelection() ?? [])
            : []

        let capturedGeneration = queryGeneration
        let capturedRowCount = tableRows.rows.count
        let tabId = tab.id

        return ExportRowSelection(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            excludedRowIDs: exportExcludedRowIDs(tableRows: tableRows, displayIDs: displayIDs),
            hasClientSideRefinement: displayOrderDiffersFromRows(tableRows: tableRows, displayIDs: displayIDs),
            hasMoreRows: tab.pagination.hasMoreRows,
            dataGridOwnsSelection: ownsSelection,
            totalRowCountEstimate: tab.pagination.totalRowCount,
            allRowsQuery: exportAllRowsQuery(for: tab, tableRows: tableRows),
            isStillCurrent: { [weak self] in
                guard let self else { return false }
                guard capturedGeneration == queryGeneration else { return false }
                return tabSessionRegistry.tableRows(for: tabId).rows.count == capturedRowCount
            }
        )
    }

    /// `deletedRowIndices` holds grid positions, which equal storage indices only when no
    /// client-side filter or sort is active, so every one of them resolves through the mapping.
    private func exportExcludedRowIDs(tableRows: TableRows, displayIDs: [RowID]?) -> Set<RowID> {
        var excluded = Set<RowID>()
        for index in changeManager.deletedRowIndices {
            guard let rowIndex = DisplayRowMapping.rowIndex(
                forDisplay: index,
                displayIDs: displayIDs,
                in: tableRows
            ) else { continue }
            guard rowIndex >= 0, rowIndex < tableRows.rows.count else { continue }
            excluded.insert(tableRows.rows[rowIndex].id)
        }
        return excluded
    }

    private func displayOrderDiffersFromRows(tableRows: TableRows, displayIDs: [RowID]?) -> Bool {
        guard let displayIDs else { return false }
        guard displayIDs.count == tableRows.rows.count else { return true }
        return !displayIDs.elementsEqual(tableRows.rows.map(\.id))
    }

    /// A table tab's executed query carries `LIMIT`/`OFFSET`, so it is recomposed with neither.
    /// A query tab's own SQL has no pagination and keeps its bound parameter values.
    private func exportAllRowsQuery(for tab: QueryTab, tableRows: TableRows) -> ExportAllRowsQuery? {
        guard let tableName = tab.tableContext.tableName, tab.tabType == .table else {
            guard let sql = tab.pagination.baseQueryForMore else { return nil }
            return ExportAllRowsQuery(sql: sql, parameterValues: tab.pagination.baseQueryParameterValues)
        }
        guard let sql = queryBuilder.buildUnpaginatedQuery(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            filters: tab.filterState.filters,
            logicMode: tab.filterState.filterLogicMode,
            sortState: tab.sortState,
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes,
            selectColumns: selectColumns(for: tab)
        ) else { return nil }
        return ExportAllRowsQuery(sql: sql)
    }
}

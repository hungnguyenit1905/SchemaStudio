//
//  ExportRowSetResolver.swift
//  TablePro
//

import Foundation

enum ExportRowSetResolver {
    static func resolve(
        scope: ExportRowScope,
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        excludedRowIDs: Set<RowID>
    ) -> TableRows {
        let rowIndices = rowIndices(
            scope: scope,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            excludedRowIDs: excludedRowIDs
        )
        var scopedRows = ContiguousArray<Row>()
        scopedRows.reserveCapacity(rowIndices.count)
        for index in rowIndices {
            scopedRows.append(tableRows.rows[index])
        }
        return TableRows(
            rows: scopedRows,
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes,
            columnDefaults: tableRows.columnDefaults,
            columnForeignKeys: tableRows.columnForeignKeys,
            columnEnumValues: tableRows.columnEnumValues,
            columnNullable: tableRows.columnNullable,
            columnComments: tableRows.columnComments,
            foreignKeysFetched: tableRows.foreignKeysFetched
        )
    }

    static func count(
        scope: ExportRowScope,
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        excludedRowIDs: Set<RowID>
    ) -> Int {
        rowIndices(
            scope: scope,
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            excludedRowIDs: excludedRowIDs
        ).count
    }

    static func displayCount(tableRows: TableRows, displayIDs: [RowID]?) -> Int {
        displayIDs?.count ?? tableRows.count
    }

    private static func rowIndices(
        scope: ExportRowScope,
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedDisplayIndices: Set<Int>,
        excludedRowIDs: Set<RowID>
    ) -> [Int] {
        switch scope {
        case .allRows:
            return tableRows.rows.indices.filter { isExportable(tableRows.rows[$0].id, excludedRowIDs) }
        case .displayedRows:
            let total = displayCount(tableRows: tableRows, displayIDs: displayIDs)
            return resolveDisplayIndices(
                Array(0 ..< total),
                tableRows: tableRows,
                displayIDs: displayIDs,
                excludedRowIDs: excludedRowIDs
            )
        case .selectedRows:
            return resolveDisplayIndices(
                selectedDisplayIndices.sorted(),
                tableRows: tableRows,
                displayIDs: displayIDs,
                excludedRowIDs: excludedRowIDs
            )
        }
    }

    private static func resolveDisplayIndices(
        _ displayIndices: [Int],
        tableRows: TableRows,
        displayIDs: [RowID]?,
        excludedRowIDs: Set<RowID>
    ) -> [Int] {
        var resolved = [Int]()
        resolved.reserveCapacity(displayIndices.count)
        for displayIndex in displayIndices {
            guard let rowIndex = DisplayRowMapping.rowIndex(
                forDisplay: displayIndex,
                displayIDs: displayIDs,
                in: tableRows
            ) else { continue }
            guard rowIndex >= 0, rowIndex < tableRows.rows.count else { continue }
            guard isExportable(tableRows.rows[rowIndex].id, excludedRowIDs) else { continue }
            resolved.append(rowIndex)
        }
        return resolved
    }

    private static func isExportable(_ id: RowID, _ excludedRowIDs: Set<RowID>) -> Bool {
        !id.isInserted && !excludedRowIDs.contains(id)
    }
}

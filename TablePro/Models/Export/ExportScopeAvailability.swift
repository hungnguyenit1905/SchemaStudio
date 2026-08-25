//
//  ExportScopeAvailability.swift
//  TablePro
//

import Foundation

struct ExportScopeOption: Equatable, Identifiable {
    let scope: ExportRowScope
    let count: Int?
    let isEnabled: Bool

    var id: ExportRowScope { scope }
}

struct ExportScopeAvailability: Equatable {
    let options: [ExportScopeOption]
    let defaultScope: ExportRowScope
    let showsPicker: Bool
    let loadedRowCount: Int
    let hasMoreRows: Bool
    let canQueryAllRows: Bool

    static func resolve(_ selection: ExportRowSelection) -> ExportScopeAvailability {
        let loadedAllCount = selection.count(for: .allRows)
        let canQueryAllRows = selection.allRowsQuery != nil
        let allRowsCount: Int? = canQueryAllRows && selection.hasMoreRows
            ? selection.totalRowCountEstimate
            : loadedAllCount

        guard selection.dataGridOwnsSelection else {
            return ExportScopeAvailability(
                options: [ExportScopeOption(scope: .allRows, count: allRowsCount, isEnabled: true)],
                defaultScope: .allRows,
                showsPicker: false,
                loadedRowCount: loadedAllCount,
                hasMoreRows: selection.hasMoreRows,
                canQueryAllRows: canQueryAllRows
            )
        }

        var options = [ExportScopeOption(
            scope: .allRows,
            count: allRowsCount,
            isEnabled: canQueryAllRows || loadedAllCount > 0
        )]
        if selection.hasClientSideRefinement {
            let displayedCount = selection.count(for: .displayedRows)
            options.append(ExportScopeOption(
                scope: .displayedRows,
                count: displayedCount,
                isEnabled: displayedCount > 0
            ))
        }
        let selectedCount = selection.count(for: .selectedRows)
        options.append(ExportScopeOption(
            scope: .selectedRows,
            count: selectedCount,
            isEnabled: selectedCount > 0
        ))

        return ExportScopeAvailability(
            options: options,
            defaultScope: .allRows,
            showsPicker: true,
            loadedRowCount: loadedAllCount,
            hasMoreRows: selection.hasMoreRows,
            canQueryAllRows: canQueryAllRows
        )
    }

    func option(for scope: ExportRowScope) -> ExportScopeOption? {
        options.first { $0.scope == scope }
    }

    func count(for scope: ExportRowScope) -> Int? {
        option(for: scope)?.count
    }

    func isEnabled(_ scope: ExportRowScope) -> Bool {
        option(for: scope)?.isEnabled ?? false
    }

    func isPartialLoad(for scope: ExportRowScope) -> Bool {
        guard hasMoreRows else { return false }
        guard scope == .allRows else { return true }
        return !canQueryAllRows
    }

    func resolvedScope(preferring scope: ExportRowScope) -> ExportRowScope {
        guard let option = option(for: scope), option.isEnabled else { return defaultScope }
        return scope
    }

    func streamsFromServer(for scope: ExportRowScope) -> Bool {
        scope == .allRows && canQueryAllRows
    }
}

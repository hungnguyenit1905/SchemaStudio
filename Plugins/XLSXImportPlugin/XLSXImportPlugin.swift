//
//  XLSXImportPlugin.swift
//  XLSXImportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class XLSXImportPlugin: ImportFormatPlugin, SettablePlugin {
    static let pluginName = "XLSX Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from Excel .xlsx workbooks"
    static let formatId = "xlsx"
    static let formatDisplayName = "Excel"
    static let acceptedFileExtensions = ["xlsx"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true
    static let capabilities: [PluginCapability] = [.importFormat]

    typealias Settings = XLSXImportOptions
    static let settingsStorageId = "xlsx-import"

    var settings = XLSXImportOptions() {
        didSet { saveSettings() }
    }

    /// Never persisted and never trusted across files. See `XLSXSheetSelection`.
    var sheetSelection = XLSXSheetSelection()

    var fieldDetectionSignature: String {
        [settings.detectionSignature, sheetSelection.signature].joined(separator: "|")
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(XLSXImportOptionsView(plugin: self))
    }

    private static let batchSize = 500
    private static let detectionSampleRows = 20

    func selectSheet(_ name: String) {
        sheetSelection.select(name)
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let workbook = try openWorkbook(at: url)
        sheetSelection.adopt(url: url, sheetNames: workbook.sheets.map(\.name))

        guard let sheet = resolvedSheet(in: workbook) else { return [] }
        let rows = try sampleRows(of: sheet, in: workbook, limit: Self.detectionSampleRows)
        return XLSXRowMapper.detectFields(rows: rows, options: settings)
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()

        let workbook = try openWorkbook(at: url, progress: progress)
        let available = workbook.sheets.map(\.name)
        let resolvedName = sheetSelection.resolvedSheetName(in: available)
        let fellBack = sheetSelection.resolutionFellBack(to: resolvedName)
        guard let sheet = workbook.sheets.first(where: { $0.name == resolvedName }) ?? workbook.sheets.first else {
            throw PluginImportError.importFailed(XLSXWorkbookError.noSheets.localizedDescription)
        }

        let sheetData = try workbook.sheetData(for: sheet, onProgress: { try progress.checkCancellation() })
        var pending: [XLSXRow] = []
        var columnNames: [String] = []
        var isFirstRow = true

        try XLSXCellDecoder.decodeSheet(
            data: sheetData,
            workbook: workbook,
            partName: sheet.partPath,
            batchSize: Self.batchSize,
            onProgress: { try progress.checkCancellation() }
        ) { batch in
            var rows = batch
            if isFirstRow, let first = rows.first {
                isFirstRow = false
                let width = rows.reduce(0) { max($0, $1.cells.count) }
                columnNames = XLSXRowMapper.columnNames(
                    headerRow: self.settings.hasHeaderRow ? first : nil,
                    columnCount: width
                )
                if self.settings.hasHeaderRow {
                    rows = Array(rows.dropFirst())
                }
            }
            pending.append(contentsOf: rows)
        }

        guard !columnNames.isEmpty else {
            throw PluginImportError.importFailed(String(localized: "No columns found in the sheet."))
        }
        progress.setEstimatedTotal(pending.count)

        let lineOffset = settings.hasHeaderRow ? 2 : 1
        var cursor = 0
        let options = settings
        let outcome = try await RowImportRunner.run(
            configuration: RowImportRunner.Configuration(
                errorHandling: settings.errorHandling,
                wrapInTransaction: settings.wrapInTransaction,
                deleteExistingRows: settings.deleteExistingRows
            ),
            sink: sink,
            progress: progress
        ) {
            try progress.checkCancellation()
            guard cursor < pending.count else { return nil }
            let end = min(cursor + Self.batchSize, pending.count)
            var batch: [(line: Int, row: [String: PluginCellValue])] = []
            batch.reserveCapacity(end - cursor)
            for offset in cursor ..< end {
                let row = pending[offset]
                if XLSXRowMapper.isBlank(row) { continue }
                batch.append((offset + lineOffset, XLSXRowMapper.row(row, columnNames: columnNames, options: options)))
            }
            let blankRows = (end - cursor) - batch.count
            if blankRows > 0 {
                progress.incrementStatement(by: blankRows)
            }
            cursor = end
            return batch
        }

        var errors = outcome.errors
        if fellBack, let resolvedName {
            errors.append(PluginImportResult.ImportStatementError(
                statement: "",
                line: 0,
                errorMessage: String(
                    format: String(localized: "The selected sheet was not found, so '%@' was imported instead."),
                    resolvedName
                )
            ))
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: outcome.skipped,
            errors: errors
        )
    }

    // MARK: - Private

    private func openWorkbook(at url: URL, progress: PluginImportProgress? = nil) throws -> XLSXWorkbookReader {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PluginImportError.importFailed(error.localizedDescription)
        }
        do {
            let archive = try ZipArchiveReader(data: data)
            return try XLSXWorkbookReader(archive: archive, onProgress: { try progress?.checkCancellation() })
        } catch let error as PluginImportCancellationError {
            throw error
        } catch {
            throw PluginImportError.importFailed(error.localizedDescription)
        }
    }

    private func resolvedSheet(in workbook: XLSXWorkbookReader) -> XLSXSheetRef? {
        let resolved = sheetSelection.resolvedSheetName(in: workbook.sheets.map(\.name))
        return workbook.sheets.first { $0.name == resolved } ?? workbook.sheets.first
    }

    private func sampleRows(
        of sheet: XLSXSheetRef,
        in workbook: XLSXWorkbookReader,
        limit: Int
    ) throws -> [XLSXRow] {
        struct Enough: Error {}
        let sheetData = try workbook.sheetData(for: sheet)
        var rows = [XLSXRow]()
        do {
            try XLSXCellDecoder.decodeSheet(
                data: sheetData,
                workbook: workbook,
                partName: sheet.partPath,
                batchSize: limit
            ) { batch in
                rows.append(contentsOf: batch)
                if rows.count >= limit { throw Enough() }
            }
        } catch is Enough {
            return Array(rows.prefix(limit))
        } catch {
            throw PluginImportError.importFailed(error.localizedDescription)
        }
        return Array(rows.prefix(limit))
    }
}

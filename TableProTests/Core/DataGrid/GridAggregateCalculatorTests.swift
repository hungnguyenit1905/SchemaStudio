//
//  GridAggregateCalculatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("GridAggregateCalculator")
struct GridAggregateCalculatorTests {
    private func makeRows(_ values: [[PluginCellValue]]) -> [Row] {
        values.enumerated().map { index, cells in
            Row(id: .existing(index), values: ContiguousArray(cells))
        }
    }

    private func provider(_ rows: [Row]) -> (Int) -> Row? {
        { index in rows.indices.contains(index) ? rows[index] : nil }
    }

    private func selection(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        GridSelection(rectangles: [GridRect(rows: rows, columns: columns)], activeCell: nil, anchor: nil)
    }

    @Test("Integer range reports count, sum, average, minimum, and maximum")
    func integerRange() {
        let rows = makeRows([[.text("10")], [.text("20")], [.text("30")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 2, columns: 0 ... 0),
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 3)
        #expect(result.numericCount == 3)
        #expect(result.sum == Decimal(60))
        #expect(result.average == Decimal(20))
        #expect(result.minimum == Decimal(10))
        #expect(result.maximum == Decimal(30))
    }

    @Test("Decimal money column sums exactly with no floating point drift")
    func decimalSumIsExact() {
        let rows = makeRows([[.text("0.1")], [.text("0.2")], [.text("0.3")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 2, columns: 0 ... 0),
            columnTypes: [.decimal(rawType: "DECIMAL(18,2)")],
            rowProvider: provider(rows)
        )

        #expect(result.sum == Decimal(string: "0.6"))
        #expect(result.sum != Decimal(0.1 + 0.2 + 0.3))
    }

    @Test("NULL cells are excluded from the totals but counted separately")
    func nullsAreExcluded() {
        let rows = makeRows([[.text("5")], [.null], [.text("15")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 2, columns: 0 ... 0),
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 3)
        #expect(result.nullCount == 1)
        #expect(result.numericCount == 2)
        #expect(result.sum == Decimal(20))
        #expect(result.average == Decimal(10))
    }

    @Test("Text column reports count only, with absent totals rather than zero")
    func textColumnHasNoTotals() {
        let rows = makeRows([[.text("alpha")], [.text("beta")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 1, columns: 0 ... 0),
            columnTypes: [.text(rawType: "VARCHAR(32)")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 2)
        #expect(result.hasNumericValues == false)
        #expect(result.sum == nil)
        #expect(result.average == nil)
        #expect(result.minimum == nil)
        #expect(result.maximum == nil)
    }

    @Test("A range spanning a numeric and a text column aggregates only the numeric one")
    func mixedSelectionIgnoresTextColumn() {
        let rows = makeRows([
            [.text("10"), .text("99")],
            [.text("20"), .text("77")],
        ])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 1, columns: 0 ... 1),
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR(8)")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 4)
        #expect(result.numericCount == 2)
        #expect(result.sum == Decimal(30))
        #expect(result.maximum == Decimal(20))
    }

    @Test("Binary values count as non-numeric")
    func bytesAreNonNumeric() {
        let rows = makeRows([[.bytes(Data([0x01, 0x02]))], [.bytes(Data([0x03]))]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 1, columns: 0 ... 0),
            columnTypes: [.blob(rawType: "BLOB")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 2)
        #expect(result.hasNumericValues == false)
        #expect(result.sum == nil)
    }

    @Test("An empty selection produces no aggregates")
    func emptySelection() {
        let rows = makeRows([[.text("10")]])
        let result = GridAggregateCalculator.aggregates(
            for: .empty,
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result == .empty)
        #expect(result.isMultiCell == false)
    }

    @Test("A single cell selection is not reported as multi-cell")
    func singleCellSelection() {
        let rows = makeRows([[.text("10")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 0, columns: 0 ... 0),
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 1)
        #expect(result.isMultiCell == false)
    }

    @Test("Overlapping rectangles count each cell once")
    func overlappingRectanglesDoNotDoubleCount() {
        let rows = makeRows([[.text("1")], [.text("2")], [.text("3")]])
        let overlapping = GridSelection(
            rectangles: [
                GridRect(rows: 0 ... 1, columns: 0 ... 0),
                GridRect(rows: 1 ... 2, columns: 0 ... 0),
            ],
            activeCell: nil,
            anchor: nil
        )
        let result = GridAggregateCalculator.aggregates(
            for: overlapping,
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 3)
        #expect(result.sum == Decimal(6))
    }

    @Test("Values parse the same way under a comma decimal locale")
    func parsingIsLocaleIndependent() {
        let rows = makeRows([[.text("1.5")], [.text("2.5")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 1, columns: 0 ... 0),
            columnTypes: [.decimal(rawType: "DECIMAL(10,2)")],
            rowProvider: provider(rows)
        )

        #expect(result.sum == Decimal(4))
        #expect(result.average == Decimal(2))
    }

    @Test("A numeric column holding unparseable text contributes nothing")
    func unparseableNumericTextIsIgnored() {
        let rows = makeRows([[.text("12abc")], [.text("8")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 1, columns: 0 ... 0),
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 2)
        #expect(result.numericCount == 1)
        #expect(result.sum == Decimal(8))
    }

    @Test("Negative values are aggregated correctly")
    func negativeValues() {
        let rows = makeRows([[.text("-10")], [.text("4")], [.text("-2")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 2, columns: 0 ... 0),
            columnTypes: [.decimal(rawType: "NUMERIC")],
            rowProvider: provider(rows)
        )

        #expect(result.sum == Decimal(-8))
        #expect(result.minimum == Decimal(-10))
        #expect(result.maximum == Decimal(4))
    }

    @Test("A selection past the end of the data ignores the missing rows")
    func selectionBeyondData() {
        let rows = makeRows([[.text("10")]])
        let result = GridAggregateCalculator.aggregates(
            for: selection(rows: 0 ... 5, columns: 0 ... 0),
            columnTypes: [.integer(rawType: "INT")],
            rowProvider: provider(rows)
        )

        #expect(result.cellCount == 1)
        #expect(result.sum == Decimal(10))
    }
}

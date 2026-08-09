import Foundation
import TableProPluginKit

enum GridAggregateCalculator {
    static func aggregates(
        for selection: GridSelection,
        columnTypes: [ColumnType],
        rowProvider: (Int) -> Row?
    ) -> GridSelectionAggregates {
        guard !selection.isEmpty else { return .empty }

        var cellCount = 0
        var nullCount = 0
        var numericCount = 0
        var sum = Decimal.zero
        var minimum: Decimal?
        var maximum: Decimal?

        for displayRow in selection.affectedRows {
            guard let row = rowProvider(displayRow) else { continue }
            for column in selection.columns(in: displayRow) {
                guard row.values.indices.contains(column) else { continue }
                cellCount += 1

                let value = row.values[column]
                if value.isNull {
                    nullCount += 1
                    continue
                }

                guard isNumeric(columnTypeAt(column, in: columnTypes)),
                      let text = value.asText,
                      let parsed = parseDecimal(text) else { continue }

                numericCount += 1
                sum += parsed
                minimum = minimum.map { Swift.min($0, parsed) } ?? parsed
                maximum = maximum.map { Swift.max($0, parsed) } ?? parsed
            }
        }

        guard numericCount > 0 else {
            return GridSelectionAggregates(
                cellCount: cellCount,
                nullCount: nullCount,
                numericCount: 0,
                sum: nil,
                average: nil,
                minimum: nil,
                maximum: nil
            )
        }

        return GridSelectionAggregates(
            cellCount: cellCount,
            nullCount: nullCount,
            numericCount: numericCount,
            sum: sum,
            average: sum / Decimal(numericCount),
            minimum: minimum,
            maximum: maximum
        )
    }

    private static func columnTypeAt(_ column: Int, in columnTypes: [ColumnType]) -> ColumnType? {
        columnTypes.indices.contains(column) ? columnTypes[column] : nil
    }

    private static func isNumeric(_ columnType: ColumnType?) -> Bool {
        guard let columnType else { return false }
        switch columnType {
        case .integer, .decimal:
            return true
        default:
            return false
        }
    }

    private static func parseDecimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(isDecimalCharacter) else { return nil }
        return Decimal(string: trimmed, locale: nil)
    }

    private static func isDecimalCharacter(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == "-" || character == "+"
            || character == "e" || character == "E"
    }
}

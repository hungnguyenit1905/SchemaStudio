import Foundation

struct GridSelectionAggregates: Equatable {
    var cellCount: Int
    var nullCount: Int
    var numericCount: Int
    var sum: Decimal?
    var average: Decimal?
    var minimum: Decimal?
    var maximum: Decimal?

    static let empty = GridSelectionAggregates(
        cellCount: 0,
        nullCount: 0,
        numericCount: 0,
        sum: nil,
        average: nil,
        minimum: nil,
        maximum: nil
    )

    var hasNumericValues: Bool { numericCount > 0 }

    var isMultiCell: Bool { cellCount > 1 }
}

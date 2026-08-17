//
//  NullGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class NullGenerator: ValueGenerator {
    static let identifier = "Null"

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {}

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .null
    }

    func reset() {}
}

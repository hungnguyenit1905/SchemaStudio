//
//  DefaultGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class DefaultGenerator: ValueGenerator {
    static let identifier = "Default"
    static let excludesColumnFromInsert = true

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {}

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .null
    }

    func reset() {}
}

//
//  TablePlan.swift
//  TablePro
//

import Foundation

struct ColumnPlan: Sendable {
    let column: GenerationColumn
    let generator: String
    let params: Data
    let common: CommonParams
    let excludedFromInsert: Bool
    let dependencies: [String]

    var name: String { column.name }
}

struct TablePlan: Sendable {
    let reference: GenerationTableReference
    let rowCount: Int
    let emptyFirst: Bool

    /// In row-dependency order, so a column that reads another is generated
    /// after the one it reads.
    let columns: [ColumnPlan]

    /// Columns written on the first pass. A column the server fills is absent.
    let insertColumns: [String]

    /// Foreign keys that point at a row that does not exist yet. Written as
    /// `NULL` on the first pass, filled by an `UPDATE` afterwards.
    let deferredColumns: [String]

    /// A table whose every column is server-assigned has nothing to list, so
    /// the insert has to take the vendor's "all defaults" shape.
    var usesDefaultValues: Bool { insertColumns.isEmpty }

    var qualifiedName: String { reference.qualifiedName }
}

struct GenerationPlan: Sendable {
    let seed: UInt64
    let tables: [TablePlan]
    let requiresConstraintDisable: Bool

    var totalRowCount: Int {
        tables.reduce(0) { $0 + $1.rowCount }
    }
}

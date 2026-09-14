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

/// A column whose values the server would otherwise have supplied from a
/// sequence. Writing explicit keys into one leaves the sequence behind the data,
/// so it has to be reset after the table is written.
struct SequenceBackedColumn: Sendable, Hashable {
    let column: String
    let sequenceName: String?
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

    /// Multi-column unique constraints. Single-column ones are already carried by
    /// `GenerationColumn.requiresUniqueValues`.
    let uniqueConstraints: [GenerationUniqueConstraint]

    /// The columns a second pass can use to find a row again, and the sequence
    /// each one is backed by where the server has one.
    let primaryKeyColumns: [String]

    let sequenceBackedColumns: [SequenceBackedColumn]

    /// A table whose every column is server-assigned has nothing to list, so
    /// the insert has to take the vendor's "all defaults" shape.
    var usesDefaultValues: Bool { insertColumns.isEmpty }

    var qualifiedName: String { reference.qualifiedName }
}

struct GenerationPlan: Sendable {
    let seed: UInt64
    let tables: [TablePlan]
    let requiresConstraintDisable: Bool

    /// Which connection, database and schema the plan runs against. Carried so a
    /// checkpoint's job id can tell two databases with identical table shapes and
    /// the same seed apart; `nil` only for a plan built without one, such as a
    /// preview that never checkpoints.
    let scope: DatabaseScope?

    init(seed: UInt64, tables: [TablePlan], requiresConstraintDisable: Bool, scope: DatabaseScope? = nil) {
        self.seed = seed
        self.tables = tables
        self.requiresConstraintDisable = requiresConstraintDisable
        self.scope = scope
    }

    var totalRowCount: Int {
        tables.reduce(0) { $0 + $1.rowCount }
    }
}

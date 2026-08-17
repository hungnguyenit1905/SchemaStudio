//
//  CompositeUniqueTracker.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// `UNIQUE(a, b)` constrains the pair, not either column, so each column may
/// repeat as long as the tuple does not.
///
/// On a collision exactly one column is redrawn, and it is the one with the most
/// values to offer. Redrawing the low-cardinality member of the pair (a status
/// enum with three values) finds a free tuple only by luck and spins for the rest
/// of the run.
struct CompositeUniqueTracker {
    struct Constraint: Sendable {
        let name: String
        let columns: [String]

        /// The member to redraw on a collision, decided once from each column's
        /// domain rather than per row.
        let redrawColumn: String

        /// How the server compares each member. A pair is only distinct if the
        /// server thinks so: under `utf8mb4_general_ci`, `(VN, Alpha)` and
        /// `(VN, alpha)` are one row.
        let matching: [String: UniqueMatching]

        init(
            name: String,
            columns: [String],
            redrawColumn: String,
            matching: [String: UniqueMatching] = [:]
        ) {
            self.name = name
            self.columns = columns
            self.redrawColumn = redrawColumn
            self.matching = matching
        }
    }

    private let constraints: [Constraint]
    private var seen: [String: Set<UInt64>]

    init(constraints: [Constraint], expectedCount: Int = 0) {
        self.constraints = constraints
        seen = Dictionary(
            uniqueKeysWithValues: constraints.map { ($0.name, Set<UInt64>(minimumCapacity: max(0, expectedCount))) }
        )
    }

    var isEmpty: Bool { constraints.isEmpty }

    /// The first constraint the row collides on, with the column to redraw, or
    /// `nil` when every tuple in the row is new. A row is only recorded once no
    /// constraint objects to it, so a rejected row leaves no trace behind.
    func collision(in values: [String: PluginCellValue]) -> Constraint? {
        for constraint in constraints where !Self.carriesNull(constraint, values: values) {
            let hash = Self.hash(constraint, values: values)
            guard seen[constraint.name]?.contains(hash) == true else { continue }
            return constraint
        }
        return nil
    }

    mutating func record(_ values: [String: PluginCellValue]) {
        for constraint in constraints where !Self.carriesNull(constraint, values: values) {
            seen[constraint.name, default: []].insert(Self.hash(constraint, values: values))
        }
    }

    /// A tuple with a null in it is never rejected by the server: `NULL` does not
    /// equal `NULL` in a unique constraint, in any of the vendors here. Tracking
    /// those tuples would redraw rows the server was always going to accept, and
    /// on a nullable member it would burn the retry budget for nothing.
    private static func carriesNull(_ constraint: Constraint, values: [String: PluginCellValue]) -> Bool {
        constraint.columns.contains { column in
            guard case .null = values[column] ?? .null else { return false }
            return true
        }
    }

    mutating func reset() {
        for name in seen.keys {
            seen[name]?.removeAll(keepingCapacity: true)
        }
    }

    /// A constraint with nothing redrawable in it is dropped rather than tracked:
    /// its columns all come from a parent's own rows, so a repeated tuple is the
    /// reference pool's business and no redraw here could settle it.
    static func constraints(
        for plan: TablePlan,
        redrawable: (String) -> Bool,
        cardinality: (String) -> Int?
    ) -> [Constraint] {
        let generated = Set(plan.columns.map(\.name))
        let matching = Dictionary(
            uniqueKeysWithValues: plan.columns.map { ($0.name, UniqueMatching.resolve(for: $0.column)) }
        )
        return plan.uniqueConstraints
            .filter { $0.columns.count > 1 && $0.columns.allSatisfy(generated.contains) }
            .compactMap { constraint in
                let candidates = constraint.columns.filter(redrawable)
                guard let redraw = widestColumn(in: candidates, cardinality: cardinality) else { return nil }
                return Constraint(
                    name: constraint.name,
                    columns: constraint.columns,
                    redrawColumn: redraw,
                    matching: matching.filter { constraint.columns.contains($0.key) }
                )
            }
    }

    /// An unknown domain counts as the widest: a lorem or random string has more
    /// to offer than any enumerated column.
    private static func widestColumn(in columns: [String], cardinality: (String) -> Int?) -> String? {
        var best: String?
        var bestCount = -1
        for column in columns {
            let count = cardinality(column) ?? Int.max
            guard count > bestCount else { continue }
            best = column
            bestCount = count
        }
        return best
    }

    private static func hash(_ constraint: Constraint, values: [String: PluginCellValue]) -> UInt64 {
        FNV1aHasher.hash { hasher in
            hasher.combine(UInt64(constraint.columns.count))
            for column in constraint.columns {
                let value = values[column] ?? .null
                guard constraint.matching[column] == .caseInsensitive, case .text(let text) = value else {
                    hasher.combine(value.stableHash)
                    continue
                }
                hasher.combine(PluginCellValue.text(text.lowercased()).stableHash)
            }
        }
    }
}

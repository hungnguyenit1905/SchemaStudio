//
//  ColumnDependencySorter.swift
//  TablePro
//

import Foundation

/// Orders the columns inside a single row. `Copy` reads another column, so the
/// column it names has to be generated first. A loop here is a configuration
/// mistake, not a schema shape, and is reported as one.
enum ColumnDependencySorter {
    static func sort(
        columns: [String],
        dependencies: [String: [String]],
        table: String
    ) throws -> [String] {
        let present = Set(columns)
        var inDegree = Dictionary(uniqueKeysWithValues: columns.map { ($0, 0) })
        var dependents: [String: [String]] = [:]

        for column in columns {
            for dependency in dependencies[column] ?? [] where present.contains(dependency) {
                dependents[dependency, default: []].append(column)
                inDegree[column, default: 0] += 1
            }
        }

        var ready = columns.filter { inDegree[$0] == 0 }
        var ordered: [String] = []
        ordered.reserveCapacity(columns.count)

        while !ready.isEmpty {
            let column = ready.removeFirst()
            ordered.append(column)
            for dependent in dependents[column] ?? [] {
                inDegree[dependent, default: 0] -= 1
                if inDegree[dependent] == 0 { ready.append(dependent) }
            }
        }

        guard ordered.count == columns.count else {
            let settled = Set(ordered)
            throw GenerationError.columnDependencyCycle(
                table: table,
                columns: columns.filter { !settled.contains($0) }.sorted()
            )
        }
        return ordered
    }
}

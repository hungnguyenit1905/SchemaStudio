//
//  DependencyResolver.swift
//  TablePro
//

import Foundation

struct TableDependencyOrder: Sendable, Equatable {
    let ordered: [GenerationTableReference]

    /// Columns that cannot be filled on the first pass because the row they
    /// point at does not exist yet. They are written as `NULL`, then an `UPDATE`
    /// fills them once every table has rows.
    let deferredColumns: [GenerationTableReference: [String]]

    /// True when the only way to order the run was to let the server stop
    /// checking foreign keys for its duration.
    let requiresConstraintDisable: Bool
}

/// Kahn's algorithm over foreign-key edges, parent before child.
struct DependencyResolver {
    private let canDisableConstraints: Bool

    init(canDisableConstraints: Bool = false) {
        self.canDisableConstraints = canDisableConstraints
    }

    func resolve(_ tables: [GenerationTable]) throws -> TableDependencyOrder {
        let nodes = tables.map(Self.reference)
        let present = Set(nodes)
        var deferred: [GenerationTableReference: [String]] = [:]
        var edges = Self.edges(in: tables, present: present, deferred: &deferred)

        if let order = Self.kahn(nodes: nodes, edges: edges) {
            return TableDependencyOrder(
                ordered: order,
                deferredColumns: deferred,
                requiresConstraintDisable: false
            )
        }

        breakCyclesAtNullableKeys(tables: tables, present: present, edges: &edges, deferred: &deferred)
        if let order = Self.kahn(nodes: nodes, edges: edges) {
            return TableDependencyOrder(
                ordered: order,
                deferredColumns: deferred,
                requiresConstraintDisable: false
            )
        }

        guard canDisableConstraints else {
            throw GenerationError.tableDependencyCycle(
                tables: Self.remainingCycle(nodes: nodes, edges: edges).map(\.qualifiedName).sorted()
            )
        }
        return TableDependencyOrder(
            ordered: nodes,
            deferredColumns: deferred,
            requiresConstraintDisable: true
        )
    }

    static func reference(_ table: GenerationTable) -> GenerationTableReference {
        GenerationTableReference(schema: table.schema, table: table.name)
    }

    /// A self-reference is not a cycle: the column is filled on a second pass
    /// against rows this same table already has.
    private static func edges(
        in tables: [GenerationTable],
        present: Set<GenerationTableReference>,
        deferred: inout [GenerationTableReference: [String]]
    ) -> [GenerationTableReference: Set<GenerationTableReference>] {
        var edges: [GenerationTableReference: Set<GenerationTableReference>] = [:]
        for table in tables {
            let child = reference(table)
            for key in table.foreignKeys {
                let parent = GenerationTableReference(
                    schema: key.referencedSchema ?? table.schema,
                    table: key.referencedTable
                )
                guard present.contains(parent) else { continue }
                guard parent != child else {
                    deferred[child, default: []].append(contentsOf: key.localColumns)
                    continue
                }
                edges[parent, default: []].insert(child)
            }
        }
        return edges
    }

    private func breakCyclesAtNullableKeys(
        tables: [GenerationTable],
        present: Set<GenerationTableReference>,
        edges: inout [GenerationTableReference: Set<GenerationTableReference>],
        deferred: inout [GenerationTableReference: [String]]
    ) {
        let nodes = tables.map(Self.reference)
        for table in tables {
            let child = Self.reference(table)
            for key in table.foreignKeys {
                let parent = GenerationTableReference(
                    schema: key.referencedSchema ?? table.schema,
                    table: key.referencedTable
                )
                guard parent != child, present.contains(parent) else { continue }
                let nullable = key.localColumns.allSatisfy { table.column(named: $0)?.isNullable ?? false }
                guard nullable else { continue }
                guard Self.kahn(nodes: nodes, edges: edges) == nil else { return }
                edges[parent]?.remove(child)
                deferred[child, default: []].append(contentsOf: key.localColumns)
            }
        }
    }

    private static func kahn(
        nodes: [GenerationTableReference],
        edges: [GenerationTableReference: Set<GenerationTableReference>]
    ) -> [GenerationTableReference]? {
        var inDegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        for children in edges.values {
            for child in children { inDegree[child, default: 0] += 1 }
        }

        var ready = nodes.filter { inDegree[$0] == 0 }
        var ordered: [GenerationTableReference] = []
        ordered.reserveCapacity(nodes.count)

        while !ready.isEmpty {
            let node = ready.removeFirst()
            ordered.append(node)
            for child in edges[node] ?? [] {
                inDegree[child, default: 0] -= 1
                if inDegree[child] == 0 { ready.append(child) }
            }
        }
        return ordered.count == nodes.count ? ordered : nil
    }

    private static func remainingCycle(
        nodes: [GenerationTableReference],
        edges: [GenerationTableReference: Set<GenerationTableReference>]
    ) -> [GenerationTableReference] {
        var inDegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        for children in edges.values {
            for child in children { inDegree[child, default: 0] += 1 }
        }
        var ready = nodes.filter { inDegree[$0] == 0 }
        var settled: Set<GenerationTableReference> = []
        while !ready.isEmpty {
            let node = ready.removeFirst()
            settled.insert(node)
            for child in edges[node] ?? [] {
                inDegree[child, default: 0] -= 1
                if inDegree[child] == 0 { ready.append(child) }
            }
        }
        return nodes.filter { !settled.contains($0) }
    }
}

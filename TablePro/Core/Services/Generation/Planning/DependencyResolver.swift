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
        try Self.validateSelfReferences(tables)
        let nodes = Self.distinctReferences(tables.map(Self.reference))
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
                let parent = parentReference(of: key, in: table)
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

    /// A self-referencing key is filled on a second pass, so the first pass
    /// writes NULL into it. A NOT NULL column rejects that, and the run would
    /// otherwise pass pre-flight and fail on its first batch.
    private static func validateSelfReferences(_ tables: [GenerationTable]) throws {
        for table in tables {
            let child = reference(table)
            for key in table.foreignKeys where parentReference(of: key, in: table) == child {
                for column in key.localColumns where table.column(named: column)?.isNullable == false {
                    throw GenerationError.nullGeneratorOnRequiredColumn(
                        table: child.qualifiedName,
                        column: column
                    )
                }
            }
        }
    }

    /// One edge entry carries every foreign key between the same pair, so a
    /// pair is only safe to break when all of them are nullable. Breaking on
    /// the first nullable key alone would order a NOT NULL sibling key ahead of
    /// its parent.
    private static func parentReference(
        of key: GenerationForeignKey,
        in table: GenerationTable
    ) -> GenerationTableReference {
        GenerationTableReference(
            schema: key.referencedSchema ?? table.schema,
            table: key.referencedTable
        )
    }

    /// Declaration order, deduplicated. The resolved plan order is hashed into
    /// the checkpoint job id, so nothing here may depend on set iteration.
    private static func distinctParents(of table: GenerationTable) -> [GenerationTableReference] {
        var seen: Set<GenerationTableReference> = []
        return table.foreignKeys.compactMap { key in
            let parent = parentReference(of: key, in: table)
            return seen.insert(parent).inserted ? parent : nil
        }
    }

    /// A profile that names the same table twice reaches here before the
    /// validator can refuse it in every path except an imported profile, so the
    /// resolver has to survive the duplicate rather than trust callers to have
    /// already removed it. `Dictionary(uniqueKeysWithValues:)` traps on a repeat
    /// key, and letting the duplicate through would double-count the table in
    /// `ordered` instead.
    private static func distinctReferences(
        _ references: [GenerationTableReference]
    ) -> [GenerationTableReference] {
        var seen: Set<GenerationTableReference> = []
        return references.filter { seen.insert($0).inserted }
    }

    private func breakCyclesAtNullableKeys(
        tables: [GenerationTable],
        present: Set<GenerationTableReference>,
        edges: inout [GenerationTableReference: Set<GenerationTableReference>],
        deferred: inout [GenerationTableReference: [String]]
    ) {
        let nodes = Self.distinctReferences(tables.map(Self.reference))
        for table in tables {
            let child = Self.reference(table)
            for parent in Self.distinctParents(of: table) {
                guard parent != child, present.contains(parent) else { continue }
                let keysToParent = table.foreignKeys.filter { Self.parentReference(of: $0, in: table) == parent }
                let columns = keysToParent.flatMap(\.localColumns)
                let nullable = columns.allSatisfy { table.column(named: $0)?.isNullable ?? false }
                guard nullable else { continue }
                guard Self.kahn(nodes: nodes, edges: edges) == nil else { return }
                edges[parent]?.remove(child)
                deferred[child, default: []].append(contentsOf: columns)
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
            for child in (edges[node] ?? []).sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
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

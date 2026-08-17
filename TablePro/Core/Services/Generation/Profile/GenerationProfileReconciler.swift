//
//  GenerationProfileReconciler.swift
//  TablePro
//

import Foundation

enum GenerationProfileChange: Sendable, Hashable {
    case tableDropped(table: String)
    case columnDropped(table: String, column: String)
    case columnAdded(table: String, column: String, generator: String)
    case generatorDowngraded(table: String, column: String, from: String, to: String, reason: String)

    var message: String {
        switch self {
        case .tableDropped(let table):
            return String(
                format: String(localized: "%@ is no longer in the database and was removed from the profile."),
                table
            )
        case .columnDropped(let table, let column):
            return String(format: String(localized: "%@.%@ is no longer in the table."), table, column)
        case .columnAdded(let table, let column, let generator):
            return String(
                format: String(localized: "%@.%@ is new and was matched to the %@ generator."),
                table,
                column,
                generator
            )
        case .generatorDowngraded(let table, let column, let from, let to, let reason):
            return String(
                format: String(localized: "%@.%@ no longer works with %@ (%@), so it now uses %@."),
                table,
                column,
                from,
                reason,
                to
            )
        }
    }
}

struct GenerationProfileReconciliation: Sendable {
    var profile: GenerationProfile
    var changes: [GenerationProfileChange]
    var addedColumns: Set<String>

    var hasChanges: Bool { !changes.isEmpty }
}

/// Brings a saved profile back into agreement with the schema as it is now. The
/// schema is re-read at the start of every run; the profile's remembered shape
/// is never trusted.
struct GenerationProfileReconciler {
    private let registry: GeneratorRegistry

    init(registry: GeneratorRegistry = .standard) {
        self.registry = registry
    }

    func reconcile(_ profile: GenerationProfile, against schema: [GenerationTable]) -> GenerationProfileReconciliation {
        var changes: [GenerationProfileChange] = []
        var addedColumns: Set<String> = []
        var tables: [GenerationTableProfile] = []

        for tableProfile in profile.tables {
            guard let live = schema.first(where: {
                $0.name == tableProfile.table && $0.schema == tableProfile.schema
            }) else {
                changes.append(.tableDropped(table: tableProfile.reference.qualifiedName))
                continue
            }
            var reconciled = tableProfile
            reconciled.columns = reconcileColumns(
                tableProfile: tableProfile,
                live: live,
                changes: &changes,
                addedColumns: &addedColumns
            )
            tables.append(reconciled)
        }

        var updated = profile
        updated.version = GenerationProfile.currentVersion
        updated.tables = tables
        return GenerationProfileReconciliation(profile: updated, changes: changes, addedColumns: addedColumns)
    }

    private func reconcileColumns(
        tableProfile: GenerationTableProfile,
        live: GenerationTable,
        changes: inout [GenerationProfileChange],
        addedColumns: inout Set<String>
    ) -> [GenerationColumnProfile] {
        let tableName = tableProfile.reference.qualifiedName
        var reconciled: [GenerationColumnProfile] = []

        for columnProfile in tableProfile.columns {
            guard let liveColumn = live.column(named: columnProfile.column) else {
                changes.append(.columnDropped(table: tableName, column: columnProfile.column))
                continue
            }
            reconciled.append(
                revalidate(columnProfile, against: liveColumn, table: tableName, changes: &changes)
            )
        }

        let known = Set(tableProfile.columns.map(\.column))
        for liveColumn in live.columns where !known.contains(liveColumn.name) {
            let resolution = TypeFallbackGeneratorResolver.resolve(liveColumn)
            reconciled.append(
                GenerationColumnProfile(
                    column: liveColumn.name,
                    generator: resolution.identifier,
                    params: resolution.params
                )
            )
            addedColumns.insert("\(tableName).\(liveColumn.name)")
            changes.append(
                .columnAdded(table: tableName, column: liveColumn.name, generator: resolution.identifier)
            )
        }
        return reconciled
    }

    /// A retyped column is caught by building its generator against the new
    /// column. A generator that cannot be built is downgraded to the type
    /// fallback, and that downgrade is always reported: silently swapping a
    /// carefully configured generator is the failure mode here.
    private func revalidate(
        _ columnProfile: GenerationColumnProfile,
        against column: GenerationColumn,
        table: String,
        changes: inout [GenerationProfileChange]
    ) -> GenerationColumnProfile {
        let reason: String
        if !registry.contains(columnProfile.generator) {
            reason = String(localized: "the generator is not installed")
        } else {
            do {
                _ = try registry.make(
                    identifier: columnProfile.generator,
                    params: columnProfile.paramData,
                    column: column,
                    seed: 0
                )
                return columnProfile
            } catch let error as GenerationError {
                reason = error.errorDescription ?? String(localized: "the column changed")
            } catch {
                reason = String(localized: "the column changed")
            }
        }

        let resolution = TypeFallbackGeneratorResolver.resolve(column)
        changes.append(
            .generatorDowngraded(
                table: table,
                column: columnProfile.column,
                from: columnProfile.generator,
                to: resolution.identifier,
                reason: reason
            )
        )
        var downgraded = columnProfile
        downgraded.generator = resolution.identifier
        downgraded.params = resolution.params
        return downgraded
    }
}

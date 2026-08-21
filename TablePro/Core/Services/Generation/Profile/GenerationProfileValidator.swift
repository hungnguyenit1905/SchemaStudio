//
//  GenerationProfileValidator.swift
//  TablePro
//

import Foundation

/// Everything a run can be refused for, checked before a single row is written.
/// A run that will fail has to fail here, not ten minutes into writing.
struct GenerationProfileValidator {
    /// How many rows a table already holds. `nil` means the count is unknown,
    /// which is treated as "not empty" so an unknown never blocks a run.
    typealias RowCountLookup = @Sendable (GenerationTableReference) -> Int?

    private let registry: GeneratorRegistry
    private let existingRowCount: RowCountLookup

    init(
        registry: GeneratorRegistry = .standard,
        existingRowCount: @escaping RowCountLookup = { _ in nil }
    ) {
        self.registry = registry
        self.existingRowCount = existingRowCount
    }

    func validate(
        profile: GenerationProfile,
        schema: [GenerationTable]
    ) -> [GenerationError] {
        var errors: [GenerationError] = []
        let generatedTables = Set(profile.tables.map(\.reference))

        for tableProfile in profile.tables {
            guard let live = schema.first(where: {
                $0.name == tableProfile.table && $0.schema == tableProfile.schema
            }) else { continue }

            for columnProfile in tableProfile.columns {
                errors.append(
                    contentsOf: validate(
                        columnProfile,
                        in: tableProfile,
                        live: live,
                        generatedTables: generatedTables
                    )
                )
            }
        }
        return errors
    }

    private func validate(
        _ columnProfile: GenerationColumnProfile,
        in tableProfile: GenerationTableProfile,
        live: GenerationTable,
        generatedTables: Set<GenerationTableReference>
    ) -> [GenerationError] {
        let tableName = tableProfile.reference.qualifiedName
        guard let column = live.column(named: columnProfile.column) else {
            return [.unknownColumn(table: tableName, column: columnProfile.column)]
        }
        guard !column.isServerAssigned else { return [] }

        var errors: [GenerationError] = []

        if !column.isNullable {
            if columnProfile.generator == NullGenerator.identifier {
                errors.append(.nullGeneratorOnRequiredColumn(table: tableName, column: column.name))
            }
            if columnProfile.common.nullPercent > 0 {
                errors.append(
                    .nullPercentOnRequiredColumn(
                        table: tableName,
                        column: column.name,
                        percent: columnProfile.common.nullPercent
                    )
                )
            }
        }

        errors.append(
            contentsOf: validateForeignKey(
                column: column,
                tableName: tableName,
                tableSchema: tableProfile.schema,
                generatedTables: generatedTables
            )
        )

        do {
            let generator = try registry.make(
                identifier: columnProfile.generator,
                params: columnProfile.paramData,
                column: column,
                seed: 0
            )
            errors.append(
                contentsOf: validateCardinality(
                    generator: generator,
                    columnProfile: columnProfile,
                    column: column,
                    tableName: tableName,
                    rowCount: tableProfile.rowCount
                )
            )
        } catch let error as GenerationError {
            errors.append(error)
        } catch {
            errors.append(
                .invalidParameters(
                    generator: columnProfile.generator,
                    reason: error.localizedDescription
                )
            )
        }
        return errors
    }

    /// The domain is checked only where it is computable. A lorem or random
    /// string generator has no closed form, so those fall through to the runtime
    /// `uniqueExhausted` error instead of being guessed at here.
    private func validateCardinality(
        generator: any ValueGenerator,
        columnProfile: GenerationColumnProfile,
        column: GenerationColumn,
        tableName: String,
        rowCount: Int
    ) -> [GenerationError] {
        let mustBeDistinct = columnProfile.common.unique || column.requiresUniqueValues
        guard mustBeDistinct, rowCount > 0, let distinctValues = generator.distinctValueCount else { return [] }
        guard distinctValues < rowCount else { return [] }
        return [
            .uniqueDomainTooSmall(
                table: tableName,
                column: column.name,
                distinctValues: distinctValues,
                rowCount: rowCount
            )
        ]
    }

    private func validateForeignKey(
        column: GenerationColumn,
        tableName: String,
        tableSchema: String?,
        generatedTables: Set<GenerationTableReference>
    ) -> [GenerationError] {
        guard !column.isNullable, let foreignKey = column.foreignKey else { return [] }
        let parent = GenerationTableReference(
            schema: foreignKey.referencedSchema ?? tableSchema,
            table: foreignKey.referencedTable
        )
        guard !generatedTables.contains(parent) else { return [] }
        guard let rows = existingRowCount(parent), rows == 0 else { return [] }
        return [
            .emptyParentTable(
                table: tableName,
                column: column.name,
                parentTable: parent.qualifiedName
            )
        ]
    }
}

//
//  GenerationTemplateApplier.swift
//  TablePro
//

import Foundation

/// What a template managed to place, and what it did not. Everything the
/// template could not bind is reported: a template that half-applies without
/// saying so is worse than one that refuses.
struct GenerationTemplateApplication: Sendable {
    var profile: GenerationProfile
    var matchedTables: [String]
    var unmatchedTables: [String]
    var unmatchedColumns: [String]
    var warnings: [ValidationWarning]

    var isComplete: Bool { unmatchedTables.isEmpty && unmatchedColumns.isEmpty }
}

/// Matches a template's shape onto a real schema. A table matches by name, a
/// column by name **and** by whether its generator can actually be built against
/// the live column: a template that names `price` cannot fill a `price` that is
/// now a date, so that column falls back to the auto-mapper and is reported.
///
/// A template that matches no table at all is refused rather than applied,
/// because the result would be an empty profile the user would have to debug.
struct GenerationTemplateApplier {
    private let registry: GeneratorRegistry

    init(registry: GeneratorRegistry = .standard) {
        self.registry = registry
    }

    func apply(
        _ template: GenerationTemplate,
        to schema: [GenerationTable],
        seed: UInt64,
        name: String? = nil,
        scope: GenerationProfileScope? = nil
    ) throws -> GenerationTemplateApplication {
        var matchedTables: [String] = []
        var unmatchedTables: [String] = []
        var unmatchedColumns: [String] = []
        var warnings: [ValidationWarning] = []
        var tableProfiles: [GenerationTableProfile] = []

        for templateTable in template.tables {
            guard let live = schema.first(where: {
                $0.name.compare(templateTable.table, options: .caseInsensitive) == .orderedSame
            }) else {
                unmatchedTables.append(templateTable.table)
                continue
            }
            matchedTables.append(live.name)
            tableProfiles.append(
                tableProfile(
                    for: live,
                    templateTable: templateTable,
                    unmatchedColumns: &unmatchedColumns,
                    warnings: &warnings
                )
            )
        }

        guard !matchedTables.isEmpty else {
            throw GenerationError.templateDidNotMatch(template: template.name)
        }

        return GenerationTemplateApplication(
            profile: GenerationProfile(
                name: name ?? template.name,
                seed: seed,
                tables: tableProfiles,
                scope: scope
            ),
            matchedTables: matchedTables,
            unmatchedTables: unmatchedTables,
            unmatchedColumns: unmatchedColumns,
            warnings: warnings
        )
    }

    /// Every live column gets a generator, whether the template named it or not.
    /// A profile that covers only the template's columns would fail validation on
    /// the first required column the template never heard of.
    private func tableProfile(
        for live: GenerationTable,
        templateTable: GenerationTemplateTable,
        unmatchedColumns: inout [String],
        warnings: inout [ValidationWarning]
    ) -> GenerationTableProfile {
        var columns: [GenerationColumnProfile] = []

        for liveColumn in live.columns {
            let templateColumn = templateTable.columns.first {
                $0.column.compare(liveColumn.name, options: .caseInsensitive) == .orderedSame
            }
            if let templateColumn, canBuild(templateColumn, against: liveColumn) {
                columns.append(
                    GenerationColumnProfile(
                        column: liveColumn.name,
                        generator: templateColumn.generator,
                        params: templateColumn.params,
                        common: templateColumn.common
                    )
                )
                continue
            }
            if templateColumn != nil {
                unmatchedColumns.append("\(live.name).\(liveColumn.name)")
            }
            let resolution = AutoMapper.resolve(liveColumn, table: live.name)
            warnings.append(contentsOf: resolution.warnings)
            columns.append(
                GenerationColumnProfile(
                    column: liveColumn.name,
                    generator: resolution.identifier,
                    params: resolution.params,
                    common: resolution.common
                )
            )
        }

        let placed = Set(columns.map { $0.column.lowercased() })
        for templateColumn in templateTable.columns where !placed.contains(templateColumn.column.lowercased()) {
            unmatchedColumns.append("\(live.name).\(templateColumn.column)")
        }

        return GenerationTableProfile(
            schema: live.schema,
            table: live.name,
            rowCount: templateTable.rowCount,
            columns: columns
        )
    }

    private func canBuild(_ templateColumn: GenerationTemplateColumn, against column: GenerationColumn) -> Bool {
        guard registry.contains(templateColumn.generator) else { return false }
        do {
            _ = try registry.make(
                identifier: templateColumn.generator,
                params: templateColumn.paramData,
                column: column,
                seed: 0
            )
            return true
        } catch {
            return false
        }
    }
}

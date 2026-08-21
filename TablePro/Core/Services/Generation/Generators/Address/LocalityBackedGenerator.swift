//
//  LocalityBackedGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Reads one field off the locality record the engine bound for this row. Every
/// address column in a table shares that record, so a row never pairs a ward with
/// the wrong province.
///
/// An unbound instance falls back to a source of its own seeded from the column,
/// which keeps it usable on its own and keeps its output seed-dependent. Only a
/// bound instance is consistent with its sibling columns, and binding is the
/// engine's job.
final class LocalityBackedGenerator<Field: LocalityField>: ValueGenerator, LocalityConsuming {
    static var identifier: String { Field.identifier }

    static var paramSchema: ParamSchema {
        ParamSchema(fields: [
            ParamField(
                key: "locale",
                label: "Locale",
                type: .choice(GenerationLocale.paramChoices),
                defaultValue: .string(GenerationLocale.fallback.rawValue)
            )
        ])
    }

    private struct Params: Codable {
        var locale: String?
    }

    let localityLocale: GenerationLocale

    private let base: TransferBaseType
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let fallback: LocalityRowSource
    private var bound: LocalityRowSource?

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        localityLocale = GenerationLocale.resolve(decoded.locale)
        fallback = LocalityRowSource(locale: localityLocale, seed: seed)
        guard !fallback.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the locality list for \(localityLocale.rawValue) is missing from the app"
            )
        }
        base = column.type.base
        maxLength = column.maxLength
        truncator = .forVendor(nil)
    }

    /// The number of distinct *values this field produces*, not the number of
    /// records. Most fields collapse the record set hard: every US locality has
    /// one country code, and a `TimeZone` column over 67 cities holds six values.
    /// Reporting the record count would overstate the domain, which is the
    /// direction that lets an unfillable unique column past pre-flight.
    var distinctValueCount: Int? {
        let source = bound ?? fallback
        return Set(source.records.map(produce(from:))).count
    }

    func bind(localities: LocalityRowSource) {
        bound = localities
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let source = bound ?? fallback
        guard let record = source.record(forRow: row.rowIndex) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the locality list for \(localityLocale.rawValue) is empty"
            )
        }
        return produce(from: record)
    }

    private func produce(from record: LocalityRecord) -> PluginCellValue {
        let value = Field.value(from: record, locale: localityLocale, base: base)
        guard case let .text(text) = value else { return value }
        return .text(truncator.truncate(text, to: maxLength))
    }

    func reset() {}
}

//
//  SlugGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The URL-safe form of another column in the same row, so `Đèn bàn LED` becomes
/// `den-ban-led` next to the title it came from rather than next to some
/// unrelated words.
final class SlugGenerator: ValueGenerator {
    static let identifier = "Slug"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "sourceColumn", label: "Slug of", type: .text, defaultValue: .string("")),
        ParamField(
            key: "separator",
            label: "Separator",
            type: .choice([
                ParamChoice(value: "-", label: String(localized: "Hyphen")),
                ParamChoice(value: "_", label: String(localized: "Underscore"))
            ]),
            defaultValue: .string("-")
        ),
        ParamField(
            key: "maxWords",
            label: "Most words",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(8)
        )
    ])

    private struct Params: Codable {
        var sourceColumn: String?
        var separator: String?
        var maxWords: Int?
    }

    private let columnName: String
    private let sourceColumn: String
    private let separator: String
    private let maxWords: Int
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?

    var rowDependencies: [String] { [sourceColumn] }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.sourceColumn ?? ""
        guard !requested.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "no source column was named"
            )
        }
        guard requested != column.name else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "a column cannot be the slug of itself"
            )
        }
        columnName = column.name
        sourceColumn = requested
        separator = decoded.separator == "_" ? "_" : "-"
        maxWords = max(1, decoded.maxWords ?? 8)
        maxLength = column.maxLength
        truncator = .forVendor(nil)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let source = row[sourceColumn] else {
            throw GenerationError.dependencyMissing(column: columnName, dependsOn: sourceColumn)
        }
        let words = AsciiSlug.words(source.textFallback).prefix(maxWords)
        return .text(truncator.truncate(words.joined(separator: separator), to: maxLength))
    }

    func reset() {}
}

//
//  ExpressionGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A template over the other columns of the same row, so an email address can be
/// built from the name that sits next to it rather than from unrelated words.
/// `{{first_name}}.{{last_name}}@example.com` is the shape it exists for.
final class ExpressionGenerator: ValueGenerator {
    static let identifier = "Expression"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "template",
            label: "Template",
            type: .text,
            defaultValue: .string(""),
            help: String(localized: "Write {{column_name}} to insert another column's value from the same row.")
        ),
        ParamField(
            key: "slugify",
            label: "Fold inserted values to ASCII",
            type: .toggle,
            defaultValue: .bool(false),
            help: String(localized: "Turns Nguyễn Hương into nguyen.huong, for handles and addresses.")
        ),
        ParamField(
            key: "slugSeparator",
            label: "Separator",
            type: .text,
            defaultValue: .string("."),
            visibleWhen: ParamVisibility(key: "slugify", equalsAnyOf: [.bool(true)])
        )
    ])

    private struct Params: Codable {
        var template: String?
        var slugify: Bool?
        var slugSeparator: String?
    }

    private enum Segment {
        case literal(String)
        case column(String)
    }

    private let columnName: String
    private let segments: [Segment]
    private let placeholders: [String]
    private let slugify: Bool
    private let slugSeparator: String
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?

    var rowDependencies: [String] { placeholders }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let template = decoded.template ?? ""
        guard !template.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the template is empty")
        }
        let parsed = Self.parse(template)
        let named = parsed.compactMap { segment -> String? in
            guard case let .column(name) = segment else { return nil }
            return name
        }
        guard !named.contains(column.name) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "a column cannot read itself"
            )
        }
        columnName = column.name
        segments = parsed
        var uniqueNames: [String] = []
        for name in named where !uniqueNames.contains(name) {
            uniqueNames.append(name)
        }
        placeholders = uniqueNames
        slugify = decoded.slugify ?? false
        slugSeparator = decoded.slugSeparator ?? "."
        maxLength = column.maxLength
        truncator = .forVendor(nil)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var rendered = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                rendered += text
            case .column(let name):
                guard let value = row[name] else {
                    throw GenerationError.dependencyMissing(column: columnName, dependsOn: name)
                }
                let text = value.textFallback
                rendered += slugify ? AsciiSlug.joined(text, separator: slugSeparator) : text
            }
        }
        return .text(truncator.truncate(rendered, to: maxLength))
    }

    func reset() {}

    /// Parsed once at build time. An unclosed `{{` is literal text rather than an
    /// error: the template is user-written and a half-typed one should render as
    /// what it says, not refuse the whole run.
    private static func parse(_ template: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var remainder = Substring(template)

        while let open = remainder.range(of: "{{") {
            guard let close = remainder.range(of: "}}", range: open.upperBound..<remainder.endIndex) else { break }
            let name = remainder[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            literal += remainder[remainder.startIndex..<open.lowerBound]
            if name.isEmpty {
                literal += remainder[open.lowerBound..<close.upperBound]
            } else {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
                segments.append(.column(name))
            }
            remainder = remainder[close.upperBound...]
        }

        literal += remainder
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }
}

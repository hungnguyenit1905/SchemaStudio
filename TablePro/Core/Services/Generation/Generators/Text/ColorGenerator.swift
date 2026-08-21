//
//  ColorGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A colour written the way the column most likely stores it. The hex and rgb
/// forms have a fixed width, so a column too narrow to hold one is refused
/// rather than filled with a value that is no longer a colour.
final class ColorGenerator: ValueGenerator {
    static let identifier = "Color"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "format",
            label: "Written as",
            type: .choice([
                ParamChoice(value: ColorFormat.hex.rawValue, label: String(localized: "Hex, such as #1a2b3c")),
                ParamChoice(value: ColorFormat.rgb.rawValue, label: String(localized: "rgb(26, 43, 60)")),
                ParamChoice(value: ColorFormat.name.rawValue, label: String(localized: "Name, such as teal"))
            ]),
            defaultValue: .string(ColorFormat.hex.rawValue)
        ),
        ParamField(
            key: "uppercase",
            label: "Uppercase hex",
            type: .toggle,
            defaultValue: .bool(false),
            visibleWhen: ParamVisibility(key: "format", equalsAnyOf: [.string(ColorFormat.hex.rawValue)])
        )
    ])

    enum ColorFormat: String, Codable, Sendable, CaseIterable {
        case hex
        case rgb
        case name
    }

    private struct Params: Codable {
        var format: ColorFormat?
        var uppercase: Bool?
    }

    private static let names = [
        "aqua", "aquamarine", "beige", "black", "blue", "brown", "chartreuse", "chocolate",
        "coral", "crimson", "cyan", "fuchsia", "gold", "gray", "green", "indigo", "ivory",
        "khaki", "lavender", "lime", "magenta", "maroon", "navy", "olive", "orange",
        "orchid", "peru", "pink", "plum", "purple", "red", "salmon", "sienna", "silver",
        "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white", "yellow"
    ]

    private static let channelCount = 256
    private static let hexWidth = 7
    private static let widestRgb = "rgb(255, 255, 255)".count

    private let format: ColorFormat
    private let uppercase: Bool
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let distinctCount: Int?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let resolvedFormat = decoded.format ?? .hex
        format = resolvedFormat
        uppercase = decoded.uppercase ?? false
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator

        switch resolvedFormat {
        case .hex:
            try ColumnFit.requireRoom(for: Self.hexWidth, column: column, generator: Self.identifier)
            distinctCount = Self.channelCount * Self.channelCount * Self.channelCount
        case .rgb:
            try ColumnFit.requireRoom(for: Self.widestRgb, column: column, generator: Self.identifier)
            distinctCount = Self.channelCount * Self.channelCount * Self.channelCount
        case .name:
            distinctCount = TruncatedCardinality.count(
                maxLength: column.maxLength,
                truncator: resolvedTruncator,
                product: Self.names.count,
                combinations: { Self.names }
            )
        }
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        switch format {
        case .name:
            return .text(truncator.truncate(Self.names[rng.nextInt(upperBound: Self.names.count)], to: maxLength))
        case .hex, .rgb:
            let red = rng.nextInt(upperBound: Self.channelCount)
            let green = rng.nextInt(upperBound: Self.channelCount)
            let blue = rng.nextInt(upperBound: Self.channelCount)
            guard format == .hex else { return .text("rgb(\(red), \(green), \(blue))") }
            let hex = String(format: uppercase ? "#%02X%02X%02X" : "#%02x%02x%02x", red, green, blue)
            return .text(hex)
        }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}

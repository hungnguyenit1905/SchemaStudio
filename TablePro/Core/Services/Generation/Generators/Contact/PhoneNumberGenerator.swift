//
//  PhoneNumberGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

protocol PhoneLineField {
    static var identifier: String { get }
    static var line: PhoneLine { get }
    static var defaultCountry: PhoneCountry { get }
}

enum LandlineField: PhoneLineField {
    static let identifier = "PhoneNumber"
    static let line = PhoneLine.landline
    static let defaultCountry = PhoneCountry.us
}

enum MobileLineField: PhoneLineField {
    static let identifier = "MobileNumber"
    static let line = PhoneLine.mobile
    static let defaultCountry = PhoneCountry.us
}

/// A phone number is refused rather than shortened when the column cannot hold
/// it: half a number is not a shorter number, and a column that narrow is a
/// mapping mistake worth reporting before the run rather than after it.
final class PhoneNumberGenerator<Field: PhoneLineField>: ValueGenerator {
    static var identifier: String { Field.identifier }

    static var paramSchema: ParamSchema {
        ParamSchema(fields: [
            ParamField(
                key: "country",
                label: "Country",
                type: .choice(PhoneCountry.paramChoices),
                defaultValue: .string(Field.defaultCountry.rawValue)
            ),
            ParamField(
                key: "writing",
                label: "Written as",
                type: .choice(PhoneWriting.paramChoices),
                defaultValue: .string(PhoneWriting.national.rawValue)
            )
        ])
    }

    private struct Params: Codable {
        var country: PhoneCountry?
        var writing: PhoneWriting?
    }

    private let plan: PhoneNumberPlan
    private let writing: PhoneWriting
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        plan = PhoneNumberPlan.plan(country: decoded.country ?? Field.defaultCountry, line: Field.line)
        writing = decoded.writing ?? .national
        try ColumnFit.requireRoom(
            for: plan.maximumLength(as: writing),
            column: column,
            generator: Self.identifier
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { plan.distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(plan.write(plan.draw(using: &rng), as: writing))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}

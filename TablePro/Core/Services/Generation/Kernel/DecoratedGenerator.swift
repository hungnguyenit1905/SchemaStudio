//
//  DecoratedGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct GenerationWarning: Sendable, Hashable {
    let column: String
    let message: String
}

final class DecoratedGenerator {
    static let defaultUniqueRetryBudget = 64

    private let inner: any ValueGenerator
    private let columnName: String
    private let maxLength: Int?
    private let common: CommonParams
    private let truncator: GenerationStringTruncator
    private let uniqueRetryBudget: Int
    private let seed: UInt64

    private var rng: SplitMix64
    private var seenHashes: Set<UInt64> = []
    private var affixWarningIssued = false
    private(set) var warnings: [GenerationWarning] = []

    init(
        inner: any ValueGenerator,
        column: GenerationColumn,
        common: CommonParams,
        truncator: GenerationStringTruncator,
        seed: UInt64,
        uniqueRetryBudget: Int = DecoratedGenerator.defaultUniqueRetryBudget
    ) {
        self.inner = inner
        columnName = column.name
        maxLength = column.maxLength
        self.common = common
        self.truncator = truncator
        self.seed = seed
        self.uniqueRetryBudget = uniqueRetryBudget
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let value = try uniqueChecked(row: row, index: index)
        let blanked = rng.rollsBelow(percent: common.blankPercent) ? Self.blanked(value) : value
        guard rng.rollsBelow(percent: common.nullPercent) else { return blanked }
        return .null
    }

    func reset() {
        inner.reset()
        rng = SplitMix64(seed: seed)
        seenHashes.removeAll(keepingCapacity: true)
        warnings.removeAll(keepingCapacity: true)
        affixWarningIssued = false
    }

    private func uniqueChecked(row: RowContext, index: Int) throws -> PluginCellValue {
        guard common.unique else { return try shaped(row: row, index: index) }
        for _ in 0..<uniqueRetryBudget {
            let value = try shaped(row: row, index: index)
            if seenHashes.insert(value.stableHash).inserted { return value }
        }
        throw GenerationError.uniqueExhausted(column: columnName, attempts: uniqueRetryBudget)
    }

    private func shaped(row: RowContext, index: Int) throws -> PluginCellValue {
        let produced = try inner.next(row: row, index: index)
        guard case .text(let text) = produced else { return produced }
        let cased = common.textCase.apply(to: text)
        let affixed = common.prefix + cased + common.suffix
        warnIfAffixCannotFit()
        return .text(truncator.truncate(affixed, to: maxLength))
    }

    private func warnIfAffixCannotFit() {
        guard !affixWarningIssued, common.hasAffix, let maxLength else { return }
        guard truncator.unit.measure(common.affix) >= maxLength else { return }
        affixWarningIssued = true
        warnings.append(
            GenerationWarning(
                column: columnName,
                message: String(
                    format: String(localized: "The prefix and suffix alone fill the %d character limit on %@."),
                    maxLength,
                    columnName
                )
            )
        )
    }

    private static func blanked(_ value: PluginCellValue) -> PluginCellValue {
        guard case .text = value else { return value }
        return .text("")
    }
}

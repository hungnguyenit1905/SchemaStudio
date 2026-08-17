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
    private var blankWarningIssued = false
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
        rng = SplitMix64(seed: Self.decoratorSeed(from: seed))
    }

    /// The decorator must not walk the same stream as the generator it wraps.
    /// Handed the same column seed, a 50% null roll and a 50% boolean draw read
    /// the same word, so every `true` became `NULL` and the column emitted only
    /// `false`.
    static func decoratorSeed(from seed: UInt64) -> UInt64 {
        FNV1aHasher.hash { hasher in
            hasher.combine(seed)
            hasher.combine("decorator")
        }
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let value = try uniqueChecked(row: row, index: index)
        let blanked = shouldBlank() ? Self.blanked(value) : value
        guard rng.rollsBelow(percent: common.nullPercent) else { return blanked }
        return .null
    }

    /// A blank is a value like any other, so emitting it on a column that has to
    /// be distinct would repeat `''` on every blanked row. Uniqueness wins and
    /// the column is warned about once. Nulls are exempt because SQL uniqueness
    /// does not constrain them.
    private func shouldBlank() -> Bool {
        guard rng.rollsBelow(percent: common.blankPercent) else { return false }
        guard common.unique else { return true }
        warnBlanksSuppressed()
        return false
    }

    func reset() {
        inner.reset()
        rng = SplitMix64(seed: Self.decoratorSeed(from: seed))
        seenHashes.removeAll(keepingCapacity: true)
        warnings.removeAll(keepingCapacity: true)
        affixWarningIssued = false
        blankWarningIssued = false
    }

    private func warnBlanksSuppressed() {
        guard !blankWarningIssued else { return }
        blankWarningIssued = true
        warnings.append(
            GenerationWarning(
                column: columnName,
                message: String(
                    format: String(localized: "%@ has to be distinct, so blank values are not written to it."),
                    columnName
                )
            )
        )
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

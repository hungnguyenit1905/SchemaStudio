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

/// How a column that has to hold distinct values gets them. Cheapest first: a
/// generator whose values never repeat needs nothing, a finite integer domain is
/// shuffled so no draw is ever wasted, and everything else is tracked.
enum UniqueStrategy {
    case off
    case trusted
    case shuffledRange(ShuffledRangeSource)
    case tracked(UniqueTracker)
}

final class DecoratedGenerator {
    static let defaultUniqueRetryBudget = 64

    private let inner: any ValueGenerator
    private let columnName: String
    private let columnBase: TransferBaseType
    private let maxLength: Int?
    private let common: CommonParams
    private let truncator: GenerationStringTruncator
    private let uniqueRetryBudget: Int
    private let seed: UInt64

    private var rng: SplitMix64
    private var unique: UniqueStrategy
    private var affixWarningIssued = false
    private var blankWarningIssued = false
    private var ownWarnings: [GenerationWarning] = []

    /// The decorator's own warnings, plus whatever the generator it wraps
    /// noticed about its own output (a clamped overflow, for instance).
    var warnings: [GenerationWarning] { ownWarnings + inner.warnings }

    init(
        inner: any ValueGenerator,
        column: GenerationColumn,
        common: CommonParams,
        truncator: GenerationStringTruncator,
        seed: UInt64,
        rowCount: Int = 0,
        uniqueRetryBudget: Int = DecoratedGenerator.defaultUniqueRetryBudget
    ) {
        self.inner = inner
        columnName = column.name
        columnBase = column.type.base
        maxLength = column.maxLength
        self.common = common
        self.truncator = truncator
        self.seed = seed
        self.uniqueRetryBudget = uniqueRetryBudget
        rng = SplitMix64(seed: Self.decoratorSeed(from: seed))
        unique = Self.strategy(
            inner: inner,
            column: column,
            common: common,
            rowCount: rowCount,
            seed: Self.shuffleSeed(from: seed)
        )
    }

    /// A column the server fills is never tracked: nothing of ours is written, so
    /// the uniqueness is the server's to keep. SQL uniqueness also does not
    /// constrain `NULL`, which is why the tracked path lets nulls through.
    ///
    /// The affix and the case transform both change the value the server compares,
    /// so a shuffle over the raw domain would no longer guarantee distinct stored
    /// values. Those columns fall back to tracking what was actually emitted.
    ///
    /// A blank or a null percentage rules the shuffle out for a different reason:
    /// a drawn value that is then thrown away cannot be put back, so a domain
    /// sized to the row count would run out partway through a run the pre-flight
    /// had already approved.
    static func strategy(
        inner: any ValueGenerator,
        column: GenerationColumn,
        common: CommonParams,
        rowCount: Int,
        seed: UInt64
    ) -> UniqueStrategy {
        guard common.unique || column.requiresUniqueValues else { return .off }
        guard !inner.excludesColumnFromInsert, !column.isServerAssigned else { return .off }
        if inner.producesDistinctValues { return .trusted }
        if !common.hasAffix, common.textCase == .unchanged, common.blankPercent == 0,
           common.nullPercent == 0,
           let domain = inner.integerDomain,
           let source = ShuffledRangeSource(domain: domain, seed: seed) {
            return .shuffledRange(source)
        }
        return .tracked(
            UniqueTracker(matching: UniqueMatching.resolve(for: column), expectedCount: rowCount)
        )
    }

    static func shuffleSeed(from seed: UInt64) -> UInt64 {
        FNV1aHasher.hash { hasher in
            hasher.combine(seed)
            hasher.combine("shuffle")
        }
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

    /// The null roll comes first so a row that ends up NULL never reserves a
    /// unique value. Drawing first burned one value out of the domain per null
    /// row, which exhausts a column whose domain is only as large as the row
    /// count. `rollsBelow` reads no word at 0%, so a column without nulls draws
    /// exactly the stream it did before.
    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !rng.rollsBelow(percent: common.nullPercent) else { return .null }
        let value = try uniqueChecked(row: row, index: index)
        return shouldBlank() ? Self.blanked(value) : value
    }

    /// A blank is a value like any other, so emitting it on a column that has to
    /// be distinct would repeat `''` on every blanked row. Uniqueness wins and
    /// the column is warned about once. Nulls are exempt because SQL uniqueness
    /// does not constrain them.
    private func shouldBlank() -> Bool {
        guard rng.rollsBelow(percent: common.blankPercent) else { return false }
        guard mustBeDistinct else { return true }
        warnBlanksSuppressed()
        return false
    }

    private var mustBeDistinct: Bool {
        if case .off = unique { return false }
        return true
    }

    func reset() {
        inner.reset()
        rng = SplitMix64(seed: Self.decoratorSeed(from: seed))
        resetUniqueState()
        ownWarnings.removeAll(keepingCapacity: true)
        affixWarningIssued = false
        blankWarningIssued = false
    }

    private func resetUniqueState() {
        switch unique {
        case .off, .trusted:
            return
        case .shuffledRange(var source):
            source.reset()
            unique = .shuffledRange(source)
        case .tracked(var tracker):
            tracker.reset()
            unique = .tracked(tracker)
        }
    }

    private func warnBlanksSuppressed() {
        guard !blankWarningIssued else { return }
        blankWarningIssued = true
        ownWarnings.append(
            GenerationWarning(
                column: columnName,
                message: String(
                    format: String(localized: "%@ has to be distinct, so blank values are not written to it."),
                    columnName
                )
            )
        )
    }

    /// Only the tracked strategy can take a value back. A shuffled range hands
    /// out each member once by construction, and returning one would let it be
    /// drawn twice.
    func discard(_ value: PluginCellValue) {
        guard case .tracked(var tracker) = unique else { return }
        tracker.withdraw(value)
        unique = .tracked(tracker)
    }

    private func uniqueChecked(row: RowContext, index: Int) throws -> PluginCellValue {
        switch unique {
        case .off, .trusted:
            return try shaped(row: row, index: index)
        case .shuffledRange(var source):
            defer { unique = .shuffledRange(source) }
            guard let drawn = source.next() else {
                throw GenerationError.uniqueExhausted(column: columnName, attempts: uniqueRetryBudget)
            }
            return .int(drawn)
        case .tracked(var tracker):
            defer { unique = .tracked(tracker) }
            for _ in 0..<uniqueRetryBudget {
                let value = try shaped(row: row, index: index)
                if case .null = value { return value }
                if tracker.admit(value) { return value }
            }
            throw GenerationError.uniqueExhausted(column: columnName, attempts: uniqueRetryBudget)
        }
    }

    /// Prefix, suffix, case and the length limit apply to every case whose wire
    /// form is already a string: `.text` and `.decimalText`. Every other case is
    /// typed and keeps its type unshaped, because stringifying it would hand the
    /// driver a value it can no longer bind natively.
    private func shaped(row: RowContext, index: Int) throws -> PluginCellValue {
        let produced = try inner.next(row: row, index: index)
        switch produced {
        case .text(let text):
            return .text(decorated(text))
        case .decimalText(let text):
            return .decimalText(decorated(text))
        default:
            return produced
        }
    }

    private func decorated(_ text: String) -> String {
        let cased = common.textCase.apply(to: text)
        let affixed = common.prefix + cased + common.suffix
        warnIfAffixCannotFit()
        return truncator.truncate(affixed, to: maxLength)
    }

    private func warnIfAffixCannotFit() {
        guard !affixWarningIssued, common.hasAffix, let maxLength else { return }
        guard truncator.unit.measure(common.affix) >= maxLength else { return }
        affixWarningIssued = true
        ownWarnings.append(
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

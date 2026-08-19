//
//  AutoMapper.swift
//  TablePro
//

import Foundation

struct AutoMapResolution: Sendable, Hashable {
    let identifier: String
    let params: JSONValue
    let common: CommonParams
    let warnings: [ValidationWarning]
}

/// Picks a generator for a column from what the schema already says about it.
///
/// Four tiers, first match wins:
///
/// 1. constraints. A generated column, an identity, a foreign key or a value list
///    leaves no choice, so nothing below can override it.
/// 2. the column name, through `NameRules`, but only where the rule accepts the
///    column's canonical type. The type always beats the name: `email int` skips
///    this tier entirely.
/// 3. the type alone, through `TypeFallbackGeneratorResolver`.
/// 4. `CHECK` expressions, which narrow whatever the tiers above chose. Anything
///    a check asks for that the generator cannot honour becomes a warning rather
///    than data the server will reject.
///
/// Pure and synchronous: no I/O, no driver call, no main actor.
enum AutoMapper {
    static func resolve(
        _ column: GenerationColumn,
        table: String,
        referenceDate: Date = Date()
    ) -> AutoMapResolution {
        var draft = Draft(column: column)
        if let constrained = TypeFallbackGeneratorResolver.constraintResolution(column) {
            draft.identifier = constrained.identifier
            draft.params = constrained.params
        } else if let rule = NameRules.firstMatch(for: column, table: table) {
            draft.identifier = rule.identifier
            draft.params = params(for: rule, referenceDate: referenceDate)
            draft.common = rule.common
            if rule.warnsAboutGuessedValues {
                draft.warnings.append(.guessedValues(column: column.name))
            }
        } else {
            let fallback = TypeFallbackGeneratorResolver.typeResolution(column)
            draft.identifier = fallback.identifier
            draft.params = fallback.params
        }
        refine(&draft)
        return draft.resolution()
    }

    private struct Draft {
        let column: GenerationColumn
        var identifier = ""
        var params: JSONValue = .object([:])
        var common: CommonParams = .none
        var warnings: [ValidationWarning] = []

        /// Which of `min`/`max` a check constraint set, as opposed to the
        /// name-based defaults. A check outranks a guess, but two checks that
        /// contradict each other are the schema's problem to report.
        var boundsFromChecks: Set<String> = []

        /// A column the server fills or that draws from a parent table has no
        /// settings of ours to narrow, so a check on it is not a gap.
        var acceptsCheckRefinement: Bool {
            identifier != DefaultGenerator.identifier && identifier != ReferenceGenerator.identifier
        }

        func resolution() -> AutoMapResolution {
            var resolved = common
            if !column.isNullable { resolved.nullPercent = 0 }
            if column.requiresUniqueValues { resolved.unique = true }
            return AutoMapResolution(
                identifier: identifier,
                params: params,
                common: resolved,
                warnings: warnings
            )
        }
    }

    private static func params(for rule: NameRule, referenceDate: Date) -> JSONValue {
        guard let window = rule.dateWindow else { return rule.params }
        let day = 86_400.0
        let from = Int(referenceDate.timeIntervalSince1970 + Double(window.fromDays) * day)
        let to = Int(referenceDate.timeIntervalSince1970 + Double(window.toDays) * day)
        guard rule.identifier == DateGenerator.identifier else {
            return .object([
                "from": .string(DateTimeGenerator.render(seconds: from)),
                "to": .string(DateTimeGenerator.render(seconds: to))
            ])
        }
        return .object([
            "from": .string(civilDate(seconds: from).iso8601),
            "to": .string(civilDate(seconds: to).iso8601)
        ])
    }

    private static func civilDate(seconds: Int) -> CivilDate {
        let days = Int((Double(seconds) / 86_400.0).rounded(.down))
        return CivilDate.fromDaysSinceEpoch(days)
    }

    private static func refine(_ draft: inout Draft) {
        guard !draft.column.checkExpressions.isEmpty, draft.acceptsCheckRefinement else { return }
        for expression in draft.column.checkExpressions {
            let parsed = CheckConstraintParser.parse(expression, column: draft.column.name)
            var applied = parsed.isComplete && !parsed.constraints.isEmpty
            for constraint in parsed.constraints {
                guard apply(constraint, to: &draft) else {
                    applied = false
                    continue
                }
            }
            guard !applied else { continue }
            draft.warnings.append(
                .uncheckedConstraint(column: draft.column.name, expression: expression)
            )
        }
    }

    private static func apply(_ constraint: CheckConstraint, to draft: inout Draft) -> Bool {
        switch constraint {
        case .lowerBound(let value, let inclusive):
            let minimum = bound(value, inclusive: inclusive, raising: true, draft: draft)
            return applyBound(key: "min", value: minimum, to: &draft)
        case .upperBound(let value, let inclusive):
            let maximum = bound(value, inclusive: inclusive, raising: false, draft: draft)
            return applyBound(key: "max", value: maximum, to: &draft)
        case .allowedValues(let values):
            draft.identifier = ListGenerator.identifier
            draft.params = .object(["values": .array(values.map(JSONValue.string))])
            let guessed = ValidationWarning.guessedValues(column: draft.column.name)
            draft.warnings.removeAll { $0 == guessed }
            return true
        case .maximumLength(let limit):
            return applyMaximumLength(limit, to: &draft)
        case .nonEmpty:
            return applyMinimumLength(1, to: &draft)
        case .notNull:
            draft.common.nullPercent = 0
            return true
        case .pattern(let pattern):
            return applyPattern(pattern, to: &draft)
        case .likePattern:
            return false
        }
    }

    /// A regular expression the reverse-regex generator understands is applied by
    /// switching the column to it, because no other generator can be narrowed
    /// into matching one. A pattern outside the supported subset is left alone
    /// and reported, which is what the tier did for every pattern before.
    private static func applyPattern(_ pattern: String, to draft: inout Draft) -> Bool {
        guard [.string, .text].contains(draft.column.type.base) else { return false }
        guard (try? RegexPatternParser.parse(pattern, repeatCap: RegexGenerator.defaultRepeatCap)) != nil else {
            return false
        }
        draft.identifier = RegexGenerator.identifier
        draft.params = .object(["pattern": .string(pattern)])
        return true
    }

    /// Every generator that takes the same `min` and `max` pair, which is what a
    /// bound from a check constraint is written into. `Price` and `Age` are here
    /// because they are the mapper's own answer for money and age columns, and a
    /// bound the mapper cannot apply to its own choice would be reported as
    /// unchecked on the most ordinary schema there is.
    private static let boundedGenerators: Set<String> = [
        IntegerGenerator.identifier,
        DecimalGenerator.identifier,
        DoubleGenerator.identifier,
        PriceGenerator.identifier,
        AgeGenerator.identifier
    ]

    /// A name-based default carries both bounds, so a check that moves one past
    /// the other leaves the generator with `min > max` and it refuses to build.
    /// The check is the server's rule and the default is a guess, so the guess
    /// gives way. Two checks that contradict each other are reported instead.
    private static func applyBound(key: String, value: JSONValue, to draft: inout Draft) -> Bool {
        guard boundedGenerators.contains(draft.identifier) else { return false }
        var fields = draft.params.objectValue ?? [:]
        let opposite = key == "min" ? "max" : "min"
        if
            let incoming = value.doubleValue,
            let existing = fields[opposite]?.doubleValue,
            key == "min" ? incoming > existing : incoming < existing {
            guard !draft.boundsFromChecks.contains(opposite) else { return false }
            fields.removeValue(forKey: opposite)
        }
        fields[key] = value
        draft.params = .object(fields)
        draft.boundsFromChecks.insert(key)
        return true
    }

    /// A strict comparison has to become the inclusive bound the generators take,
    /// and the step depends on the column: one for an integer, one unit of the
    /// declared scale for a decimal, the adjacent representable value for a float.
    private static func bound(
        _ value: Double,
        inclusive: Bool,
        raising: Bool,
        draft: Draft
    ) -> JSONValue {
        let base = draft.column.type.base
        let isInteger = [.int8, .int16, .int32, .int64].contains(base)
        guard !inclusive else {
            return isInteger ? .int(Int(raising ? value.rounded(.up) : value.rounded(.down))) : .double(value)
        }
        if isInteger {
            return .int(Int(raising ? value.rounded(.down) + 1 : value.rounded(.up) - 1))
        }
        guard base == .decimal else { return .double(raising ? value.nextUp : value.nextDown) }
        let scale = max(0, min(draft.column.type.scale ?? 2, 18))
        let step = pow(10.0, -Double(scale))
        return .double(raising ? value + step : value - step)
    }

    /// A length cap the current generator cannot honour is switched to
    /// `RandomString`, which can. Keeping a generator that overruns the cap trades
    /// a readable value for rows the server rejects.
    ///
    /// A generator drawing from a fixed set of values is left alone: those values
    /// come from the schema itself, so replacing them with a random string of the
    /// right length would drop the only constraint that actually matters.
    ///
    /// The cap has to cover the prefix and suffix too. `DecoratedGenerator` adds
    /// those after the generator has produced its value and trims only to the
    /// column's declared length, so a cap applied to the generator alone would be
    /// reported as honoured while the written value overran it. Where the affix
    /// leaves no room at all, the check is not applied and the column is warned
    /// about instead.
    private static func applyMaximumLength(_ limit: Int, to draft: inout Draft) -> Bool {
        guard limit > 0 else { return false }
        if let declared = draft.column.maxLength, declared <= limit { return true }
        if [ListGenerator.identifier, FixedGenerator.identifier].contains(draft.identifier) { return true }
        guard [.string, .text].contains(draft.column.type.base) else { return false }

        let room = limit - draft.common.affix.unicodeScalars.count
        guard room >= 1 else { return false }

        guard draft.identifier == RandomStringGenerator.identifier else {
            draft.identifier = RandomStringGenerator.identifier
            draft.params = .object([
                "minLength": .int(max(1, min(3, room))),
                "maxLength": .int(room)
            ])
            return true
        }
        var fields = draft.params.objectValue ?? [:]
        fields["maxLength"] = .int(room)
        if (fields["minLength"]?.intValue ?? 0) > room {
            fields["minLength"] = .int(room)
        }
        draft.params = .object(fields)
        return true
    }

    private static func applyMinimumLength(_ minimum: Int, to draft: inout Draft) -> Bool {
        guard draft.identifier == RandomStringGenerator.identifier else { return true }
        var fields = draft.params.objectValue ?? [:]
        if (fields["minLength"]?.intValue ?? 0) < minimum {
            fields["minLength"] = .int(minimum)
        }
        draft.params = .object(fields)
        return true
    }
}

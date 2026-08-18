//
//  Distribution.swift
//  TablePro
//

import Foundation

enum DistributionShape: String, Codable, Sendable, Hashable, CaseIterable {
    case uniform
    case normal
    case exponential
}

/// Shapes a draw over a numeric range. Uniform data makes an index benchmark
/// meaningless, because a real column is rarely evenly spread.
///
/// `mean` and `stddev` are read in the column's own units, so a price column
/// takes 100 and 20 rather than a fraction of its span. `lambda` is a rate over
/// the span: the average sits `span / lambda` above the lower bound.
struct Distribution: Sendable, Hashable {
    private static let redrawAttempts = 8
    private static let defaultLambda = 2.0

    let shape: DistributionShape
    private let mean: Double?
    private let stddev: Double?
    private let lambda: Double

    static let uniform = Distribution(shape: .uniform, mean: nil, stddev: nil, lambda: defaultLambda)

    private init(shape: DistributionShape, mean: Double?, stddev: Double?, lambda: Double) {
        self.shape = shape
        self.mean = mean
        self.stddev = stddev
        self.lambda = lambda
    }

    private struct Params: Codable {
        var distribution: DistributionShape?
        var mean: Double?
        var stddev: Double?
        var lambda: Double?
    }

    init(params: Data, generator: String) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: generator,
            default: Params()
        )
        shape = decoded.distribution ?? .uniform
        mean = decoded.mean
        stddev = decoded.stddev
        lambda = decoded.lambda ?? Self.defaultLambda
        guard shape != .normal || (stddev ?? 1) > 0 else {
            throw GenerationError.invalidParameters(
                generator: generator,
                reason: "the standard deviation has to be above zero"
            )
        }
        guard shape != .exponential || lambda > 0 else {
            throw GenerationError.invalidParameters(
                generator: generator,
                reason: "the rate has to be above zero"
            )
        }
    }

    var isUniform: Bool { shape == .uniform }

    /// The fields every generator that takes a distribution appends to its own
    /// schema, so the three numeric generators describe it the same way.
    static let paramFields: [ParamField] = [
        ParamField(
            key: "distribution",
            label: "Distribution",
            type: .choice([
                ParamChoice(value: DistributionShape.uniform.rawValue, label: String(localized: "Uniform")),
                ParamChoice(value: DistributionShape.normal.rawValue, label: String(localized: "Normal")),
                ParamChoice(value: DistributionShape.exponential.rawValue, label: String(localized: "Exponential"))
            ]),
            defaultValue: .string(DistributionShape.uniform.rawValue)
        ),
        ParamField(
            key: "mean",
            label: "Mean",
            type: .decimal(minimum: nil, maximum: nil),
            defaultValue: .null,
            help: String(localized: "Leave empty to centre on the middle of the range."),
            visibleWhen: ParamVisibility(key: "distribution", equalsAnyOf: [.string(DistributionShape.normal.rawValue)])
        ),
        ParamField(
            key: "stddev",
            label: "Standard deviation",
            type: .decimal(minimum: nil, maximum: nil),
            defaultValue: .null,
            help: String(localized: "Leave empty to spread the range over six deviations."),
            visibleWhen: ParamVisibility(key: "distribution", equalsAnyOf: [.string(DistributionShape.normal.rawValue)])
        ),
        ParamField(
            key: "lambda",
            label: "Rate",
            type: .decimal(minimum: nil, maximum: nil),
            defaultValue: .double(2),
            help: String(localized: "Higher rates push more values towards the minimum."),
            visibleWhen: ParamVisibility(
                key: "distribution",
                equalsAnyOf: [.string(DistributionShape.exponential.rawValue)]
            )
        )
    ]

    func sample(in range: ClosedRange<Double>, using rng: inout SplitMix64) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        switch shape {
        case .uniform:
            return rng.nextDouble(in: range)
        case .normal:
            return normalSample(in: range, span: span, using: &rng)
        case .exponential:
            return exponentialSample(in: range, span: span, using: &rng)
        }
    }

    /// A draw outside the column's range is redrawn rather than folded back,
    /// because clamping piles the whole tail onto the two end values. The clamp
    /// after the last attempt keeps the call total, which matters for a mean
    /// parked far outside the range.
    private func normalSample(in range: ClosedRange<Double>, span: Double, using rng: inout SplitMix64) -> Double {
        let centre = mean ?? (range.lowerBound + span / 2)
        let spread = stddev ?? (span / 6)
        var value = range.lowerBound
        for _ in 0..<Self.redrawAttempts {
            value = centre + spread * Self.standardNormal(using: &rng)
            if range.contains(value) { return value }
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func exponentialSample(in range: ClosedRange<Double>, span: Double, using rng: inout SplitMix64) -> Double {
        for _ in 0..<Self.redrawAttempts {
            let position = -log(1 - rng.nextUnitFraction()) / lambda
            guard position > 1 else { return range.lowerBound + position * span }
        }
        return range.upperBound
    }

    /// Box-Muller. The unit fraction is nudged off zero because `log(0)` is
    /// negative infinity.
    private static func standardNormal(using rng: inout SplitMix64) -> Double {
        let first = max(rng.nextUnitFraction(), .leastNormalMagnitude)
        let second = rng.nextUnitFraction()
        return (-2 * log(first)).squareRoot() * cos(2 * .pi * second)
    }
}

/// Draws a rank out of a pool so a few entries take most of the draws, which is
/// the few-parents-many-children shape a real foreign key has. The cumulative
/// table is built once per pool and searched in log time.
struct ZipfDistribution: Sendable {
    private let cumulative: [Double]

    init(count: Int, exponent: Double) {
        guard count > 0 else {
            cumulative = []
            return
        }
        var running: [Double] = []
        running.reserveCapacity(count)
        var total = 0.0
        for rank in 1...count {
            total += 1 / pow(Double(rank), exponent)
            running.append(total)
        }
        cumulative = running.map { $0 / total }
    }

    var isEmpty: Bool { cumulative.isEmpty }

    func nextRank(using rng: inout SplitMix64) -> Int {
        guard !cumulative.isEmpty else { return 0 }
        let draw = rng.nextUnitFraction()
        var lower = 0
        var upper = cumulative.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulative[middle] < draw {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

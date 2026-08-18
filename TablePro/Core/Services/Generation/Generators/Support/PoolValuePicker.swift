//
//  PoolValuePicker.swift
//  TablePro
//

import Foundation

/// Picks a position in a pool of parent values. Shared by every generator that
/// draws from a pool loaded before the run, so a single-column foreign key, a
/// composite one and a query column all spread themselves the same way.
///
/// `nil` from `nextIndex` means the pool is used up, which only `oneToOne` can
/// reach and only when the row count was never checked against the pool.
struct PoolValuePicker {
    static let defaultSkew = 1.0

    private let strategy: ReferenceStrategy
    private let skew: Double
    private let seed: UInt64
    private var zipf: ZipfDistribution?
    private var permutation: [Int] = []
    private var position = 0

    /// The covering permutation is shuffled from a stream of its own rather than
    /// from the column's, so binding the same pool twice lays out the same order
    /// however many values the column has already drawn.
    private var shuffleRng: SplitMix64

    init(strategy: ReferenceStrategy, skew: Double = defaultSkew, seed: UInt64) {
        self.strategy = strategy
        self.skew = skew
        self.seed = seed
        shuffleRng = SplitMix64(seed: seed)
    }

    /// Built once the pool is known, because both the cumulative table and the
    /// covering permutation are sized by it.
    mutating func bind(count: Int) {
        position = 0
        zipf = nil
        permutation = []
        shuffleRng = SplitMix64(seed: seed)
        guard count > 0 else { return }
        switch strategy {
        case .weighted:
            zipf = ZipfDistribution(count: count, exponent: skew)
        case .ensureCoverage:
            permutation = Array(0..<count)
            shufflePermutation()
        default:
            return
        }
    }

    mutating func nextIndex(count: Int, using rng: inout SplitMix64) -> Int? {
        guard count > 0 else { return nil }
        switch strategy {
        case .random:
            return rng.nextInt(upperBound: count)
        case .roundRobin:
            defer { position += 1 }
            return position % count
        case .oneToOne:
            guard position < count else { return nil }
            defer { position += 1 }
            return position
        case .ensureCoverage:
            return coveringIndex(count: count)
        case .weighted:
            guard let zipf, !zipf.isEmpty else { return rng.nextInt(upperBound: count) }
            return min(zipf.nextRank(using: &rng), count - 1)
        }
    }

    /// Every parent is handed out once before any of them is handed out twice,
    /// which is what keeps a join from dropping rows.
    private mutating func coveringIndex(count: Int) -> Int {
        if permutation.count != count {
            permutation = Array(0..<count)
            position = 0
            shufflePermutation()
        }
        if position >= permutation.count {
            position = 0
            shufflePermutation()
        }
        defer { position += 1 }
        return permutation[position]
    }

    private mutating func shufflePermutation() {
        guard permutation.count > 1 else { return }
        for index in stride(from: permutation.count - 1, to: 0, by: -1) {
            let target = shuffleRng.nextInt(upperBound: index + 1)
            permutation.swapAt(index, target)
        }
    }

    static func paramFields(strategies: [ReferenceStrategy] = ReferenceStrategy.allCases) -> [ParamField] {
        [
            ParamField(
                key: "strategy",
                label: "Pick",
                type: .choice(strategies.map { ParamChoice(value: $0.rawValue, label: $0.label) }),
                defaultValue: .string(ReferenceStrategy.random.rawValue)
            ),
            ParamField(
                key: "skew",
                label: "Skew",
                type: .decimal(minimum: 0, maximum: nil),
                defaultValue: .double(defaultSkew),
                help: String(localized: "Higher values send more rows to the first few parents."),
                visibleWhen: ParamVisibility(
                    key: "strategy",
                    equalsAnyOf: [.string(ReferenceStrategy.weighted.rawValue)]
                )
            )
        ]
    }
}

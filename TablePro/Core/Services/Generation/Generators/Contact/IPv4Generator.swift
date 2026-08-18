//
//  IPv4Generator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The blocks an address can come from. Both are unroutable on the public
/// internet: RFC 5737 sets the documentation blocks aside for exactly this, and
/// RFC 1918 addresses never leave a private network. Nothing generated here can
/// name somebody else's real host, which a column called `last_login_ip` filled
/// with routable addresses would.
enum IPv4Block: String, Codable, Sendable, CaseIterable {
    case documentation
    case privateNetwork

    var label: String {
        switch self {
        case .documentation: return String(localized: "Documentation (RFC 5737)")
        case .privateNetwork: return String(localized: "Private network (RFC 1918)")
        }
    }

    /// The fixed leading octets of each range, and how many octets stay free.
    var ranges: [(leading: [Int], freeOctets: Int)] {
        switch self {
        case .documentation:
            return [([192, 0, 2], 1), ([198, 51, 100], 1), ([203, 0, 113], 1)]
        case .privateNetwork:
            return [([10], 3), ([172, 16], 2), ([192, 168], 2)]
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

final class IPv4Generator: ValueGenerator {
    static let identifier = "IPv4"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "block",
            label: "Address block",
            type: .choice(IPv4Block.paramChoices),
            defaultValue: .string(IPv4Block.documentation.rawValue)
        )
    ])

    private struct Params: Codable {
        var block: IPv4Block?
    }

    private static let maximumLength = 15
    private static let hostRange = 1...254

    private let ranges: [(leading: [Int], freeOctets: Int)]
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        ranges = (decoded.block ?? .documentation).ranges
        try ColumnFit.requireRoom(for: Self.maximumLength, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// The host octet skips `.0` and `.255`, so each free octet carries 254
    /// addresses rather than 256. A documentation run has only 762 in total,
    /// which a unique column has to know before it starts.
    var distinctValueCount: Int? {
        var total = 0
        for range in ranges {
            var block = 1
            for _ in 0..<range.freeOctets {
                let (product, overflowed) = block.multipliedReportingOverflow(by: Self.hostRange.count)
                guard !overflowed else { return Int.max }
                block = product
            }
            let (sum, overflowed) = total.addingReportingOverflow(block)
            guard !overflowed else { return Int.max }
            total = sum
        }
        return total
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let range = ranges[rng.nextInt(upperBound: ranges.count)]
        var octets = range.leading
        for _ in 0..<range.freeOctets {
            octets.append(rng.nextInt(in: Self.hostRange))
        }
        return .text(octets.map(String.init).joined(separator: "."))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}

//
//  UserAgentGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Browser user agent strings, built as a fixed list at plan time rather than
/// assembled per row. The list is small enough to hold, which is what makes the
/// distinct count exact instead of a guess.
final class UserAgentGenerator: ValueGenerator {
    static let identifier = "UserAgent"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "platform",
            label: "Platform",
            type: .choice([
                ParamChoice(value: "any", label: String(localized: "Any")),
                ParamChoice(value: "desktop", label: String(localized: "Desktop")),
                ParamChoice(value: "mobile", label: String(localized: "Mobile"))
            ]),
            defaultValue: .string("any")
        )
    ])

    private struct Params: Codable {
        var platform: String?
    }

    private struct Family {
        let isMobile: Bool
        let versions: ClosedRange<Int>
        let render: (Int) -> String
    }

    private static let families: [Family] = [
        Family(isMobile: false, versions: 118...131) { version in
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/\(version).0.0.0 Safari/537.36"
        },
        Family(isMobile: false, versions: 118...131) { version in
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/\(version).0.0.0 Safari/537.36"
        },
        Family(isMobile: false, versions: 115...133) { version in
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(version).0) "
                + "Gecko/20100101 Firefox/\(version).0"
        },
        Family(isMobile: false, versions: 115...133) { version in
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:\(version).0) Gecko/20100101 Firefox/\(version).0"
        },
        Family(isMobile: false, versions: 15...18) { version in
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/\(version).0 Safari/605.1.15"
        },
        Family(isMobile: true, versions: 15...18) { version in
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/\(version).0 Mobile/15E148 Safari/604.1"
        },
        Family(isMobile: true, versions: 118...131) { version in
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/\(version).0.0.0 Mobile Safari/537.36"
        },
        Family(isMobile: true, versions: 118...131) { version in
            "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/\(version).0.0.0 Mobile Safari/537.36"
        }
    ]

    private let agents: [String]
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
        let platform = decoded.platform ?? "any"
        let selected = Self.families.filter { family in
            switch platform {
            case "desktop": return !family.isMobile
            case "mobile": return family.isMobile
            default: return true
            }
        }
        guard !selected.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(platform) matches no browser"
            )
        }
        agents = selected.flatMap { family in family.versions.map(family.render) }
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedAgents = agents
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolvedAgents.count,
            combinations: { resolvedAgents }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(agents[rng.nextInt(upperBound: agents.count)], to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}

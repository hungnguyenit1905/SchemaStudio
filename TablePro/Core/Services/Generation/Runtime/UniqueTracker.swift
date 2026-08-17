//
//  UniqueTracker.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How the server compares two values when it decides they collide.
///
/// A case-insensitive collation is the trap here: the engine happily produces
/// `Alice` and `alice`, the server sees one value, and the whole batch is
/// rejected. Where the driver reports no collation the tracking stays
/// case-sensitive, which can only ever produce a clear server error, never
/// silently wrong data.
enum UniqueMatching: Sendable, Hashable {
    case exact
    case caseInsensitive

    static func resolve(for column: GenerationColumn) -> UniqueMatching {
        if column.type.native.lowercased().contains("citext") { return .caseInsensitive }
        guard let collation = column.collation?.lowercased(), !collation.isEmpty else { return .exact }
        if collation == "nocase" { return .caseInsensitive }
        return collation.hasSuffix("_ci") || collation.contains("_ci_") ? .caseInsensitive : .exact
    }
}

/// The general uniqueness strategy: a set of `stableHash` values.
///
/// `stableHash` is the FNV-1a from Phase 1, never Swift's `Hasher`, whose seed
/// changes per process and would make a seeded run unrepeatable. The set is
/// pre-sized so a five-million-row column does not rehash its way there.
struct UniqueTracker {
    private let matching: UniqueMatching
    private var seen: Set<UInt64>

    init(matching: UniqueMatching = .exact, expectedCount: Int = 0) {
        self.matching = matching
        seen = Set(minimumCapacity: max(0, expectedCount))
    }

    var count: Int { seen.count }

    mutating func admit(_ value: PluginCellValue) -> Bool {
        seen.insert(Self.hash(value, matching: matching)).inserted
    }

    mutating func reset() {
        seen.removeAll(keepingCapacity: true)
    }

    private static func hash(_ value: PluginCellValue, matching: UniqueMatching) -> UInt64 {
        guard matching == .caseInsensitive, case .text(let text) = value else { return value.stableHash }
        return PluginCellValue.text(text.lowercased()).stableHash
    }
}

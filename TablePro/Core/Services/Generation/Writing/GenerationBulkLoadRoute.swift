//
//  GenerationBulkLoadRoute.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Why a table fell back to prepared batches. Carries the transfer reasons
/// unchanged and adds the two that only generation has.
enum GenerationLoadFallbackReason: String, Sendable, Equatable {
    case noBulkWriter
    case localInfileDisabled
    case rowErrorIsolation
    case harvestRequired
    case resumedMidTable

    init(_ transfer: TransferLoadFallbackReason) {
        switch transfer {
        case .noBulkWriter: self = .noBulkWriter
        case .localInfileDisabled: self = .localInfileDisabled
        case .rowErrorIsolation: self = .rowErrorIsolation
        }
    }
}

/// Picks the write path for one table. The shared conditions are
/// `TransferLoadStrategyResolver`'s, so generation and transfer cannot drift on
/// what a vendor supports; the two conditions here are generation's own.
enum GenerationBulkLoadRoute {
    struct Decision: Sendable, Equatable {
        let strategy: TransferLoadStrategy
        let reason: GenerationLoadFallbackReason?
    }

    /// `harvestRequired` rules out bulk load because a `COPY` stream reports a row
    /// count and nothing else, so a child table would have no parent keys to point
    /// at. `isResumedMidTable` rules it out because the resumed rows have to be
    /// written through a path whose progress is countable per batch.
    static func resolve(
        supportsBulkLoad: Bool,
        supportsLocalInfile: Bool?,
        requiresLocalInfile: Bool,
        continueOnError: Bool,
        harvestRequired: Bool,
        isResumedMidTable: Bool
    ) -> Decision {
        if harvestRequired {
            return Decision(strategy: .preparedBatch, reason: .harvestRequired)
        }
        if isResumedMidTable {
            return Decision(strategy: .preparedBatch, reason: .resumedMidTable)
        }
        let resolved = TransferLoadStrategyResolver.resolve(
            bulkWriterAvailable: supportsBulkLoad,
            supportsLocalInfile: supportsLocalInfile,
            localInfileRequired: requiresLocalInfile,
            continueOnError: continueOnError
        )
        return Decision(
            strategy: resolved.strategy,
            reason: resolved.reason.map(GenerationLoadFallbackReason.init)
        )
    }
}

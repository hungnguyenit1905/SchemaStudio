//
//  TransferLoadStrategyResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferLoadStrategy: Sendable, Equatable {
    case bulk
    case preparedBatch
}

enum TransferLoadFallbackReason: String, Sendable, Equatable {
    case noBulkWriter
    case localInfileDisabled
    case rowErrorIsolation
}

/// Chooses between a native bulk path and the prepared-statement fallback.
/// The decision is a pure function of probe results so it can be table-driven
/// in tests; the caller supplies the vendor-specific `localInfileRequired`.
enum TransferLoadStrategyResolver {
    static func resolve(
        bulkWriterAvailable: Bool,
        supportsLocalInfile: Bool?,
        localInfileRequired: Bool,
        continueOnError: Bool
    ) -> (strategy: TransferLoadStrategy, reason: TransferLoadFallbackReason?) {
        guard bulkWriterAvailable else { return (.preparedBatch, .noBulkWriter) }
        if localInfileRequired, supportsLocalInfile != true {
            return (.preparedBatch, .localInfileDisabled)
        }
        if continueOnError { return (.preparedBatch, .rowErrorIsolation) }
        return (.bulk, nil)
    }
}

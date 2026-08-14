//
//  TransferBatchSplitter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferBatchAction: Sendable, Equatable {
    case buffered
    case flushBefore
    case sendAlone
}

/// Cuts a row stream into batches by two ceilings at once: total bytes and
/// bind-parameter count. Byte sizing runs after value conversion so a hex
/// blob or a widened decimal is measured at its real wire size.
struct TransferBatchSplitter: Sendable {
    let maxBytes: Int
    let maxBindParameters: Int
    let columnCount: Int

    private(set) var bufferedRows = 0
    private(set) var bufferedBytes = 0

    init(maxBytes: Int, maxBindParameters: Int, columnCount: Int) {
        self.maxBytes = maxBytes
        self.maxBindParameters = maxBindParameters
        self.columnCount = max(columnCount, 1)
    }

    mutating func append(_ row: [PluginCellValue], estimatedBytes: Int) -> TransferBatchAction {
        if estimatedBytes > maxBytes {
            return .sendAlone
        }

        let nextRows = bufferedRows + 1
        let nextBytes = bufferedBytes + estimatedBytes
        let nextBinds = nextRows * columnCount

        if nextBytes <= maxBytes && nextBinds <= maxBindParameters {
            bufferedRows = nextRows
            bufferedBytes = nextBytes
            return .buffered
        }

        guard bufferedRows > 0 else {
            bufferedRows = nextRows
            bufferedBytes = nextBytes
            return .buffered
        }

        return .flushBefore
    }

    mutating func reset() {
        bufferedRows = 0
        bufferedBytes = 0
    }

    static func estimatedBytes(for row: [PluginCellValue]) -> Int {
        row.reduce(0) { partial, value in
            switch value {
            case .null: return partial + 4
            case .text(let string): return partial + string.utf8.count
            case .bytes(let data): return partial + data.count
            }
        }
    }
}

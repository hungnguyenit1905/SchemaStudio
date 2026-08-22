//
//  DuplicatePartialCopyPrompt.swift
//  TablePro
//

import Foundation
import Observation

/// Asks whether to keep or delete a table a chunked copy left part way through.
///
/// The question only exists for a copy that already committed rows: an atomic copy rolls back and
/// leaves nothing to decide. The service waits on the answer, so the continuation is resumed
/// exactly once and a prompt that is torn down without an answer resolves to keeping the table.
@MainActor @Observable
final class DuplicatePartialCopyPrompt {
    private(set) var copiedRows: Int64?

    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    var isPresented: Bool {
        get { copiedRows != nil }
        set {
            guard !newValue else { return }
            answer(shouldDrop: false)
        }
    }

    func ask(copiedRows rows: Int64) async -> Bool {
        copiedRows = rows
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func answer(shouldDrop: Bool) {
        copiedRows = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: shouldDrop)
    }

    var message: String {
        String(
            format: String(
                localized: """
                %lld rows were already copied and committed. Keeping the table leaves the rows that \
                made it; deleting it removes the table and everything in it.
                """
            ),
            copiedRows ?? 0
        )
    }
}

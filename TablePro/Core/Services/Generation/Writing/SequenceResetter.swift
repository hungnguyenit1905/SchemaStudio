//
//  SequenceResetter.swift
//  TablePro
//

import Foundation

/// Puts a sequence back above the keys the run wrote by hand.
///
/// This is the step tools of this class skip, and skipping it is why generated
/// data breaks the application's very next insert with a duplicate key: the
/// sequence still hands out 1 while the table already holds 1 through 100000.
/// It runs after the table is written, for every column the run filled itself
/// that the server would otherwise have filled from a sequence.
struct SequenceResetter {
    private let driver: any GenerationDriver

    init(driver: any GenerationDriver) {
        self.driver = driver
    }

    func reset(table: TablePlan) async throws {
        for backed in table.sequenceBackedColumns {
            try await driver.resetSequence(
                table: table.reference,
                column: backed.column,
                sequenceName: backed.sequenceName
            )
        }
    }
}

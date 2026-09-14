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

    /// A failure resetting one column is reported back as a warning rather than
    /// thrown, so one column's failure never stops another column's reset in the
    /// same table, and never turns a run whose rows already committed into a
    /// failed run.
    func reset(table: TablePlan) async -> [GenerationWarning] {
        var warnings: [GenerationWarning] = []
        for backed in table.sequenceBackedColumns {
            do {
                try await driver.resetSequence(
                    table: table.reference,
                    column: backed.column,
                    sequenceName: backed.sequenceName
                )
            } catch {
                warnings.append(
                    GenerationWarning(
                        column: "\(table.qualifiedName).\(backed.column)",
                        message: String(
                            format: String(
                                localized: """
                                Resetting the sequence for %@.%@ failed: %@. Without it the next insert your \
                                application makes may collide with a generated row.
                                """
                            ),
                            table.qualifiedName,
                            backed.column,
                            error.localizedDescription
                        )
                    )
                )
            }
        }
        return warnings
    }
}

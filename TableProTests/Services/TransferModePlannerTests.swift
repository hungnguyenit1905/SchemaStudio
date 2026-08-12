import Foundation
@testable import SchemaStudio
import Testing

@Suite("TransferModePlanner")
struct TransferModePlannerTests {
    private func options(create: Bool) -> TransferOptions {
        TransferOptions(createTargetIfNotExists: create, useSingleTransaction: true, continueOnError: false)
    }

    @Test("Copy over an existing target drops it first")
    func copyExistingTarget() {
        for create in [true, false] {
            let steps = TransferModePlanner.plan(
                mode: .copy,
                options: options(create: create),
                targetExists: true
            )
            #expect(steps == [
                .dropTargetTable,
                .dropTargetTypes,
                .createTargetTypes,
                .createTargetTable,
                .transferRows,
                .createIndexes,
                .createForeignKeys,
                .resetSequences
            ])
        }
    }

    @Test("Copy with no target at the far end drops nothing")
    func copyMissingTarget() {
        for create in [true, false] {
            let steps = TransferModePlanner.plan(
                mode: .copy,
                options: options(create: create),
                targetExists: false
            )
            #expect(!steps.contains(.dropTargetTable))
            #expect(!steps.contains(.dropTargetTypes))
            #expect(steps.first == .createTargetTypes)
        }
    }

    @Test("Empty then transfer leaves an existing table's structure alone")
    func emptyThenTransferExistingTarget() {
        for create in [true, false] {
            let steps = TransferModePlanner.plan(
                mode: .emptyThenTransfer,
                options: options(create: create),
                targetExists: true
            )
            #expect(steps == [.truncateTarget, .transferRows, .resetSequences])
            #expect(!steps.contains(.createIndexes))
            #expect(!steps.contains(.createForeignKeys))
            #expect(!steps.contains(.dropTargetTable))
        }
    }

    @Test("Empty then transfer creates a missing table when the option is on")
    func emptyThenTransferCreatesMissingTarget() {
        let steps = TransferModePlanner.plan(
            mode: .emptyThenTransfer,
            options: options(create: true),
            targetExists: false
        )
        #expect(steps == [
            .createTargetTypes,
            .createTargetTable,
            .transferRows,
            .createIndexes,
            .createForeignKeys,
            .resetSequences
        ])
    }

    @Test("Empty then transfer fails on a missing table when the option is off")
    func emptyThenTransferMissingTargetFails() {
        let steps = TransferModePlanner.plan(
            mode: .emptyThenTransfer,
            options: options(create: false),
            targetExists: false
        )
        #expect(steps == [.failMissingTarget])
    }

    @Test("Every branch that writes rows ends by catching sequences up")
    func successfulBranchesResetSequences() {
        let combinations: [(TransferMode, Bool, Bool)] = [
            (.copy, true, true),
            (.copy, false, false),
            (.emptyThenTransfer, true, false),
            (.emptyThenTransfer, false, true)
        ]
        for (mode, exists, create) in combinations {
            let steps = TransferModePlanner.plan(
                mode: mode,
                options: options(create: create),
                targetExists: exists
            )
            #expect(steps.last == .resetSequences)
            #expect(steps.contains(.transferRows))
        }
    }
}

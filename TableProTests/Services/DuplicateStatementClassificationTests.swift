//
//  DuplicateStatementClassificationTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

/// These are the net that catches a new `DuplicateStatement.Kind` case whose classification
/// nobody thought about. `carriesRowFilter` decides whether a statement reaches the server
/// through the protocol that refuses multi-statement text; `severity` decides whether failing it
/// throws away a finished copy.
@Suite("DuplicateStatementClassification")
struct DuplicateStatementClassificationTests {
    private func statement(_ kind: DuplicateStatement.Kind) -> DuplicateStatement {
        DuplicateStatement(kind: kind, sql: "SELECT 1")
    }

    @Test("Only the row-filter-bearing kinds carry the filter")
    func filterBearingKinds() {
        let carrying: Set<DuplicateStatement.Kind> = [.validateRowFilter, .copyData]
        for kind in DuplicateStatement.Kind.allCases {
            #expect(
                statement(kind).carriesRowFilter == carrying.contains(kind),
                "\(kind) is classified wrong for carriesRowFilter"
            )
        }
    }

    /// Statistics, the table comment and the auto-increment counter are all derived or cosmetic:
    /// losing one leaves a table that is correct and usable, and dropping it would throw away the
    /// rows that already landed.
    @Test("Only statistics, comments and the auto-increment counter are best effort")
    func bestEffortKinds() {
        let bestEffort: Set<DuplicateStatement.Kind> = [.analyze, .tableComment, .resetAutoIncrement]
        for kind in DuplicateStatement.Kind.allCases {
            let expected: DuplicateStatement.Severity = bestEffort.contains(kind) ? .bestEffort : .fatal
            #expect(statement(kind).severity == expected, "\(kind) is classified wrong for severity")
        }
    }

    @Test("Every kind is classified, so a new case cannot slip through untouched")
    func everyKindClassified() {
        #expect(DuplicateStatement.Kind.allCases.count == 16)
        for kind in DuplicateStatement.Kind.allCases {
            _ = statement(kind).carriesRowFilter
            _ = statement(kind).severity
        }
    }

    @Test("A deferred statement keeps its classification")
    func deferredStatementClassification() {
        let dropIndex = DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes)
        #expect(dropIndex.carriesRowFilter == false)
        #expect(dropIndex.severity == .fatal)
        #expect(dropIndex.body == .deferred(.fromHarvestedIndexes))
    }
}

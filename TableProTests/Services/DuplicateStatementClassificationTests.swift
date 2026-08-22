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

    @Test("Only statistics and comments are best effort")
    func bestEffortKinds() {
        let bestEffort: Set<DuplicateStatement.Kind> = [.analyze, .tableComment]
        for kind in DuplicateStatement.Kind.allCases {
            let expected: DuplicateStatement.Severity = bestEffort.contains(kind) ? .bestEffort : .fatal
            #expect(statement(kind).severity == expected, "\(kind) is classified wrong for severity")
        }
    }

    @Test("Every kind is classified, so a new case cannot slip through untouched")
    func everyKindClassified() {
        #expect(DuplicateStatement.Kind.allCases.count == 15)
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

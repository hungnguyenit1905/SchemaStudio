//
//  DuplicateRecoveryTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicateRecovery")
struct DuplicateRecoveryTests {
    @Test("An atomic run on a transactional engine rolls back")
    func atomicRollsBack() {
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: true, copyMode: .atomic, hasCommittedRows: false)
                == .rollback
        )
    }

    /// Chunked mode commits every batch, so there is no open transaction left to undo.
    @Test("Chunked mode cannot roll back and drops the target instead")
    func chunkedDropsTarget() {
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: true, copyMode: .chunked, hasCommittedRows: false)
                == .dropTarget
        )
    }

    /// Dropping a table that already holds millions of copied rows is not a decision to take on
    /// the user's behalf.
    @Test("Chunked mode with committed rows asks before dropping")
    func chunkedWithRowsAsksFirst() {
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: true, copyMode: .chunked, hasCommittedRows: true)
                == .askBeforeDropping
        )
    }

    /// MySQL commits each DDL statement, so even an atomic-looking run has committed objects.
    @Test("An engine without transactional DDL always drops the target")
    func nonTransactionalDropsTarget() {
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: false, copyMode: .atomic, hasCommittedRows: false)
                == .dropTarget
        )
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: false, copyMode: .atomic, hasCommittedRows: true)
                == .askBeforeDropping
        )
    }

    @Test("The cleanup statement drops the qualified target and tolerates it being gone")
    func dropStatementIsQualifiedAndSafe() {
        let quoting = DuplicateFixtures.quoting
        let statement = DuplicateRecovery.dropStatement(
            target: DuplicateTableRef(schema: "public", name: "orders_copy"),
            quoting: quoting
        )
        #expect(statement.kind == .dropTarget)
        #expect(statement.body == .sql("DROP TABLE IF EXISTS \"public\".\"orders_copy\""))
        #expect(statement.severity == .fatal)
        #expect(statement.carriesRowFilter == false)
    }

    @Test("A target with no schema drops by bare name")
    func dropStatementWithoutSchema() {
        let statement = DuplicateRecovery.dropStatement(
            target: DuplicateTableRef(schema: nil, name: "orders_copy"),
            quoting: DuplicateFixtures.quoting
        )
        #expect(statement.body == .sql("DROP TABLE IF EXISTS \"orders_copy\""))
    }
}

@Suite("DuplicateStructureFingerprint")
struct DuplicateStructureFingerprintTests {
    @Test("An unchanged column list matches itself")
    func unchangedMatches() {
        let columns = DuplicateFixtures.serialTable.columns
        #expect(DuplicateStructureFingerprint.matches(columns, columns))
    }

    @Test("A dropped column is detected")
    func droppedColumnDetected() {
        let before = DuplicateFixtures.serialTable.columns
        let after = Array(before.dropLast())
        #expect(!DuplicateStructureFingerprint.matches(before, after))
    }

    @Test("A retyped column is detected")
    func retypedColumnDetected() {
        let before = [DuplicateFixtures.column("id", "integer", primaryKey: true)]
        let after = [DuplicateFixtures.column("id", "bigint", primaryKey: true)]
        #expect(!DuplicateStructureFingerprint.matches(before, after))
    }

    /// A plain column becoming `GENERATED ALWAYS AS IDENTITY` changes whether the copy needs
    /// `OVERRIDING SYSTEM VALUE`, so it has to invalidate the plan.
    @Test("A column becoming an identity column is detected")
    func identityChangeDetected() {
        let before = [DuplicateFixtures.column("id", primaryKey: true)]
        let after = [DuplicateFixtures.column("id", primaryKey: true, identity: .always)]
        #expect(!DuplicateStructureFingerprint.matches(before, after))
    }

    @Test("A column becoming generated is detected, because it leaves the copy column list")
    func generatedChangeDetected() {
        let before = [DuplicateFixtures.column("total", "numeric")]
        let after = [DuplicateFixtures.column("total", "numeric", generated: true)]
        #expect(!DuplicateStructureFingerprint.matches(before, after))
    }

    @Test("Reordered columns are detected, since the copy lists them positionally")
    func reorderDetected() {
        let first = DuplicateFixtures.column("a")
        let second = DuplicateFixtures.column("b")
        #expect(!DuplicateStructureFingerprint.matches([first, second], [second, first]))
    }
}

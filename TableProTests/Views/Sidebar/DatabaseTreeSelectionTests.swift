//
//  DatabaseTreeSelectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("Database Tree Selection Identity")
struct DatabaseTreeSelectionTests {
    private static let connection = UUID()

    private func makeTable(_ name: String, schema: String? = nil) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private func makeRef(
        database: String,
        schema: String?,
        table: TableInfo,
        connectionId: UUID = DatabaseTreeSelectionTests.connection
    ) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    @Test("Same database, schema, and table in different connections produces distinct refs")
    func sameNameDifferentConnectionIsDistinct() {
        let table = makeTable("users", schema: "public")
        let inFirst = makeRef(database: "shop", schema: "public", table: table, connectionId: UUID())
        let inSecond = makeRef(database: "shop", schema: "public", table: table, connectionId: UUID())

        #expect(inFirst != inSecond)
        #expect(inFirst.id != inSecond.id)
        #expect(Set([inFirst, inSecond]).count == 2)
    }

    @Test("Same table name in different databases produces distinct refs")
    func sameNameDifferentDatabaseIsDistinct() {
        let table = makeTable("users")
        let inDb1 = makeRef(database: "db1", schema: nil, table: table)
        let inDb2 = makeRef(database: "db2", schema: nil, table: table)

        #expect(inDb1 != inDb2)
        #expect(inDb1.id != inDb2.id)
        #expect(Set([inDb1, inDb2]).count == 2)
    }

    @Test("Same public schema in different databases produces distinct refs")
    func samePublicSchemaDifferentDatabaseIsDistinct() {
        let table = makeTable("users", schema: "public")
        let inDb1 = makeRef(database: "db1", schema: "public", table: table)
        let inDb2 = makeRef(database: "db2", schema: "public", table: table)

        #expect(inDb1 != inDb2)
        #expect(Set([inDb1, inDb2]).count == 2)
    }

    @Test("Identical database, schema, and table are equal")
    func identicalRefsAreEqual() {
        let lhs = makeRef(database: "db1", schema: "public", table: makeTable("users", schema: "public"))
        let rhs = makeRef(database: "db1", schema: "public", table: makeTable("users", schema: "public"))

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }
}

@Suite("Selection Delta")
struct SelectionDeltaTests {
    @Test("Single addition is detected")
    func singleAdditionDetected() {
        let old: Set = [1, 2]
        let new: Set = [1, 2, 3]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == 3)
    }

    @Test("No addition returns nil")
    func noAdditionReturnsNil() {
        let set: Set = [1, 2]
        #expect(SelectionDelta.singleAddition(old: set, new: set) == nil)
    }

    @Test("Removal returns nil")
    func removalReturnsNil() {
        let old: Set = [1, 2, 3]
        let new: Set = [1, 2]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == nil)
    }

    @Test("Multiple additions return nil")
    func multipleAdditionsReturnNil() {
        let old: Set = [1]
        let new: Set = [1, 2, 3]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == nil)
    }
}

//
//  TableSelectionChangeTests.swift
//  TableProTests
//
//  Tests for TableSelectionAction — the pure decision logic that determines
//  whether a sidebar selection change should trigger table navigation.
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TableSelectionAction")
struct TableSelectionChangeTests {
    // MARK: - Single click (exactly one table added)

    @Test("Single click adds one table — navigate to it")
    func singleClickNavigates() {
        let orders = TestFixtures.makeTableRef(name: "orders")
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [orders])
        #expect(action == .navigate(ref: orders))
    }

    @Test("Single click on a view navigates with the view ref")
    func singleClickOnView() {
        let view = TestFixtures.makeTableRef(name: "my_view", type: .view)
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [view])
        #expect(action == .navigate(ref: view))
    }

    @Test("Cmd+click adds exactly one more table — navigate to it")
    func cmdClickAddsOneMore() {
        let existing = TestFixtures.makeTableRef(name: "users")
        let added = TestFixtures.makeTableRef(name: "orders")
        let action = TableSelectionAction.resolve(oldTables: [existing], newTables: [existing, added])
        #expect(action == .navigate(ref: added))
    }

    @Test("The same table name in two connections counts as two distinct additions")
    func sameNameInTwoConnectionsIsNotOneAddition() {
        let first = TestFixtures.makeTableRef(name: "users", connectionId: UUID())
        let second = TestFixtures.makeTableRef(name: "users", connectionId: UUID())
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [first, second])
        #expect(action == .noNavigation)
    }

    // MARK: - Multi-selection (Cmd+A, Shift+click)

    @Test("Cmd+A adds many tables — no navigation")
    func cmdANoNavigation() {
        let new: Set<DatabaseTreeTableRef> = [
            TestFixtures.makeTableRef(name: "users"),
            TestFixtures.makeTableRef(name: "orders"),
            TestFixtures.makeTableRef(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: [], newTables: new)
        #expect(action == .noNavigation)
    }

    @Test("Shift+click adds multiple tables — no navigation")
    func shiftClickNoNavigation() {
        let existing = TestFixtures.makeTableRef(name: "users")
        let new: Set<DatabaseTreeTableRef> = [
            existing,
            TestFixtures.makeTableRef(name: "orders"),
            TestFixtures.makeTableRef(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: [existing], newTables: new)
        #expect(action == .noNavigation)
    }

    // MARK: - Deselection

    @Test("Deselect tables (none added) — no navigation")
    func deselectNoNavigation() {
        let users = TestFixtures.makeTableRef(name: "users")
        let old: Set<DatabaseTreeTableRef> = [users, TestFixtures.makeTableRef(name: "orders")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: [users])
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let old: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: [])
        #expect(action == .noNavigation)
    }

    // MARK: - No change

    @Test("No change (same set) — no navigation")
    func noChangeNoNavigation() {
        let tables: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: tables, newTables: tables)
        #expect(action == .noNavigation)
    }

    @Test("Empty to empty — no navigation")
    func emptyToEmptyNoNavigation() {
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [])
        #expect(action == .noNavigation)
    }
}

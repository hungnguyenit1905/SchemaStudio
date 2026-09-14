//
//  DependencyResolverTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DependencyResolver")
struct DependencyResolverTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func names(_ order: TableDependencyOrder) -> [String] {
        order.ordered.map(\.table)
    }

    private func position(_ order: TableDependencyOrder, _ table: String) -> Int? {
        order.ordered.firstIndex { $0.table == table }
    }

    @Test("A linear chain is ordered parent before child")
    func linearChain() throws {
        let order = try DependencyResolver().resolve(Fixtures.shopSchema)
        #expect(names(order) == ["customers", "orders", "order_items"])
        #expect(order.deferredColumns.isEmpty)
        #expect(!order.requiresConstraintDisable)
    }

    @Test("A chain given in reverse still resolves parent first")
    func reversedInputStillOrders() throws {
        let order = try DependencyResolver().resolve(Fixtures.shopSchema.reversed())
        #expect(try #require(position(order, "customers")) < #require(position(order, "orders")))
        #expect(try #require(position(order, "orders")) < #require(position(order, "order_items")))
    }

    @Test("Disjoint components both appear exactly once")
    func disjointComponents() throws {
        let schema = Fixtures.shopSchema + [
            Fixtures.table("audit_log", columns: [Fixtures.identityColumn()])
        ]
        let order = try DependencyResolver().resolve(schema)
        #expect(order.ordered.count == 4)
        #expect(Set(names(order)).count == 4)
    }

    @Test("A self-reference resolves and is recorded as a second pass")
    func selfReferenceIsNotACycle() throws {
        let employees = Fixtures.table(
            "employees",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "manager_id", dataType: "bigint", isNullable: true)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "manager_id", to: "employees")]
        )
        let order = try DependencyResolver().resolve([employees])
        #expect(names(order) == ["employees"])
        let reference = GenerationTableReference(schema: "public", table: "employees")
        #expect(order.deferredColumns[reference] == ["manager_id"])
    }

    @Test("A two-table cycle is broken at the nullable foreign key")
    func twoCycleBrokenAtNullableKey() throws {
        let authors = Fixtures.table(
            "authors",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "featured_book_id", dataType: "bigint", isNullable: true)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "featured_book_id", to: "books")]
        )
        let books = Fixtures.table(
            "books",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "author_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "author_id", to: "authors")]
        )
        let order = try DependencyResolver().resolve([authors, books])
        #expect(names(order) == ["authors", "books"])
        let reference = GenerationTableReference(schema: "public", table: "authors")
        #expect(order.deferredColumns[reference] == ["featured_book_id"])
        #expect(!order.requiresConstraintDisable)
    }

    @Test("A cycle with no nullable key fails and names both tables")
    func twoCycleAllRequiredFails() {
        let left = Fixtures.table(
            "left",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "right_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "right_id", to: "right")]
        )
        let right = Fixtures.table(
            "right",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "left_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "left_id", to: "left")]
        )
        #expect(throws: GenerationError.tableDependencyCycle(tables: ["public.left", "public.right"])) {
            _ = try DependencyResolver().resolve([left, right])
        }
    }

    @Test("A cycle with no nullable key is allowed when constraints can be disabled")
    func twoCycleAllRequiredUsesConstraintDisable() throws {
        let left = Fixtures.table(
            "left",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "right_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "right_id", to: "right")]
        )
        let right = Fixtures.table(
            "right",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "left_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "left_id", to: "left")]
        )
        let order = try DependencyResolver(canDisableConstraints: true).resolve([left, right])
        #expect(order.requiresConstraintDisable)
        #expect(order.ordered.count == 2)
    }

    @Test("A three-table cycle fails and names all three")
    func threeCycleFails() {
        let tables = ["a", "b", "c"].enumerated().map { index, name in
            let parent = ["a", "b", "c"][(index + 1) % 3]
            return Fixtures.table(
                name,
                columns: [
                    Fixtures.identityColumn(),
                    PluginColumnInfo(name: "next_id", dataType: "bigint", isNullable: false)
                ],
                foreignKeys: [Fixtures.foreignKey(from: "next_id", to: parent)]
            )
        }
        #expect(throws: GenerationError.tableDependencyCycle(tables: ["public.a", "public.b", "public.c"])) {
            _ = try DependencyResolver().resolve(tables)
        }
    }

    @Test("A diamond puts the root first and the join last")
    func diamondOrder() throws {
        let root = Fixtures.table("root", columns: [Fixtures.identityColumn()])
        let left = Fixtures.table(
            "left",
            columns: [Fixtures.identityColumn(), PluginColumnInfo(name: "root_id", dataType: "bigint")],
            foreignKeys: [Fixtures.foreignKey(from: "root_id", to: "root")]
        )
        let right = Fixtures.table(
            "right",
            columns: [Fixtures.identityColumn(), PluginColumnInfo(name: "root_id", dataType: "bigint")],
            foreignKeys: [Fixtures.foreignKey(from: "root_id", to: "root")]
        )
        let join = Fixtures.table(
            "join",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "left_id", dataType: "bigint"),
                PluginColumnInfo(name: "right_id", dataType: "bigint")
            ],
            foreignKeys: [
                Fixtures.foreignKey(from: "left_id", to: "left"),
                Fixtures.foreignKey(from: "right_id", to: "right")
            ]
        )
        let order = try DependencyResolver().resolve([join, left, right, root])
        #expect(position(order, "root") == 0)
        #expect(position(order, "join") == 3)
    }

    @Test("A table passed in twice does not trap building the in-degree map")
    func duplicateTableDoesNotTrap() throws {
        let order = try DependencyResolver().resolve(Fixtures.shopSchema + [Fixtures.shopSchema[0]])
        #expect(names(order) == ["customers", "orders", "order_items"])
    }

    @Test("A foreign key to a table outside the run is not an edge")
    func foreignKeyOutsideTheRunIsIgnored() throws {
        let orders = Fixtures.table(
            "orders",
            columns: [
                Fixtures.identityColumn(),
                PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [Fixtures.foreignKey(from: "customer_id", to: "customers")]
        )
        let order = try DependencyResolver().resolve([orders])
        #expect(names(order) == ["orders"])
        #expect(order.deferredColumns.isEmpty)
    }
}

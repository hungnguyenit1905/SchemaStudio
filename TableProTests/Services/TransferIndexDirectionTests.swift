//
//  TransferIndexDirectionTests.swift
//  TableProTests
//
//  Covers how a descending index survives, or is reported when it cannot.
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer index direction")
struct TransferIndexDirectionTests {
    @Test("MySQL keeps the direction from 8.0 and MariaDB from 10.8")
    func mysqlVersionGate() {
        #expect(TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "8.0.36"))
        #expect(TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "9.2.0"))
        #expect(!TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "5.7.44"))
        #expect(TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "10.11.6-MariaDB"))
        #expect(!TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "10.6.16-MariaDB"))
    }

    @Test("An unknown MySQL version is treated as unable rather than assumed able")
    func unknownMysqlVersion() {
        #expect(!TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: nil))
        #expect(!TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .mysql, version: "unknown"))
    }

    @Test("Engines that always store the direction are not gated on a version")
    func otherEngines() {
        #expect(TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .postgresql, version: nil))
        #expect(TransferIndexDirectionSupport.keepsDescendingIndex(targetType: .sqlite, version: "3.45.0"))
    }

    @Test("A target that keeps the direction carries it into the plan")
    func directionSurvives() {
        let structure = TransferStructureBuilder.build(
            table: "events",
            columns: [column("id"), column("created_at")],
            indexes: [index(name: "by_recent", columns: ["created_at"], descending: ["created_at"])],
            foreignKeys: [],
            targetSchema: nil,
            keepsDescendingIndex: true
        )
        #expect(structure.indexes.first?.descendingColumns == ["created_at"])
        #expect(structure.warnings.isEmpty)
    }

    @Test("A target that cannot store it drops the direction and says so")
    func directionReported() {
        let structure = TransferStructureBuilder.build(
            table: "events",
            columns: [column("id"), column("created_at")],
            indexes: [index(name: "by_recent", columns: ["created_at"], descending: ["created_at"])],
            foreignKeys: [],
            targetSchema: nil,
            keepsDescendingIndex: false
        )
        #expect(structure.indexes.first?.descendingColumns.isEmpty == true)
        #expect(structure.warnings.contains { warning in
            if case .indexSilentlyIgnored(_, let name, _) = warning { return name == "by_recent" }
            return false
        })
    }

    @Test("An ascending index draws no warning on a target that cannot store direction")
    func ascendingIndexIsQuiet() {
        let structure = TransferStructureBuilder.build(
            table: "events",
            columns: [column("id")],
            indexes: [index(name: "by_id", columns: ["id"], descending: [])],
            foreignKeys: [],
            targetSchema: nil,
            keepsDescendingIndex: false
        )
        #expect(structure.warnings.isEmpty)
    }

    @Test("A driver that reports no direction reads as every column ascending")
    func absentDirection() {
        let info = PluginIndexInfo(name: "by_id", columns: ["id"], type: "BTREE")
        #expect(info.descendingColumns == nil)

        let structure = TransferStructureBuilder.build(
            table: "events",
            columns: [column("id")],
            indexes: [info],
            foreignKeys: [],
            targetSchema: nil,
            keepsDescendingIndex: false
        )
        #expect(structure.indexes.first?.descendingColumns.isEmpty == true)
        #expect(structure.warnings.isEmpty)
    }

    private func column(_ name: String) -> PluginColumnInfo {
        PluginColumnInfo(name: name, dataType: "int", isNullable: true)
    }

    private func index(name: String, columns: [String], descending: Set<String>) -> PluginIndexInfo {
        PluginIndexInfo(
            name: name,
            columns: columns,
            isUnique: false,
            isPrimary: false,
            type: "BTREE",
            columnPrefixes: nil,
            whereClause: nil,
            descendingColumns: descending
        )
    }
}

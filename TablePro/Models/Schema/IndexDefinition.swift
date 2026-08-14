//
//  IndexDefinition.swift
//  TablePro
//
//  Represents an index definition for schema editing.
//

import Foundation
import TableProPluginKit

/// Index definition for schema modification (editable structure tab)
struct EditableIndexDefinition: Hashable, Codable, Identifiable {
    let id: UUID
    var name: String
    var columns: [String]
    var type: IndexType
    var isUnique: Bool
    var isPrimary: Bool
    var comment: String?
    var columnPrefixes: [String: Int] = [:]
    var whereClause: String?

    /// Carried through editing so saving an index the editor did not change the
    /// direction of does not quietly rebuild it ascending.
    var descendingColumns: Set<String> = []

    enum IndexType: String, Codable, CaseIterable {
        case btree = "BTREE"
        case hash = "HASH"
        case fulltext = "FULLTEXT"
        case spatial = "SPATIAL" // MySQL only
        case gin = "GIN" // PostgreSQL only
        case gist = "GIST" // PostgreSQL only
        case brin = "BRIN" // PostgreSQL only
    }

    /// Create a placeholder index for adding new indexes
    static func placeholder() -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: "",
            columns: [],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil,
            columnPrefixes: [:],
            whereClause: nil
        )
    }

    /// Check if this definition is valid (not a placeholder)
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !columns.isEmpty
    }

    /// Create from existing IndexInfo
    static func from(_ indexInfo: IndexInfo) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: indexInfo.id,
            name: indexInfo.name,
            columns: indexInfo.columns,
            type: IndexType(rawValue: indexInfo.type.uppercased()) ?? .btree,
            isUnique: indexInfo.isUnique,
            isPrimary: indexInfo.isPrimary,
            comment: nil,
            columnPrefixes: indexInfo.columnPrefixes ?? [:],
            whereClause: indexInfo.whereClause,
            descendingColumns: indexInfo.descendingColumns
        )
    }

    func toPlugin() -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: name,
            columns: columns,
            isUnique: isUnique,
            indexType: type.rawValue,
            columnPrefixes: columnPrefixes.isEmpty ? nil : columnPrefixes,
            whereClause: whereClause,
            descendingColumns: descendingColumns
        )
    }

    /// Convert back to IndexInfo
    func toIndexInfo() -> IndexInfo {
        IndexInfo(
            name: name,
            columns: columns,
            isUnique: isUnique,
            isPrimary: isPrimary,
            type: type.rawValue,
            columnPrefixes: columnPrefixes.isEmpty ? nil : columnPrefixes,
            whereClause: whereClause,
            descendingColumns: descendingColumns
        )
    }
}

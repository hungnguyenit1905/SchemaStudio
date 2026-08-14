import Foundation

public struct PluginIndexInfo: Codable, Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String
    public let columnPrefixes: [String: Int]?
    public let whereClause: String?

    /// The columns the index sorts in descending order. It is optional rather
    /// than an empty set by default so a payload written before the field
    /// existed still decodes, and so "the driver does not report direction"
    /// stays distinguishable from "every column is ascending".
    public let descendingColumns: Set<String>?

    /// Kept at its published signature so plugins built against an earlier
    /// PluginKit keep resolving the symbol their witness table references.
    /// `@_disfavoredOverload` steers new call sites to the full initializer.
    @_disfavoredOverload
    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE",
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        descendingColumns = nil
    }

    public init(
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool,
        type: String,
        columnPrefixes: [String: Int]?,
        whereClause: String?,
        descendingColumns: Set<String>?
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        self.descendingColumns = descendingColumns
    }
}

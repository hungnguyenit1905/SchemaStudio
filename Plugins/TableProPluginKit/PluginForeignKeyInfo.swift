import Foundation

public struct PluginForeignKeyInfo: Codable, Sendable {
    public let name: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let onDelete: String
    public let onUpdate: String

    /// Every local column in this constraint, in constraint order. `column`
    /// stays the first element so readers that only understand single-column
    /// keys keep working unchanged.
    public let localColumns: [String]

    /// Every referenced column, positionally paired with `localColumns`.
    /// `referencedColumn` stays the first element.
    public let referencedColumns: [String]

    @_disfavoredOverload
    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        localColumns = [column]
        referencedColumns = [referencedColumn]
    }

    /// Composite form. `localColumns` and `referencedColumns` must be non-empty
    /// and the same length; the singular `column` and `referencedColumn` are
    /// derived from their first elements so both readerships see the same key.
    public init(
        name: String,
        localColumns: [String],
        referencedTable: String,
        referencedColumns: [String],
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        column = localColumns.first ?? ""
        self.referencedTable = referencedTable
        referencedColumn = referencedColumns.first ?? ""
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.localColumns = localColumns
        self.referencedColumns = referencedColumns
    }
}

// Hand-written for the same reason as `PluginColumnInfo`: synthesized decoding
// of a non-optional array throws `keyNotFound` on a pre-v20 payload. A payload
// without the arrays backfills them from the singular fields, so an old
// serialized key still describes itself completely. Single-column keys omit the
// arrays on encode, keeping their payload identical to pre-v20.
extension PluginForeignKeyInfo {
    private enum CodingKeys: String, CodingKey {
        case name
        case column
        case referencedTable
        case referencedColumn
        case referencedSchema
        case onDelete
        case onUpdate
        case localColumns
        case referencedColumns
    }

    private var isSingleColumn: Bool {
        localColumns == [column] && referencedColumns == [referencedColumn]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        column = try container.decode(String.self, forKey: .column)
        referencedTable = try container.decode(String.self, forKey: .referencedTable)
        referencedColumn = try container.decode(String.self, forKey: .referencedColumn)
        referencedSchema = try container.decodeIfPresent(String.self, forKey: .referencedSchema)
        onDelete = try container.decode(String.self, forKey: .onDelete)
        onUpdate = try container.decode(String.self, forKey: .onUpdate)

        let decodedLocal = try container.decodeIfPresent([String].self, forKey: .localColumns)
        let decodedReferenced = try container.decodeIfPresent([String].self, forKey: .referencedColumns)
        localColumns = decodedLocal ?? [column]
        referencedColumns = decodedReferenced ?? [referencedColumn]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(column, forKey: .column)
        try container.encode(referencedTable, forKey: .referencedTable)
        try container.encode(referencedColumn, forKey: .referencedColumn)
        try container.encodeIfPresent(referencedSchema, forKey: .referencedSchema)
        try container.encode(onDelete, forKey: .onDelete)
        try container.encode(onUpdate, forKey: .onUpdate)
        guard !isSingleColumn else { return }
        try container.encode(localColumns, forKey: .localColumns)
        try container.encode(referencedColumns, forKey: .referencedColumns)
    }
}

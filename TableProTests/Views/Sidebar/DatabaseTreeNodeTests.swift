import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DatabaseTreeNode")
struct DatabaseTreeNodeTests {
    private static let connection = UUID()

    private func tableRef(
        _ name: String,
        schema: String? = "public",
        connectionId: UUID = DatabaseTreeNodeTests.connection
    ) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            connectionId: connectionId,
            database: "shop",
            schema: schema,
            table: TableInfo(name: name, type: .table, rowCount: 0)
        )
    }

    @Test("identity helpers are unique across kinds and stable")
    func identityHelpers() {
        let connection = Self.connection
        let databaseId = DatabaseTreeNode.databaseId(connectionId: connection, database: "shop")
        let schemaId = DatabaseTreeNode.schemaId(connectionId: connection, database: "shop", schema: "public")
        let tableId = DatabaseTreeNode.tableId(tableRef("users"))

        #expect(databaseId == DatabaseTreeNode.databaseId(connectionId: connection, database: "shop"))
        #expect(Set([databaseId, schemaId, tableId]).count == 3)
    }

    @Test("two connections sharing a database name do not share node ids")
    func nodeIdsCarryConnectionIdentity() {
        let first = UUID()
        let second = UUID()

        #expect(
            DatabaseTreeNode.databaseId(connectionId: first, database: "shop")
                != DatabaseTreeNode.databaseId(connectionId: second, database: "shop")
        )
        #expect(
            DatabaseTreeNode.schemaId(connectionId: first, database: "shop", schema: "public")
                != DatabaseTreeNode.schemaId(connectionId: second, database: "shop", schema: "public")
        )
        #expect(
            DatabaseTreeNode.tableId(tableRef("users", connectionId: first))
                != DatabaseTreeNode.tableId(tableRef("users", connectionId: second))
        )
    }

    @Test("every node under a connection resolves that connection")
    func connectionIdResolution() {
        let connection = Self.connection
        let database = DatabaseTreeNode(
            id: "d", kind: .database(connectionId: connection, metadata: .minimal(name: "shop"))
        )
        let schema = DatabaseTreeNode(
            id: "s", kind: .schema(connectionId: connection, database: "shop", schema: "public")
        )
        let table = DatabaseTreeNode(id: "t", kind: .table(tableRef("users")))
        let root = DatabaseTreeNode(id: "r", kind: .connectionRoot)

        #expect(database.connectionId == connection)
        #expect(schema.connectionId == connection)
        #expect(table.connectionId == connection)
        #expect(root.connectionId == nil)
    }

    @Test("status ids are unique per parent and per status")
    func statusIds() {
        let loading = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .loading)
        let empty = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .empty)
        let errored = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .error("x"))
        let otherParent = DatabaseTreeNode.statusId(parentId: "db\u{1}other", status: .loading)

        #expect(Set([loading, empty, errored, otherParent]).count == 4)
    }

    private func partitionedRef(_ name: String, schema: String? = "public") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            connectionId: Self.connection,
            database: "shop",
            schema: schema,
            table: TableInfo(name: name, type: .partitionedTable, rowCount: 0)
        )
    }

    @Test("database, schema, and partitioned table nodes are expandable")
    func expandable() {
        let database = DatabaseTreeNode(
            id: "d", kind: .database(connectionId: Self.connection, metadata: .minimal(name: "shop"))
        )
        let schema = DatabaseTreeNode(
            id: "s", kind: .schema(connectionId: Self.connection, database: "shop", schema: "public")
        )
        let table = DatabaseTreeNode(id: "t", kind: .table(tableRef("users")))
        let status = DatabaseTreeNode(id: "x", kind: .status(.loading))

        #expect(database.isExpandable)
        #expect(schema.isExpandable)
        #expect(!table.isExpandable)
        #expect(!status.isExpandable)
    }

    @Test("a partitioned table expands but its partitions and other kinds do not")
    func partitionedTableExpandable() {
        let parent = DatabaseTreeNode(id: "p", kind: .table(partitionedRef("orders")))
        let leafPartition = DatabaseTreeNode(id: "c", kind: .table(tableRef("orders_2024_01")))
        let subpartitioned = DatabaseTreeNode(id: "sp", kind: .table(partitionedRef("orders_2024_02")))
        let recent = DatabaseTreeNode(id: "r", kind: .recentTable(partitionedRef("orders")))

        #expect(parent.isExpandable)
        #expect(!leafPartition.isExpandable)
        #expect(subpartitioned.isExpandable)
        #expect(!recent.isExpandable)
    }

    @Test("a partition child gets its own node identity, distinct from its parent")
    func partitionChildIdentity() {
        let parentId = DatabaseTreeNode.tableId(partitionedRef("orders"))
        let childId = DatabaseTreeNode.tableId(tableRef("orders_2024_01"))
        #expect(parentId != childId)
    }

    @Test("tableRef is returned only for table nodes")
    func tableRefExtraction() {
        let ref = tableRef("users")
        let table = DatabaseTreeNode(id: "t", kind: .table(ref))
        let schema = DatabaseTreeNode(
            id: "s", kind: .schema(connectionId: Self.connection, database: "shop", schema: "public")
        )

        #expect(table.tableRef == ref)
        #expect(schema.tableRef == nil)
    }
}

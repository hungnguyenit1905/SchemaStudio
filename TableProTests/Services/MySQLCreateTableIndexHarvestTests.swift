//
//  MySQLCreateTableIndexHarvestTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

/// Fixtures copied from real `SHOW CREATE TABLE` output. MySQL 8 and MariaDB 10.11 do not print
/// the same statement, and the reader has to agree with both without guessing.
enum MySQLCreateTableFixtures {
    static let mysql8 = """
    CREATE TABLE `orders_copy` (
      `id` int NOT NULL AUTO_INCREMENT,
      `email` varchar(255) COLLATE utf8mb4_0900_ai_ci DEFAULT NULL,
      `tenant_id` int NOT NULL,
      `body` text COLLATE utf8mb4_0900_ai_ci,
      `total` decimal(10,2) GENERATED ALWAYS AS ((`id` * 2)) STORED,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_orders_email` (`email`),
      KEY `idx_orders_tenant` (`tenant_id`,`id`),
      KEY `idx_orders_email_prefix` (`email`(10)),
      FULLTEXT KEY `ft_orders_body` (`body`),
      CONSTRAINT `chk_orders_total` CHECK ((`total` >= 0))
    ) ENGINE=InnoDB AUTO_INCREMENT=91 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
    """

    static let mariadb = """
    CREATE TABLE `orders_copy` (
      `id` int(11) NOT NULL AUTO_INCREMENT,
      `geom` geometry NOT NULL,
      `label` varchar(64) DEFAULT NULL,
      PRIMARY KEY (`id`),
      SPATIAL KEY `sp_orders_geom` (`geom`),
      KEY `idx_orders_label` (`label`) USING BTREE COMMENT 'lookup, not (unique)'
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    """

    static let functionalIndex = """
    CREATE TABLE `orders_copy` (
      `id` int NOT NULL,
      `email` varchar(255) DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_orders_lower_email` ((lower(`email`)))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """

    static let foreignKeyTable = """
    CREATE TABLE `lines_copy` (
      `id` int NOT NULL,
      `order_id` int NOT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_lines_order` (`order_id`),
      CONSTRAINT `fk_lines_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """
}

@Suite("MySQLCreateTableIndexHarvest")
struct MySQLCreateTableIndexHarvestTests {
    @Test("Every secondary index kind MySQL 8 prints is read")
    func readsMySql8Indexes() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mysql8)
        #expect(
            indexes.map(\.name) == [
                "uq_orders_email",
                "idx_orders_tenant",
                "idx_orders_email_prefix",
                "ft_orders_body"
            ]
        )
    }

    /// The primary key is a constraint `CREATE TABLE … LIKE` already carries. Dropping and
    /// replaying it would fight the engine rather than help it.
    @Test("The primary key is never read as an index")
    func skipsPrimaryKey() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mysql8)
        #expect(!indexes.contains { $0.definition.uppercased().hasPrefix("PRIMARY KEY") })
    }

    @Test("CHECK and FOREIGN KEY constraints are never read as indexes")
    func skipsConstraints() {
        let mysql = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mysql8)
        #expect(!mysql.contains { $0.definition.contains("CHECK") })

        let referencing = MySQLCreateTableIndexHarvest.indexes(
            inCreateTable: MySQLCreateTableFixtures.foreignKeyTable
        )
        #expect(referencing.map(\.name) == ["idx_lines_order"])
    }

    /// A prefix length is inside the parentheses, which the reader never opens. Losing it turns a
    /// 10-byte index into a full-column one, which is a different index.
    @Test("A prefix length survives because nothing inside the parentheses is rewritten")
    func keepsPrefixLength() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mysql8)
        let prefixed = indexes.first { $0.name == "idx_orders_email_prefix" }
        #expect(prefixed?.definition == "KEY `idx_orders_email_prefix` (`email`(10))")
    }

    @Test("A composite index keeps its column order and its trailing comma is dropped")
    func keepsCompositeOrder() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mysql8)
        #expect(
            indexes.first { $0.name == "idx_orders_tenant" }?.definition
                == "KEY `idx_orders_tenant` (`tenant_id`,`id`)"
        )
    }

    /// MariaDB prints `USING BTREE` and an index comment after the column list, and the comment
    /// here contains an unmatched-looking bracket on purpose.
    @Test("MariaDB spatial indexes and trailing clauses are kept verbatim")
    func readsMariaDbIndexes() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(inCreateTable: MySQLCreateTableFixtures.mariadb)
        #expect(indexes.map(\.name) == ["sp_orders_geom", "idx_orders_label"])
        #expect(
            indexes.last?.definition
                == "KEY `idx_orders_label` (`label`) USING BTREE COMMENT 'lookup, not (unique)'"
        )
    }

    /// The plan-time guard on `information_schema.STATISTICS.EXPRESSION` is what keeps a
    /// functional index out of the drop-and-replay path. This proves the reader does not mangle
    /// one if it ever does see it: nested parentheses stay as printed.
    @Test("A functional index is returned verbatim, nested parentheses included")
    func keepsFunctionalIndexVerbatim() {
        let indexes = MySQLCreateTableIndexHarvest.indexes(
            inCreateTable: MySQLCreateTableFixtures.functionalIndex
        )
        #expect(indexes.map(\.definition) == ["KEY `idx_orders_lower_email` ((lower(`email`)))"])
    }

    @Test("An embedded backquote in an index name is unescaped for the drop clause")
    func unescapesBackquotedName() {
        let statement = """
        CREATE TABLE `t` (
          `a` int NOT NULL,
          KEY `odd``name` (`a`)
        ) ENGINE=InnoDB
        """
        #expect(MySQLCreateTableIndexHarvest.indexes(inCreateTable: statement).map(\.name) == ["odd`name"])
    }

    /// A line whose parentheses do not close continued somewhere this reader does not follow.
    /// Skipping it loses the speedup for that index; guessing would lose the index.
    @Test("A line the reader cannot place is skipped rather than guessed at")
    func skipsUnplaceableLines() {
        let statement = """
        CREATE TABLE `t` (
          `a` int NOT NULL,
          KEY `idx_broken` (`a`,
          KEY idx_unquoted (`a`),
          KEY `idx_good` (`a`)
        ) ENGINE=InnoDB
        """
        #expect(MySQLCreateTableIndexHarvest.indexes(inCreateTable: statement).map(\.name) == ["idx_good"])
    }

    @Test("A create statement with no secondary index yields nothing")
    func noIndexesYieldsEmpty() {
        let statement = """
        CREATE TABLE `t` (
          `a` int NOT NULL,
          PRIMARY KEY (`a`)
        ) ENGINE=InnoDB
        """
        #expect(MySQLCreateTableIndexHarvest.indexes(inCreateTable: statement).isEmpty)
    }
}

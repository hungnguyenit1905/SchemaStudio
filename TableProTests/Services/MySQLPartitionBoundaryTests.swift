//
//  MySQLPartitionBoundaryTests.swift
//  TableProTests
//
//  Covers the equal-row partition boundaries used for parallel reads.
//
import Foundation
import Testing

@Suite("MySQL partition boundaries")
struct MySQLPartitionBoundaryTests {
    @Test("The table minimum is not a split point")
    func dropsFirstBucketMinimum() {
        let boundaries = MySQLPartitionBoundarySQL.boundaries(
            fromBucketMinimums: ["1", "5000", "9000", "9990"]
        )
        #expect(boundaries == ["5000", "9000", "9990"])
    }

    @Test("A single bucket yields no split point")
    func singleBucket() {
        #expect(MySQLPartitionBoundarySQL.boundaries(fromBucketMinimums: ["1"]).isEmpty)
        #expect(MySQLPartitionBoundarySQL.boundaries(fromBucketMinimums: []).isEmpty)
    }

    @Test("The sample query buckets by row count and skips NULL keys")
    func percentileQueryShape() {
        let sql = MySQLPartitionBoundarySQL.percentileQuery(
            table: "`orders`",
            column: "`id`",
            partitions: 4
        )
        #expect(sql.contains("NTILE(4) OVER (ORDER BY `id`)"))
        #expect(sql.contains("WHERE `id` IS NOT NULL"))
        #expect(sql.contains("GROUP BY bucket ORDER BY bucket"))
    }

    @Test("Window functions are claimed only where the server has them")
    func windowFunctionSupport() {
        #expect(MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "8.0.36", isMariaDB: false))
        #expect(MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "9.1.0", isMariaDB: false))
        #expect(!MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "5.7.44", isMariaDB: false))
        #expect(MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "10.2.6-MariaDB", isMariaDB: true))
        #expect(MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "11.4.2-MariaDB", isMariaDB: true))
        #expect(!MySQLPartitionBoundarySQL.supportsWindowFunctions(version: "10.1.48-MariaDB", isMariaDB: true))
        #expect(!MySQLPartitionBoundarySQL.supportsWindowFunctions(version: nil, isMariaDB: false))
    }
}

// MARK: - Local Copy of the Plugin Helper

// Copied from Plugins/MySQLDriverPlugin/MySQLPartitionBoundarySQL.swift because
// the plugin is a bundle target and cannot be imported with @testable import,
// the same arrangement GeometryWKBParserTests uses.

private enum MySQLPartitionBoundarySQL {
    static func percentileQuery(table: String, column: String, partitions: Int) -> String {
        """
        SELECT MIN(bucket_key) FROM ( \
        SELECT \(column) AS bucket_key, NTILE(\(partitions)) OVER (ORDER BY \(column)) AS bucket \
        FROM \(table) WHERE \(column) IS NOT NULL \
        ) AS sampled GROUP BY bucket ORDER BY bucket
        """
    }

    static func boundaries(fromBucketMinimums minimums: [String]) -> [String] {
        guard minimums.count > 1 else { return [] }
        return Array(minimums.dropFirst())
    }

    static func supportsWindowFunctions(version: String?, isMariaDB: Bool) -> Bool {
        guard let version, let major = versionComponents(version).first else { return false }
        let components = versionComponents(version)
        let minor = components.count > 1 ? components[1] : 0
        guard isMariaDB else { return major >= 8 }
        return major > 10 || (major == 10 && minor >= 2)
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}

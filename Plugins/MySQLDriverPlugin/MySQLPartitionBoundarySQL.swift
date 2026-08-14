//
//  MySQLPartitionBoundarySQL.swift
//  MySQLDriverPlugin
//

import Foundation

/// Boundary discovery for parallel reads inside one table.
///
/// Splitting `MIN`..`MAX` into equal value ranges only balances the workers
/// when the key is dense. A key with gaps, which is what an autoincrement
/// column looks like after deletes or after an insert burst, puts most of the
/// rows in one range and leaves the other workers idle. `NTILE` divides by row
/// count instead of by value, so every partition gets the same number of rows
/// whatever the distribution looks like. It costs one ordered pass over the key
/// index, which is why the caller only asks past its size threshold.
enum MySQLPartitionBoundarySQL {
    static func percentileQuery(table: String, column: String, partitions: Int) -> String {
        """
        SELECT MIN(bucket_key) FROM ( \
        SELECT \(column) AS bucket_key, NTILE(\(partitions)) OVER (ORDER BY \(column)) AS bucket \
        FROM \(table) WHERE \(column) IS NOT NULL \
        ) AS sampled GROUP BY bucket ORDER BY bucket
        """
    }

    /// The first bucket starts at the table's own minimum, which is not a split
    /// point: the boundaries are where each later bucket begins.
    static func boundaries(fromBucketMinimums minimums: [String]) -> [String] {
        guard minimums.count > 1 else { return [] }
        return Array(minimums.dropFirst())
    }

    /// MySQL learned window functions in 8.0 and MariaDB in 10.2. An older
    /// server parses `NTILE` as a missing function and fails, so the caller
    /// splits by value there instead.
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

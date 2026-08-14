//
//  MySQLIndexDirection.swift
//  MySQLDriverPlugin
//

import Foundation

/// The rows `SHOW INDEX` returns for one index, gathered before they become a
/// `PluginIndexInfo`.
struct MySQLIndexRows {
    var columns: [String]
    var isUnique: Bool
    var type: String
    var prefixes: [String: Int]
    var descending: Set<String>
}

/// Whether the server stores a descending index or only tolerates the syntax.
///
/// MySQL before 8.0 and MariaDB before 10.8 parse `DESC` in an index and then
/// build an ascending index anyway, with no error and no warning. Emitting
/// `DESC` there would claim something the server does not do, so the statement
/// leaves it out and the transfer reports the index as changed instead.
enum MySQLIndexDirection {
    static func supportsDescendingIndex(version: String?, isMariaDB: Bool) -> Bool {
        guard let version else { return false }
        let components = versionComponents(version)
        guard let major = components.first else { return false }
        let minor = components.count > 1 ? components[1] : 0
        guard isMariaDB else { return major >= 8 }
        return major > 10 || (major == 10 && minor >= 8)
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}

//
//  TransferIndexDirectionSupport.swift
//  TablePro
//

import Foundation

/// Whether the target stores the sort direction of an index or accepts the
/// syntax and builds an ascending index anyway.
///
/// MySQL before 8.0 and MariaDB before 10.8 do the latter, with no error and no
/// warning, which makes it the one difference the transfer cannot detect from a
/// failed statement. It is decided from the target's version string, read at
/// preflight, and it applies to a same-engine transfer too: MySQL 8.0 to MySQL
/// 5.7 loses the direction exactly the same way.
enum TransferIndexDirectionSupport {
    static func keepsDescendingIndex(targetType: DatabaseType, version: String?) -> Bool {
        guard targetType == .mysql else { return true }
        guard let version else { return false }

        let isMariaDB = version.lowercased().contains("mariadb")
        let components = version
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .compactMap { Int($0) }
        guard let major = components.first else { return false }
        let minor = components.count > 1 ? components[1] : 0
        guard isMariaDB else { return major >= 8 }
        return major > 10 || (major == 10 && minor >= 8)
    }
}

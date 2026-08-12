//
//  TransferMappingOptions.swift
//  TablePro
//

import Foundation

enum MysqlEnumTarget: String, Sendable, Hashable, CaseIterable {
    /// `varchar(n)` plus a CHECK holding the value list. Alterable later, and
    /// every supported target understands it.
    case check

    /// A named enumerated type on a target that has one. Nothing else can be
    /// altered as cheaply, and the type outlives the table it belongs to.
    case nativeType

    /// `varchar(n)` with no constraint. The column stops restricting values.
    case plainText
}

struct TransferTypeOverride: Sendable, Hashable {
    let table: String
    let column: String
    let targetType: String
}

struct TransferMappingOptions: Sendable, Hashable {
    var tinyint1AsBool: Bool = true
    var mysqlEnumAs: MysqlEnumTarget = .check
    var zeroDateAsNull: Bool = true
    var overrides: [TransferTypeOverride] = []

    func override(table: String, column: String) -> TransferTypeOverride? {
        overrides.first { $0.table.caseInsensitiveCompare(table) == .orderedSame
            && $0.column.caseInsensitiveCompare(column) == .orderedSame }
    }
}

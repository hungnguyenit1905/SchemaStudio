//
//  TransferMappingOptions.swift
//  TablePro
//

import Foundation

enum MysqlEnumTarget: String, Sendable, Hashable, CaseIterable {
    case check
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

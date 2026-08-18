//
//  ColumnFit.swift
//  TablePro
//

import Foundation

/// A value whose shape is the value cannot be shortened to fit: a truncated card
/// number, IBAN, phone number or MAC address is not a shorter valid one, it is a
/// broken one. These generators therefore refuse up front instead of letting the
/// common truncator quietly corrupt every row.
enum ColumnFit {
    static func requireRoom(for length: Int, column: GenerationColumn, generator: String) throws {
        guard let limit = column.maxLength, limit < length else { return }
        throw GenerationError.invalidParameters(
            generator: generator,
            reason: "\(column.name) holds \(limit) characters but the value needs \(length), "
                + "and shortening it would break the value"
        )
    }
}

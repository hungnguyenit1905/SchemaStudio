//
//  MySQLLoadDataStatement.swift
//  MySQLDriverPlugin
//

import Foundation

/// Builds the `LOAD DATA LOCAL INFILE` statement for one table. Binary columns
/// are read into a user variable and assigned through `UNHEX`, so their bytes
/// travel as hex text and land unchanged.
enum MySQLLoadDataStatement {
    /// The name is never opened: the local infile handler serves the stream from
    /// memory and ignores whatever the server asks for.
    static let streamName = "tablepro-transfer-stream"

    static func statement(
        table: String,
        schema: String?,
        columns: [String],
        hexColumns: [Bool],
        quote: (String) -> String
    ) -> String {
        let qualified = schema.map { "\(quote($0)).\(quote(table))" } ?? quote(table)
        var targets: [String] = []
        var assignments: [String] = []

        for (index, column) in columns.enumerated() {
            guard index < hexColumns.count, hexColumns[index] else {
                targets.append(quote(column))
                continue
            }
            let variable = "@tablepro_col\(index)"
            targets.append(variable)
            assignments.append("\(quote(column)) = UNHEX(\(variable))")
        }

        var sql = """
        LOAD DATA LOCAL INFILE '\(streamName)' INTO TABLE \(qualified) \
        CHARACTER SET utf8mb4 \
        FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' \
        LINES TERMINATED BY '\\n' \
        (\(targets.joined(separator: ", ")))
        """
        if !assignments.isEmpty {
            sql += " SET \(assignments.joined(separator: ", "))"
        }
        return sql
    }

    /// The types whose values are bytes rather than characters. `BIT` and the
    /// spatial types are included because their text form is not what the
    /// column stores.
    static func isBinaryType(_ typeName: String) -> Bool {
        let normalized = typeName.lowercased()
        if normalized.hasSuffix("blob") || normalized.hasPrefix("blob") { return true }
        return [
            "binary", "varbinary", "bit",
            "geometry", "point", "linestring", "polygon",
            "multipoint", "multilinestring", "multipolygon", "geometrycollection"
        ].contains(normalized)
    }
}

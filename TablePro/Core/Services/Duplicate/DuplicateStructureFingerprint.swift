//
//  DuplicateStructureFingerprint.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A cheap summary of the source columns, taken before the authorization prompt and compared
/// again after it.
///
/// The gap matters because authorization deliberately runs outside any driver lease: it can wait
/// on a confirmation sheet and Touch ID, so it is paced by the person, not by the machine. During
/// that wait another tab can `ALTER TABLE` the source. The server-side `LIKE` would then copy the
/// **new** structure while the `INSERT … SELECT` column list still describes the **old** one. The
/// mild outcome is a server error partway through; the bad one is copying the wrong columns.
///
/// Only what the plan depends on is included. A comment or a statistics target changing between
/// the two reads does not invalidate anything, and treating it as a change would make the check
/// fire on edits that do not matter.
enum DuplicateStructureFingerprint {
    static func make(columns: [PluginColumnInfo]) -> String {
        columns
            .map { column in
                [
                    column.name,
                    column.dataType,
                    column.isNullable ? "null" : "notnull",
                    column.isPrimaryKey ? "pk" : "",
                    column.isGenerated ? "generated" : "",
                    column.identityKind?.rawValue ?? ""
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }

    static func matches(_ first: [PluginColumnInfo], _ second: [PluginColumnInfo]) -> Bool {
        make(columns: first) == make(columns: second)
    }
}

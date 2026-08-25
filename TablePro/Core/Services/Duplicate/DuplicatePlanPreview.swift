//
//  DuplicatePlanPreview.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Renders a plan as the script the sheet shows, from the same `DuplicatePlan` the run executes.
///
/// A `.sql` body is rendered verbatim, so the preview is exact for it. A `.deferred` body has no
/// text until the statement it depends on has run, so it renders as a labelled comment carrying
/// the count instead of an invented statement: the names come from the server once the new table
/// exists, and guessing them here is the text rewriting this feature refuses to do.
enum DuplicatePlanPreview {
    static func script(plan: DuplicatePlan, harvestedIndexCount: Int, quoting: DuplicateSQLQuoting) -> String {
        plan.statements
            .map { block(for: $0, harvestedIndexCount: harvestedIndexCount, plan: plan, quoting: quoting) }
            .joined(separator: "\n\n")
    }

    /// How many statements each deferred block is expected to expand into, counted from the
    /// source. It is an estimate: the harvest reads the indexes the server creates on the new
    /// table and skips only the ones a constraint owns, which a unique index without a
    /// constraint is not, and `PluginIndexInfo` cannot tell those two apart.
    static func estimatedHarvestedIndexCount(_ indexes: [PluginIndexInfo]) -> Int {
        indexes.filter { !$0.isPrimary && !$0.isUnique }.count
    }

    private static func block(
        for statement: DuplicateStatement,
        harvestedIndexCount: Int,
        plan: DuplicatePlan,
        quoting: DuplicateSQLQuoting
    ) -> String {
        switch statement.body {
        case .sql(let sql):
            return "\(sql);"
        case .deferred(.fromHarvestedIndexes):
            return deferredLabel(for: statement.kind, count: harvestedIndexCount)
        case .chunked(let spec):
            return spec.previewScript(estimatedRowCount: plan.estimatedRowCount, quoting: quoting)
        }
    }

    private static func deferredLabel(for kind: DuplicateStatement.Kind, count: Int) -> String {
        switch kind {
        case .dropIndex:
            return String(
                format: String(
                    localized: "-- Generated when this runs: DROP INDEX for the %d index(es) the server creates"
                ),
                count
            )
        case .replayIndex:
            return String(
                format: String(
                    localized: "-- Generated when this runs: %d index(es) recreated after the rows are copied"
                ),
                count
            )
        default:
            return String(
                format: String(localized: "-- Generated when this runs: %d statement(s)"),
                count
            )
        }
    }
}

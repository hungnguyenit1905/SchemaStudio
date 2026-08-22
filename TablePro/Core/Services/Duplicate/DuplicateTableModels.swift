//
//  DuplicateTableModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The vendor's quoting rules, taken from the driver rather than reimplemented. The driver
/// already knows how its dialect escapes an embedded quote character.
struct DuplicateSQLQuoting: Sendable {
    let identifier: @Sendable (String) -> String
    let stringLiteral: @Sendable (String) -> String
}

struct DuplicateTableRef: Sendable, Hashable {
    let schema: String?
    let name: String
}

enum DuplicateMode: Sendable, Hashable {
    case structureOnly
    case structureAndData
}

enum DuplicateExistsPolicy: Sendable, Hashable {
    case cancel
    case dropAndRecreate
}

enum DuplicateCopyMode: Sendable, Hashable {
    case auto
    case atomic
    case chunked
}

/// `constraints` is one switch rather than the two the spec's dialog draws. PostgreSQL's
/// `LIKE` clause carries `CHECK` constraints and the primary/unique keys under a single
/// `INCLUDING CONSTRAINTS`, so two independent switches would be a control the engine cannot
/// honour.
struct DuplicateOptions: Sendable, Hashable {
    var indexes = true
    var constraints = true
    var foreignKeys = false
    var defaults = true
    var identity = true
    var generated = true
    var comments = true
    var tableOptions = true
    var rowFilter: String?
    var limit: Int64?
    var onExists: DuplicateExistsPolicy = .cancel
    var copyMode: DuplicateCopyMode = .auto
    var batchSize: Int64 = 10_000
}

struct DuplicateTableRequest: Sendable, Hashable {
    let source: DuplicateTableRef
    let targetSchema: String?
    let targetName: String
    let mode: DuplicateMode
    let options: DuplicateOptions

    var target: DuplicateTableRef {
        DuplicateTableRef(schema: targetSchema, name: targetName)
    }
}

/// Read from `pg_sequences` rather than through `PluginDatabaseDriver.fetchDependentSequences`,
/// which renders these attributes into a DDL string carrying the *source* sequence name and
/// omits `CACHE`. Recovering them from that string would mean parsing server-generated DDL,
/// which this feature does not do anywhere.
struct DuplicateSequenceAttributes: Sendable, Hashable {
    let name: String
    let increment: String
    let minValue: String
    let maxValue: String
    let cache: String
    let cycle: Bool
}

struct DuplicateTableIntrospection: Sendable {
    let columns: [PluginColumnInfo]
    let indexes: [PluginIndexInfo]
    let foreignKeys: [PluginForeignKeyInfo]
    let sequencesByColumn: [String: DuplicateSequenceAttributes]
    let tableComment: String?
    let estimatedRowCount: Int64?
    let hasRowLevelSecurity: Bool
    let isOwner: Bool
    let isPartitioned: Bool

    init(
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo] = [],
        foreignKeys: [PluginForeignKeyInfo] = [],
        sequencesByColumn: [String: DuplicateSequenceAttributes] = [:],
        tableComment: String? = nil,
        estimatedRowCount: Int64? = nil,
        hasRowLevelSecurity: Bool = false,
        isOwner: Bool = true,
        isPartitioned: Bool = false
    ) {
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.sequencesByColumn = sequencesByColumn
        self.tableComment = tableComment
        self.estimatedRowCount = estimatedRowCount
        self.hasRowLevelSecurity = hasRowLevelSecurity
        self.isOwner = isOwner
        self.isPartitioned = isPartitioned
    }

    /// Columns whose default is a sequence the source owns, as opposed to an identity column.
    /// An identity column's sequence is cloned by `INCLUDING IDENTITY`; a `serial` column's is
    /// not, so only these need the create/set-default/own-by fixup.
    var serialColumns: [PluginColumnInfo] {
        columns.filter { $0.identityKind == nil && sequencesByColumn[$0.name] != nil }
    }

    var hasIdentityAlwaysColumn: Bool {
        columns.contains { $0.identityKind == .always }
    }

    var writableColumns: [PluginColumnInfo] {
        columns.filter { !$0.isGenerated }
    }
}

enum DuplicateWarning: Sendable, Hashable {
    case rowLevelSecurityPoliciesNotCopied
    case rowLevelSecurityMayHideRows
    case partitionedTableNotSupported(String)
    case foreignKeyNotCarried(String)
    case bestEffortStepFailed(step: String, serverMessage: String)
    case chunkedNeedsSingleColumnKey
    case chunkedCopyIsNotASnapshot

    /// A blocking warning means the plan carries no statements and the UI must refuse to run.
    var isBlocking: Bool {
        switch self {
        case .partitionedTableNotSupported:
            return true
        case .rowLevelSecurityPoliciesNotCopied, .rowLevelSecurityMayHideRows, .foreignKeyNotCarried,
             .bestEffortStepFailed, .chunkedNeedsSingleColumnKey, .chunkedCopyIsNotASnapshot:
            return false
        }
    }

    var message: String {
        switch self {
        case .rowLevelSecurityPoliciesNotCopied:
            return String(localized: "Source table has row-level security policies; they will not be copied.")
        case .rowLevelSecurityMayHideRows:
            return String(
                localized: """
                Row-level security is filtering what you can read from the source table, so the copy \
                may contain fewer rows than the original.
                """
            )
        case .partitionedTableNotSupported(let table):
            return String(
                format: String(localized: "Duplicating partitioned tables is not supported yet. '%@' is partitioned."),
                table
            )
        case .foreignKeyNotCarried(let constraint):
            return String(
                format: String(localized: "Foreign key '%@' could not be read completely and is not created."),
                constraint
            )
        case .chunkedNeedsSingleColumnKey:
            return String(
                localized: """
                This table has no single-column primary key, so the rows are copied in one \
                statement. There is no percentage and no way to stop part way.
                """
            )
        case .chunkedCopyIsNotASnapshot:
            return String(
                localized: """
                The rows are copied in batches that each commit, so changes another session makes \
                to the source while this runs can land in the copy.
                """
            )
        case .bestEffortStepFailed(let step, let serverMessage):
            return String(
                format: String(localized: "The table was created, but %1$@ did not run. %2$@"),
                step,
                serverMessage
            )
        }
    }
}

struct DuplicateStatement: Sendable, Hashable {
    enum Kind: Sendable, Hashable, CaseIterable {
        case validateRowFilter
        case createTable
        case tableComment
        case harvestIndexes
        case dropIndex
        case createSequence
        case setColumnDefault
        case ownSequence
        case copyData
        case replayIndex
        case resetSequence
        case addForeignKey
        case analyze
        case dropTarget
        case dropReferencingForeignKey
    }

    /// A statement whose text only exists once an earlier statement has run. Modelling this
    /// keeps preview and execution on the same object: the preview renders the deferred block
    /// with a label instead of pretending to know SQL that cannot exist yet.
    enum Body: Sendable, Hashable {
        case sql(String)
        case deferred(DeferredSource)
        /// A loop of committed batches rather than one statement. The spec renders every batch,
        /// so the preview and the run still share one description of the copy.
        case chunked(DuplicateChunkedCopySpec)
    }

    enum DeferredSource: Sendable, Hashable {
        case fromHarvestedIndexes
    }

    /// A failure at `bestEffort` must not discard work that already succeeded. `ANALYZE`
    /// failing after twenty million rows have been copied leaves a correct, usable table.
    enum Severity: Sendable, Hashable {
        case fatal
        case bestEffort
    }

    let kind: Kind
    let body: Body

    init(kind: Kind, sql: String) {
        self.kind = kind
        body = .sql(sql)
    }

    init(kind: Kind, deferred: DeferredSource) {
        self.kind = kind
        body = .deferred(deferred)
    }

    init(kind: Kind, chunked: DuplicateChunkedCopySpec) {
        self.kind = kind
        body = .chunked(chunked)
    }
}

struct DuplicatePlan: Sendable, Hashable {
    let statements: [DuplicateStatement]
    let warnings: [DuplicateWarning]
    let copyMode: DuplicateCopyMode
    let estimatedRowCount: Int64?

    init(
        statements: [DuplicateStatement],
        warnings: [DuplicateWarning] = [],
        copyMode: DuplicateCopyMode = .atomic,
        estimatedRowCount: Int64? = nil
    ) {
        self.statements = statements
        self.warnings = warnings
        self.copyMode = copyMode
        self.estimatedRowCount = estimatedRowCount
    }

    var isBlocked: Bool {
        warnings.contains { $0.isBlocking }
    }
}

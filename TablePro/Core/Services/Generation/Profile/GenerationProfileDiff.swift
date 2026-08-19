//
//  GenerationProfileDiff.swift
//  TablePro
//

import Foundation

/// One line of the review list a user sees before a loaded profile is applied.
struct GenerationProfileDiffEntry: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case tableRemoved
        case columnRemoved
        case columnAdded
        case generatorChanged

        var title: String {
            switch self {
            case .tableRemoved: return String(localized: "Table gone")
            case .columnRemoved: return String(localized: "Column gone")
            case .columnAdded: return String(localized: "New column")
            case .generatorChanged: return String(localized: "Generator changed")
            }
        }
    }

    let kind: Kind
    let table: String
    let column: String?
    let message: String

    var id: String { "\(kind)|\(table)|\(column ?? "")" }
}

/// What loading a saved profile against the schema as it is now would change.
/// The classification comes from `GenerationProfileReconciler`, which already
/// does the work; this turns its changes into something reviewable instead of
/// warnings scrolling past in the run log.
struct GenerationProfileDiff: Sendable, Hashable {
    let entries: [GenerationProfileDiffEntry]

    var isEmpty: Bool { entries.isEmpty }

    init(entries: [GenerationProfileDiffEntry]) {
        self.entries = entries
    }

    init(changes: [GenerationProfileChange]) {
        entries = changes.map { change in
            switch change {
            case .tableDropped(let table):
                return GenerationProfileDiffEntry(
                    kind: .tableRemoved,
                    table: table,
                    column: nil,
                    message: change.message
                )
            case .columnDropped(let table, let column):
                return GenerationProfileDiffEntry(
                    kind: .columnRemoved,
                    table: table,
                    column: column,
                    message: change.message
                )
            case .columnAdded(let table, let column, _):
                return GenerationProfileDiffEntry(
                    kind: .columnAdded,
                    table: table,
                    column: column,
                    message: change.message
                )
            case .generatorDowngraded(let table, let column, _, _, _):
                return GenerationProfileDiffEntry(
                    kind: .generatorChanged,
                    table: table,
                    column: column,
                    message: change.message
                )
            }
        }
    }

    init(reconciliation: GenerationProfileReconciliation) {
        self.init(changes: reconciliation.changes)
    }

    func entries(ofKind kind: GenerationProfileDiffEntry.Kind) -> [GenerationProfileDiffEntry] {
        entries.filter { $0.kind == kind }
    }
}

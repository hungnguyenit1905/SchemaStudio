//
//  ValidationWarning.swift
//  TablePro
//

import Foundation

/// A mapping the auto-mapper is not certain about. Every one of these has to
/// reach the UI: generating data the database will reject, or data the user
/// meant to replace, is worse when it happens quietly.
enum ValidationWarning: Sendable, Hashable {
    case uncheckedConstraint(column: String, expression: String)
    case guessedValues(column: String)
    case affixClearedByCheck(column: String)

    var message: String {
        switch self {
        case .uncheckedConstraint(let column, let expression):
            return String(
                format: String(localized: "%@ has a check the generator does not enforce: %@"),
                column,
                expression
            )
        case .guessedValues(let column):
            return String(
                format: String(localized: "The values for %@ are a guess. Replace them with the ones your app uses."),
                column
            )
        case .affixClearedByCheck(let column):
            return String(
                format: String(
                    localized: "A check replaced %@'s generator, so its prefix and suffix were cleared: they would have broken the check."
                ),
                column
            )
        }
    }

    var column: String {
        switch self {
        case .uncheckedConstraint(let column, _): return column
        case .guessedValues(let column): return column
        case .affixClearedByCheck(let column): return column
        }
    }
}

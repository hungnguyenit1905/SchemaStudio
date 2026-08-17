//
//  GenerationError.swift
//  TablePro
//

import Foundation

enum GenerationError: Error, Equatable {
    case unknownGenerator(identifier: String)
    case invalidParameters(generator: String, reason: String)
    case uniqueExhausted(column: String, attempts: Int)
    case dependencyMissing(column: String, dependsOn: String)
    case nullGeneratorOnRequiredColumn(table: String, column: String)
    case nullPercentOnRequiredColumn(table: String, column: String, percent: Int)
    case uniqueDomainTooSmall(table: String, column: String, distinctValues: Int, rowCount: Int)
    case emptyParentTable(table: String, column: String, parentTable: String)
    case tableDependencyCycle(tables: [String])
    case columnDependencyCycle(table: String, columns: [String])
    case unsupportedProfileVersion(found: Int, supported: Int)
    case unknownColumn(table: String, column: String)
}

extension GenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unknownGenerator(let identifier):
            return String(format: String(localized: "No generator is registered as %@."), identifier)
        case .invalidParameters(let generator, let reason):
            return String(
                format: String(localized: "The %@ generator rejected its settings: %@"),
                generator,
                reason
            )
        case .uniqueExhausted(let column, let attempts):
            return String(
                format: String(localized: "Could not find a distinct value for %@ after %d attempts."),
                column,
                attempts
            )
        case .dependencyMissing(let column, let dependsOn):
            return String(
                format: String(localized: "%@ needs %@, which has not been generated yet."),
                column,
                dependsOn
            )
        case .nullGeneratorOnRequiredColumn(let table, let column):
            return String(
                format: String(localized: "%@.%@ cannot be null, but its generator only produces nulls."),
                table,
                column
            )
        case .nullPercentOnRequiredColumn(let table, let column, let percent):
            return String(
                format: String(localized: "%@.%@ cannot be null, but it is set to %d%% nulls."),
                table,
                column,
                percent
            )
        case .uniqueDomainTooSmall(let table, let column, let distinctValues, let rowCount):
            return String(
                format: String(
                    localized: "%@.%@ has to be distinct, but its generator can produce only %d values for %d rows."
                ),
                table,
                column,
                distinctValues,
                rowCount
            )
        case .emptyParentTable(let table, let column, let parentTable):
            return String(
                format: String(
                    localized: "%@.%@ must point at a row in %@, which is empty and is not being filled."
                ),
                table,
                column,
                parentTable
            )
        case .tableDependencyCycle(let tables):
            return String(
                format: String(localized: "These tables reference each other in a loop: %@"),
                tables.joined(separator: ", ")
            )
        case .columnDependencyCycle(let table, let columns):
            return String(
                format: String(localized: "These columns in %@ reference each other in a loop: %@"),
                table,
                columns.joined(separator: ", ")
            )
        case .unsupportedProfileVersion(let found, let supported):
            return String(
                format: String(localized: "This profile was saved in format %d, and this version reads up to %d."),
                found,
                supported
            )
        case .unknownColumn(let table, let column):
            return String(format: String(localized: "%@ has no column named %@."), table, column)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unknownGenerator:
            return String(localized: "Pick a generator from the list, or install the plugin that provides it.")
        case .invalidParameters:
            return String(localized: "Correct the generator's settings in the column panel.")
        case .uniqueExhausted(let column, _):
            return String(
                format: String(
                    localized: "Widen the range for %@, turn off Unique, or generate fewer rows."
                ),
                column
            )
        case .dependencyMissing(_, let dependsOn):
            return String(
                format: String(localized: "Give %@ a generator, or point this column at a different one."),
                dependsOn
            )
        case .nullGeneratorOnRequiredColumn(_, let column):
            return String(
                format: String(localized: "Choose a generator that produces values for %@, or allow nulls on it."),
                column
            )
        case .nullPercentOnRequiredColumn:
            return String(localized: "Set the null percentage to 0, or allow nulls on the column.")
        case .uniqueDomainTooSmall(_, let column, _, _):
            return String(
                format: String(
                    localized: "Widen the range for %@, generate fewer rows, or turn off Unique."
                ),
                column
            )
        case .emptyParentTable(_, _, let parentTable):
            return String(
                format: String(localized: "Add %@ to this run, put rows in it first, or allow nulls on the column."),
                parentTable
            )
        case .tableDependencyCycle:
            return String(
                localized: "Allow nulls on one of the foreign keys in the loop so it can be filled in a second pass."
            )
        case .columnDependencyCycle:
            return String(localized: "Change one of these columns to a generator that does not read another column.")
        case .unsupportedProfileVersion:
            return String(localized: "Update SchemaStudio, or rebuild the profile in this version.")
        case .unknownColumn:
            return String(localized: "Reload the profile so it matches the table as it is now.")
        }
    }
}

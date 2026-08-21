//
//  GenerationDialogStorage.swift
//  TablePro
//

import Foundation

/// What the generation wizard remembers between openings: the row count and the
/// write options, not the schema or the seed.
///
/// The seed is deliberately not remembered. Reusing a saved seed by accident would
/// regenerate the same rows into a table that already holds them, which is the one
/// way a repeatable run becomes a surprise.
final class GenerationDialogStorage {
    static let shared = GenerationDialogStorage()

    private let defaults: UserDefaults

    private enum Keys {
        static let lastRowCount = "com.SchemaStudio.generation.dialog.lastRowCount"
        static let singleTransaction = "com.SchemaStudio.generation.dialog.singleTransaction"
        static let continueOnError = "com.SchemaStudio.generation.dialog.continueOnError"
    }

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
    }

    func loadLastRowCount() -> Int {
        let stored = defaults.integer(forKey: Keys.lastRowCount)
        return stored > 0 ? stored : 100
    }

    func saveLastRowCount(_ rowCount: Int) {
        guard rowCount > 0 else { return }
        defaults.set(rowCount, forKey: Keys.lastRowCount)
    }

    func loadSingleTransaction() -> Bool {
        defaults.bool(forKey: Keys.singleTransaction)
    }

    func saveSingleTransaction(_ isOn: Bool) {
        defaults.set(isOn, forKey: Keys.singleTransaction)
    }

    func loadContinueOnError() -> Bool {
        defaults.bool(forKey: Keys.continueOnError)
    }

    func saveContinueOnError(_ isOn: Bool) {
        defaults.set(isOn, forKey: Keys.continueOnError)
    }
}

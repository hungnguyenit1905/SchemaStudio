//
//  ColumnNameNormalizer.swift
//  TablePro
//

import Foundation

/// Turns a column name into the forms the name rules match against.
///
/// Two forms exist because they answer different questions. The squashed form
/// (`created_at` and `createdAt` both become `createdat`) lets a rule name a
/// column without caring how the schema spells its separators. The tokenized
/// form keeps the separators (`is_active`, `issued_count`) so a prefix rule can
/// require a real word boundary: matching `^is` against the squashed form makes
/// `issued_count` a boolean.
///
/// The table prefix is stripped into an extra candidate rather than replacing
/// the original, because `username` in table `users` is a username, not a name.
enum ColumnNameNormalizer {
    static func candidates(column: String, table: String) -> [String] {
        let trimmed = trimmingFieldSuffix(column)
        let tokenized = tokenize(trimmed)
        let squashed = tokenized.replacingOccurrences(of: "_", with: "")
        var forms = [squashed, tokenized]
        for form in [squashed, tokenized] {
            guard let stripped = strippingTablePrefix(form, table: table) else { continue }
            forms.append(stripped)
        }
        var unique: [String] = []
        for form in forms where !form.isEmpty && !unique.contains(form) {
            unique.append(form)
        }
        return unique
    }

    static func tokenize(_ name: String) -> String {
        var tokens: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                previousWasLower = false
                continue
            }
            if character.isUppercase, previousWasLower, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(Character(character.lowercased()))
            previousWasLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.joined(separator: "_")
    }

    private static func trimmingFieldSuffix(_ name: String) -> String {
        for suffix in ["_col", "-col", "_column", "-column", "_field", "-field"] {
            guard name.lowercased().hasSuffix(suffix), name.count > suffix.count else { continue }
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func strippingTablePrefix(_ form: String, table: String) -> String? {
        let separated = form.contains("_")
        for prefix in tablePrefixes(table) {
            let candidate = separated ? "\(prefix)_" : prefix
            guard form.hasPrefix(candidate), form.count > candidate.count else { continue }
            return String(form.dropFirst(candidate.count))
        }
        return nil
    }

    private static func tablePrefixes(_ table: String) -> [String] {
        let squashed = tokenize(table).replacingOccurrences(of: "_", with: "")
        guard !squashed.isEmpty else { return [] }
        var prefixes = [squashed]
        for plural in ["ies", "es", "s"] where squashed.hasSuffix(plural) && squashed.count > plural.count {
            let stem = String(squashed.dropLast(plural.count))
            prefixes.append(plural == "ies" ? stem + "y" : stem)
            break
        }
        return prefixes
    }
}

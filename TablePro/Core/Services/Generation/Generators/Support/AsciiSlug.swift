//
//  AsciiSlug.swift
//  TablePro
//

import Foundation

/// Folds a display name down to the ASCII a handle, domain or path can hold.
/// `Nguyễn Thị Hương` has to become `nguyen.thi.huong` before it can be half an
/// email address, and the Vietnamese `đ` is the trap: it is a letter in its own
/// right rather than a `d` with a mark, so diacritic folding leaves it behind and
/// the filter below would drop it, turning `Đồng Tâm` into `ong.tam`.
enum AsciiSlug {
    private static let standInLetters: [Character: Character] = [
        "đ": "d", "Đ": "d", "ø": "o", "Ø": "o", "æ": "a", "Æ": "a", "ß": "s", "ð": "d", "þ": "t"
    ]

    static func words(_ text: String) -> [String] {
        var replaced = ""
        replaced.reserveCapacity(text.count)
        for character in text {
            replaced.append(standInLetters[character] ?? character)
        }
        let folded = replaced
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var tokens: [String] = []
        var current = ""
        for character in folded {
            guard character.isASCII, character.isLetter || character.isNumber else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func joined(_ text: String, separator: String = "") -> String {
        words(text).joined(separator: separator)
    }
}

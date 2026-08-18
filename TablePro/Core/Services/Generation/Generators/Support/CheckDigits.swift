//
//  CheckDigits.swift
//  TablePro
//

import Foundation

/// The check-digit arithmetic shared by the card, article-number and bank-account
/// generators. Kept apart from the generators so the rule is stated once and the
/// generators only decide which digits to feed it.
enum CheckDigits {
    /// ISO/IEC 7812, used by every payment card network. Doubles every second
    /// digit counting from the right of the finished number, so the position
    /// parity depends on how long the payload is.
    static func luhn(appendingTo payload: [Int]) -> Int {
        var total = 0
        for (offset, digit) in payload.reversed().enumerated() {
            guard offset.isMultiple(of: 2) else {
                total += digit
                continue
            }
            let doubled = digit * 2
            total += doubled > 9 ? doubled - 9 : doubled
        }
        return (10 - total % 10) % 10
    }

    /// GS1 modulo-10, which EAN-13, UPC-A and ISBN-13 all use. Weights alternate
    /// 1 and 3 from the left of the payload.
    static func gs1Modulo10(appendingTo payload: [Int]) -> Int {
        var total = 0
        for (offset, digit) in payload.enumerated() {
            total += offset.isMultiple(of: 2) ? digit : digit * 3
        }
        return (10 - total % 10) % 10
    }

    /// ISO 13616. `body` is everything after the two check digits, `country` the
    /// two-letter prefix. Returns the two digits that make the rotated number
    /// congruent to 1 modulo 97.
    static func ibanCheckDigits(country: String, body: String) -> String {
        let remainder = modulo97(rotated: body + country + "00")
        let check = 98 - remainder
        return check < 10 ? "0\(check)" : String(check)
    }

    /// Folds the string a digit at a time so the intermediate value never
    /// approaches the width of `Int`: an IBAN expands to well over thirty digits
    /// once its letters are replaced, which no fixed-width integer holds.
    private static func modulo97(rotated: String) -> Int {
        var remainder = 0
        for character in rotated.uppercased() {
            let chunk: String
            if character.isNumber, let digit = character.wholeNumberValue {
                chunk = String(digit)
            } else if character.isLetter, let ascii = character.asciiValue {
                chunk = String(Int(ascii - 65) + 10)
            } else {
                continue
            }
            for scalar in chunk {
                guard let value = scalar.wholeNumberValue else { continue }
                remainder = (remainder * 10 + value) % 97
            }
        }
        return remainder
    }
}

//
//  ChecksumGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Checksum validators written against the published specifications rather than
/// against `CheckDigits`. A generator checked with its own arithmetic proves only
/// that the code is self-consistent, so these are deliberately a second
/// implementation: whichever one is wrong, the suite fails.
private enum IndependentChecksum {
    static func passesLuhn(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count == digits.count, numbers.count >= 2 else { return false }
        var total = 0
        for (offset, digit) in numbers.reversed().enumerated() {
            guard offset.isMultiple(of: 2) == false else {
                total += digit
                continue
            }
            let doubled = digit * 2
            total += doubled > 9 ? doubled - 9 : doubled
        }
        return total % 10 == 0
    }

    /// EAN-13 and ISBN-13 share one rule: weights of 1 and 3 alternating from the
    /// left across the first twelve digits, check digit closing the sum to a
    /// multiple of ten.
    static func passesThirteenDigitCheck(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count == 13, numbers.count == digits.count else { return false }
        var total = 0
        for (offset, digit) in numbers.prefix(12).enumerated() {
            total += offset.isMultiple(of: 2) ? digit : digit * 3
        }
        let expected = (10 - total % 10) % 10
        return expected == numbers[12]
    }

    /// ISO 13616: rotate the first four characters to the end, replace each
    /// letter with its position in the alphabet plus nine, and the whole number
    /// read as a decimal is congruent to 1 modulo 97.
    static func passesIbanCheck(_ iban: String) -> Bool {
        let compact = iban.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let rotated = String(compact.dropFirst(4) + compact.prefix(4))
        var remainder = 0
        for character in rotated {
            let chunk: String
            if let digit = character.wholeNumberValue, character.isNumber {
                chunk = String(digit)
            } else if let ascii = character.asciiValue, character.isLetter {
                chunk = String(Int(ascii - 65) + 10)
            } else {
                return false
            }
            for scalar in chunk {
                guard let value = scalar.wholeNumberValue else { return false }
                remainder = (remainder * 10 + value) % 97
            }
        }
        return remainder == 1
    }
}

@Suite("Checksum generators")
struct ChecksumGeneratorTests {
    private static let registry = GeneratorRegistry.standard

    private func values(
        _ identifier: String,
        params: String = "{}",
        count: Int = 500,
        seed: UInt64 = 42,
        column: GenerationColumn = GeneratorTestFixtures.column(dataType: "varchar(64)")
    ) throws -> [String] {
        let generator = try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: column,
            seed: seed
        )
        return try (0..<count).map { index in
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .text(text) = value else {
                Issue.record("\(identifier) produced \(value) rather than text")
                return ""
            }
            return text
        }
    }

    @Test("Every credit card number passes Luhn", arguments: ["visa", "mastercard", "amex", "discover", "jcb", "any"])
    func creditCardNumbersPassLuhn(brand: String) throws {
        let produced = try values(CreditCardNumberGenerator.identifier, params: #"{"brand":"\#(brand)"}"#)
        for number in produced {
            #expect(IndependentChecksum.passesLuhn(number), "\(number) fails Luhn")
        }
    }

    @Test("Each brand keeps its own prefix and length")
    func creditCardBrandsMatchTheirIssuerRanges() throws {
        let expectations: [String: (prefixes: [String], lengths: Set<Int>)] = [
            "visa": (["4"], [16]),
            "mastercard": (["51", "52", "53", "54", "55"], [16]),
            "amex": (["34", "37"], [15]),
            "discover": (["6011", "65"], [16]),
            "jcb": (["3528", "3529", "353", "354", "355", "356", "357", "358"], [16])
        ]
        for (brand, expectation) in expectations {
            for number in try values(CreditCardNumberGenerator.identifier, params: #"{"brand":"\#(brand)"}"#, count: 200) {
                #expect(expectation.lengths.contains(number.count), "\(brand) produced \(number.count) digits")
                #expect(
                    expectation.prefixes.contains(where: number.hasPrefix),
                    "\(number) is not in the \(brand) issuer range"
                )
            }
        }
    }

    @Test("Grouped formatting keeps the digits Luhn-valid underneath")
    func creditCardGroupingIsCosmetic() throws {
        let grouped = try values(
            CreditCardNumberGenerator.identifier,
            params: #"{"brand":"visa","format":"grouped"}"#,
            count: 100
        )
        for number in grouped {
            #expect(number.contains(" "))
            #expect(IndependentChecksum.passesLuhn(number.replacingOccurrences(of: " ", with: "")))
        }
    }

    @Test("Every EAN-13 passes its check digit")
    func ean13PassesItsCheckDigit() throws {
        for code in try values(Ean13Generator.identifier) {
            #expect(code.count == 13)
            #expect(IndependentChecksum.passesThirteenDigitCheck(code), "\(code) fails the EAN-13 check")
        }
    }

    @Test("Every ISBN-13 passes its check digit and carries a bookland prefix")
    func isbn13PassesItsCheckDigit() throws {
        for code in try values(Isbn13Generator.identifier) {
            #expect(code.count == 13)
            #expect(code.hasPrefix("978") || code.hasPrefix("979"), "\(code) is not a bookland ISBN")
            #expect(IndependentChecksum.passesThirteenDigitCheck(code), "\(code) fails the ISBN-13 check")
        }
    }

    @Test("Hyphenated ISBNs validate once the hyphens are removed")
    func isbn13HyphenationIsCosmetic() throws {
        for code in try values(Isbn13Generator.identifier, params: #"{"format":"hyphenated"}"#, count: 100) {
            #expect(code.contains("-"))
            #expect(IndependentChecksum.passesThirteenDigitCheck(code.replacingOccurrences(of: "-", with: "")))
        }
    }

    @Test("Every IBAN satisfies mod-97", arguments: ["DE", "GB", "FR", "NL", "ES", "IT"])
    func ibanSatisfiesModNinetySeven(country: String) throws {
        let produced = try values(IbanGenerator.identifier, params: #"{"country":"\#(country)"}"#, count: 200)
        for iban in produced {
            #expect(iban.hasPrefix(country), "\(iban) does not start with \(country)")
            #expect(IndependentChecksum.passesIbanCheck(iban), "\(iban) fails mod-97")
        }
    }

    @Test("IBAN country lengths match ISO 13616")
    func ibanLengthsMatchTheRegistry() throws {
        let lengths = ["DE": 22, "GB": 22, "FR": 27, "NL": 18, "ES": 24, "IT": 27]
        for (country, length) in lengths {
            for iban in try values(IbanGenerator.identifier, params: #"{"country":"\#(country)"}"#, count: 50) {
                #expect(iban.count == length, "\(country) IBAN \(iban) is \(iban.count) characters, expected \(length)")
            }
        }
    }

    @Test("SWIFT codes are 8 or 11 characters in the ISO 9362 shape")
    func swiftCodesMatchIso9362() throws {
        for code in try values(SwiftCodeGenerator.identifier) {
            #expect(code.count == 8 || code.count == 11, "\(code) is \(code.count) characters")
            #expect(code.prefix(6).allSatisfy { $0.isUppercase && $0.isLetter }, "\(code) has a malformed bank or country part")
            #expect(code.dropFirst(6).allSatisfy { $0.isUppercase || $0.isNumber }, "\(code) has a malformed location part")
        }
    }

    @Test("CVV length follows the card brand")
    func cvvLengthFollowsTheBrand() throws {
        for code in try values(CvvGenerator.identifier, params: #"{"brand":"amex"}"#, count: 100) {
            #expect(code.count == 4)
            #expect(code.allSatisfy { $0.isNumber })
        }
        for code in try values(CvvGenerator.identifier, params: #"{"brand":"visa"}"#, count: 100) {
            #expect(code.count == 3)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }

    @Test("Card expiry dates are in the future and use a real month")
    func cardExpiryIsPlausible() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        for value in try values(CreditCardExpiryGenerator.identifier, count: 200) {
            let parts = value.split(separator: "/")
            #expect(parts.count == 2, "\(value) is not MM/YY")
            guard parts.count == 2, let month = Int(parts[0]), let year = Int(parts[1]) else { continue }
            #expect((1...12).contains(month), "\(value) has month \(month)")
            var components = DateComponents()
            components.year = 2_000 + year
            components.month = month
            let expiry = try #require(calendar.date(from: components))
            #expect(expiry > now, "\(value) is already expired")
        }
    }

    @Test("Checksummed generators stay deterministic under one seed", arguments: [
        CreditCardNumberGenerator.identifier,
        Ean13Generator.identifier,
        Isbn13Generator.identifier,
        IbanGenerator.identifier,
        SwiftCodeGenerator.identifier,
        CvvGenerator.identifier,
        CreditCardExpiryGenerator.identifier
    ])
    func checksummedGeneratorsAreDeterministic(identifier: String) throws {
        #expect(try values(identifier, count: 100, seed: 9) == (try values(identifier, count: 100, seed: 9)))
    }

    @Test("A short column truncates rather than emitting a broken checksum")
    func aShortColumnRefusesRatherThanCorrupting() throws {
        #expect(throws: GenerationError.self) {
            _ = try Self.registry.make(
                identifier: Ean13Generator.identifier,
                params: Data("{}".utf8),
                column: GeneratorTestFixtures.column(dataType: "varchar(5)"),
                seed: 1
            )
        }
    }
}

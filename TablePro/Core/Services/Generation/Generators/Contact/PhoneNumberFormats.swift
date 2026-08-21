//
//  PhoneNumberFormats.swift
//  TablePro
//

import Foundation

enum PhoneCountry: String, Codable, Sendable, CaseIterable {
    case us = "US"
    case vn = "VN"

    var label: String {
        switch self {
        case .us: return String(localized: "United States (+1)")
        case .vn: return String(localized: "Vietnam (+84)")
        }
    }

    var callingCode: String {
        switch self {
        case .us: return "1"
        case .vn: return "84"
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

enum PhoneWriting: String, Codable, Sendable, CaseIterable {
    case national
    case international
    case digits

    var label: String {
        switch self {
        case .national: return String(localized: "National, such as (212) 555-0137")
        case .international: return String(localized: "International, such as +1 212 555 0137")
        case .digits: return String(localized: "Digits only")
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

enum PhoneLine: Sendable {
    case landline
    case mobile
}

/// Number plans, and how much of each one is real.
///
/// US numbers use the `555-0100` to `555-0199` block, which the North American
/// Numbering Plan reserves for fiction, so a generated number cannot ring anyone.
/// That plan has no landline and mobile split, so both lines draw the same shape.
///
/// Vietnam reserves no fictional block, so its numbers are only plausible: real
/// mobile prefixes and real area codes with a random subscriber number behind
/// them. That is the same trade the Vietnamese national identifier makes, and it
/// is recorded in `DATASETS.md`.
struct PhoneNumberPlan: Sendable {
    /// Carried after the trunk digit, so the Vietnamese `24` writes as `024`.
    let prefixes: [String]

    /// How many digits follow the trunk prefix, prefix included. Ten everywhere
    /// except Vietnamese mobiles, which run to nine.
    let nationalDigits: Int

    /// The fixed middle the US plan puts in front of its two free digits.
    let fictionalBody: String?

    let trunkPrefix: String
    let country: PhoneCountry
    let line: PhoneLine

    static func plan(country: PhoneCountry, line: PhoneLine) -> PhoneNumberPlan {
        switch country {
        case .us:
            return PhoneNumberPlan(
                prefixes: usAreaCodes,
                nationalDigits: 10,
                fictionalBody: "55501",
                trunkPrefix: "",
                country: .us,
                line: line
            )
        case .vn:
            return PhoneNumberPlan(
                prefixes: line == .mobile ? vietnamMobilePrefixes : vietnamAreaCodes,
                nationalDigits: line == .mobile ? 9 : 10,
                fictionalBody: nil,
                trunkPrefix: "0",
                country: .vn,
                line: line
            )
        }
    }

    private static let usAreaCodes = [
        "202", "205", "212", "213", "215", "303", "305", "312", "313", "404", "408", "415", "503",
        "512", "602", "617", "646", "702", "713", "718", "801", "808", "857", "901", "917", "971"
    ]

    /// Hanoi, Ho Chi Minh City, Da Nang, Hai Phong, Can Tho, Khanh Hoa, Lam Dong
    /// and Quang Ninh.
    private static let vietnamAreaCodes = ["24", "28", "236", "225", "292", "258", "263", "203"]

    /// The prefixes the Vietnamese networks hold since the 2018 renumbering.
    private static let vietnamMobilePrefixes = [
        "32", "33", "34", "35", "36", "37", "38", "39", "56", "58", "59", "70", "76", "77", "78",
        "79", "81", "82", "83", "85", "86", "88", "89", "90", "91", "92", "93", "94", "96", "97", "98", "99"
    ]

    func draw(using rng: inout SplitMix64) -> String {
        let prefix = prefixes[rng.nextInt(upperBound: prefixes.count)]
        var body = fictionalBody ?? ""
        for _ in 0..<freeDigits(after: prefix) {
            body.append(String(rng.nextInt(upperBound: 10)))
        }
        return prefix + body
    }

    func write(_ national: String, as writing: PhoneWriting) -> String {
        switch writing {
        case .digits:
            return trunkPrefix + national
        case .international:
            return "+\(country.callingCode) " + groups(of: national).joined(separator: " ")
        case .national:
            return nationalText(national)
        }
    }

    /// The longest a number can be once written, which is what a column has to
    /// have room for. Prefix length is the only thing that varies, so the widest
    /// prefix gives the answer.
    func maximumLength(as writing: PhoneWriting) -> Int {
        let widest = prefixes.max { $0.count < $1.count } ?? ""
        let body = (fictionalBody ?? "") + String(repeating: "9", count: freeDigits(after: widest))
        return write(widest + body, as: writing).count
    }

    var distinctCount: Int {
        var total = 0
        for prefix in prefixes {
            let (block, overflowed) = Self.powerOfTen(freeDigits(after: prefix))
            guard !overflowed else { return Int.max }
            let (sum, sumOverflow) = total.addingReportingOverflow(block)
            guard !sumOverflow else { return Int.max }
            total = sum
        }
        return total
    }

    private func freeDigits(after prefix: String) -> Int {
        max(0, nationalDigits - prefix.count - (fictionalBody?.count ?? 0))
    }

    /// The trunk digit belongs to the first group rather than standing alone, so
    /// a Vietnamese mobile reads `0912 345 678` and a Hanoi landline reads
    /// `024 3856 1234`, which is how both are written down.
    private func nationalText(_ national: String) -> String {
        guard country != .us else {
            let parts = groups(of: national)
            guard parts.count == 3 else { return national }
            return "(\(parts[0])) \(parts[1])-\(parts[2])"
        }
        var parts = groups(of: national)
        guard !parts.isEmpty else { return trunkPrefix + national }
        parts[0] = trunkPrefix + parts[0]
        return parts.joined(separator: " ")
    }

    private func groups(of national: String) -> [String] {
        var rest = Substring(national)
        var parts: [String] = []
        for size in groupSizes(for: national) where !rest.isEmpty {
            let taken = min(size, rest.count)
            parts.append(String(rest.prefix(taken)))
            rest = rest.dropFirst(taken)
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    /// A US number is always area, exchange, subscriber. A Vietnamese mobile runs
    /// in threes. A Vietnamese landline leads with its area code, whose length
    /// varies, and then runs in fours with the short block last.
    private func groupSizes(for national: String) -> [Int] {
        switch (country, line) {
        case (.us, _):
            return [3, 3, 4]
        case (.vn, .mobile):
            return [3, 3, 3]
        case (.vn, .landline):
            let matched = prefixes
                .filter { national.hasPrefix($0) }
                .max { $0.count < $1.count } ?? String(national.prefix(2))
            var sizes = [matched.count]
            var remaining = national.count - matched.count
            while remaining > 4 {
                sizes.append(4)
                remaining -= 4
            }
            if remaining > 0 { sizes.append(remaining) }
            return sizes
        }
    }

    private static func powerOfTen(_ exponent: Int) -> (value: Int, overflowed: Bool) {
        var value = 1
        for _ in 0..<exponent {
            let (product, overflowed) = value.multipliedReportingOverflow(by: 10)
            guard !overflowed else { return (Int.max, true) }
            value = product
        }
        return (value, false)
    }
}

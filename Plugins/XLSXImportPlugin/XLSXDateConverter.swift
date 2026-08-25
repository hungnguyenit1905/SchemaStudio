//
//  XLSXDateConverter.swift
//  XLSXImportPlugin
//
//  Pure civil-date arithmetic, so a workbook's dates never shift with the machine's calendar
//  or timezone.
//

import Foundation

public struct XLSXDateTime: Equatable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    public var hasTimeOfDay: Bool {
        hour != 0 || minute != 0 || second != 0
    }
}

public enum XLSXDateConverter {
    /// Excel's 1900 mode counts serial 60 as a 1900-02-29 that never existed, so serials up to
    /// 59 sit one day later than the serials after the gap.
    public static func dateTime(serial: Double, usesDate1904: Bool) -> XLSXDateTime? {
        guard serial.isFinite, serial >= 0, serial < 3_000_000 else { return nil }

        let wholeDays = Int(serial.rounded(.down))
        var fraction = serial - Double(wholeDays)
        var totalSeconds = Int((fraction * 86_400).rounded())
        if totalSeconds >= 86_400 {
            totalSeconds = 86_399
        }
        fraction = 0

        let dayNumber: Int
        if usesDate1904 {
            dayNumber = daysFromCivil(year: 1904, month: 1, day: 1) + wholeDays
        } else if wholeDays < 60 {
            dayNumber = daysFromCivil(year: 1899, month: 12, day: 31) + wholeDays
        } else {
            dayNumber = daysFromCivil(year: 1899, month: 12, day: 30) + wholeDays
        }

        let civil = civilFromDays(dayNumber)
        return XLSXDateTime(
            year: civil.year,
            month: civil.month,
            day: civil.day,
            hour: totalSeconds / 3_600,
            minute: (totalSeconds % 3_600) / 60,
            second: totalSeconds % 60
        )
    }

    /// Builtin number formats 14-22 and 45-47 are dates or times. A custom format is a date when
    /// it carries an unquoted y, m, d, h or s, so a currency format whose literal text contains
    /// one of those letters stays a number.
    public static func isDateFormat(numberFormatId: Int, formatCode: String?) -> Bool {
        if (14 ... 22).contains(numberFormatId) { return true }
        if (45 ... 47).contains(numberFormatId) { return true }
        guard let formatCode else { return false }
        return unquotedFormatBody(formatCode).contains { "ymdhs".contains($0) }
    }

    private static func unquotedFormatBody(_ code: String) -> String {
        var output = ""
        var inQuotes = false
        var skipNext = false
        var inBracket = false

        for character in code.lowercased() {
            if skipNext {
                skipNext = false
                continue
            }
            switch character {
            case "\"":
                inQuotes.toggle()
            case "\\":
                skipNext = true
            case "[":
                inBracket = true
            case "]":
                inBracket = false
            default:
                if !inQuotes, !inBracket {
                    output.append(character)
                }
            }
        }
        return output
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (month <= 2 ? year + 1 : year, month, day)
    }
}

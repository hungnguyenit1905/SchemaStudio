//
//  LocalityField.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One column's worth of a locality record. Every plain address generator is the
/// same code reading a different field, so the field is the only thing each one
/// declares and `LocalityBackedGenerator` supplies the rest.
protocol LocalityField {
    static var identifier: String { get }
    static func value(
        from record: LocalityRecord,
        locale: GenerationLocale,
        base: TransferBaseType
    ) -> PluginCellValue
}

enum CityField: LocalityField {
    static let identifier = "City"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(record.city)
    }
}

enum StateField: LocalityField {
    static let identifier = "State"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(record.state)
    }
}

enum StateCodeField: LocalityField {
    static let identifier = "StateCode"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(record.stateCode)
    }
}

enum PostalCodeField: LocalityField {
    static let identifier = "PostalCode"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        GenerationValueMapper.value(from: record.postalCode, base: base)
    }
}

enum CountryField: LocalityField {
    static let identifier = "Country"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(CountryNames.name(forCode: record.countryCode, locale: locale))
    }
}

enum CountryCodeField: LocalityField {
    static let identifier = "CountryCode"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(record.countryCode)
    }
}

enum LatitudeField: LocalityField {
    static let identifier = "Latitude"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        GenerationValueMapper.value(from: .double(record.latitude), base: base)
    }
}

enum LongitudeField: LocalityField {
    static let identifier = "Longitude"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        GenerationValueMapper.value(from: .double(record.longitude), base: base)
    }
}

enum TimeZoneField: LocalityField {
    static let identifier = "TimeZone"

    static func value(from record: LocalityRecord, locale: GenerationLocale, base: TransferBaseType) -> PluginCellValue {
        .text(record.timeZone)
    }
}

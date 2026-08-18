//
//  LocalityRecord.swift
//  TablePro
//

import Foundation

/// One real place, held whole. The address generators draw a record per row and
/// read every address column off it, which is what stops a Vietnamese address
/// from pairing a ward in Ho Chi Minh City with the province of Ha Noi.
struct LocalityRecord: Sendable, Hashable {
    let city: String
    let state: String
    let stateCode: String
    let postalCode: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
    let timeZone: String

    /// Tab-separated, one record per line, in the column order below. Tabs rather
    /// than JSON because the file is read once and the budget is a megabyte for
    /// every locale together.
    ///
    /// `city  state  stateCode  postalCode  countryCode  latitude  longitude  timeZone`
    static func parse(_ lines: [String]) -> [LocalityRecord] {
        lines.compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 8 else { return nil }
            guard let latitude = Double(fields[5]), let longitude = Double(fields[6]) else { return nil }
            return LocalityRecord(
                city: fields[0],
                state: fields[1],
                stateCode: fields[2],
                postalCode: fields[3],
                countryCode: fields[4],
                latitude: latitude,
                longitude: longitude,
                timeZone: fields[7]
            )
        }
    }
}

//
//  TransferIR.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferBaseType: String, Sendable, Hashable, CaseIterable {
    case unknown
    case bool
    case int8, int16, int32, int64
    case decimal
    case float32, float64
    case string
    case text
    case bytes
    case date, time, timestamp, timestampTZ
    case interval
    case json
    case uuid
    case enumeration, set
    case geometry
}

/// The vendor-neutral shape of a column type. `native` is always populated so a
/// type the mapper cannot render still has an exact string to fall back to.
struct TransferColumnType: Sendable, Hashable {
    let base: TransferBaseType
    let length: Int?
    let precision: Int?
    let scale: Int?
    let unsigned: Bool
    let allowedValues: [String]?
    let native: String

    init(
        base: TransferBaseType,
        length: Int? = nil,
        precision: Int? = nil,
        scale: Int? = nil,
        unsigned: Bool = false,
        allowedValues: [String]? = nil,
        native: String
    ) {
        self.base = base
        self.length = length
        self.precision = precision
        self.scale = scale
        self.unsigned = unsigned
        self.allowedValues = allowedValues
        self.native = native
    }

    func with(base: TransferBaseType) -> TransferColumnType {
        TransferColumnType(
            base: base,
            length: length,
            precision: precision,
            scale: scale,
            unsigned: unsigned,
            allowedValues: allowedValues,
            native: native
        )
    }

    var isArray: Bool {
        native.hasSuffix("[]")
    }
}

enum TransferValueConversion: Sendable, Hashable {
    case boolToInt
    case intToBool
    case zeroDateToNull
    case zeroDateToSentinel(String)
    case unsignedToDecimalText
    case arrayToJson
    case jsonValidate
}

struct TransferColumnPlan: Sendable {
    let sourceColumn: PluginColumnInfo
    let targetType: String
    let conversion: TransferValueConversion?
    let warnings: [TransferStructureWarning]
}

/// A dropped index carries `index == nil`; the warnings explain why.
struct TransferIndexPlan: Sendable {
    let index: PluginIndexDefinition?
    let warnings: [TransferStructureWarning]
}

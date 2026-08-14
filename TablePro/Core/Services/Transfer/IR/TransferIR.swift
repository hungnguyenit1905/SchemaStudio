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
    case zeroDateReject
    case unsignedToDecimalText
    case arrayToJson
    case jsonValidate
    case mysqlTimestampRange
    case decimalFit(precision: Int, scale: Int)
    case decimalRound(precision: Int, scale: Int)
}

/// A standalone enumerated type the target has to declare before the table that
/// names it.
struct TransferEnumType: Sendable, Hashable {
    let name: String
    let values: [String]
}

struct TransferColumnPlan: Sendable {
    let sourceColumn: PluginColumnInfo
    let targetType: String
    let conversion: TransferValueConversion?
    let warnings: [TransferStructureWarning]

    /// Carried to the target as a CHECK constraint when the target has no
    /// enumerated type of its own.
    let allowedValues: [String]?

    /// Set only when the target declares the value list as a named type and
    /// `targetType` is that type's name.
    let enumType: TransferEnumType?

    init(
        sourceColumn: PluginColumnInfo,
        targetType: String,
        conversion: TransferValueConversion? = nil,
        warnings: [TransferStructureWarning] = [],
        allowedValues: [String]? = nil,
        enumType: TransferEnumType? = nil
    ) {
        self.sourceColumn = sourceColumn
        self.targetType = targetType
        self.conversion = conversion
        self.warnings = warnings
        self.allowedValues = allowedValues
        self.enumType = enumType
    }
}

/// A dropped index carries `index == nil`; the warnings explain why.
struct TransferIndexPlan: Sendable {
    let index: PluginIndexDefinition?
    let warnings: [TransferStructureWarning]
}

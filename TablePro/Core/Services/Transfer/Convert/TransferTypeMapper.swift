//
//  TransferTypeMapper.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Translates a source column type to the target vendor through the neutral IR.
///
/// There is no per-pair mapping table. Each vendor contributes one parser and
/// one renderer, and this type only encodes the exceptions where the target
/// renderer alone would lose or corrupt data.
struct TransferTypeMapper: Sendable {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "TransferTypeMapper")

    let sourceType: DatabaseType
    let targetType: DatabaseType
    let options: TransferMappingOptions

    init(
        sourceType: DatabaseType,
        targetType: DatabaseType,
        options: TransferMappingOptions = TransferMappingOptions()
    ) {
        self.sourceType = sourceType
        self.targetType = targetType
        self.options = options
    }

    var sourceVendor: TransferVendor? { TransferVendor(sourceType) }
    var targetVendor: TransferVendor? { TransferVendor(targetType) }

    /// True when the source and target speak the same dialect, so v1 behaviour
    /// applies and every type passes through untouched.
    var isSameDialect: Bool {
        if sourceType == targetType { return true }
        guard let source = sourceVendor, let target = targetVendor else { return false }
        return source == target
    }

    func plan(for column: PluginColumnInfo, table: String) -> TransferColumnPlan {
        if let override = options.override(table: table, column: column.name) {
            return TransferColumnPlan(
                sourceColumn: column,
                targetType: override.targetType,
                conversion: nil,
                warnings: []
            )
        }

        if isSameDialect { return passthrough(column) }

        guard let source = sourceVendor, let target = targetVendor else {
            Self.logger.warning("No type parser for \(sourceType.rawValue) to \(targetType.rawValue)")
            return passthrough(
                column,
                warnings: [.typeNotMapped(table: table, column: column.name, native: column.dataType)]
            )
        }

        let parsed = NativeTypeParserRegistry.parser(for: source)
            .parse(column.dataType, allowedValues: column.allowedValues)

        var mapping = Mapping(type: parsed)
        applyBoolPreference(&mapping, source: source)
        applyArray(&mapping, table: table, column: column, source: source, target: target)
        applyUnsigned(&mapping, table: table, column: column, target: target)
        applyInterval(&mapping, table: table, column: column, target: target)
        applyLossyNotes(&mapping, table: table, column: column, source: source, target: target)
        applyBoolRepresentation(&mapping, source: source, target: target)
        applyZeroDate(&mapping, column: column, source: source, target: target)

        guard let rendered = NativeTypeParserRegistry.parser(for: target).render(mapping.type) else {
            return passthrough(
                column,
                warnings: mapping.warnings
                    + [.typeNotMapped(table: table, column: column.name, native: column.dataType)]
            )
        }

        return TransferColumnPlan(
            sourceColumn: column,
            targetType: rendered,
            conversion: mapping.conversion,
            warnings: mapping.warnings
        )
    }

    private func passthrough(
        _ column: PluginColumnInfo,
        warnings: [TransferStructureWarning] = []
    ) -> TransferColumnPlan {
        TransferColumnPlan(
            sourceColumn: column,
            targetType: column.dataType,
            conversion: nil,
            warnings: warnings
        )
    }

    private struct Mapping {
        var type: TransferColumnType
        var conversion: TransferValueConversion?
        var warnings: [TransferStructureWarning] = []
    }

    /// `tinyint(1)` is MySQL's conventional boolean. When the user says it is
    /// really a small integer, the IR is walked back to `.int8` before mapping.
    private func applyBoolPreference(_ mapping: inout Mapping, source: TransferVendor) {
        guard !options.tinyint1AsBool, source == .mysql, mapping.type.base == .bool else { return }
        guard mapping.type.native.lowercased().hasPrefix("tinyint") else { return }
        mapping.type = mapping.type.with(base: .int8)
    }

    private func applyArray(
        _ mapping: inout Mapping,
        table: String,
        column: PluginColumnInfo,
        source: TransferVendor,
        target: TransferVendor
    ) {
        guard source == .postgresql, target != .postgresql, mapping.type.isArray else { return }
        mapping.type = mapping.type.with(base: .json)
        mapping.conversion = .arrayToJson
        mapping.warnings.append(
            .typeLossy(
                table: table,
                column: column.name,
                from: column.dataType,
                to: "json",
                reason: String(localized: "Array elements become a JSON document and lose their element type.")
            )
        )
    }

    /// Only MySQL has unsigned integers. Every other target needs the next
    /// width up, and `bigint unsigned` exceeds every signed 64-bit type so it
    /// has to become an exact decimal.
    private func applyUnsigned(
        _ mapping: inout Mapping,
        table: String,
        column: PluginColumnInfo,
        target: TransferVendor
    ) {
        guard mapping.type.unsigned, target != .mysql else { return }

        switch mapping.type.base {
        case .int8:
            mapping.type = mapping.type.with(base: .int16)
        case .int16:
            mapping.type = mapping.type.with(base: .int32)
        case .int32:
            mapping.type = mapping.type.with(base: .int64)
        case .int64:
            mapping.type = TransferColumnType(
                base: .decimal,
                precision: 20,
                scale: 0,
                native: mapping.type.native
            )
            mapping.conversion = .unsignedToDecimalText
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: "decimal(20,0)",
                    reason: String(localized: "The target has no unsigned 64-bit integer, so values are stored as an exact decimal.")
                )
            )
        default:
            return
        }
    }

    /// PostgreSQL is the only supported vendor with a real interval type.
    private func applyInterval(
        _ mapping: inout Mapping,
        table: String,
        column: PluginColumnInfo,
        target: TransferVendor
    ) {
        guard mapping.type.base == .interval, target != .postgresql else { return }
        mapping.type = mapping.type.with(base: .int64)
        mapping.warnings.append(
            .typeLossy(
                table: table,
                column: column.name,
                from: column.dataType,
                to: "bigint",
                reason: String(localized: "The target has no interval type, so values are stored as a number of seconds.")
            )
        )
    }

    private func applyLossyNotes(
        _ mapping: inout Mapping,
        table: String,
        column: PluginColumnInfo,
        source: TransferVendor,
        target: TransferVendor
    ) {
        let native = mapping.type.native.lowercased()

        if mapping.type.base == .enumeration, target != .mysql {
            let reason = options.mysqlEnumAs == .check
                ? String(localized: "The allowed value list is not carried as a CHECK constraint yet.")
                : String(localized: "The column becomes free text and no longer restricts its values.")
            mapping.warnings.append(
                .typeLossy(table: table, column: column.name, from: column.dataType, to: "varchar", reason: reason)
            )
        }

        if mapping.type.base == .set, target != .mysql {
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: "text",
                    reason: String(localized: "The target has no SET type, so membership is no longer enforced.")
                )
            )
        }

        if mapping.type.base == .json, target == .sqlite || target == .mssql {
            if mapping.conversion == nil { mapping.conversion = .jsonValidate }
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: "text",
                    reason: String(localized: "The target stores JSON as text and cannot index inside the document.")
                )
            )
        }

        if source == .mysql, native.hasPrefix("year"), target != .mysql {
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: "smallint",
                    reason: String(localized: "The target does not range check year values.")
                )
            )
        }

        if mapping.type.base == .timestampTZ {
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: target == .mysql ? "timestamp" : "timestamptz",
                    reason: target == .mysql
                        ? String(localized: "MySQL only stores timestamps from 1970 to 2038. Values outside that range fail on write.")
                        : String(localized: "The two engines resolve time zones differently, so stored instants can shift.")
                )
            )
        }

        if mapping.type.base == .decimal, mapping.type.precision == nil, target == .mysql {
            mapping.warnings.append(
                .typeLossy(
                    table: table,
                    column: column.name,
                    from: column.dataType,
                    to: "decimal(65,30)",
                    reason: String(localized: "MySQL requires a fixed precision, so the widest supported one is used.")
                )
            )
        }
    }

    /// MySQL and SQLite hand a boolean back as 0 or 1; PostgreSQL and SQL Server
    /// expect a real boolean. Only a crossing between the two needs a value
    /// conversion.
    private func applyBoolRepresentation(
        _ mapping: inout Mapping,
        source: TransferVendor,
        target: TransferVendor
    ) {
        guard mapping.type.base == .bool, source.hasNativeBool != target.hasNativeBool else { return }
        mapping.conversion = target.hasNativeBool ? .intToBool : .boolToInt
    }

    /// MySQL accepts `0000-00-00`, which no other engine will store.
    private func applyZeroDate(
        _ mapping: inout Mapping,
        column: PluginColumnInfo,
        source: TransferVendor,
        target: TransferVendor
    ) {
        guard source == .mysql, target != .mysql else { return }
        switch mapping.type.base {
        case .date, .timestamp, .timestampTZ:
            break
        default:
            return
        }

        guard options.zeroDateAsNull, column.isNullable else {
            mapping.conversion = .zeroDateToSentinel("1970-01-01 00:00:00")
            return
        }
        mapping.conversion = .zeroDateToNull
    }
}

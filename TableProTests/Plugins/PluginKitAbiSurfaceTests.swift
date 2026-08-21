//
//  PluginKitAbiSurfaceTests.swift
//  TableProTests
//
//  Locks the v19 PluginKit public surface so an ABI change is a red test, not a
//  plugin that compiles, ships, and then fails to load with "Bundle failed to
//  load executable". Two shipped incidents motivate this file: 0.49.0 added a
//  defaulted parameter to an existing public init and took down every registry
//  plugin, and #1917 removed a defaulted requirement that shipped plugins still
//  hard-referenced. Neither was caught by a compiler.
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("PluginKit ABI surface")
struct PluginKitAbiSurfaceTests {
    // MARK: - Existing initializer signatures
    //
    // Each of these binds an unapplied initializer reference to an explicit
    // function type. Overload resolution then has to find an init whose arity
    // and parameter types match exactly. Adding a parameter to the existing
    // init, even with a default value, replaces its mangled symbol and breaks
    // every already-built plugin; the correct move is a new overload, which
    // leaves the reference below still resolvable.

    @Test("PluginColumnInfo keeps its v19 12-parameter initializer")
    func columnInfoInitSignatureUnchanged() {
        let make: (
            String, String, Bool, Bool, String?, String?, String?, String?, String?, IdentityKind?, Bool, [String]?
        ) -> PluginColumnInfo = PluginColumnInfo.init

        let column = make("id", "INTEGER", false, true, nil, nil, nil, nil, nil, nil, false, nil)
        #expect(column.name == "id")
        #expect(column.dataType == "INTEGER")
        #expect(column.isPrimaryKey)
    }

    @Test("PluginColumnInfo v19 initializer accepts every parameter by label")
    func columnInfoInitAcceptsAllLabels() {
        let column = PluginColumnInfo(
            name: "status",
            dataType: "ENUM",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: "'active'",
            extra: "on update",
            charset: "utf8mb4",
            collation: "utf8mb4_general_ci",
            comment: "row status",
            identityKind: .byDefault,
            isGenerated: false,
            allowedValues: ["active", "inactive"]
        )
        #expect(column.identityKind == .byDefault)
        #expect(column.isIdentity)
        #expect(column.allowedValues == ["active", "inactive"])
    }

    @Test("PluginForeignKeyInfo keeps its v19 7-parameter initializer")
    func foreignKeyInitSignatureUnchanged() {
        let make: (String, String, String, String, String?, String, String) -> PluginForeignKeyInfo =
            PluginForeignKeyInfo.init

        let key = make("fk_orders_user", "user_id", "users", "id", nil, "CASCADE", "NO ACTION")
        #expect(key.column == "user_id")
        #expect(key.referencedColumn == "id")
        #expect(key.onDelete == "CASCADE")
    }

    @Test("PluginForeignKeyInfo v19 initializer accepts every parameter by label")
    func foreignKeyInitAcceptsAllLabels() {
        let key = PluginForeignKeyInfo(
            name: "fk_orders_user",
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id",
            referencedSchema: "public",
            onDelete: "CASCADE",
            onUpdate: "RESTRICT"
        )
        #expect(key.referencedSchema == "public")
        #expect(key.onUpdate == "RESTRICT")
    }

    // MARK: - PluginCellValue exhaustiveness canary
    //
    // This switch carries no `default:` on purpose. While PluginCellValue is
    // @frozen it is a hard compile error the moment a case is added, which is a
    // single deliberate place saying "the 38-site switch audit is now required"
    // instead of discovering that across the tree. Once @frozen is dropped the
    // compiler downgrades this to a warning, so `expectedCaseCount` below backs
    // it with a runtime assertion that still fails loudly.

    private func canaryLabel(for value: PluginCellValue) -> String {
        switch value {
        case .null: "null"
        case .text: "text"
        case .bytes: "bytes"
        case .int: "int"
        case .double: "double"
        case .decimalText: "decimalText"
        case .bool: "bool"
        case .date: "date"
        case .time: "time"
        case .timestamp: "timestamp"
        case .uuid: "uuid"
        case .array: "array"
        }
    }

    @Test("Every PluginCellValue case is accounted for by the canary")
    func cellValueCanaryCoversEveryCase() {
        let cases: [(PluginCellValue, String)] = [
            (.null, "null"),
            (.text("hello"), "text"),
            (.bytes(Data([0xDE, 0xAD])), "bytes"),
            (.int(7), "int"),
            (.double(1.5), "double"),
            (.decimalText("1.10"), "decimalText"),
            (.bool(true), "bool"),
            (.date(year: 2_026, month: 8, day: 16), "date"),
            (.time(seconds: 3_661, nanoseconds: 0), "time"),
            (.timestamp(Date(timeIntervalSince1970: 0)), "timestamp"),
            (.uuid(UUID()), "uuid"),
            (.array([.int(1)]), "array"),
        ]

        #expect(cases.count == PluginCellValueCanary.expectedCaseCount)
        for (value, label) in cases {
            #expect(canaryLabel(for: value) == label)
        }
    }

    // MARK: - Codable kind tags

    @Test("PluginCellValue Codable round-trips every case")
    func cellValueCodableKindTagsUnchanged() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let values: [PluginCellValue] = [
            .null, .text("hello"), .bytes(Data([0x01, 0x02])),
            .int(-9_223_372_036_854_775_808), .double(1.5), .decimalText("1.10"), .bool(false),
            .date(year: 2_026, month: 8, day: 16), .time(seconds: 3_661, nanoseconds: 500_000),
            .timestamp(Date(timeIntervalSince1970: 1_755_000_000)),
            .uuid(UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301") ?? UUID()),
            .array([.int(1), .text("x"), .null]),
        ]

        #expect(values.count == PluginCellValueCanary.expectedCaseCount)
        for value in values {
            let decoded = try decoder.decode(PluginCellValue.self, from: encoder.encode(value))
            #expect(decoded == value)
        }
    }

    @Test("PluginCellValue decodes the v19 wire tags verbatim")
    func cellValueDecodesV19WireTags() throws {
        let decoder = JSONDecoder()
        let nullValue = try decoder.decode(PluginCellValue.self, from: Data(#"{"kind":"null"}"#.utf8))
        let textValue = try decoder.decode(PluginCellValue.self, from: Data(#"{"kind":"text","value":"hi"}"#.utf8))

        #expect(nullValue == .null)
        #expect(textValue == .text("hi"))
    }

    // MARK: - Capability bits

    @Test("PluginCapabilities occupies bits 0 through 12 with no gaps or collisions")
    func capabilityBitsAreContiguousAndDistinct() {
        let declared: [PluginCapabilities] = [
            .materializedViews, .foreignTables, .storedProcedures, .userFunctions,
            .alterTableDDL, .foreignKeyToggle, .truncateTable, .multiSchema,
            .parameterizedQueries, .cancelQuery, .batchExecute, .transactions,
            .userManagement,
        ]

        #expect(Set(declared.map(\.rawValue)).count == declared.count)
        for (index, capability) in declared.enumerated() {
            #expect(capability.rawValue == UInt32(1) << UInt32(index))
        }
    }

    // MARK: - Version gate constants
    //
    // Phase 4 flips both of these to 20. They move together: a v19 plugin is ABI
    // incompatible with a v20 PluginKit, so raising `current` without raising
    // `minimumCompatible` would admit a stale binary instead of refusing it.

    @Test("PluginKit version constants are pinned at 20")
    @MainActor
    func pluginKitVersionConstantsPinned() {
        #expect(PluginManager.currentPluginKitVersion == 20)
        #expect(PluginManager.minimumCompatiblePluginKitVersion == 20)
        #expect(PluginManager.currentInspectorKitVersion == 1)
    }

    @Test("The shipping gate is built from the shipping constants")
    @MainActor
    func shippingGateMatchesConstants() {
        let gate = PluginManager.bundleVersionGate
        #expect(gate.currentPluginKit == PluginManager.currentPluginKitVersion)
        #expect(gate.minimumCompatiblePluginKit == PluginManager.minimumCompatiblePluginKitVersion)
        #expect(gate.currentInspectorKit == PluginManager.currentInspectorKitVersion)
    }
}

/// The load gate is the difference between a stale plugin producing a legible
/// "outdated" message and an `EXC_BAD_INSTRUCTION` in a user's app, so it is
/// tested against synthesized declarations rather than through a bundle on disk.
@Suite("Plugin bundle version gate")
struct PluginBundleVersionGateTests {
    private let gate = PluginBundleVersionGate(
        currentPluginKit: 20,
        minimumCompatiblePluginKit: 20,
        currentInspectorKit: 1
    )

    private func validate(pluginKit: Int?, inspectorKit: Int? = nil) throws {
        try gate.validate(
            declaredPluginKit: pluginKit,
            declaredInspectorKit: inspectorKit,
            minimumAppVersion: nil,
            appVersion: "99.0.0"
        )
    }

    @Test("A v20 plugin loads")
    func currentVersionPasses() throws {
        try validate(pluginKit: 20)
    }

    @Test("A v19 plugin is refused as outdated, not as a crash")
    func staleVersionIsOutdated() {
        #expect(throws: PluginError.self) { try validate(pluginKit: 19) }

        do {
            try validate(pluginKit: 19)
            Issue.record("expected a v19 plugin to be refused")
        } catch let error as PluginError {
            #expect(error.isOutdated)
            guard case .pluginOutdated(let pluginVersion, let requiredVersion) = error else {
                Issue.record("expected pluginOutdated, got \(error)")
                return
            }
            #expect(pluginVersion == 19)
            #expect(requiredVersion == 20)
        } catch {
            Issue.record("expected PluginError, got \(error)")
        }
    }

    @Test("A future v21 plugin is refused as incompatible, not as outdated")
    func futureVersionIsIncompatible() {
        do {
            try validate(pluginKit: 21)
            Issue.record("expected a v21 plugin to be refused")
        } catch let error as PluginError {
            guard case .incompatibleVersion(let required, let current) = error else {
                Issue.record("expected incompatibleVersion, got \(error)")
                return
            }
            #expect(required == 21)
            #expect(current == 20)
        } catch {
            Issue.record("expected PluginError, got \(error)")
        }
    }

    @Test("A bundle declaring neither framework version is refused")
    func missingBothKeysIsRefused() {
        do {
            try validate(pluginKit: nil, inspectorKit: nil)
            Issue.record("expected a bundle with no declared versions to be refused")
        } catch let error as PluginError {
            #expect(error.isOutdated)
        } catch {
            Issue.record("expected PluginError, got \(error)")
        }
    }

    @Test("An inspector-only bundle at the current version loads")
    func inspectorOnlyBundlePasses() throws {
        try validate(pluginKit: nil, inspectorKit: 1)
    }

    @Test("An inspector-only bundle at a stale version is refused")
    func staleInspectorIsRefused() {
        #expect(throws: PluginError.self) { try validate(pluginKit: nil, inspectorKit: 0) }
    }

    @Test("A plugin requiring a newer app is refused with the app version error")
    func appVersionTooOldIsRefused() {
        do {
            try gate.validate(
                declaredPluginKit: 20,
                declaredInspectorKit: nil,
                minimumAppVersion: "2.0.0",
                appVersion: "1.9.0"
            )
            Issue.record("expected an app-version refusal")
        } catch let error as PluginError {
            guard case .appVersionTooOld(let minimumRequired, let currentApp) = error else {
                Issue.record("expected appVersionTooOld, got \(error)")
                return
            }
            #expect(minimumRequired == "2.0.0")
            #expect(currentApp == "1.9.0")
        } catch {
            Issue.record("expected PluginError, got \(error)")
        }
    }
}

/// Case count for `PluginCellValue`, asserted by the exhaustiveness canary.
/// Bumped deliberately alongside any case addition so the canary keeps failing
/// loudly after `@frozen` is dropped and the compiler stops erroring.
enum PluginCellValueCanary {
    static let expectedCaseCount = 12
}

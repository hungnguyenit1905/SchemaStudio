//
//  DiagnosticEventFactoryTests.swift
//  TableProTests
//

import Foundation
import TableProDiagnostics
import Testing

@testable import SchemaStudio

@Suite("DiagnosticEventFactory")
struct DiagnosticEventFactoryTests {
    @Test("Drops the driver message and keeps only the case name")
    func dropsAssociatedValues() {
        let error = DatabaseError.connectionFailed(
            "connection to server at \"10.0.0.4\", port 5432 failed: password authentication failed for user \"admin\""
        )
        let event = DiagnosticEventFactory.connectFailed(type: .postgresql, error: error)

        #expect(event.tags[.errorCase] == "connectionFailed")
        #expect(event.tags[.databaseType] == "postgresql")
        #expect(event.tags.values.contains { $0.contains("admin") } == false)
        #expect(event.tags.values.contains { $0.contains("10.0.0.4") } == false)
    }

    @Test("Folds display names into a valid tag, so no type is reported as invalid")
    func slugsEveryKnownDatabaseType() {
        for type in DatabaseType.allKnownTypes {
            let slug = DiagnosticEventFactory.slug(for: type)
            #expect(
                DiagnosticTagValueSanitizer.isValid(slug, for: .databaseType),
                "\(type.rawValue) produced an invalid slug: \(slug)"
            )
        }

        #expect(DiagnosticEventFactory.slug(for: .mssql) == "sql_server")
        #expect(DiagnosticEventFactory.slug(for: .cloudflareD1) == "cloudflare_d1")
        #expect(DiagnosticEventFactory.slug(for: .postgresql) == "postgresql")
    }

    @Test("Maps every error family the chokepoints can see")
    func mapsErrorFamilies() {
        #expect(DiagnosticEventFactory.errorCase(for: CancellationError()) == "cancelled")
        #expect(DiagnosticEventFactory.errorCase(for: DatabaseError.notConnected) == "notConnected")
        #expect(DiagnosticEventFactory.errorCase(for: PluginError.checksumMismatch) == "checksumMismatch")
        #expect(DiagnosticEventFactory.errorCase(for: TransferError.sameEndpoint) == "sameEndpoint")
        #expect(DiagnosticEventFactory.errorCase(for: URLError(.timedOut)) == "unknown")
    }

    @Test("Every mapped case name is itself a valid tag value")
    func caseNamesAreValidTags() {
        let errors: [Error] = [
            DatabaseError.connectionFailed("x"),
            DatabaseError.queryFailed("x"),
            DatabaseError.invalidCredentials,
            DatabaseError.fileNotFound("x"),
            DatabaseError.notConnected,
            DatabaseError.unsupportedOperation,
            PluginError.invalidBundle("x"),
            PluginError.signatureInvalid(detail: "x"),
            PluginError.incompatibleVersion(required: 1, current: 2),
            PluginError.installFailed("x"),
            TransferError.noTablesSelected,
            TransferError.targetColumnsMissing(table: "customers", columns: ["email"]),
            TransferError.blockingForeignKeys(table: "orders", references: ["customers"])
        ]

        for error in errors {
            let name = DiagnosticEventFactory.errorCase(for: error)
            #expect(DiagnosticTagValueSanitizer.isValid(name, for: .errorCase), "\(name) is not a valid tag")
        }
    }

    @Test("A plugin bundle ID survives, an unknown one is replaced")
    func pluginIdTagging() {
        let good = DiagnosticEventFactory.pluginLoadFailed(
            bundleId: "com.TablePro.MySQLDriver",
            error: PluginError.checksumMismatch
        )
        #expect(good.tags[.pluginId] == "com.TablePro.MySQLDriver")

        let foreign = DiagnosticEventFactory.pluginLoadFailed(
            bundleId: "db.internal",
            error: PluginError.checksumMismatch
        )
        #expect(foreign.tags[.pluginId] == DiagnosticTagValueSanitizer.placeholder)

        let missing = DiagnosticEventFactory.pluginLoadFailed(
            bundleId: nil,
            error: PluginError.notFound
        )
        #expect(missing.tags[.pluginId] == nil)
    }

    @Test("Reconnect reporting carries the attempt number as digits")
    func reconnectTagging() {
        let event = DiagnosticEventFactory.reconnectStillFailing(attempt: 5)

        #expect(event.tags[.attemptCount] == "5")
        #expect(event.level == .warning)
    }
}
